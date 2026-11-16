import Darwin
import DirectaKit
import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

/** A `wait` started in the background, so a test can tell parked from
    answered without sleeping: `result` stays nil until the wait returns. */
private final class ParkedWait: Sendable {
    private let answer = OSAllocatedUnfairLock<AwaitChangeResult?>(initialState: nil)

    init(_ signal: StatusChangeSignal, after: String?, timeoutSeconds: Double = 30) {
        let answer = answer
        Task {
            let result = await signal.wait(after: after, timeoutSeconds: timeoutSeconds)
            answer.withLock { $0 = result }
        }
    }

    var result: AwaitChangeResult? { answer.withLock { $0 } }

    func settles(within limit: Duration = .seconds(5)) async throws -> AwaitChangeResult? {
        try await firstAnswer(within: limit) { result }
    }

    func staysParked(for window: Duration = .milliseconds(300)) async throws -> Bool {
        try await !eventually(within: window) { result != nil }
    }
}

/** The generation half of a token, for a test that asserts how many times a
    source bumped. Tokens are opaque to clients; only tests read this. */
private func generation(of token: String) throws -> UInt64 {
    try #require(token.split(separator: "-").last.flatMap { UInt64($0) })
}

struct StatusChangeSignalTests {
    @Test func eachSignalHasItsOwnBootIdSoARestartedDaemonNeverAcceptsAStaleToken() {
        #expect(StatusChangeSignal().token != StatusChangeSignal().token)
    }

    @Test func aWaitParksOnlyOnTheCurrentToken() async throws {
        let signal = StatusChangeSignal()
        let before = signal.token
        let parked = ParkedWait(signal, after: before)
        #expect(try await parked.staysParked())

        signal.bump()
        let released = try #require(try await parked.settles())
        #expect(released.changed)
        #expect(released.token == signal.token)
        #expect(released.token != before)
    }

    @Test func everyOtherTokenAnswersAtOnceWithTheCurrentOne() async throws {
        let signal = StatusChangeSignal()
        let stale = signal.token
        signal.bump()
        let current = signal.token
        let boot = stale.split(separator: "-").dropLast().joined(separator: "-")
        let ahead = "\(boot)-\(try generation(of: current) + 1)"
        let expected = AwaitChangeResult(changed: true, token: current)

        for other in [nil, stale, ahead, "1-2-\(try generation(of: current))", "garbage", ""] {
            #expect(await signal.wait(after: other, timeoutSeconds: 30) == expected, "after: \(other ?? "nil")")
        }
    }

    @Test func aBumpReleasesEveryParkedWaiter() async throws {
        let signal = StatusChangeSignal()
        let token = signal.token
        let waiters = (0..<3).map { _ in ParkedWait(signal, after: token) }
        for waiter in waiters {
            #expect(try await waiter.staysParked(for: .milliseconds(50)))
        }

        signal.bump()
        for waiter in waiters {
            #expect(try await waiter.settles() == AwaitChangeResult(changed: true, token: signal.token))
        }
    }

    @Test func theDeadlineAnswersNotChangedWithTheSameToken() async throws {
        let signal = StatusChangeSignal()
        let token = signal.token
        let answered = await signal.wait(after: token, timeoutSeconds: 0.2)
        #expect(answered == AwaitChangeResult(changed: false, token: token))
        #expect(signal.token == token)
    }

    @Test func aBumpAfterADeadlineStillMovesTheToken() async throws {
        let signal = StatusChangeSignal()
        let token = signal.token
        _ = await signal.wait(after: token, timeoutSeconds: 0.05)
        signal.bump()
        #expect(await signal.wait(after: token, timeoutSeconds: 30).changed)
    }

    @Test func wireTimeoutsClampToTheCapWithoutTrapping() {
        #expect(StatusChangeSignal.clampedWaitSeconds(1e30) == 60)
        #expect(StatusChangeSignal.clampedWaitSeconds(61) == 60)
        #expect(StatusChangeSignal.clampedWaitSeconds(25) == 25)
        #expect(StatusChangeSignal.clampedWaitSeconds(-5) == 0)
    }
}

