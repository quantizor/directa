import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

private struct LockEnv {
    let paths: DirectaPaths
    let projectPath: String
}

private func makeLockEnv() throws -> LockEnv {
    let base = FileManager.default.temporaryDirectory.appending(path: "directa-lock-\(UUID().uuidString)")
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
    /** Give spawn a beat so phase is active for pause detection. */
    try await Task.sleep(for: .milliseconds(200))
}

private func phaseOf(router: Router, project: String, name: String) async throws -> ServerPhase {
    let list = try await handle(
        router: router, method: .serverStatus,
        params: ProjectParams(project: project),
        expecting: ServerListResult.self)
    let server = try #require(list.servers.first { $0.server == name })
    return server.phase
}

@Suite(.serialized) struct ResourceLockTests {
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
        try await registry.updateState(serverID: id) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
            entry.pid = nil
        }
        /** A pid we know is gone: spawn and wait, then reuse the identifier. */
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try probe.run()
        probe.waitUntilExit()
        let deadPid = Int(probe.processIdentifier)
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
        let phase = try await phaseOf(router: router, project: env.projectPath, name: "db")
        #expect(phase == .starting || phase == .running)
        let locks = AtomicFile.loadDefensively(LocksFile.self, from: env.paths.locksFile)
        #expect(locks?.locks.isEmpty == true)
        _ = try await handle(
            router: router, method: .serverStop,
            params: ServerTargetParams(name: "db", project: env.projectPath),
            expecting: ServerResult.self)
    }

    /** If the harness survived the daemon restart, recover must leave the
        paused server down and keep the lock so ensure stays refused. */
    @Test func recoverLeavesPausedWhenHolderStillAlive() async throws {
        let env = try makeLockEnv()
        try writeLockDevservers(project: env.projectPath)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let id = serverID(project: env.projectPath, name: "db")
        try await registry.updateState(serverID: id) { entry in
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
        /** Inside the block TestPorts reserves. At 41_000 these fixtures were
            outside it, so a failure here leaked one that nothing reaped, and
            they collided with scripts/smoke.sh, which draws its project-phase
            ports from that same range. */
        let port = 45_500 + Int.random(in: 0..<250)
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
        let port = 45_750 + Int.random(in: 0..<250)
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
