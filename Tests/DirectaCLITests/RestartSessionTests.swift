import DirectaKit
import Foundation
import Testing

@testable import directa

/** `RestartSession`: a restart whose connection drops mid-flight must finish
    without bouncing a server whose restart already landed. A scripted fake
    stands in for the daemon, and a virtual clock for time, so every branch
    runs without a socket or a real wait. */
@Suite struct RestartSessionTests {
    private static let project = "/code/app"

    private static func status(
        _ name: String, phase: ServerPhase, pid: Int? = nil
    ) -> ServerStatus {
        var status = ServerStatus(
            logPath: "/logs/\(name)/current.log", phase: phase, project: project, server: name)
        status.pid = pid
        return status
    }

    private static let closed = WireError(code: .daemonUnreachable, message: "daemon closed the connection")
    private static let starting = WireError(code: .daemonStarting, message: "restoring")

    /** Each method answers from its own queue, in order; an empty queue is a
        test bug and fails loudly. Every call is logged. */
    private actor FakeDaemon: RestartRequesting {
        var calls: [String] = []
        var ensures: [Result<EnsureResult, WireError>] = []
        var restarts: [Result<GroupResult, WireError>] = []
        var statuses: [Result<ServerListResult, WireError>] = []
        var waits: [Result<EnsureResult, WireError>] = []

        init(
            ensures: [Result<EnsureResult, WireError>] = [],
            restarts: [Result<GroupResult, WireError>] = [],
            statuses: [Result<ServerListResult, WireError>] = [],
            waits: [Result<EnsureResult, WireError>] = []
        ) {
            self.ensures = ensures
            self.restarts = restarts
            self.statuses = statuses
            self.waits = waits
        }

        func ensure(_ params: EnsureParams) async throws -> EnsureResult {
            calls.append("ensure \(params.name) port=\(params.port.map(String.init) ?? "-")")
            return try Self.next(&ensures, "ensure")
        }

        func restart(_ params: RestartParams) async throws -> GroupResult {
            calls.append("restart \(params.names?.joined(separator: ",") ?? "--all")")
            return try Self.next(&restarts, "restart")
        }

        func status(_ params: ProjectParams) async throws -> ServerListResult {
            calls.append("status \(params.name ?? "--all")")
            return try Self.next(&statuses, "status")
        }

        func wait(_ params: WaitParams) async throws -> EnsureResult {
            calls.append("wait \(params.name) \(params.condition.rawValue)")
            return try Self.next(&waits, "wait")
        }

        private static func next<T>(_ queue: inout [Result<T, WireError>], _ method: String) throws -> T {
            guard !queue.isEmpty else {
                Issue.record("unscripted \(method) call")
                throw WireError(code: .internalError, message: "unscripted \(method)")
            }
            return try queue.removeFirst().get()
        }
    }

    /** Time moves only when the session sleeps. */
    private actor VirtualClock: RestartClock {
        private let start = ContinuousClock.now
        private var elapsed = Duration.zero
        var sleeps: [Duration] = []

        func now() async -> ContinuousClock.Instant { start.advanced(by: elapsed) }

        func sleep(for duration: Duration) async {
            sleeps.append(duration)
            elapsed += duration
        }
    }

    private final class Notices: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    private struct Harness {
        let clock = VirtualClock()
        let daemon: FakeDaemon
        let notices = Notices()
        let session: RestartSession

        init(daemon: FakeDaemon, names: [String]? = ["web"], port: Int? = nil, timeout: Double = 60) {
            self.daemon = daemon
            let notices = self.notices
            session = RestartSession(
                clock: clock, notice: { notices.append($0) },
                params: RestartParams(names: names, port: port, project: RestartSessionTests.project, timeoutSeconds: timeout),
                requester: daemon)
        }
    }

    private static func list(_ servers: ServerStatus...) -> ServerListResult {
        ServerListResult(servers: servers)
    }

    @Test(arguments: [
        (Int?.some(10), ServerPhase.running, Int?.some(10), RestartSession.Action.restartAgain),
        (10, .unhealthy, 10, .restartAgain),
        (10, .starting, 11, .wait),
        (10, .running, 11, .wait),
        (10, .crashed, nil, .wait),
        (10, .failed, nil, .wait),
        (10, .stopped, nil, .ensure),
        (nil, .stopped, nil, .ensure),
        (nil, .crashed, nil, .ensure),
        (nil, .failed, nil, .ensure),
        (nil, .running, 11, .wait),
    ])
    func theDecisionAfterADrop(before: Int?, phase: ServerPhase, pid: Int?, expected: RestartSession.Action) {
        #expect(RestartSession.action(before: before, after: Self.status("web", phase: phase, pid: pid)) == expected)
    }