@Suite(.temporaryTree) struct StatusChangeSourceTests {
    @Test func aPostedEventIsReadableByTheTimeItReleasesAParkedWait() async throws {
        let store = EventStore(url: try TemporaryTree.directory(named: "changes").appending(path: "events.log"))
        let parked = ParkedWait(store.changes, after: store.changes.token)
        #expect(try await parked.staysParked(for: .milliseconds(100)))

        await store.post(kind: .started, project: "/p", server: "web", detail: "pid 1")
        _ = try #require(try await parked.settles())
        #expect(await store.query().map(\.server) == ["web"])
    }

    private func supervisor(
        _ env: RouterEnv, events: EventStore, command: [String], port: Int? = nil,
        listeningPorts: (@Sendable ([pid_t]) async -> [Int])? = nil
    ) -> ServerSupervisor {
        let spec = ServerSpec(
            command: command,
            healthcheck: port.map {
                HealthCheckSpec(healthyAfter: 1, intervalMs: 30, port: $0, timeoutMs: 500, type: .tcp, unhealthyAfter: 3)
            },
            name: "web", port: port)
        guard let listeningPorts else {
            return ServerSupervisor(
                events: events, launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.project,
                registry: Registry(paths: env.paths), spec: spec)
        }
        return ServerSupervisor(
            events: events, launcher: SubprocessLauncher(), listeningPorts: listeningPorts, paths: env.paths,
            projectPath: env.project, registry: Registry(paths: env.paths), spec: spec)
    }

    /** `.stopping` posts no event (the stopped event comes when the process is
        gone), so only the phase's own bump can release this wait. A server
        that ignores SIGTERM holds the phase there until the grace window
        ends. */
    @Test func aPhaseTransitionThatPostsNoEventStillReleasesAParkedWait() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let port = TestPorts.port(727)
        let env = try makeRouterEnv(named: "changes-stopping")
        let events = EventStore(url: env.paths.eventsFile)
        let supervisor = supervisor(
            env, events: events, command: [fixture, "--ignore-sigterm", "--listen-tcp", "\(port)"], port: port)
        _ = await supervisor.start()
        let settled = try await eventually(within: .seconds(15)) { await supervisor.status().observedPort == port }
        try #require(settled, "the server never reported its port")
        let eventsBefore = await events.query()

        let parked = ParkedWait(events.changes, after: events.changes.token)
        let stop = Task { await supervisor.stop(graceSeconds: 1, reason: "test stop") }
        let released = try await parked.settles(within: .seconds(2))
        let phase = await supervisor.status().phase
        let eventsDuring = await events.query()
        _ = await stop.value

        #expect(released?.changed == true)
        #expect(phase == .stopping)
        #expect(eventsDuring == eventsBefore)
    }

    /** The scan that finds a server's first port runs after the healthy event
        is written. It is held on a latch so the wait is parked before the port
        arrives, and no event follows it, so only `recordObservedPort`'s bump
        can release the wait. */
    @Test func aFirstObservedPortReleasesAParkedWaitWithNoNewEvent() async throws {
        let env = try makeRouterEnv(named: "changes-first-port")
        let events = EventStore(url: env.paths.eventsFile)
        let scanned = Latch<Void>()
        let port = TestPorts.port(728)
        let supervisor = supervisor(
            env, events: events, command: ["/bin/sh", "-c", "sleep 30"],
            listeningPorts: { _ in
                await scanned.wait()
                return [port]
            })
        _ = await supervisor.start()
        defer { scanned.open() }
        let healthy = try await eventually(within: .seconds(15)) {
            let kinds = await events.query().map(\.kind)
            return await supervisor.status().phase == .running && kinds.contains(.healthy)
        }
        try #require(healthy, "the server never reported healthy")
        #expect(await supervisor.status().observedPort == nil)
        let eventsBefore = await events.query()

        let parked = ParkedWait(events.changes, after: events.changes.token)
        #expect(try await parked.staysParked(for: .milliseconds(200)))
        scanned.open()
        let released = try await parked.settles(within: .seconds(5))

        #expect(released?.changed == true)
        #expect(await supervisor.status().observedPort == port)
        #expect(await events.query() == eventsBefore)
        _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
    }

    @Test func aPhaseTransitionMovesTheTokenAndAStoppedServerStoppingAgainDoesNot() async throws {
        let env = try makeRouterEnv(named: "changes-phase")
        let events = EventStore(url: env.paths.eventsFile)
        let supervisor = supervisor(env, events: events, command: ["/bin/sh", "-c", "sleep 30"])

        let idle = events.changes.token
        _ = await supervisor.status()
        _ = await supervisor.stop(graceSeconds: 1, reason: "already stopped")
        #expect(events.changes.token == idle, "a stopped server stopping again changed nothing a client renders")

        _ = await supervisor.start()
        #expect(events.changes.token != idle)
        _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
    }

    @Test func aPortThatStaysTheSameBumpsOnlyOnce() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let port = TestPorts.port(721)
        let env = try makeRouterEnv(named: "changes-port-once")
        let events = EventStore(url: env.paths.eventsFile)
        let supervisor = supervisor(
            env, events: events, command: [fixture, "--listen-tcp", "\(port)"], port: port)
        _ = await supervisor.start()
        let settled = try await eventually(within: .seconds(15)) {
            let status = await supervisor.status()
            return status.observedPort == port && status.lastHealthCheck != nil
        }
        try #require(settled)
        /** Health probes keep running; a repeat of the same port must move nothing. */
        let token = events.changes.token
        #expect(try await !eventually(within: .milliseconds(500)) { events.changes.token != token })
        _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
    }
}

