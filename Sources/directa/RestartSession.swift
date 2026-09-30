import DirectaKit
import Foundation

/** The daemon calls `directa restart` makes, behind a protocol so a fake can
    script a connection that drops mid-restart. */
protocol RestartRequesting: Sendable {
    func ensure(_ params: EnsureParams) async throws -> EnsureResult
    func restart(_ params: RestartParams) async throws -> GroupResult
    /** `responseTimeoutSeconds` nil keeps the client's default deadline. */
    func status(_ params: ProjectParams, responseTimeoutSeconds: Double?) async throws -> ServerListResult
    func wait(_ params: WaitParams) async throws -> EnsureResult
}

protocol RestartClock: Sendable {
    func now() async -> ContinuousClock.Instant
    func sleep(for duration: Duration) async
}

struct SystemRestartClock: RestartClock {
    func now() async -> ContinuousClock.Instant { .now }

    func sleep(for duration: Duration) async {
        /** A cancelled sleep only shortens one backoff step; the deadline
            still ends the loop. */
        try? await Task.sleep(for: duration)
    }
}

struct DaemonClientRestartRequester: RestartRequesting {
    let client: DaemonClient

    func ensure(_ params: EnsureParams) async throws -> EnsureResult {
        try await client.request(
            .serverEnsure, params: params, expecting: EnsureResult.self,
            operationTimeoutSeconds: params.timeoutSeconds)
    }

    func restart(_ params: RestartParams) async throws -> GroupResult {
        try await client.request(
            .serverRestart, params: params, expecting: GroupResult.self,
            operationTimeoutSeconds: params.timeoutSeconds)
    }

    func status(_ params: ProjectParams, responseTimeoutSeconds: Double?) async throws -> ServerListResult {
        try await client.request(
            .serverStatus, params: params, expecting: ServerListResult.self,
            responseTimeoutSeconds: responseTimeoutSeconds)
    }

    func wait(_ params: WaitParams) async throws -> EnsureResult {
        try await client.request(
            .serverWait, params: params, expecting: EnsureResult.self,
            operationTimeoutSeconds: params.timeoutSeconds)
    }
}

/** `directa restart` as a sequence that survives the daemon going away in the
    middle of it. The restart is one daemon-side transition, and a daemon that
    dies during it (a crash, a jetsam kill, a `daemon restart`) closes the
    connection with the outcome unknown: the server may not have been stopped
    yet, may be down, or may already be running its replacement. Sending the
    restart again would bounce a replacement that already landed, so after a
    dropped connection the session reconnects and decides per server from
    what the daemon reports, against the pids read before the restart was
    sent:

    - the same process is still running: the restart never reached it, so
      only those servers are restarted again
    - no process, and either none was running before (restarting a down
      server is a start) or it is stopped (the stop landed and the start did
      not): it is ensured, which bounces nothing
    - anything else (a new process starting or running, or a new run that
      crashed): the restart landed, so it is waited on until healthy, and a
      crash is reported as the restart's own result would have been

    A connection lost again while acting on that repeats the decision from a
    fresh status read, a bounded number of times. No new wire method is
    needed: status, ensure, and wait all exist, and the decision reads only
    fields every daemon version reports. */
struct RestartSession: Sendable {
    let clock: any RestartClock
    /** Receives `CLINotice.restartConnectionLost` once, when the session
        starts recovering. */
    let notice: @Sendable (String) -> Void
    let params: RestartParams
    let requester: any RestartRequesting

    static let backoffCeiling = Duration.seconds(2)
    static let backoffFloor = Duration.milliseconds(250)
    /** Rounds of reconnect-then-act after the first drop. */
    static let maxRecoveryRounds = 3

    /** How long the session waits for a daemon to answer again after a drop:
        the restart's own timeout, with a floor that covers a launchd relaunch
        plus boot restore. */
    var reconnectBudget: Duration {
        .seconds(max(params.timeoutSeconds, 30))
    }

    enum Action: Equatable, Sendable {
        case ensure
        case restartAgain
        case wait
    }

    /** The per-server decision after a drop. `before` is the pid of the run
        that was live when the restart was sent, nil when none was. */
    static func action(before: Int?, after: ServerStatus) -> Action {
        if let before, after.pid == before, after.hasLiveRun {
            return .restartAgain
        }
        if !after.hasLiveRun, before == nil || after.phase == .stopped {
            return .ensure
        }
        return .wait
    }

    /** The status scope every read uses: the one named server, or the whole
        project for `--all`. */
    var scope: ProjectParams {
        ProjectParams(name: params.names?.count == 1 ? params.names?.first : nil, project: params.project)
    }