    @Test func anAnsweredRestartIsReturnedAsIs() async throws {
        let answer = GroupResult(results: [EnsureResult(server: Self.status("web", phase: .running, pid: 11))])
        let harness = Harness(daemon: FakeDaemon(restarts: [.success(answer)]))

        let result = try await harness.session.run(before: Self.list(Self.status("web", phase: .running, pid: 10)))

        #expect(result == answer)
        #expect(await harness.daemon.calls == ["restart web"])
        #expect(harness.notices.all.isEmpty)
    }

    /** The observed failure: the daemon died after the restart landed and a
        new daemon brought the replacement up. The session waits on it and
        never sends a second restart. */
    @Test func aDropAfterTheRestartLandedWaitsInsteadOfRestartingAgain() async throws {
        let healthy = EnsureResult(server: Self.status("web", phase: .running, pid: 12))
        let harness = Harness(
            daemon: FakeDaemon(
                restarts: [.failure(Self.closed)],
                statuses: [.success(Self.list(Self.status("web", phase: .starting, pid: 12)))],
                waits: [.success(healthy)]))

        let result = try await harness.session.run(before: Self.list(Self.status("web", phase: .running, pid: 10)))

        #expect(result == GroupResult(results: [healthy]))
        #expect(await harness.daemon.calls == ["restart web", "status web", "wait web healthy"])
        #expect(harness.notices.all == [RestartSession.recoveringNotice])
    }

    @Test func aDropBeforeTheRestartReachedTheServerRestartsItOnce() async throws {
        let restarted = GroupResult(results: [EnsureResult(server: Self.status("web", phase: .running, pid: 11))])
        let harness = Harness(
            daemon: FakeDaemon(
                restarts: [.failure(Self.closed), .success(restarted)],
                statuses: [.success(Self.list(Self.status("web", phase: .running, pid: 10)))]))

        let result = try await harness.session.run(before: Self.list(Self.status("web", phase: .running, pid: 10)))

        #expect(result == restarted)
        #expect(await harness.daemon.calls == ["restart web", "status web", "restart web"])
    }

    @Test func aDropBetweenTheStopAndTheStartEnsuresWithThePortOverride() async throws {
        let started = EnsureResult(server: Self.status("web", phase: .running, pid: 11))
        let harness = Harness(
            daemon: FakeDaemon(
                ensures: [.success(started)],
                restarts: [.failure(Self.closed)],
                statuses: [.success(Self.list(Self.status("web", phase: .stopped)))]),
            port: 4100)

        let result = try await harness.session.run(before: Self.list(Self.status("web", phase: .running, pid: 10)))

        #expect(result == GroupResult(results: [started]))
        #expect(await harness.daemon.calls == ["restart web", "status web", "ensure web port=4100"])
    }

