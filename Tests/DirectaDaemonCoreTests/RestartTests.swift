import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

/** `directa stop X && directa ensure X` was what twelve sessions wrote by hand.
    It has two defects a single daemon-side transition removes: another session's
    ensure can land between the two commands, and a refusal (a held resource, a
    broken config) arrives only after the server is already down. */
@Suite(.serialized, .temporaryTree) struct RestartTests {
    /** A port per test: a case that fails before its teardown would otherwise
        leave a listener behind and fail the next one for an unrelated reason. */
    private func env(
        flood: Bool = false, port: Int, waitFor: String? = nil
    ) throws -> (paths: DirectaPaths, project: String) {
        let base = try TemporaryTree.directory(named: "restart")
        let project = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writeConfig(flood: flood, port: port, project: project.path, waitFor: waitFor)
        return (
            paths: DirectaPaths(
                dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            project: project.path
        )
    }

    private func writeConfig(
        flood: Bool = false, port: Int, project: String, waitFor: String? = nil
    ) throws {
        let fixture = try #require(Self.fixtureServerPath())
        /** `--flood` composes with `--listen-tcp`: the fixture still binds and
            answers the healthcheck, it just also writes heartbeat lines as
            fast as possible instead of pacing them, which is what makes the
            stop-side tailer drain slow enough to expose a stuck `.stopping`
            wait. */
        let floodFlag = flood ? ", \"--flood\"" : ""
        let waitForField = waitFor.map { ",\n          \"waitFor\": \"\($0)\"" } ?? ""
        let body = """
            {
              "servers": {
                "db": {
                  "command": ["\(fixture)", "--listen-tcp", "\(port)"\(floodFlag)],
                  "healthcheck": { "type": "tcp", "port": \(port) },
                  "locks": ["data"],
                  "port": \(port)\(waitForField)
                }
              },
              "version": 1
            }
            """
        try Data(body.utf8)
            .write(to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
    }

    private func handle<P: Codable & Sendable, R: Codable & Sendable>(
        _ router: Router, _ method: WireMethod, _ params: P, _ expecting: R.Type
    ) async throws -> R {
        let line = try NDJSON.encodeLine(
            WireRequest(id: "t", method: method.rawValue, params: params))
        let data = await router.handle(line: line)
        let response = try JSONCoding.decoder().decode(WireResponse<R>.self, from: data)
        if response.ok, let result = response.result { return result }
        throw response.error ?? WireError(code: .internalError, message: "no result")
    }

    private func phase(_ router: Router, _ project: String, _ name: String) async throws
        -> ServerPhase
    {
        let list = try await handle(
            router, .serverStatus, ProjectParams(project: project), ServerListResult.self)
        return try #require(list.servers.first { $0.server == name }).phase
    }

    @Test func restartReplacesThePidAndKeepsResumeOnBoot() async throws {
        let env = try env(port: 45411)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let first = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        #expect(first.server.phase == .running)
        let id = serverID(project: env.project, name: "db")
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        let restarted = try await handle(
            router, .serverRestart,
            RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
            GroupResult.self)
        let server = try #require(restarted.results.first?.server)
        #expect(server.phase == .running)
        #expect(server.pid != first.server.pid)
        /** A deliberate stop would clear this, so a hand-rolled stop-then-ensure
            drops the boot intent and re-sets it; restart never drops it. */
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** Restarting a server that floods stdout: recordOutcome clears
        `runTask` before its tailer drain (slow under a flood) and registry
        write, so the restart's `ensure()` must wait on the phase leaving
        `.stopping`, never on `runTask`, or it recurses on the actor without
        suspending and grows the daemon's heap until it is killed. */
    @Test func restartOfAFloodingServerCompletesAndStaysRunning() async throws {
        let env = try env(flood: true, port: 45417)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let first = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        #expect(first.server.phase == .running)

        try await Task.sleep(for: .seconds(1))

        let restarted = try await handle(
            router, .serverRestart,
            RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
            GroupResult.self)
        let server = try #require(restarted.results.first?.server)
        #expect(server.phase == .running)
        #expect(server.pid != first.server.pid)

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
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
        let env = try env(flood: true, port: 45418, waitFor: "started")
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let first = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        #expect(first.server.phase == .running)

        async let stopResult: ServerResult = handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
        /** A head start for the stop: long enough that its SIGTERM is sent and
            the flooding tailer drain is under way, short enough that `up`
            still lands while the phase reads `.stopping`. */
        try await Task.sleep(for: .milliseconds(50))

        let up = try await handle(
            router, .groupUp, GroupParams(project: env.project, timeoutSeconds: 10),
            GroupResult.self)
        let started = try #require(up.results.first { $0.server.server == "db" }).server
        #expect(started.pid != first.server.pid)

        var running = false
        for _ in 0..<50 where !running {
            running = try await phase(router, env.project, "db") == .running
            if !running { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(running, "server did not become healthy after up raced a slow stop")

        _ = try await stopResult
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** An explicit restart's reason survives in the server's own log (OSLog
        does not persist) and on the `stopped` event, not just as an exit code
        directa itself caused. */
    @Test func restartLogsAndEventsTheReason() async throws {
        let env = try env(port: 45416)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        _ = try await handle(
            router, .serverRestart,
            RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
            GroupResult.self)

        let logs = try await handle(
            router, .logsQuery,
            LogsQueryParams(name: "db", project: env.project, streams: [.sys]),
            LogsQueryResult.self)
        #expect(logs.lines.contains { $0.text == "stopping: requested by restart" })

        let events = try await handle(
            router, .eventsQuery, EventsQueryParams(project: env.project), EventsQueryResult.self)
        let stopped = try #require(events.events.last { $0.kind == .stopped })
        #expect(stopped.detail == "requested by restart")

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** The headline: a stop-then-ensure pair takes the server down and is then
        refused, leaving it down. Restart refuses before touching it. */
    @Test func restartUnderALiveLockIsRefusedAndLeavesTheServerRunning() async throws {
        let env = try env(port: 45412)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        _ = try await handle(
            router, .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: false, project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)

        await #expect(throws: WireError.self) {
            _ = try await handle(
                router, .serverRestart,
                RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
        }
        #expect(try await phase(router, env.project, "db") == .running)

        _ = try await handle(
            router, .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** A server the lock already paused must not come back behind the hold. */
    @Test func restartOfAPausedServerIsRefusedAndItStaysDown() async throws {
        let env = try env(port: 45413)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        let acquired = try await handle(
            router, .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: true, project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)
        #expect(acquired.paused == ["db"])

        await #expect(throws: WireError.self) {
            _ = try await handle(
                router, .serverRestart,
                RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
        }
        #expect(try await phase(router, env.project, "db") == .stopped)

        _ = try await handle(
            router, .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** A bad save must not take a healthy server down. */
    @Test func restartWithABrokenConfigLeavesTheServerRunning() async throws {
        let env = try env(port: 45414)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        try Data("{ not json".utf8)
            .write(to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))

        await #expect(throws: WireError.self) {
            _ = try await handle(
                router, .serverRestart,
                RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
        }
        /** Restore the config before reading status: the status path parses it
            too, so a broken file would fail the assertion for the wrong reason. */
        try writeConfig(port: 45414, project: env.project)
        #expect(try await phase(router, env.project, "db") == .running)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    @Test func restartOfAnUnknownNameIsNotFoundAndTouchesNothing() async throws {
        let env = try env(port: 45415)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        do {
            _ = try await handle(
                router, .serverRestart,
                RestartParams(names: ["ghost"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
            Issue.record("expected not-found")
        } catch let error as WireError {
            #expect(error.code == .notFound)
        }
        #expect(try await phase(router, env.project, "db") == .running)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    private static func fixtureServerPath() -> String? { fixtureServerExecutable() }
}
