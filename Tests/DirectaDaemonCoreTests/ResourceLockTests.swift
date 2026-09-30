import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

private struct LockEnv {
    let paths: DirectaPaths
    let projectPath: String
}

private func makeLockEnv() throws -> LockEnv {
    let base = try TemporaryTree.directory(named: "lock")
    let project = base.appending(path: "proj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return LockEnv(
        paths: DirectaPaths(dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
        projectPath: project.path)
}

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

private func handle<P: Codable & Sendable, R: Codable & Sendable>(
    router: Router, method: WireMethod, params: P, expecting: R.Type
) async throws -> R {
    let line = try NDJSON.encodeLine(
        WireRequest(id: "t", method: method.rawValue, params: params))
    let data = await router.handle(line: line)
    let response = try JSONCoding.decoder().decode(WireResponse<R>.self, from: data)
    guard response.ok, let result = response.result else {
        throw response.error
            ?? WireError(code: .internalError, message: "request failed")
    }
    return result
}

private func startDB(router: Router, project: String) async throws {
    _ = try await handle(
        router: router, method: .serverStart,
        params: ServerTargetParams(name: "db", project: project),
        expecting: ServerResult.self)
    /** Pause detection acts on a live phase. */
    let live = try await eventually(within: .seconds(5), every: .milliseconds(20)) {
        let phase = try await phaseOf(router: router, project: project, name: "db")
        return [.starting, .running].contains(phase)
    }
    #expect(live, "db never reached a live phase")
}

private func phaseOf(router: Router, project: String, name: String) async throws -> ServerPhase {
    let list = try await handle(
        router: router, method: .serverStatus,
        params: ProjectParams(project: project),
        expecting: ServerListResult.self)
    let server = try #require(list.servers.first { $0.server == name })
    return server.phase
}

@Suite(.serialized, .temporaryTree) struct ResourceLockTests {
    /** Acquire pauses the declaring server, refuses ensure, release brings it
        back. Pause is non-retiring so boot intent survives the hold. */
    @Test func acquirePausesReleaseResumesAndPreservesBootIntent() async throws {
        let env = try makeLockEnv()
        try writeLockDevservers(project: env.projectPath)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        try await startDB(router: router, project: env.projectPath)
        let id = serverID(project: env.projectPath, name: "db")
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        let acquired = try await handle(
            router: router, method: .lockAcquire,
            params: LockParams(
                holderPid: Int(getpid()), pause: true, project: env.projectPath, resource: "data",
                resumeTimeoutSeconds: 15),
            expecting: LockResult.self)
        #expect(acquired.paused == ["db"])
        #expect(try await phaseOf(router: router, project: env.projectPath, name: "db") == .stopped)
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)
        #expect(FileManager.default.fileExists(atPath: env.paths.locksFile.path))

        let ensureLine = try NDJSON.encodeLine(
            WireRequest(
                id: "e", method: WireMethod.serverEnsure.rawValue,
                params: EnsureParams(name: "db", project: env.projectPath, timeoutSeconds: 2)))
        let ensureData = await router.handle(line: ensureLine)
        let ensureResponse = try JSONCoding.decoder().decode(
            WireResponse<EnsureResult>.self, from: ensureData)
        #expect(ensureResponse.ok == false)
        #expect(ensureResponse.error?.code == .resourceLocked)
        #expect(ensureResponse.error?.hint == "run: ps -p \(getpid())")
        #expect(ensureResponse.error?.message.hasSuffix("; it is released when the holder finishes") == true)

        let released = try await handle(
            router: router, method: .lockRelease,
            params: LockParams(
                holderPid: Int(getpid()), project: env.projectPath, resource: "data",
                resumeTimeoutSeconds: 15),
            expecting: LockResult.self)
        #expect(released.paused == ["db"])
        let phase = try await phaseOf(router: router, project: env.projectPath, name: "db")
        #expect(phase == .starting || phase == .running)
        _ = try await handle(
            router: router, method: .serverStop,
            params: ServerTargetParams(name: "db", project: env.projectPath),
            expecting: ServerResult.self)
    }

    /** A lock pause's reason survives in the server's own log (OSLog does not
        persist) and on the `stopped` event, naming the resource, not just the
        exit code the pause itself caused. */
    @Test func acquirePauseLogsAndEventsTheResourceAsTheReason() async throws {
        let env = try makeLockEnv()
        try writeLockDevservers(project: env.projectPath)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        try await startDB(router: router, project: env.projectPath)

        _ = try await handle(
            router: router, method: .lockAcquire,
            params: LockParams(
                holderPid: Int(getpid()), pause: true, project: env.projectPath, resource: "data",
                resumeTimeoutSeconds: 15),
            expecting: LockResult.self)
        #expect(try await phaseOf(router: router, project: env.projectPath, name: "db") == .stopped)

        let logs = try await handle(
            router: router, method: .logsQuery,
            params: LogsQueryParams(name: "db", project: env.projectPath, streams: [.sys]),
            expecting: LogsQueryResult.self)
        #expect(logs.lines.contains { $0.text == "stopping: paused for lock data" })

        let events = try await handle(
            router: router, method: .eventsQuery,
            params: EventsQueryParams(project: env.projectPath), expecting: EventsQueryResult.self)
        let stopped = try #require(events.events.last { $0.kind == .stopped })
        #expect(stopped.detail == "paused for lock data")

        _ = try await handle(
            router: router, method: .lockRelease,
            params: LockParams(
                holderPid: Int(getpid()), project: env.projectPath, resource: "data",
                resumeTimeoutSeconds: 15),
            expecting: LockResult.self)
        _ = try await handle(
            router: router, method: .serverStop,
            params: ServerTargetParams(name: "db", project: env.projectPath),
            expecting: ServerResult.self)
    }

    /** A waiting run has to be able to name the holder, or it looks hung and
        someone kills the run that is making progress. */
    @Test func lockStatusNamesTheLiveHolderAndForgetsADeadOne() async throws {
        let env = try makeLockEnv()
        try writeLockDevservers(project: env.projectPath)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        try await startDB(router: router, project: env.projectPath)

        let empty = try await handle(
            router: router, method: .lockStatus,
            params: LockStatusParams(project: env.projectPath, resource: "data"),
            expecting: LockStatusResult.self)
        #expect(empty.holder == nil)

        _ = try await handle(
            router: router, method: .lockAcquire,
            params: LockParams(
                holderPid: Int(getpid()), pause: true, project: env.projectPath, resource: "data",
                resumeTimeoutSeconds: 15),
            expecting: LockResult.self)
        let held = try await handle(
            router: router, method: .lockStatus,
            params: LockStatusParams(project: env.projectPath, resource: "data"),
            expecting: LockStatusResult.self)
        let holder = try #require(held.holder)
        #expect(holder.pid == Int(getpid()))
        #expect(holder.pause == true)
        #expect(holder.paused == ["db"])
        #expect(holder.live == nil)

        _ = try await handle(
            router: router, method: .lockRelease,
            params: LockParams(
                holderPid: Int(getpid()), project: env.projectPath, resource: "data",
                resumeTimeoutSeconds: 15),
            expecting: LockResult.self)
        let after = try await handle(
            router: router, method: .lockStatus,
            params: LockStatusParams(project: env.projectPath, resource: "data"),
            expecting: LockStatusResult.self)
        #expect(after.holder == nil)
        _ = try await handle(
            router: router, method: .serverStop,
            params: ServerTargetParams(name: "db", project: env.projectPath),
            expecting: ServerResult.self)
    }

    /** By default (no pause) the declarers stay up, and which ones is exactly
        what a waiting run needs to be told. Omitting `pause` here also guards the
        daemon default: an absent flag must not stop a declarer. */
    @Test func defaultAcquireRecordsTheServersItLeftRunning() async throws {
        let env = try makeLockEnv()
        try writeLockDevservers(project: env.projectPath)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        try await startDB(router: router, project: env.projectPath)

        let acquired = try await handle(
            router: router, method: .lockAcquire,
            params: LockParams(
                holderPid: Int(getpid()), project: env.projectPath,
                resource: "data", resumeTimeoutSeconds: 15),
            expecting: LockResult.self)
        #expect(acquired.live == ["db"])
        #expect(acquired.paused.isEmpty)
        let held = try await handle(
            router: router, method: .lockStatus,
            params: LockStatusParams(project: env.projectPath, resource: "data"),
            expecting: LockStatusResult.self)
        #expect(held.holder?.live == ["db"])
        #expect(held.holder?.pause == false)
        /** The claim is that nothing was paused. startDB does not health-gate, so
            the server is legitimately still starting; `stopped` is what a pause
            would have left behind. */
        #expect(try await phaseOf(router: router, project: env.projectPath, name: "db") != .stopped)

        _ = try await handle(
            router: router, method: .lockRelease,
            params: LockParams(
                holderPid: Int(getpid()), project: env.projectPath, resource: "data",
                resumeTimeoutSeconds: 15),
            expecting: LockResult.self)
        _ = try await handle(
            router: router, method: .serverStop,
            params: ServerTargetParams(name: "db", project: env.projectPath),
            expecting: ServerResult.self)
    }

    /** The reported failure: daemon dies mid-hold, holder is gone, recover must
        resume the paused set from locks.json. */
    @Test func recoverResumesWhenHolderIsDead() async throws {
        let env = try makeLockEnv()
        try writeLockDevservers(project: env.projectPath)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let id = serverID(project: env.projectPath, name: "db")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
            entry.pid = nil
        }
        /** A pid we know is gone: spawn and wait, then reuse the identifier. */
        let deadPid = Int(try await TestProcess.run("/usr/bin/true", []).pid)
        #expect(kill(pid_t(deadPid), 0) != 0)
        let key = "\(canonicalProjectPath(env.projectPath))::data"
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
        let list = try await handle(
            router: router, method: .serverStatus, params: ProjectParams(project: env.projectPath),
            expecting: ServerListResult.self)
        let server = try #require(list.servers.first { $0.server == "db" })
        #expect(
            server.phase == .starting || server.phase == .running,
            "resumed server is \(server.phase.rawValue), last exit \(String(describing: server.lastExit))")
        let locks = AtomicFile.loadDefensively(LocksFile.self, from: env.paths.locksFile)
        #expect(locks?.locks.isEmpty == true)
        _ = try await handle(
            router: router, method: .serverStop,
            params: ServerTargetParams(name: "db", project: env.projectPath),
            expecting: ServerResult.self)
    }

    /** A second holder's acquire is refused with the live holder's pid as the
        one command to run, and the wait advice in the message. */
    @Test func acquireByASecondHolderNamesTheLiveHolder() async throws {
        let env = try makeLockEnv()
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router: router, method: .lockAcquire,
            params: LockParams(holderPid: Int(getpid()), project: env.projectPath, resource: "data"),
            expecting: LockResult.self)

        let outcome = try await router.attempt(
            .lockAcquire,
            LockParams(holderPid: Int(getpid()) + 1, project: env.projectPath, resource: "data"),
            LockResult.self)
        guard case .failure(let error) = outcome else {
            Issue.record("a second holder acquired a resource a live process holds")
            return
        }
        #expect(error.code == .resourceLocked)
        #expect(error.hint == "run: ps -p \(getpid())")
        #expect(error.message.hasPrefix("resource 'data' is locked by pid \(getpid()) since "))
        #expect(error.message.hasSuffix("; wait for it to finish"))

        _ = try await handle(
            router: router, method: .lockRelease,
            params: LockParams(holderPid: Int(getpid()), project: env.projectPath, resource: "data"),
            expecting: LockResult.self)
    }

    /** If the harness survived the daemon restart, recover must leave the
        paused server down and keep the lock so ensure stays refused. */
    @Test func recoverLeavesPausedWhenHolderStillAlive() async throws {
        let env = try makeLockEnv()
        try writeLockDevservers(project: env.projectPath)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let id = serverID(project: env.projectPath, name: "db")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
            entry.pid = nil
        }
        let livePid = Int(getpid())
        let key = "\(canonicalProjectPath(env.projectPath))::data"
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
        #expect(try await phaseOf(router: router, project: env.projectPath, name: "db") == .stopped)

        let ensureLine = try NDJSON.encodeLine(
            WireRequest(
                id: "e", method: WireMethod.serverEnsure.rawValue,
                params: EnsureParams(name: "db", project: env.projectPath, timeoutSeconds: 2)))
        let ensureData = await router.handle(line: ensureLine)
        let ensureResponse = try JSONCoding.decoder().decode(
            WireResponse<EnsureResult>.self, from: ensureData)
        #expect(ensureResponse.error?.code == .resourceLocked)
        #expect(ensureResponse.error?.hint == "run: ps -p \(livePid)")

        _ = try await handle(
            router: router, method: .lockRelease,
            params: LockParams(
                holderPid: livePid, project: env.projectPath, resource: "data",
                resumeTimeoutSeconds: 15),
            expecting: LockResult.self)
        let phase = try await phaseOf(router: router, project: env.projectPath, name: "db")
        #expect(phase == .starting || phase == .running)
        _ = try await handle(
            router: router, method: .serverStop,
            params: ServerTargetParams(name: "db", project: env.projectPath),
            expecting: ServerResult.self)
    }

    @Test func defaultLeavesDeclarerRunning() async throws {
        let env = try makeLockEnv()
        try writeLockDevservers(project: env.projectPath)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        try await startDB(router: router, project: env.projectPath)
        let acquired = try await handle(
            router: router, method: .lockAcquire,
            params: LockParams(
                holderPid: Int(getpid()), project: env.projectPath, resource: "data"),
            expecting: LockResult.self)
        #expect(acquired.paused.isEmpty)
        let phase = try await phaseOf(router: router, project: env.projectPath, name: "db")
        #expect(phase == .starting || phase == .running)
        /** Already-up under a default lock is not a start: groupUp no-ops. */
        _ = try await handle(
            router: router, method: .groupUp,
            params: GroupParams(project: env.projectPath, timeoutSeconds: 5),
            expecting: GroupResult.self)
        let stillUp = try await phaseOf(router: router, project: env.projectPath, name: "db")
        #expect(stillUp == .starting || stillUp == .running)
        _ = try await handle(
            router: router, method: .serverStop,
            params: ServerTargetParams(name: "db", project: env.projectPath),
            expecting: ServerResult.self)
        let upLine = try NDJSON.encodeLine(
            WireRequest(
                id: "u", method: WireMethod.groupUp.rawValue,
                params: GroupParams(project: env.projectPath, timeoutSeconds: 2)))
        let upData = await router.handle(line: upLine)
        let upResponse = try JSONCoding.decoder().decode(
            WireResponse<GroupResult>.self, from: upData)
        #expect(upResponse.error?.code == .resourceLocked)
        #expect(upResponse.error?.hint == "run: ps -p \(getpid())")
        _ = try await handle(
            router: router, method: .lockRelease,
            params: LockParams(
                holderPid: Int(getpid()), pause: false, project: env.projectPath, resource: "data"),
            expecting: LockResult.self)
        _ = try await handle(
            router: router, method: .serverStop,
            params: ServerTargetParams(name: "db", project: env.projectPath),
            expecting: ServerResult.self)
    }

    /** Experiment L: rapid pause/resume must not leave the declarer in
        `crashed`. Classifies L1/L2/L3 via phase + lastExit after each cycle. */
    @Test func rapidAcquireReleaseNeverLeavesCrashed() async throws {
        let fixture = try #require(fixtureServerPath())
        let env = try makeLockEnv()
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
            to: URL(fileURLWithPath: env.projectPath).appending(path: "devservers.json"))
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router: router, method: .serverEnsure,
            params: EnsureParams(name: "db", project: env.projectPath, timeoutSeconds: 10),
            expecting: EnsureResult.self)
        var crashCount = 0
        var lastCrashDetail = ""
        for cycle in 0..<20 {
            let holder = Int(getpid())
            _ = try await handle(
                router: router, method: .lockAcquire,
                params: LockParams(
                    holderPid: holder, pause: true, project: env.projectPath, resource: "data",
                    resumeTimeoutSeconds: 15),
                expecting: LockResult.self)
            #expect(try await phaseOf(router: router, project: env.projectPath, name: "db") == .stopped)
            _ = try await handle(
                router: router, method: .lockRelease,
                params: LockParams(
                    holderPid: holder, project: env.projectPath, resource: "data",
                    resumeTimeoutSeconds: 15),
                expecting: LockResult.self)
            let list = try await handle(
                router: router, method: .serverStatus,
                params: ProjectParams(project: env.projectPath),
                expecting: ServerListResult.self)
            let server = try #require(list.servers.first { $0.server == "db" })
            if server.phase == .crashed {
                crashCount += 1
                lastCrashDetail =
                    "cycle \(cycle) pid=\(server.pid.map(String.init) ?? "nil") exit=\(String(describing: server.lastExit))"
            }
            if server.phase == .starting || server.phase == .running {
                _ = try await handle(
                    router: router, method: .serverEnsure,
                    params: EnsureParams(
                        name: "db", project: env.projectPath, timeoutSeconds: 10),
                    expecting: EnsureResult.self)
            }
        }
        let final = try await phaseOf(router: router, project: env.projectPath, name: "db")
        #expect(crashCount == 0, "\(lastCrashDetail)")
        #expect(final == .running || final == .starting)
        _ = try await handle(
            router: router, method: .serverStop,
            params: ServerTargetParams(name: "db", project: env.projectPath),
            expecting: ServerResult.self)
    }

    /** Experiment L with a grandchild that can outlive a naive root-only stop. */
    @Test func rapidAcquireReleaseWithGrandchildNeverLeavesCrashed() async throws {
        let fixture = try #require(fixtureServerPath())
        let env = try makeLockEnv()
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
            to: URL(fileURLWithPath: env.projectPath).appending(path: "devservers.json"))
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router: router, method: .serverEnsure,
            params: EnsureParams(name: "db", project: env.projectPath, timeoutSeconds: 10),
            expecting: EnsureResult.self)
        var crashCount = 0
        for _ in 0..<12 {
            let holder = Int(getpid())
            _ = try await handle(
                router: router, method: .lockAcquire,
                params: LockParams(
                    holderPid: holder, pause: true, project: env.projectPath, resource: "data",
                    resumeTimeoutSeconds: 15),
                expecting: LockResult.self)
            _ = try await handle(
                router: router, method: .lockRelease,
                params: LockParams(
                    holderPid: holder, project: env.projectPath, resource: "data",
                    resumeTimeoutSeconds: 15),
                expecting: LockResult.self)
            let list = try await handle(
                router: router, method: .serverStatus,
                params: ProjectParams(project: env.projectPath),
                expecting: ServerListResult.self)
            let server = try #require(list.servers.first { $0.server == "db" })
            if server.phase == .crashed { crashCount += 1 }
            if server.phase == .starting || server.phase == .running || server.phase == .crashed
                || server.phase == .stopped
            {
                _ = try? await handle(
                    router: router, method: .serverEnsure,
                    params: EnsureParams(
                        name: "db", project: env.projectPath, timeoutSeconds: 10),
                    expecting: EnsureResult.self)
            }
        }
        #expect(crashCount == 0)
        _ = try await handle(
            router: router, method: .serverStop,
            params: ServerTargetParams(name: "db", project: env.projectPath),
            expecting: ServerResult.self)
    }
}

private func fixtureServerPath() -> String? { fixtureServerExecutable() }
