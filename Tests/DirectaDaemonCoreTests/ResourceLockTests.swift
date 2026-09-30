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

private func fixtureServerPath() -> String? { fixtureServerExecutable() }