    /** A restarting daemon is waited out with a doubling backoff, capped. */
    @Test func theSessionWaitsForTheDaemonToComeBack() async throws {
        let healthy = EnsureResult(server: Self.status("web", phase: .running, pid: 12))
        let harness = Harness(
            daemon: FakeDaemon(
                restarts: [.failure(Self.closed)],
                statuses: [
                    .failure(Self.closed), .failure(Self.closed), .failure(Self.starting),
                    .failure(Self.starting), .failure(Self.closed),
                    .success(Self.list(Self.status("web", phase: .running, pid: 12))),
                ],
                waits: [.success(healthy)]))

        let result = try await harness.session.run(before: Self.list(Self.status("web", phase: .running, pid: 10)))

        #expect(result == GroupResult(results: [healthy]))
        #expect(
            await harness.clock.sleeps == [
                .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(2),
            ])
        #expect(await harness.daemon.calls.filter { $0.hasPrefix("restart") } == ["restart web"])
    }

    /** A daemon that never answers again ends the session with exit-3
        semantics and a message that warns against restarting blindly; the
        restart was sent exactly once. */
    @Test func aDaemonThatNeverReturnsEndsWithoutASecondRestart() async throws {
        let harness = Harness(
            daemon: FakeDaemon(
                restarts: [.failure(Self.closed)],
                statuses: Array(repeating: .failure(Self.closed), count: 40)),
            timeout: 5)

        let error = await #expect(throws: WireError.self) {
            _ = try await harness.session.run(before: Self.list(Self.status("web", phase: .running, pid: 10)))
        }

        #expect(error?.code == .daemonUnreachable)
        #expect(error?.hint == "run: directa status")
        #expect(
            error?.message
                == "the daemon went away during the restart and did not answer again in time (daemon closed the connection); the restart may already have happened, so check the server before restarting it again")
        #expect(await harness.daemon.calls.filter { $0.hasPrefix("restart") } == ["restart web"])
        /** The 30-second floor applies over a shorter restart timeout. */
        let slept = await harness.clock.sleeps.reduce(Duration.zero, +)
        #expect(slept >= .seconds(30))
        #expect(slept <= .seconds(32))
    }

    /** `--all`: each server gets its own decision, only the unreached one is
        restarted again (in one request, after the others), and results come
        back sorted by name. */
    @Test func restartAllDecidesPerServer() async throws {
        let apiHealthy = EnsureResult(server: Self.status("api", phase: .running, pid: 21))
        let dbRestarted = EnsureResult(server: Self.status("db", phase: .running, pid: 32))
        let webStarted = EnsureResult(server: Self.status("web", phase: .running, pid: 41))
        let harness = Harness(
            daemon: FakeDaemon(
                ensures: [.success(webStarted)],
                restarts: [.failure(Self.closed), .success(GroupResult(results: [dbRestarted]))],
                statuses: [
                    .success(
                        Self.list(
                            Self.status("web", phase: .stopped),
                            Self.status("db", phase: .running, pid: 30),
                            Self.status("api", phase: .starting, pid: 21)))
                ],
                waits: [.success(apiHealthy)]),
            names: nil)

        let result = try await harness.session.run(
            before: Self.list(
                Self.status("api", phase: .running, pid: 20),
                Self.status("db", phase: .running, pid: 30),
                Self.status("web", phase: .running, pid: 40)))

        #expect(result == GroupResult(results: [apiHealthy, dbRestarted, webStarted]))
        #expect(
            await harness.daemon.calls == [
                "restart --all", "status --all", "wait api healthy", "ensure web port=-", "restart db",
            ])
    }

    /** A second drop while acting re-reads status and decides again against
        the original pids, so a restart sent in the first round that landed
        is waited on, not repeated. */
    @Test func aSecondDropRedecidesFromAFreshStatus() async throws {
        let healthy = EnsureResult(server: Self.status("web", phase: .running, pid: 11))
        let harness = Harness(
            daemon: FakeDaemon(
                restarts: [.failure(Self.closed), .failure(Self.closed)],
                statuses: [
                    .success(Self.list(Self.status("web", phase: .running, pid: 10))),
                    .success(Self.list(Self.status("web", phase: .starting, pid: 11))),
                ],
                waits: [.success(healthy)]))

        let result = try await harness.session.run(before: Self.list(Self.status("web", phase: .running, pid: 10)))

        #expect(result == GroupResult(results: [healthy]))
        #expect(
            await harness.daemon.calls == [
                "restart web", "status web", "restart web", "status web", "wait web healthy",
            ])
        #expect(harness.notices.all.count == 1)
    }

    @Test func repeatedDropsWhileActingGiveUpAfterTheRoundLimit() async throws {
        let harness = Harness(
            daemon: FakeDaemon(
                restarts: [.failure(Self.closed)],
                statuses: Array(
                    repeating: .success(Self.list(Self.status("web", phase: .starting, pid: 11))),
                    count: RestartSession.maxRecoveryRounds),
                waits: Array(repeating: .failure(Self.closed), count: RestartSession.maxRecoveryRounds)))

        let error = await #expect(throws: WireError.self) {
            _ = try await harness.session.run(before: Self.list(Self.status("web", phase: .running, pid: 10)))
        }

        #expect(error?.code == .daemonUnreachable)
        #expect(await harness.daemon.calls.filter { $0.hasPrefix("wait") }.count == RestartSession.maxRecoveryRounds)
        #expect(await harness.daemon.calls.filter { $0.hasPrefix("restart") } == ["restart web"])
    }

    /** A refusal is a real answer, not a lost connection: it is surfaced as
        is and nothing else is sent. */
    @Test func aRefusalIsNotRecovered() async throws {
        let locked = WireError(code: .resourceLocked, hint: "wait", message: "held")
        let harness = Harness(daemon: FakeDaemon(restarts: [.failure(locked)]))

        let error = await #expect(throws: WireError.self) {
            _ = try await harness.session.run(before: Self.list(Self.status("web", phase: .running, pid: 10)))
        }

        #expect(error == locked)
        #expect(await harness.daemon.calls == ["restart web"])
    }

    @Test func aServerGoneAfterTheDropIsNotFound() async throws {
        let harness = Harness(
            daemon: FakeDaemon(
                restarts: [.failure(Self.closed)],
                statuses: [.success(Self.list())]))

        let error = await #expect(throws: WireError.self) {
            _ = try await harness.session.run(before: Self.list(Self.status("web", phase: .running, pid: 10)))
        }

        #expect(error?.code == .notFound)
    }

    @Test func aNamedRestartScopesStatusToThatServer() {
        let named = Harness(daemon: FakeDaemon())
        #expect(named.session.scope == ProjectParams(name: "web", project: Self.project))
        let all = Harness(daemon: FakeDaemon(), names: nil)
        #expect(all.session.scope == ProjectParams(project: Self.project))
    }
}
