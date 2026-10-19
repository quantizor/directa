import DirectaKit
import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

/** `directa stop X && directa ensure X` was what twelve sessions wrote by hand.
    It has two defects a single daemon-side transition removes: another session's
    ensure can land between the two commands, and a refusal (a held resource, a
    broken config) arrives only after the server is already down. */
@Suite(.serialized, .temporaryTree) struct RestartTests {
    /** A port per test (`offset` into this run's block): a case that fails
        before its teardown would otherwise leave a listener behind and fail
        the next one for an unrelated reason. */
    private func env(flood: Bool = false, offset: Int, waitFor: String? = nil) throws -> RouterEnv {
        let env = try makeRouterEnv(named: "restart")
        try writeConfig(flood: flood, port: TestPorts.port(offset), project: env.project, waitFor: waitFor)
        return env
    }

    private func writeConfig(
        flood: Bool = false, heads: [String: String] = [:], port: Int, project: String,
        waitFor: String? = nil
    ) throws {
        let fixture = try #require(fixtureServerExecutable())
        /** `--flood` composes with `--listen-tcp`: the fixture still binds and
            answers the healthcheck, it just also writes heartbeat lines as
            fast as possible instead of pacing them, which is what makes the
            stop-side tailer drain slow enough to expose a stuck `.stopping`
            wait. */
        let floodFlag = flood ? ", \"--flood\"" : ""
        let waitForField = waitFor.map { ",\n          \"waitFor\": \"\($0)\"" } ?? ""
        let headsField =
            heads.isEmpty
            ? ""
            : ",\n          \"heads\": {"
                + heads.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \"\($0.value)\"" }
                .joined(separator: ", ") + "}"
        let body = """
            {
              "servers": {
                "db": {
                  "command": ["\(fixture)", "--listen-tcp", "\(port)"\(floodFlag)],
                  "healthcheck": { "type": "tcp", "port": \(port) },
                  "locks": ["data"],
                  "port": \(port)\(waitForField)\(headsField)
                }
              },
              "version": 1
            }
            """
        try Data(body.utf8)
            .write(to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
    }

    private func phase(_ router: Router, _ project: String, _ name: String) async throws
        -> ServerPhase
    {
        let list = try await router.call(
            .serverStatus, ProjectParams(project: project), ServerListResult.self)
        return try #require(list.servers.first { $0.server == name }).phase
    }

