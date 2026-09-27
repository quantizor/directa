import Foundation
import Testing

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

/** An explicit response deadline bounds the whole request, the hello read
    included, so a daemon that accepts and never answers releases the caller
    at that deadline rather than the default one. */
@Suite struct DaemonClientResponseDeadlineTests {
    @Test func anExplicitDeadlineEndsAWaitOnASilentDaemon() async throws {
        let path = "/tmp/directa-dc-\(UUID().uuidString.prefix(8)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer {
            close(listener)
            unlink(path)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(listener >= 0 && bound == 0 && listen(listener, 4) == 0)
        /** The kernel completes the connect from the backlog; nothing ever
            accepts, so no hello is ever sent. */
        let client = DaemonClient(socketPath: path)
        let started = ContinuousClock.now
        let failure = try await #require(throws: WireError.self) {
            _ = try await client.request(
                .daemonInfo, params: WireEmpty(), expecting: WireEmpty.self, responseTimeoutSeconds: 0.3)
        }
        #expect(failure.code == .daemonUnreachable)
        #expect(failure.message == "the daemon did not answer in time; it may be wedged")
        #expect(started.duration(to: .now) < .seconds(10))
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