@Suite(.serialized, .temporaryTree) struct AwaitChangeRouterTests {
    private func writeConfig(port: Int, project: String) throws {
        let fixture = try #require(fixtureServerExecutable())
        let body = """
            {
              "servers": {
                "db": {
                  "command": ["\(fixture)", "--listen-tcp", "\(port)"],
                  "healthcheck": { "type": "tcp", "port": \(port) },
                  "port": \(port)
                }
              },
              "version": 1
            }
            """
        try Data(body.utf8).write(to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
    }

    private func router(offset: Int) async throws -> (router: Router, env: RouterEnv, registry: Registry) {
        let env = try makeRouterEnv(named: "await-change")
        try writeConfig(port: TestPorts.port(offset), project: env.project)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        return (Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry), env, registry)
    }

    private func token(_ router: Router) async throws -> String {
        try await router.call(
            .serverAwaitChange, AwaitChangeParams(timeoutSeconds: 1), AwaitChangeResult.self
        ).token
    }

    @Test func startingAServerReleasesAParkedWait() async throws {
        let (router, env, _) = try await router(offset: 722)
        let first = try await token(router)
        async let parked = router.call(
            .serverAwaitChange, AwaitChangeParams(after: first, timeoutSeconds: 30), AwaitChangeResult.self)

        _ = try await router.call(
            .serverEnsure, EnsureParams(name: "db", project: env.project, timeoutSeconds: 10),
            EnsureResult.self)
        let released = try await parked
        #expect(released.changed)
        #expect(released.token != first)

        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
    }

    @Test func aMachineWideStatusReadOnAnIdleDaemonDoesNotMoveTheToken() async throws {
        let (router, env, _) = try await router(offset: 723)
        _ = try await router.call(
            .serverStatus, ProjectParams(project: env.project), ServerListResult.self)
        let first = try await token(router)

        for _ in 0..<3 {
            let list = try await router.call(
                .serverStatus, ProjectParams(project: ""), ServerListResult.self)
            #expect(list.servers.map(\.server) == ["db"])
        }
        let answered = try await router.call(
            .serverAwaitChange, AwaitChangeParams(after: first, timeoutSeconds: 0.3), AwaitChangeResult.self)
        #expect(answered == AwaitChangeResult(changed: false, token: first))
    }

    @Test func everyConfigArmMovesTheToken() async throws {
        let (router, env, registry) = try await router(offset: 724)

        var seen = try await token(router)
        func expectMoved(_ what: String) async throws {
            let now = try await token(router)
            #expect(now != seen, "\(what) left the token where it was")
            seen = now
        }

        _ = try await router.call(.projectTrust, ProjectOnlyParams(project: env.project), WireEmpty.self)
        try await expectMoved("project.trust")

        let content = try String(
            contentsOf: URL(fileURLWithPath: env.project).appending(path: "devservers.json"), encoding: .utf8)
        _ = try await router.call(
            .projectWriteConfig,
            WriteConfigParams(
                baselineHash: DirectaPaths.hash8(content), content: content, project: env.project),
            CheckResult.self)
        try await expectMoved("project.writeConfig")

        let fresh = try makeRouterEnv(named: "await-change-init").project
        _ = try await router.call(
            .projectInitConfig,
            InitConfigParams(
                fromDaemon: false, mode: .create, project: fresh,
                servers: [ServerSpec(command: ["/bin/true"], name: "web")]),
            InitConfigResult.self)
        try await expectMoved("project.initConfig")

        let gone = try makeRouterEnv(named: "await-change-forget").project
        try await registry.setTrusted(project: gone)
        try FileManager.default.removeItem(atPath: gone)
        _ = try await router.call(
            .projectForget, ProjectOnlyParams(project: gone), ProjectForgetResult.self)
        try await expectMoved("project.forget")
    }

