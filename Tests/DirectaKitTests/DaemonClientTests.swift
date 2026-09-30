import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaKit

/** The response-deadline clamp exists because the value flows from a
    caller-supplied `--timeout`, and `Int(Double)` traps on a non-finite or
    out-of-range input. Before the clamp, `directa ensure --timeout inf` crashed
    the process with a runtime trap instead of running. */
@Suite struct DaemonClientTimeoutTests {
    @Test func infiniteAndNaNDegradeToTheDefault() {
        #expect(DaemonClient.clampedResponseTimeout(.infinity) == 120)
        #expect(DaemonClient.clampedResponseTimeout(-.infinity) == 120)
        #expect(DaemonClient.clampedResponseTimeout(.nan) == 120)
    }

    @Test func finiteValuesPassThroughWithinRange() {
        #expect(DaemonClient.clampedResponseTimeout(30) == 30)
        #expect(DaemonClient.clampedResponseTimeout(0.25) == 0.25)
    }

    @Test func outOfRangeValuesClampToTheEdges() {
        /** Zero or a negative deadline floors at one millisecond, since a zero
            `SO_RCVTIMEO` means no deadline at all. A value past a day is far
            beyond any real deadline and would risk the Int conversion, so it
            caps rather than overflows. */
        #expect(DaemonClient.clampedResponseTimeout(0) == 0.001)
        #expect(DaemonClient.clampedResponseTimeout(-5) == 0.001)
        #expect(DaemonClient.clampedResponseTimeout(1_000_000_000) == 86_400)
    }
}

/** A daemon socket that nothing accepts on: the kernel completes each
    connect from the backlog, so no hello is ever sent. */
private final class SilentDaemonSocket: Sendable {
    let path: String
    private let listener: Int32

    init(backlog: Int32) throws {
        path = "/tmp/directa-dc-\(UUID().uuidString.prefix(8)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listener >= 0, bound == 0, listen(listener, backlog) == 0 else {
            throw WireError(code: .internalError, message: "test listener failed: \(String(cString: strerror(errno)))")
        }
    }

    deinit {
        close(listener)
        unlink(path)
    }
}

/** An explicit response deadline bounds the whole request, the hello read
    included, so a daemon that accepts and never answers releases the caller
    at that deadline rather than the default one. */
@Suite struct DaemonClientResponseDeadlineTests {
    @Test func anExplicitDeadlineEndsAWaitOnASilentDaemon() async throws {
        let daemon = try SilentDaemonSocket(backlog: 4)
        let client = DaemonClient(socketPath: daemon.path)
        let started = ContinuousClock.now
        let failure = try await #require(throws: WireError.self) {
            _ = try await client.request(
                .daemonInfo, params: WireEmpty(), expecting: WireEmpty.self, responseTimeoutSeconds: 0.3)
        }
        #expect(failure.code == .daemonUnreachable)
        #expect(failure.message == "the daemon did not answer in time; it may be wedged")
        #expect(started.duration(to: .now) < .seconds(10))
    }

    /** Clients waiting on a daemon that never answers wait off the
        cooperative pool: with twice as many of them as the pool has threads,
        a trivial task submitted after all of them still runs while they
        wait. Nothing answers, so they can only finish at their deadline: the
        task counts how many had finished when it ran, and any nonzero count
        means it waited for them to give pool threads back. Measured from a
        thread of its own, since the test body runs on the pool it measures. */
    @Test func clientsWaitingOnASilentDaemonLeaveTheCooperativePoolFree() async throws {
        let callers = ProcessInfo.processInfo.activeProcessorCount * 2
        let daemon = try SilentDaemonSocket(backlog: Int32(callers * 2))
        let deadline = 3.0
        let finished = OSAllocatedUnfairLock(initialState: 0)
        let finishedWhenTaskRan = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let path = daemon.path
        let calls = (0..<callers).map { _ in
            Task.detached {
                let client = DaemonClient(socketPath: path)
                let answer = try? await client.request(
                    .daemonInfo, params: WireEmpty(), expecting: WireEmpty.self, responseTimeoutSeconds: deadline)
                finished.withLock { $0 += 1 }
                return answer
            }
        }
        await offPool {
            let ran = DispatchSemaphore(value: 0)
            Task.detached {
                finishedWhenTaskRan.withLock { $0 = finished.withLock { $0 } }
                ran.signal()
            }
            _ = ran.wait(timeout: .now() + deadline * 4)
        }
        for call in calls {
            #expect(await call.value == nil)
        }
        let seen = finishedWhenTaskRan.withLock { $0 }
        #expect(
            seen == 0,
            "a trivial task ran only after \(seen.map(String.init) ?? "none") of \(callers) waiting clients had given up")
    }
}