    @Test func restartReplacesThePidAndKeepsResumeOnBoot() async throws {
        let env = try env(offset: 411)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let first = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        #expect(first.server.phase == .running)
        let id = serverID(project: env.project, name: "db")
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        let restarted = try await router.call(
            .serverRestart,
            RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
            GroupResult.self)
        let server = try #require(restarted.results.first?.server)
        #expect(server.phase == .running)
        #expect(server.pid != first.server.pid)
        /** A deliberate stop would clear this, so a hand-rolled stop-then-ensure
            drops the boot intent and re-sets it; restart never drops it. */
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** Restarting a server that floods stdout: recordOutcome clears
        `runTask` before its tailer drain (slow under a flood) and registry
        write, so the restart's `ensure()` must wait on the phase leaving
        `.stopping`, never on `runTask`, or it recurses on the actor without
        suspending and grows the daemon's heap until it is killed. */
    @Test func restartOfAFloodingServerCompletesAndStaysRunning() async throws {
        let env = try env(flood: true, offset: 417)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let first = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        #expect(first.server.phase == .running)

        /** A backlog for the stop's drain to work through. */
        let spool = env.paths.spoolOutFile(project: env.project, server: "db").path
        let backlogged = try await eventually(within: .seconds(5)) {
            ((try? FileManager.default.attributesOfItem(atPath: spool)[.size] as? Int) ?? 0) >= 1_048_576
        }
        try #require(backlogged, "the flooding server never wrote a backlog")

        let restarted = try await router.call(
            .serverRestart,
            RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
            GroupResult.self)
        let server = try #require(restarted.results.first?.server)
        #expect(server.phase == .running)
        #expect(server.pid != first.server.pid)

        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** `restart` is not the only path that can land on a server whose phase
        reads `.stopping`: `up` (`.groupUp`) calls `start()` directly for a
        spec whose `waitFor` is `started`, unconditionally once `prepareSpawn`
        returns (which is a no-op for a `.stopping` target, not a refusal). A
        session racing a concurrent `stop` of a flooding server must see `up`
        wait for that stop to actually land rather than recurse against a
        phase that has not moved, the same class of bug `ensure()` had. */
    @Test func upDuringASlowStopOfAFloodingServerWaitsForThePhaseChange() async throws {
        let env = try env(flood: true, offset: 418, waitFor: "started")
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let first = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        #expect(first.server.phase == .running)

        async let stopResult: ServerResult = router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
        /** `up` lands while the phase reads `.stopping`: the stop has begun
            and the flooding tailer's drain is still under way. */
        try #require(try await eventually(within: .seconds(5)) { try await phase(router, env.project, "db") == .stopping })

        let up = try await router.call(
            .groupUp, GroupParams(project: env.project, timeoutSeconds: 10),
            GroupResult.self)
        let started = try #require(up.results.first { $0.server.server == "db" }).server
        #expect(started.pid != first.server.pid)

        let running = try await eventually(within: .seconds(5)) {
            try await phase(router, env.project, "db") == .running
        }
        #expect(running, "server did not become healthy after up raced a slow stop")

        _ = try await stopResult
        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** An explicit restart's reason survives in the server's own log (OSLog
        does not persist) and on the `stopped` event, not just as an exit code
        directa itself caused. */
    @Test func restartLogsAndEventsTheReason() async throws {
        let env = try env(offset: 416)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        _ = try await router.call(
            .serverRestart,
            RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
            GroupResult.self)

        let logs = try await router.call(
            .logsQuery,
            LogsQueryParams(name: "db", project: env.project, streams: [.sys]),
            LogsQueryResult.self)
        #expect(logs.lines.contains { $0.text == "stopping: requested by restart" })

        let events = try await router.call(
            .eventsQuery, EventsQueryParams(project: env.project), EventsQueryResult.self)
        let stopped = try #require(events.events.last { $0.kind == .stopped })
        #expect(stopped.detail == "requested by restart")

        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** The headline: a stop-then-ensure pair takes the server down and is then
        refused, leaving it down. Restart refuses before touching it. */
    @Test func restartUnderALiveLockIsRefusedAndLeavesTheServerRunning() async throws {
        let env = try env(offset: 412)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        _ = try await router.call(
            .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: false, project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)

        await #expect(throws: WireError.self) {
            _ = try await router.call(
                .serverRestart,
                RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
        }
        #expect(try await phase(router, env.project, "db") == .running)

        _ = try await router.call(
            .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)
        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** A server the lock already paused must not come back behind the hold. */
    @Test func restartOfAPausedServerIsRefusedAndItStaysDown() async throws {
        let env = try env(offset: 413)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        let acquired = try await router.call(
            .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: true, project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)
        #expect(acquired.paused == ["db"])

        await #expect(throws: WireError.self) {
            _ = try await router.call(
                .serverRestart,
                RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
        }
        #expect(try await phase(router, env.project, "db") == .stopped)

        _ = try await router.call(
            .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)
        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** A bad save must not take a healthy server down. */
    @Test func restartWithABrokenConfigLeavesTheServerRunning() async throws {
        let env = try env(offset: 414)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        try Data("{ not json".utf8)
            .write(to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))

        await #expect(throws: WireError.self) {
            _ = try await router.call(
                .serverRestart,
                RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
        }
        /** Restore the config before reading status: the status path parses it
            too, so a broken file would fail the assertion for the wrong reason. */
        try writeConfig(port: TestPorts.port(414), project: env.project)
        #expect(try await phase(router, env.project, "db") == .running)
        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    @Test func restartOfAnUnknownNameIsNotFoundAndTouchesNothing() async throws {
        let env = try env(offset: 415)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        do {
            _ = try await router.call(
                .serverRestart,
                RestartParams(names: ["ghost"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
            Issue.record("expected not-found")
        } catch let error as WireError {
            #expect(error.code == .notFound)
        }
        #expect(try await phase(router, env.project, "db") == .running)
        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    private func sysLines(_ router: Router, _ project: String) async throws -> [String] {
        try await router.call(
            .logsQuery, LogsQueryParams(name: "db", project: project, streams: [.sys]),
            LogsQueryResult.self
        ).lines.map(\.text)
    }

    /** The field failure: a process the stop did not remove (here, a stand-in
        for a worker that left the run's tree) still listens, so the next run's
        first health check would be answered by it. The restart names the
        listener and starts nothing. */
    @Test(arguments: [(421, true), (422, false)])
    func restartIsRefusedWhileAListenerOutlivesTheStop(offset: Int, inStoppedRun: Bool) async throws {
        let env = try env(offset: offset)
        let port = TestPorts.port(offset)
        let lingering = LingeringListener(reports: inStoppedRun ? .stoppedRun : .outsider)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths, portProbe: lingering.probe,
            registry: registry,
            stopTiming: StopTiming(graceSeconds: 2, overtimeSeconds: 2, portClearSeconds: 0.3))
        let first = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        let firstPid = try #require(first.server.pid)
        lingering.watch(pid: pid_t(firstPid))
        let reported = lingering.reportedPid

        let refused = try await router.attempt(
            .serverRestart,
            RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
            GroupResult.self)
        guard case .failure(let error) = refused else {
            Issue.record("restart went ahead beside a listener the stop did not remove")
            return
        }
        #expect(error.code == .portHeld)
        #expect(
            error.message
                == "port \(port) is still held by pid \(reported) (stand-in listener) after stopping 'db'; the new run was not started"
        )
        #expect(error.hint == "run: directa why db")

        let status = try #require(
            try await router.call(
                .serverStatus, ProjectParams(name: "db", project: env.project), ServerListResult.self
            ).servers.first)
        #expect(status.phase == .stopped)
        #expect(status.pid == nil)
        let membership = inStoppedRun ? "was" : "was not"
        #expect(
            try await sysLines(router, env.project).contains(
                "not starting: port \(port) is still held by pid \(reported) (stand-in listener) after the stop; that process \(membership) part of the run just stopped (root and descendants recorded at stop)"
            ))
    }

    /** A restart that fails after its prepare abandons the prepared spec: the
        server stays down, and a config edit made afterward shows in its status
        rather than the spec the failed restart prepared. */
    @Test func aRestartRefusedAfterItsStopLeavesTheServerReadingLaterConfigEdits() async throws {
        let env = try env(offset: 426)
        let port = TestPorts.port(426)
        let lingering = LingeringListener(reports: .outsider)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths, portProbe: lingering.probe,
            registry: registry,
            stopTiming: StopTiming(graceSeconds: 2, overtimeSeconds: 2, portClearSeconds: 0.3))
        let first = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        lingering.watch(pid: pid_t(try #require(first.server.pid)))
        let refused = try await router.attempt(
            .serverRestart,
            RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
            GroupResult.self)
        guard case .failure(let error) = refused else {
            Issue.record("restart went ahead beside a listener the stop did not remove")
            return
        }
        #expect(error.code == .portHeld)

        let heads = ["api": "http://api.localhost/"]
        try writeConfig(heads: heads, port: port, project: env.project)
        let status = try #require(
            try await router.call(
                .serverStatus, ProjectParams(name: "db", project: env.project), ServerListResult.self
            ).servers.first)
        #expect(status.phase == .stopped)
        #expect(status.heads == heads)
    }

    /** A listener that is on its way out (the stop's SIGKILL pass has run and
        the socket is closing) is waited for, not refused. */
    @Test func restartWaitsForAListenerThatLeavesWithinTheBound() async throws {
        let env = try env(offset: 423)
        let lingering = LingeringListener(pollsBeforeLeaving: 3, reports: .outsider)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths, portProbe: lingering.probe,
            registry: registry,
            stopTiming: StopTiming(graceSeconds: 2, overtimeSeconds: 2, portClearSeconds: 5))
        let first = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        let firstPid = try #require(first.server.pid)
        lingering.watch(pid: pid_t(firstPid))

        let restarted = try await router.call(
            .serverRestart,
            RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
            GroupResult.self)
        let server = try #require(restarted.results.first?.server)
        #expect(server.phase == .running)
        #expect(server.pid != firstPid)
        #expect(lingering.polls >= 4, "the restart did not wait for the listener to leave")
        #expect(try await sysLines(router, env.project).filter { $0.hasPrefix("not starting") }.isEmpty)

        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    // MARK: - ensure over an unhealthy run

    private static let ensureRestartDetail = "restarted by ensure: unhealthy"

    /** The `db` server again, with an HTTP healthcheck answered by `responder`
        so a test turns the run unhealthy by changing the status code. The
        fixture listens on `port`, which is declared as an absolute secondary
        port: the claim the restart's port checks look at, without the primary
        port that would rewrite the healthcheck URL onto it. */
    private func writeHTTPHealthConfig(
        heads: [String: String] = [:], port: Int, project: String, responder: TestHTTPResponder,
        unhealthyAfter: Int
    ) throws {
        let fixture = try #require(fixtureServerExecutable())
        let headsField =
            heads.isEmpty
            ? ""
            : ",\n          \"heads\": {"
                + heads.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \"\($0.value)\"" }
                .joined(separator: ", ") + "}"
        let body = """
            {
              "servers": {
                "db": {
                  "command": ["\(fixture)", "--listen-tcp", "\(port)"],
                  "healthcheck": {
                    "intervalMs": 50, "timeoutMs": 1000, "type": "http",
                    "unhealthyAfter": \(unhealthyAfter),
                    "url": "http://127.0.0.1:\(responder.port)/health"
                  },
                  "ports": { "listener": { "port": \(port) } }\(headsField)
                }
              },
              "version": 1
            }
            """
        try Data(body.utf8)
            .write(to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
    }

    private func status(_ router: Router, _ project: String) async throws -> ServerStatus {
        try #require(
            try await router.call(
                .serverStatus, ProjectParams(name: "db", project: project), ServerListResult.self
            ).servers.first)
    }

    /** A router over a `db` run that has passed its healthcheck, then had
        the responder switched to 500 until `failing` holds. */
    private func failingRun(
        offset: Int, portProbe: PortProbe = .live, responder: TestHTTPResponder,
        unhealthyAfter: Int, failing: (ServerStatus) -> Bool
    ) async throws -> (env: RouterEnv, pid: Int, router: Router) {
        let env = try makeRouterEnv(named: "restart")
        try writeHTTPHealthConfig(
            port: TestPorts.port(offset), project: env.project, responder: responder,
            unhealthyAfter: unhealthyAfter)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths, portProbe: portProbe,
            registry: registry,
            stopTiming: StopTiming(graceSeconds: 2, overtimeSeconds: 2, portClearSeconds: 0.3))
        let first = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        #expect(first.server.phase == .running)
        let pid = try #require(first.server.pid)

        responder.respond(with: 500)
        let reached = try await eventually(within: .seconds(5)) {
            failing(try await status(router, env.project))
        }
        try #require(reached, "the run never reached the failing state")
        return (env: env, pid: pid, router: router)
    }

    /** Lets the replacement run pass its healthcheck once ensure has stopped
        the old one: the run being replaced fails until then, so it cannot
        recover on its own before ensure reaches it. */
    private func recoverAfterTheStop(
        _ router: Router, project: String, responder: TestHTTPResponder
    ) -> Task<Void, Never> {
        Task {
            let stopped = try? await awaitStoppedEvents(
                router, project: project, detail: Self.ensureRestartDetail, within: .seconds(20))
            if stopped != nil { responder.respond(with: 200) }
        }
    }

    @Test func ensureRestartsAnUnhealthyServerAndWaitsForTheNewRun() async throws {
        let responder = try TestHTTPResponder()
        defer { responder.stop() }
        let run = try await failingRun(
            offset: 431, responder: responder, unhealthyAfter: 2, failing: { $0.phase == .unhealthy })
        let recover = recoverAfterTheStop(run.router, project: run.env.project, responder: responder)
        defer { recover.cancel() }

        let ensured = try await run.router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: run.env.project, timeoutSeconds: 15),
            EnsureResult.self)
        #expect(ensured.reason == nil)
        #expect(ensured.server.phase == .running)
        #expect(ensured.server.pid != run.pid)
        #expect(ensured.server.lastHealthCheck?.passed == true)

        let events = try await run.router.call(
            .eventsQuery, EventsQueryParams(project: run.env.project), EventsQueryResult.self)
        let stopped = events.events.filter { $0.kind == .stopped }
        #expect(stopped.map(\.detail) == [Self.ensureRestartDetail])
        #expect(try await sysLines(run.router, run.env.project).contains("stopping: \(Self.ensureRestartDetail)"))

        _ = try await run.router.call(
            .serverStop, ServerTargetParams(name: "db", project: run.env.project),
            ServerResult.self)
    }

    /** Two sessions ensuring one broken server is the ordinary case: the
        second joins the restart the first started, so one process is stopped
        and one is spawned. */
    @Test func twoConcurrentEnsuresOfAnUnhealthyServerRestartItOnce() async throws {
        let responder = try TestHTTPResponder()
        defer { responder.stop() }
        let run = try await failingRun(
            offset: 432, responder: responder, unhealthyAfter: 2, failing: { $0.phase == .unhealthy })
        let recover = recoverAfterTheStop(run.router, project: run.env.project, responder: responder)
        defer { recover.cancel() }

        let params = EnsureParams(name: "db", project: run.env.project, timeoutSeconds: 15)
        async let first = run.router.call(.serverEnsure, params, EnsureResult.self)
        async let second = run.router.call(.serverEnsure, params, EnsureResult.self)
        let results = try await [first, second]

        #expect(results.map(\.reason) == [nil, nil])
        #expect(results.map(\.server.phase) == [.running, .running])
        let pids = Set(results.compactMap(\.server.pid))
        #expect(pids.count == 1)
        #expect(!pids.contains(run.pid))

        let events = try await run.router.call(
            .eventsQuery, EventsQueryParams(project: run.env.project), EventsQueryResult.self)
        #expect(events.events.filter { $0.kind == .stopped }.map(\.detail) == [Self.ensureRestartDetail])
        #expect(events.events.filter { $0.kind == .started }.count == 2)

        _ = try await run.router.call(
            .serverStop, ServerTargetParams(name: "db", project: run.env.project),
            ServerResult.self)
    }

    /** The restart's port re-check applies to ensure: a listener that outlives
        the stop refuses the transition, leaves the server stopped, and
        releases the spec the ensure prepared. */
    @Test func ensureOfAnUnhealthyServerIsRefusedWhileAListenerOutlivesTheStop() async throws {
        let responder = try TestHTTPResponder()
        defer { responder.stop() }
        let lingering = LingeringListener(reports: .outsider)
        let run = try await failingRun(
            offset: 433, portProbe: lingering.probe, responder: responder, unhealthyAfter: 2,
            failing: { $0.phase == .unhealthy })
        lingering.watch(pid: pid_t(run.pid))
        let port = TestPorts.port(433)

        let refused = try await run.router.attempt(
            .serverEnsure,
            EnsureParams(name: "db", project: run.env.project, timeoutSeconds: 10),
            EnsureResult.self)
        guard case .failure(let error) = refused else {
            Issue.record("ensure went ahead beside a listener the stop did not remove")
            return
        }
        #expect(error.code == .portHeld)
        #expect(
            error.message
                == "port \(port) is still held by pid \(lingering.reportedPid) (stand-in listener) after stopping 'db'; the new run was not started"
        )
        #expect(error.hint == "run: directa why db")

        let stopped = try await status(run.router, run.env.project)
        #expect(stopped.phase == .stopped)
        #expect(stopped.pid == nil)

        let heads = ["api": "http://api.localhost/"]
        try writeHTTPHealthConfig(
            heads: heads, port: port, project: run.env.project, responder: responder,
            unhealthyAfter: 2)
        #expect(try await status(run.router, run.env.project).heads == heads)
    }

    /** `running` with a failing latest check is not `unhealthy`: ensure waits
        for it, as for any run still proving itself, and does not restart. */
    @Test func ensureOfARunningServerWithAFailingCheckWaitsWithoutRestarting() async throws {
        let responder = try TestHTTPResponder()
        defer { responder.stop() }
        let run = try await failingRun(
            offset: 434, responder: responder, unhealthyAfter: 200,
            failing: { $0.phase == .running && ($0.lastHealthCheck?.failures ?? 0) >= 2 })

        let ensured = try await run.router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: run.env.project, timeoutSeconds: 1),
            EnsureResult.self)
        #expect(ensured.reason == .timeout)
        #expect(ensured.server.phase == .running)
        #expect(ensured.server.pid == run.pid)