    /** The status read the decision compares against. The caller sends it
        before `run` through the retrying runner, which may bootstrap a
        daemon: nothing has been restarted yet at that point, so a retry is
        safe there and nowhere after. */
    func readBefore() async throws -> ServerListResult {
        try await requester.status(scope, responseTimeoutSeconds: nil)
    }

    func run(before: ServerListResult) async throws -> GroupResult {
        let livePids = Self.livePids(before.servers)
        let targets = params.names ?? before.servers.map(\.server)
        do {
            return try await requester.restart(params)
        } catch let error as WireError where Self.isConnectionLoss(error) {
            notice(CLINotice.restartConnectionLost)
        }
        return try await recover(livePids: livePids, scope: scope, targets: targets)
    }

    private func recover(livePids: [String: Int], scope: ProjectParams, targets: [String]) async throws
        -> GroupResult
    {
        let deadline = await clock.now().advanced(by: reconnectBudget)
        var lastLoss: WireError?
        for _ in 0..<Self.maxRecoveryRounds {
            let after = try await statusWhenReachable(scope: scope, deadline: deadline)
            do {
                return try await act(after: after, livePids: livePids, targets: targets)
            } catch let error as WireError where Self.isConnectionLoss(error) {
                lastLoss = error
            }
        }
        throw Self.gaveUp(lastLoss)
    }

    private func act(after: ServerListResult, livePids: [String: Int], targets: [String]) async throws
        -> GroupResult
    {
        let byName = Dictionary(after.servers.map { ($0.server, $0) }, uniquingKeysWith: { first, _ in first })
        var again: [String] = []
        var results: [EnsureResult] = []
        for name in targets {
            guard let status = byName[name] else {
                throw ProjectConfigLoader.serverNotFound(name: name, project: params.project)
            }
            switch Self.action(before: livePids[name], after: status) {
            case .restartAgain:
                again.append(name)
            case .ensure:
                results.append(
                    try await requester.ensure(
                        EnsureParams(
                            name: name, port: params.port, project: params.project,
                            timeoutSeconds: params.timeoutSeconds)))
            case .wait:
                results.append(
                    try await requester.wait(
                        WaitParams(
                            condition: .healthy, name: name, project: params.project,
                            timeoutSeconds: params.timeoutSeconds)))
            }
        }
        if !again.isEmpty {
            var retry = params
            retry.names = again
            results += try await requester.restart(retry).results
        }
        return GroupResult(results: results.sorted { $0.server.server < $1.server.server })
    }

    /** Polls status until the daemon answers, backing off, until `deadline`.
        An unreachable or still-restoring daemon is waited out; any other
        refusal is a real answer and ends the session. Each poll's response
        deadline is what is left of the budget, since a daemon that accepts
        and never answers would otherwise hold one poll for the client's full
        default deadline. */
    private func statusWhenReachable(scope: ProjectParams, deadline: ContinuousClock.Instant) async throws
        -> ServerListResult
    {
        var delay = Self.backoffFloor
        var lastLoss: WireError?
        while true {
            let remaining = await clock.now().duration(to: deadline)
            guard remaining > .zero else { throw Self.gaveUp(lastLoss) }
            do {
                return try await requester.status(scope, responseTimeoutSeconds: remaining / .seconds(1))
            } catch let error as WireError where Self.isConnectionLoss(error) {
                lastLoss = error
                guard await clock.now() < deadline else { throw Self.gaveUp(error) }
                await clock.sleep(for: delay)
                delay = min(delay * 2, Self.backoffCeiling)
            }
        }
    }

    static func isConnectionLoss(_ error: WireError) -> Bool {
        error.code == .daemonUnreachable || error.code == .daemonStarting
    }

    static func livePids(_ servers: [ServerStatus]) -> [String: Int] {
        var pids: [String: Int] = [:]
        for server in servers where server.hasLiveRun {
            if let pid = server.pid { pids[server.server] = pid }
        }
        return pids
    }

    /** Exit 3 like any unreachable daemon, but the message says the restart
        may already have happened, so the fix is to look before restarting
        again. */
    static func gaveUp(_ error: WireError?) -> WireError {
        let detail = error.map { " (\($0.message))" } ?? ""
        return WireError(
            code: .daemonUnreachable,
            hint: "run: directa status",
            message:
                "the daemon went away during the restart and did not answer again in time\(detail); the restart may already have happened, so check the server before restarting it again")
    }
}
