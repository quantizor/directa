import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

private func writeLockDevservers(project: String) throws {
    let body = """
    {
      "servers": {
        "db": {
          "command": ["/bin/sh", "-c", "sleep 60"],
          "locks": ["data"]
        }
      },
      "version": 1
    }
    """
    try Data(body.utf8).write(
        to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
}

private func startDB(router: Router, project: String) async throws {
    _ = try await router.call(.serverStart, ServerTargetParams(name: "db", project: project), ServerResult.self)
    /** Pause detection acts on a live phase. */
    let live = try await eventually(within: .seconds(5), every: .milliseconds(20)) {
        let phase = try await phaseOf(router: router, project: project, name: "db")
        return [.starting, .running].contains(phase)
    }
    #expect(live, "db never reached a live phase")
}

private func phaseOf(router: Router, project: String, name: String) async throws -> ServerPhase {
    let list = try await router.call(.serverStatus, ProjectParams(project: project), ServerListResult.self)
    let server = try #require(list.servers.first { $0.server == name })
    return server.phase
}

@Suite(.serialized, .temporaryTree) struct ResourceLockTests {
    /** Acquire pauses the declaring server, refuses ensure, release brings it
        back. Pause is non-retiring so boot intent survives the hold. */
    @Test func acquirePausesReleaseResumesAndPreservesBootIntent() async throws {
        let env = try makeRouterEnv(named: "lock")
        try writeLockDevservers(project: env.project)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        try await startDB(router: router, project: env.project)
        let id = serverID(project: env.project, name: "db")
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        let acquired = try await router.call(
            .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: true, project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        #expect(acquired.paused == ["db"])
        #expect(try await phaseOf(router: router, project: env.project, name: "db") == .stopped)
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)
        #expect(FileManager.default.fileExists(atPath: env.paths.locksFile.path))

        let ensureResponse = try await router.response(
            .serverEnsure, EnsureParams(name: "db", project: env.project, timeoutSeconds: 2), EnsureResult.self)
        #expect(ensureResponse.ok == false)
        #expect(ensureResponse.error?.code == .resourceLocked)
        #expect(ensureResponse.error?.hint == "run: ps -p \(getpid())")
        #expect(ensureResponse.error?.message.hasSuffix("; it is released when the holder finishes") == true)

        let released = try await router.call(
            .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        #expect(released.paused == ["db"])
        let phase = try await phaseOf(router: router, project: env.project, name: "db")
        #expect(phase == .starting || phase == .running)
        _ = try await router.call(.serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
    }

    /** A lock pause's reason survives in the server's own log (OSLog does not
        persist) and on the `stopped` event, naming the resource, not just the
        exit code the pause itself caused. */
    @Test func acquirePauseLogsAndEventsTheResourceAsTheReason() async throws {
        let env = try makeRouterEnv(named: "lock")
        try writeLockDevservers(project: env.project)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        try await startDB(router: router, project: env.project)

        _ = try await router.call(
            .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: true, project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        #expect(try await phaseOf(router: router, project: env.project, name: "db") == .stopped)

        let logs = try await router.call(
            .logsQuery, LogsQueryParams(name: "db", project: env.project, streams: [.sys]), LogsQueryResult.self)
        #expect(logs.lines.contains { $0.text == "stopping: paused for lock data" })

        let events = try await router.call(
            .eventsQuery, EventsQueryParams(project: env.project), EventsQueryResult.self)
        let stopped = try #require(events.events.last { $0.kind == .stopped })
        #expect(stopped.detail == "paused for lock data")

        _ = try await router.call(
            .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        _ = try await router.call(.serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
    }

    /** A waiting run has to be able to name the holder, or it looks hung and
        someone kills the run that is making progress. */
    @Test func lockStatusNamesTheLiveHolderAndForgetsADeadOne() async throws {
        let env = try makeRouterEnv(named: "lock")
        try writeLockDevservers(project: env.project)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        try await startDB(router: router, project: env.project)

        let empty = try await router.call(
            .lockStatus, LockStatusParams(project: env.project, resource: "data"), LockStatusResult.self)
        #expect(empty.holder == nil)

        _ = try await router.call(
            .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: true, project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        let held = try await router.call(
            .lockStatus, LockStatusParams(project: env.project, resource: "data"), LockStatusResult.self)
        let holder = try #require(held.holder)
        #expect(holder.pid == Int(getpid()))
        #expect(holder.pause == true)
        #expect(holder.paused == ["db"])
        #expect(holder.live == nil)

        _ = try await router.call(
            .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        let after = try await router.call(
            .lockStatus, LockStatusParams(project: env.project, resource: "data"), LockStatusResult.self)
        #expect(after.holder == nil)
        _ = try await router.call(.serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
    }

    /** By default (no pause) the declarers stay up, and which ones is exactly
        what a waiting run needs to be told. Omitting `pause` here also guards the
        daemon default: an absent flag must not stop a declarer. */
    @Test func defaultAcquireRecordsTheServersItLeftRunning() async throws {
        let env = try makeRouterEnv(named: "lock")
        try writeLockDevservers(project: env.project)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        try await startDB(router: router, project: env.project)

        let acquired = try await router.call(
            .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), project: env.project,
                resource: "data", resumeTimeoutSeconds: 15),
            LockResult.self)
        #expect(acquired.live == ["db"])
        #expect(acquired.paused.isEmpty)
        let held = try await router.call(
            .lockStatus, LockStatusParams(project: env.project, resource: "data"), LockStatusResult.self)
        #expect(held.holder?.live == ["db"])
        #expect(held.holder?.pause == false)
        /** The claim is that nothing was paused. startDB does not health-gate, so
            the server is legitimately still starting; `stopped` is what a pause
            would have left behind. */
        #expect(try await phaseOf(router: router, project: env.project, name: "db") != .stopped)

        _ = try await router.call(
            .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        _ = try await router.call(.serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
    }

    /** The reported failure: daemon dies mid-hold, holder is gone, recover must
        resume the paused set from locks.json. */
    @Test func recoverResumesWhenHolderIsDead() async throws {
        let env = try makeRouterEnv(named: "lock")
        try writeLockDevservers(project: env.project)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let id = serverID(project: env.project, name: "db")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
            entry.pid = nil
        }
        /** A pid we know is gone: spawn and wait, then reuse the identifier. */
        let deadPid = Int(try await TestProcess.run("/usr/bin/true", []).pid)
        #expect(kill(pid_t(deadPid), 0) != 0)
        let key = "\(canonicalProjectPath(env.project))::data"
        try AtomicFile.write(
            JSONCoding.encoder().encode(
                LocksFile(
                    locks: [
                        key: LockHolder(
                            paused: ["db"], pid: deadPid, resumeTimeoutSeconds: 15, since: Date())
                    ])),
            to: env.paths.locksFile)

        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        let list = try await router.call(.serverStatus, ProjectParams(project: env.project), ServerListResult.self)
        let server = try #require(list.servers.first { $0.server == "db" })
        #expect(
            server.phase == .starting || server.phase == .running,
            "resumed server is \(server.phase.rawValue), last exit \(String(describing: server.lastExit))")
        let locks = AtomicFile.loadDefensively(LocksFile.self, from: env.paths.locksFile)
        #expect(locks?.locks.isEmpty == true)
        _ = try await router.call(.serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
    }

    /** A second holder's acquire is refused with the live holder's pid as the
        one command to run, and the wait advice in the message. */
    @Test func acquireByASecondHolderNamesTheLiveHolder() async throws {
        let env = try makeRouterEnv(named: "lock")
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await router.call(
            .lockAcquire, LockParams(holderPid: Int(getpid()), project: env.project, resource: "data"),
            LockResult.self)

        let outcome = try await router.attempt(
            .lockAcquire,
            LockParams(holderPid: Int(getpid()) + 1, project: env.project, resource: "data"),
            LockResult.self)
        guard case .failure(let error) = outcome else {
            Issue.record("a second holder acquired a resource a live process holds")
            return
        }
        #expect(error.code == .resourceLocked)
        #expect(error.hint == "run: ps -p \(getpid())")
        #expect(error.message.hasPrefix("resource 'data' is locked by pid \(getpid()) since "))
        #expect(error.message.hasSuffix("; wait for it to finish"))

        _ = try await router.call(
            .lockRelease, LockParams(holderPid: Int(getpid()), project: env.project, resource: "data"),
            LockResult.self)
    }

    /** A name holding `,` or `::` could not be split back out of the
        `DIRECTA_LOCKS` list a guarded command reads, so the daemon refuses it
        for a client that never checked, and holds nothing. */
    @Test func acquireRefusesAResourceNameTheLockListCannotHold() async throws {
        let env = try makeRouterEnv(named: "lock")
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        for name in ["a,b", "a::b"] {
            let outcome = try await router.attempt(
                .lockAcquire,
                LockParams(holderPid: Int(getpid()), project: env.project, resource: name),
                LockResult.self)
            guard case .failure(let error) = outcome else {
                Issue.record("a lock named \(name) was granted")
                continue
            }
            #expect(error.code == .usage)
            #expect(error.hint == "run: directa lock a-b -- <command>")
        }
        let status = try await router.call(
            .lockStatus, LockStatusParams(project: env.project, resource: "a,b"), LockStatusResult.self)
        #expect(status.holder == nil)
    }

    /** If the harness survived the daemon restart, recover must leave the
        paused server down and keep the lock so ensure stays refused. */
    @Test func recoverLeavesPausedWhenHolderStillAlive() async throws {
        let env = try makeRouterEnv(named: "lock")
        try writeLockDevservers(project: env.project)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let id = serverID(project: env.project, name: "db")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
            entry.pid = nil
        }
        let livePid = Int(getpid())
        let key = "\(canonicalProjectPath(env.project))::data"
        try AtomicFile.write(
            JSONCoding.encoder().encode(
                LocksFile(
                    locks: [
                        key: LockHolder(
                            paused: ["db"], pid: livePid, resumeTimeoutSeconds: 15, since: Date())
                    ])),
            to: env.paths.locksFile)

        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        #expect(try await phaseOf(router: router, project: env.project, name: "db") == .stopped)

        let ensureResponse = try await router.response(
            .serverEnsure, EnsureParams(name: "db", project: env.project, timeoutSeconds: 2), EnsureResult.self)
        #expect(ensureResponse.error?.code == .resourceLocked)
        #expect(ensureResponse.error?.hint == "run: ps -p \(livePid)")

        _ = try await router.call(
            .lockRelease,
            LockParams(
                holderPid: livePid, project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        let phase = try await phaseOf(router: router, project: env.project, name: "db")
        #expect(phase == .starting || phase == .running)
        _ = try await router.call(.serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
    }

    @Test func defaultLeavesDeclarerRunning() async throws {
        let env = try makeRouterEnv(named: "lock")
        try writeLockDevservers(project: env.project)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        try await startDB(router: router, project: env.project)
        let acquired = try await router.call(
            .lockAcquire,
            LockParams(holderPid: Int(getpid()), project: env.project, resource: "data"),
            LockResult.self)
        #expect(acquired.paused.isEmpty)
        let phase = try await phaseOf(router: router, project: env.project, name: "db")
        #expect(phase == .starting || phase == .running)
        /** Already-up under a default lock is not a start: groupUp no-ops. */
        _ = try await router.call(.groupUp, GroupParams(project: env.project, timeoutSeconds: 5), GroupResult.self)
        let stillUp = try await phaseOf(router: router, project: env.project, name: "db")
        #expect(stillUp == .starting || stillUp == .running)
        _ = try await router.call(.serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
        let upResponse = try await router.response(
            .groupUp, GroupParams(project: env.project, timeoutSeconds: 2), GroupResult.self)
        #expect(upResponse.error?.code == .resourceLocked)
        #expect(upResponse.error?.hint == "run: ps -p \(getpid())")
        _ = try await router.call(
            .lockRelease,
            LockParams(holderPid: Int(getpid()), pause: false, project: env.project, resource: "data"),
            LockResult.self)
        _ = try await router.call(.serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
    }

    /** Experiment L: rapid pause/resume must not leave the declarer in
        `crashed`. Classifies L1/L2/L3 via phase + lastExit after each cycle. */
    @Test func rapidAcquireReleaseNeverLeavesCrashed() async throws {
        let fixture = try #require(fixtureServerPath())
        let env = try makeRouterEnv(named: "lock")
        /** Inside the block TestPorts leases, so a failure here leaves a
            fixture the next run's reaper finds, and clear of scripts/smoke.sh,
            which draws its project-phase ports from elsewhere. */
        let port = TestPorts.port(500 + Int.random(in: 0..<250))
        let body = """
        {
          "servers": {
            "db": {
              "command": ["\(fixture)", "--listen-tcp", "\(port)"],
              "healthcheck": { "type": "tcp", "port": \(port) },
              "locks": ["data"],
              "port": \(port)
            }
          },
          "version": 1
        }
        """
        try Data(body.utf8).write(
            to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await router.call(
            .serverEnsure, EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        var crashCount = 0
        var lastCrashDetail = ""
        for cycle in 0..<20 {
            let holder = Int(getpid())
            _ = try await router.call(
                .lockAcquire,
                LockParams(
                    holderPid: holder, pause: true, project: env.project, resource: "data",
                    resumeTimeoutSeconds: 15),
                LockResult.self)
            #expect(try await phaseOf(router: router, project: env.project, name: "db") == .stopped)
            _ = try await router.call(
                .lockRelease,
                LockParams(
                    holderPid: holder, project: env.project, resource: "data",
                    resumeTimeoutSeconds: 15),
                LockResult.self)
            let list = try await router.call(.serverStatus, ProjectParams(project: env.project), ServerListResult.self)
            let server = try #require(list.servers.first { $0.server == "db" })
            if server.phase == .crashed {
                crashCount += 1
                lastCrashDetail =
                    "cycle \(cycle) pid=\(server.pid.map(String.init) ?? "nil") exit=\(String(describing: server.lastExit))"
            }
            if server.phase == .starting || server.phase == .running {
                _ = try await router.call(
                    .serverEnsure, EnsureParams(name: "db", project: env.project, timeoutSeconds: 10),
                    EnsureResult.self)
            }
        }
        let final = try await phaseOf(router: router, project: env.project, name: "db")
        #expect(crashCount == 0, "\(lastCrashDetail)")
        #expect(final == .running || final == .starting)
        _ = try await router.call(.serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
    }

    /** Experiment L with a grandchild that can outlive a naive root-only stop. */
    @Test func rapidAcquireReleaseWithGrandchildNeverLeavesCrashed() async throws {
        let fixture = try #require(fixtureServerPath())
        let env = try makeRouterEnv(named: "lock")
        let port = TestPorts.port(750 + Int.random(in: 0..<250))
        let body = """
        {
          "servers": {
            "db": {
              "command": ["\(fixture)", "--listen-tcp", "\(port)", "--spawn-grandchild"],
              "healthcheck": { "type": "tcp", "port": \(port) },
              "locks": ["data"],
              "port": \(port)
            }
          },
          "version": 1
        }
        """
        try Data(body.utf8).write(
            to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await router.call(
            .serverEnsure, EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        var crashCount = 0
        for _ in 0..<12 {
            let holder = Int(getpid())
            _ = try await router.call(
                .lockAcquire,
                LockParams(
                    holderPid: holder, pause: true, project: env.project, resource: "data",
                    resumeTimeoutSeconds: 15),
                LockResult.self)
            _ = try await router.call(
                .lockRelease,
                LockParams(
                    holderPid: holder, project: env.project, resource: "data",
                    resumeTimeoutSeconds: 15),
                LockResult.self)
            let list = try await router.call(.serverStatus, ProjectParams(project: env.project), ServerListResult.self)
            let server = try #require(list.servers.first { $0.server == "db" })
            if server.phase == .crashed { crashCount += 1 }
            if server.phase == .starting || server.phase == .running || server.phase == .crashed
                || server.phase == .stopped
            {
                _ = try? await router.call(
                    .serverEnsure, EnsureParams(name: "db", project: env.project, timeoutSeconds: 10),
                    EnsureResult.self)
            }
        }
        #expect(crashCount == 0)
        _ = try await router.call(.serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
    }
}

/** Runs a spawn whose command ends in `stuck` on the double that never reports
    an exit (its stop can only give up) and every other on a real process. */
private struct StuckOrRealLauncher: NeverAdopts {
    let stuck: StuckRunLauncher
    let real: any ProcessLauncher = SubprocessLauncher()

    func run(
        argv: [String], capture: SpawnCapture, cwd: String?, environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        let target: any ProcessLauncher = argv.last == "stuck" ? stuck : real
        return await target.run(
            argv: argv, capture: capture, cwd: cwd, environment: environment,
            onExitedBeforeWatch: onExitedBeforeWatch, onSpawn: onSpawn)
    }
}

/** The guarantees `--pause` gives the guarded command: it starts only with
    every paused declarer's whole tree gone, and never beside one whose stop
    gave up. Not serialized with the suite above: each test has a tree and a
    router of its own, and the suite above is already the longest on the
    critical path. */
@Suite(.temporaryTree) struct ResourceLockPauseTests {
    private let stopTiming = StopTiming(graceSeconds: 0.05, overtimeSeconds: 0.1)

    private func writeDevservers(project: String, servers: String) throws {
        let body = #"{ "servers": { \#(servers) }, "version": 1 }"#
        try Data(body.utf8).write(
            to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
    }

    private func outLines(router: Router, project: String, name: String) async throws -> [String] {
        try await router.call(
            .logsQuery, LogsQueryParams(name: name, project: project, streams: [.out]),
            LogsQueryResult.self
        ).lines.map(\.text)
    }

    private func pid(prefix: String, in lines: [String]) -> pid_t? {
        lines.compactMap { line in
            line.hasPrefix(prefix) ? pid_t(line.dropFirst(prefix.count)) : nil
        }.first
    }

    /** A declarer that ignores SIGTERM and leaves a setsid child plus an orphan
        that ignores it too is only reached by the SIGKILL pass. The acquire
        that comes back must find none of them alive, not merely the root. */
    @Test func acquireGrantsOnlyOnceTheWholeTreeOfASigtermIgnoringDeclarerIsGone() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeRouterEnv(named: "lock-tree")
        let port = TestPorts.port(700)
        let command = [
            fixture, "--ignore-sigterm", "--setsid-listener", "\(port)", "--orphan-grandchild-ignterm",
        ].map { "\"\($0)\"" }.joined(separator: ", ")
        try writeDevservers(
            project: env.project, servers: #""db": { "command": [\#(command)], "locks": ["data"] }"#)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths, registry: registry,
            stopTiming: StopTiming(graceSeconds: 0.3, overtimeSeconds: 5))
        try await startDB(router: router, project: env.project)

        var listener: pid_t?
        var orphan: pid_t?
        let reported = try await eventually(within: .seconds(5), every: .milliseconds(20)) {
            let lines = try await outLines(router: router, project: env.project, name: "db")
            listener = pid(prefix: "setsid listener pid ", in: lines)
            orphan = pid(prefix: "grandchild pid ", in: lines)
            return listener != nil && orphan != nil
        }
        #expect(reported, "the fixture never reported its descendants")
        let descendants = try [#require(listener), #require(orphan)]
        #expect(descendants.allSatisfy { kill($0, 0) == 0 }, "the descendants were not running before the pause")

        let acquired = try await router.call(
            .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: true, project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        #expect(acquired.paused == ["db"])
        let survivors = descendants.filter { kill($0, 0) == 0 }
        defer { survivors.forEach { _ = kill($0, SIGKILL) } }
        #expect(survivors.isEmpty, "the lock was granted while \(survivors) still ran")

        _ = try await router.call(
            .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        _ = try await router.call(.serverStop, ServerTargetParams(name: "db", project: env.project), ServerResult.self)
    }

    /** The hint is a command someone pastes, so a server name from committed
        config reaches it only when it is inert. */
    @Test func theRefusalNamesTheServerAndPointsAtWhy() {
        let gaveUp = Router.pauseRefusal(
            server: "db", project: "/p/app", resource: "data", survivors: nil)
        #expect(gaveUp.code == .resourceLocked)
        #expect(gaveUp.hint == "run: directa why db --project '/p/app'")
        #expect(
            gaveUp.message
                == "server 'db' did not finish stopping and may still hold resource 'data' open; the lock was not granted and the command did not run, and any other server paused for it was resumed"
        )

        let left = Router.pauseRefusal(
            server: "db", project: "/p/app", resource: "data", survivors: [41, 42])
        #expect(
            left.message
                == "server 'db' stopped, but its processes 41, 42 survived a forced kill and may still hold resource 'data' open; the lock was not granted and the command did not run, and any other server paused for it was resumed"
        )

        let one = Router.pauseRefusal(
            server: "db", project: "/p/app", resource: "data", survivors: [41])
        #expect(
            one.message
                == "server 'db' stopped, but its process 41 survived a forced kill and may still hold resource 'data' open; the lock was not granted and the command did not run, and any other server paused for it was resumed"
        )

        let hostile = Router.pauseRefusal(
            server: "x; rm -rf ~", project: "/p/app", resource: "data", survivors: nil)
        #expect(hostile.hint == "run: directa why <name> --project '/p/app'")
    }

    /** An ensure restart that comes back empty points at `why` with the project,
        the same as every other refusal that names a server. */
    @Test func aRestartWithNoResultNamesTheServerProjectAndWhy() {
        let gap = Router.restartGapError(name: "db", project: "/p/app")
        #expect(gap.code == .internalError)
        #expect(gap.hint == "run: directa why db --project '/p/app'")
        #expect(gap.message == "restarting 'db' returned no result")
    }

    /** A declarer whose stop never lands (its run reports no exit), declaring
        `data`, running through `router`. */
    private func stuckDeclarerRouter(
        named name: String, gate: AdoptGate, overtimeSeconds: Double
    ) async throws -> (env: RouterEnv, router: Router) {
        let env = try makeRouterEnv(named: name)
        try writeDevservers(
            project: env.project,
            servers: #""db": { "command": ["/bin/sh", "-c", "sleep 60", "stuck"], "locks": ["data"] }"#)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(
            launcher: StuckOrRealLauncher(stuck: StuckRunLauncher(gate: gate)), paths: env.paths,
            registry: registry,
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: overtimeSeconds))
        try await startDB(router: router, project: env.project)
        return (env, router)
    }

    /** The key is held from the moment an acquire begins pausing declarers: an
        `ensure` of the declarer, or a second acquire, that lands while the
        pause is still stopping it is refused as contended and names the
        holder. When the pause then gives up, nothing stays held. */
    @Test func anEnsureOrASecondAcquireLandingMidPauseIsRefusedAsContended() async throws {
        let gate = AdoptGate()
        defer { gate.signal(.signaled(signal: Int(SIGKILL))) }
        let (env, router) = try await stuckDeclarerRouter(
            named: "lock-reserve", gate: gate, overtimeSeconds: 0.5)
        let project = env.project
        let first = Task {
            try await router.attempt(
                .lockAcquire,
                LockParams(
                    holderPid: Int(getpid()), pause: true, project: project, resource: "data",
                    resumeTimeoutSeconds: 15),
                LockResult.self)
        }
        let pausing = try await eventually(within: .seconds(5), every: .milliseconds(5)) {
            try await phaseOf(router: router, project: env.project, name: "db") == .stopping
        }
        try #require(pausing)

        let ensure = try await router.response(
            .serverEnsure, EnsureParams(name: "db", project: env.project, timeoutSeconds: 2),
            EnsureResult.self)
        #expect(ensure.error?.code == .resourceLocked)
        #expect(ensure.error?.hint == "run: ps -p \(getpid())")

        let second = try await router.attempt(
            .lockAcquire,
            LockParams(
                holderPid: Int(getppid()), pause: true, project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        guard case .failure(let contended) = second else {
            Issue.record("a second acquire was granted over a pause still in progress: \(second)")
            return
        }
        #expect(contended.code == .resourceLocked)
        #expect(contended.hint == "run: ps -p \(getpid())")

        guard case .failure(let refusal) = try await first.value else {
            Issue.record("the pause was granted over a declarer whose stop never landed")
            return
        }
        #expect(
            refusal.hint
                == "run: directa why db --project \(ShellWord.singleQuoted(canonicalProjectPath(env.project)))")
        let held = try await router.call(
            .lockStatus, LockStatusParams(project: env.project, resource: "data"), LockStatusResult.self)
        #expect(held.holder == nil)
        try await releaseStuckDeclarer(router: router, project: env.project, gate: gate)
    }

    /** Lets the stuck declarer's run end and waits for its supervisor to finish
        writing, so nothing writes into the test's tree after it is removed. */
    private func releaseStuckDeclarer(router: Router, project: String, gate: AdoptGate) async throws {
        gate.signal(.signaled(signal: Int(SIGKILL)))
        let settled = try await eventually(within: .seconds(5)) {
            try await phaseOf(router: router, project: project, name: "db") == .stopped
        }
        #expect(settled, "the stuck declarer never settled after its run was released")
    }

    /** A pause that arrives while a stop is already in flight answers with
        that stop's own completion, the moment it lands, rather than waiting
        out a bound of its own that starts later: the in-flight stop never
        lands here, so both give up together. */
    @Test func aPauseJoiningAStopInFlightSharesItsCompletion() async throws {
        let gate = AdoptGate()
        defer { gate.signal(.signaled(signal: Int(SIGKILL))) }
        let (env, router) = try await stuckDeclarerRouter(
            named: "lock-join", gate: gate, overtimeSeconds: 0.6)
        let clock = ContinuousClock()
        let stopBegan = clock.now
        let project = env.project
        let stop = Task {
            _ = try await router.attempt(
                .serverStop, ServerTargetParams(name: "db", project: project), ServerResult.self)
            return clock.now
        }
        let stopping = try await eventually(within: .seconds(5), every: .milliseconds(5)) {
            try await phaseOf(router: router, project: env.project, name: "db") == .stopping
        }
        try #require(stopping)
        /** Joins well into the stop's bound, so a bound of its own would end
            long after the stop's. */
        let joinAt = stopBegan.advanced(by: .milliseconds(300))
        let late = try await eventually(within: .seconds(5), every: .milliseconds(5)) {
            clock.now >= joinAt
        }
        try #require(late)

        let attempt = try await router.attempt(
            .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: true, project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        let joinerEnded = clock.now
        let stopEnded = try await stop.value

        guard case .failure(let refusal) = attempt else {
            Issue.record("the pause was granted over a stop that never landed: \(attempt)")
            return
        }
        #expect(
            refusal.hint
                == "run: directa why db --project \(ShellWord.singleQuoted(canonicalProjectPath(project)))")
        #expect(
            joinerEnded - stopEnded < .milliseconds(150),
            "the pause waited a bound of its own after the stop it joined gave up")
        try await releaseStuckDeclarer(router: router, project: env.project, gate: gate)
    }

    /** One declarer stops cleanly and the next one's stop gives up: the lock is
        refused with `resource-locked` naming the second, the first is back up,
        and no hold is left recorded. */
    @Test func aDeclarerWhoseStopGivesUpRefusesTheLockAndResumesTheOthers() async throws {
        let env = try makeRouterEnv(named: "lock-stuck")
        try writeDevservers(
            project: env.project,
            servers: """
                "a-cache": { "command": ["/bin/sh", "-c", "sleep 60"], "locks": ["data"] },
                "db": { "command": ["/bin/sh", "-c", "sleep 60", "stuck"], "locks": ["data"] }
                """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let gate = AdoptGate()
        let router = Router(
            launcher: StuckOrRealLauncher(stuck: StuckRunLauncher(gate: gate)), paths: env.paths,
            registry: registry, stopTiming: stopTiming)
        _ = try await router.call(
            .serverStart, ServerTargetParams(name: "a-cache", project: env.project), ServerResult.self)
        try await startDB(router: router, project: env.project)
        defer { gate.signal(.signaled(signal: Int(SIGKILL))) }

        let attempt = try await router.attempt(
            .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: true, project: env.project, resource: "data",
                resumeTimeoutSeconds: 15),
            LockResult.self)
        guard case .failure(let refusal) = attempt else {
            Issue.record("the lock was granted over a declarer whose stop gave up: \(attempt)")
            return
        }
        #expect(refusal.code == .resourceLocked)
        #expect(
            refusal.hint
                == "run: directa why db --project \(ShellWord.singleQuoted(canonicalProjectPath(env.project)))")
        #expect(refusal.message.contains("'db'"))

        let held = try await router.call(
            .lockStatus, LockStatusParams(project: env.project, resource: "data"), LockStatusResult.self)
        #expect(held.holder == nil)
        let resumed = try await eventually(within: .seconds(10), every: .milliseconds(50)) {
            [.starting, .running].contains(
                try await phaseOf(router: router, project: env.project, name: "a-cache"))
        }
        #expect(resumed, "the declarer paused before the refusal was not resumed")

        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "a-cache", project: env.project), ServerResult.self)
        gate.signal(.signaled(signal: Int(SIGKILL)))
        let settled = try await eventually(within: .seconds(5)) {
            try await phaseOf(router: router, project: env.project, name: "db") == .stopped
        }
        #expect(settled, "the stuck declarer never settled after its run was released")
    }
}

private func fixtureServerPath() -> String? { fixtureServerExecutable() }