/** A unix-socket listener that plays one scripted daemon connection per
    `serve` call: accept, send hello with the given version, read `requests`
    requests (answering each with an empty ok result unless `answering` is
    false), then close. Stands in for a
    daemon that dies and comes back, which is what a long-lived client (the
    monitor loop) must survive. */
private final class ScriptedDaemonSocket: Sendable {
    let path: String
    private let listener: Int32

    init() throws {
        path = "/tmp/directa-dc-\(UUID().uuidString.prefix(8)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listener >= 0, bound == 0, listen(listener, 4) == 0 else {
            throw WireError(code: .internalError, message: "test listener failed: \(String(cString: strerror(errno)))")
        }
    }

    deinit {
        close(listener)
        unlink(path)
    }

    /** Runs one connection on a background thread (accept and read block, so
        they stay off the cooperative pool); the returned stream finishes once
        the server side has closed the connection. */
    func serve(daemonVersion: String, requests: Int, answering: Bool = true) -> AsyncStream<Void> {
        let (done, finish) = AsyncStream<Void>.makeStream()
        let listener = listener
        Thread {
            defer { finish.finish() }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { close(connection) }
            Self.send(
                WireEvent(event: "hello", params: HelloParams(daemonVersion: daemonVersion, proto: DirectaVersion.proto)),
                to: connection)
            var buffer = NDJSONBuffer()
            var lines: [Data] = []
            var scratch = [UInt8](repeating: 0, count: 4096)
            var remaining = requests
            while remaining > 0 {
                if lines.isEmpty {
                    let n = read(connection, &scratch, scratch.count)
                    guard n > 0 else { return }
                    lines += buffer.feed(Data(scratch[0..<n]))
                    continue
                }
                let line = lines.removeFirst()
                guard let head = try? JSONCoding.decoder().decode(WireRequestHead.self, from: line) else { return }
                if answering {
                    Self.send(WireResponse(id: head.id, ok: true, result: WireEmpty()), to: connection)
                }
                remaining -= 1
            }
        }.start()
        return done
    }

    private static func send<T: Encodable>(_ frame: T, to connection: Int32) {
        guard let data = try? NDJSON.encodeLine(frame) else { return }
        _ = data.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
    }
}

/** A client that outlives one daemon connection reconnects on the next
    request, re-reading hello, after any socket failure: the daemon closing
    mid-request (a read that hits end of file) and a write into a connection
    the daemon already closed (EPIPE). */
@Suite struct DaemonClientReconnectTests {
    private func info(_ client: DaemonClient) async throws {
        _ = try await client.request(.daemonInfo, params: WireEmpty(), expecting: WireEmpty.self)
    }

    private func closed(_ connection: AsyncStream<Void>) async {
        for await _ in connection {}
    }

    @Test func aReadThatHitsEndOfFileReconnectsOnTheNextRequest() async throws {
        let server = try ScriptedDaemonSocket()
        let client = DaemonClient(socketPath: server.path)

        let first = server.serve(daemonVersion: "1.0.0", requests: 1, answering: false)
        await #expect(throws: WireError(code: .daemonUnreachable, message: "daemon closed the connection")) {
            try await info(client)
        }
        await closed(first)

        let second = server.serve(daemonVersion: "2.0.0", requests: 1)
        try await info(client)
        #expect(await client.hello == HelloParams(daemonVersion: "2.0.0", proto: DirectaVersion.proto))
        await closed(second)
    }

    @Test func aWriteIntoAClosedConnectionReconnectsOnTheNextRequest() async throws {
        let server = try ScriptedDaemonSocket()
        let client = DaemonClient(socketPath: server.path)

        let first = server.serve(daemonVersion: "1.0.0", requests: 1)
        try await info(client)
        await closed(first)

        let failure = try await #require(throws: WireError.self) { try await info(client) }
        #expect(failure.code == .daemonUnreachable)

        let second = server.serve(daemonVersion: "2.0.0", requests: 1)
        try await info(client)
        #expect(await client.hello == HelloParams(daemonVersion: "2.0.0", proto: DirectaVersion.proto))
        await closed(second)
    }
}