        let events = try await run.router.call(
            .eventsQuery, EventsQueryParams(project: run.env.project), EventsQueryResult.self)
        #expect(events.events.filter { $0.kind == .stopped }.isEmpty)

        _ = try await run.router.call(
            .serverStop, ServerTargetParams(name: "db", project: run.env.project),
            ServerResult.self)
    }

    /** A server whose command only works once the router has substituted its
        port: the raw committed command carries the literal `{port}`, which the
        fixture refuses, and the injected `PORT` is written to a file so the
        spawn's environment is observable. */
    private func writePortSensitiveConfig(port: Int, project: String) throws -> String {
        let fixture = try #require(fixtureServerExecutable())
        let envFile = URL(fileURLWithPath: project).appending(path: "spawn-env.txt").path
        let script = "echo $PORT > '\(envFile)'; exec '\(fixture)' --listen-tcp {port}"
        let body = """
            {
              "servers": {
                "db": {
                  "command": ["/bin/sh", "-c", "\(script)"],
                  "healthcheck": { "type": "tcp", "port": \(port) },
                  "port": \(port)
                }
              },
              "version": 1
            }
            """
        try Data(body.utf8)
            .write(to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
        return envFile
    }

    /** A status read lands in the gap between the restart's stop and its
        spawn (the port probe between them fires one). It must not replace the
        spec the restart prepared: the new run spawns with the injected port,
        and is not reported as running a stale config. */
    @Test func aStatusReadBetweenTheStopAndTheSpawnLeavesThePreparedSpecAlone() async throws {
        let env = try makeRouterEnv(named: "restart")
        let port = TestPorts.port(424)
        let envFile = try writePortSensitiveConfig(port: port, project: env.project)
        let reader = StatusReadingProbe()
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths, portProbe: reader.probe,
            registry: registry)
        reader.attach(router: router, project: env.project)
        let first = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        #expect(first.server.phase == .running)
        try FileManager.default.removeItem(atPath: envFile)
        reader.arm()

        let restarted = try await router.call(
            .serverRestart,
            RestartParams(names: ["db"], project: env.project, timeoutSeconds: 5),
            GroupResult.self)
        let server = try #require(restarted.results.first?.server)
        #expect(reader.reads >= 2, "no status read landed between the stop and the spawn")
        #expect(server.phase == .running)
        #expect(server.specStale != true)
        #expect(try String(contentsOfFile: envFile, encoding: .utf8) == "\(port)\n")

        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** The same race at its natural timing: status reads fired back to back
        through several restarts never leave a run reading as stale. */
    @Test func statusReadsDuringRestartsNeverLeaveARunStale() async throws {
        let env = try makeRouterEnv(named: "restart")
        let port = TestPorts.port(425)
        _ = try writePortSensitiveConfig(port: port, project: env.project)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await router.call(
            .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)

        let reads = Task {
            var stale = 0
            while !Task.isCancelled {
                let list = try await router.call(
                    .serverStatus, ProjectParams(name: "db", project: env.project),
                    ServerListResult.self)
                if list.servers.first?.specStale == true { stale += 1 }
            }
            return stale
        }
        var phases: [ServerPhase] = []
        for _ in 0..<5 {
            let restarted = try await router.call(
                .serverRestart,
                RestartParams(names: ["db"], project: env.project, timeoutSeconds: 5),
                GroupResult.self)
            phases.append(try #require(restarted.results.first?.server.phase))
        }
        reads.cancel()
        let staleReads = try await reads.value
        #expect(phases == Array(repeating: .running, count: 5))
        #expect(staleReads == 0)
        let settled = try #require(
            try await router.call(
                .serverStatus, ProjectParams(name: "db", project: env.project),
                ServerListResult.self
            ).servers.first)
        #expect(settled.specStale != true)

        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }
}