    @Test func aNegativeTimeoutAnswersAtOnceAndAHugeOneStillReleasesOnABump() async throws {
        let (router, env, _) = try await router(offset: 725)
        let first = try await token(router)
        let immediate = try await router.call(
            .serverAwaitChange, AwaitChangeParams(after: first, timeoutSeconds: -5), AwaitChangeResult.self)
        #expect(immediate == AwaitChangeResult(changed: false, token: first))

        async let parked = router.call(
            .serverAwaitChange, AwaitChangeParams(after: first, timeoutSeconds: 1e30), AwaitChangeResult.self)
        _ = try await router.call(.projectTrust, ProjectOnlyParams(project: env.project), WireEmpty.self)
        #expect(try await parked.changed)
    }

    @Test func anUnknownMethodAnswersTheUnknownMethodRefusal() async throws {
        let (router, _, _) = try await router(offset: 726)
        let line = try NDJSON.encodeLine(
            WireRequest(id: "t", method: "server.awaitChanges", params: WireEmpty()))
        let data = await router.handle(line: line)
        let error = try #require(
            try JSONCoding.decoder().decode(WireResponse<WireEmpty>.self, from: data).error)
        #expect(error == WireError(code: .usage, message: WireError.unknownMethodMessage("server.awaitChanges")))
    }
}

/** `ControlServer.receiveLoop` counts each request in `DaemonActivity` so the
    telemetry can name what is stuck. A parked `server.awaitChange` is meant to
    wait, so it is left out. Needs the real socket path, below the typed
    client, which blocks its caller. */
@Suite(.temporaryTree) struct AwaitChangeActivityTests {
    private func connect(_ socketPath: String) throws -> Int32 {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(socketPath.utf8)) }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(result == 0)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return sock
    }

    private func readLine(_ sock: Int32) async throws -> Data {
        await offPool {
            var line = Data()
            var byte: UInt8 = 0
            while read(sock, &byte, 1) == 1 {
                if byte == 0x0A { break }
                line.append(byte)
            }
            return line
        }
    }

    private func send(_ sock: Int32, _ params: AwaitChangeParams) throws {
        let line = try NDJSON.encodeLine(
            WireRequest(id: "a", method: WireMethod.serverAwaitChange.rawValue, params: params))
        let written = line.withUnsafeBytes { write(sock, $0.baseAddress, $0.count) }
        try #require(written == line.count)
    }

    @Test func aParkedWaitIsNotCountedAsAnInFlightRequest() async throws {
        let base = try TemporaryTree.directory(named: "await-activity")
        let paths = DirectaPaths.scratch(in: base)
        try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        let router = Router(
            launcher: SubprocessLauncher(), paths: paths, registry: Registry(paths: paths))
        let socketPath = "/tmp/directa-await-\(UUID().uuidString.prefix(8)).sock"
        let server = try ControlServer(router: router, socketPath: socketPath)
        try await server.startAccepting()
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        let sock = try connect(socketPath)
        defer { close(sock) }
        _ = try await readLine(sock)

        try send(sock, AwaitChangeParams(timeoutSeconds: 1))
        let first = try JSONCoding.decoder().decode(
            WireResponse<AwaitChangeResult>.self, from: try await readLine(sock))
        let token = try #require(first.result?.token)

        try send(sock, AwaitChangeParams(after: token, timeoutSeconds: 1.5))
        let counted = try await eventually(within: .seconds(1)) {
            DaemonActivity.shared.snapshot().requests[WireMethod.serverAwaitChange.rawValue] != nil
        }
        #expect(!counted)

        let second = try JSONCoding.decoder().decode(
            WireResponse<AwaitChangeResult>.self, from: try await readLine(sock))
        #expect(second.result == AwaitChangeResult(changed: false, token: token))
        withExtendedLifetime(server) {}
    }
}