/** A port probe that reports every port free and fires one status read through
    the router per probe, so a read lands exactly where the probe is asked: in
    a restart, between the stop and the spawn. A read's own probes (latent
    conflict checks) do not fire another. */
final class StatusReadingProbe: Sendable {
    private struct State {
        var armed = false
        var project = ""
        var reading = false
        var reads = 0
        var router: Router?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var reads: Int { state.withLock { $0.reads } }

    var probe: PortProbe {
        PortProbe(isListening: { [self] _ in
            await readStatus()
            return false
        })
    }

    func arm() {
        state.withLock { $0.armed = true }
    }

    func attach(router: Router, project: String) {
        state.withLock {
            $0.project = project
            $0.router = router
        }
    }

    private func readStatus() async {
        let target = state.withLock { state -> (Router, String)? in
            guard state.armed, !state.reading, let router = state.router else { return nil }
            state.reading = true
            return (router, state.project)
        }
        guard let (router, project) = target else { return }
        do {
            _ = try await router.call(
                .serverStatus, ProjectParams(name: "db", project: project), ServerListResult.self)
        } catch {
            Issue.record("the status read in the stopped gap failed: \(error)")
        }
        state.withLock {
            $0.reading = false
            $0.reads += 1
        }
    }
}

/** The port probe of a stop-then-spawn test, scripted around the first run's
    process: while that process is alive the ports read free (the pre-checks
    pass), and once it is gone a stand-in listener holds them for
    `pollsBeforeLeaving` probes (forever by default). `listenerInfo` names
    the stand-in: the first run's own pid or a pid outside it. */
final class LingeringListener: Sendable {
    enum Reported { case outsider, stoppedRun }

    private struct State {
        var firstRun: pid_t?
        var polls = 0
    }

    private let pollsBeforeLeaving: Int
    private let reports: Reported
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(pollsBeforeLeaving: Int = .max, reports: Reported) {
        self.pollsBeforeLeaving = pollsBeforeLeaving
        self.reports = reports
    }

    /** Probes answered while the stand-in held the ports. */
    var polls: Int { state.withLock { $0.polls } }

    var probe: PortProbe {
        PortProbe(
            isListening: { [self] _ in listening() },
            listenerInfo: { [self] _ in (pid: Int(reportedPid), command: "stand-in listener") })
    }

    var reportedPid: pid_t {
        switch reports {
        case .outsider: getpid()
        case .stoppedRun: state.withLock { $0.firstRun } ?? 0
        }
    }

    func watch(pid: pid_t) {
        state.withLock { $0.firstRun = pid }
    }

    private func listening() -> Bool {
        state.withLock { state in
            guard let pid = state.firstRun, kill(pid, 0) != 0 else { return false }
            state.polls += 1
            return state.polls <= pollsBeforeLeaving
        }
    }
}
