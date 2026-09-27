import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

/** Two checkouts of one project declare the same committed port, so every
    start-shaped path must refuse the second binder loudly instead of letting two
    processes silently fight over the port. These share the same declared port
    numbers, so the suite is serialized. */
@Suite(.serialized, .temporaryTree) struct PortOwnershipTests {
    private struct Env {
        let paths: DirectaPaths
        let projectA: String
        let projectB: String
    }

    private func makeEnv() throws -> Env {
        let base = try TemporaryTree.directory(named: "port")
        let a = base.appending(path: "checkout-a")
        let b = base.appending(path: "checkout-b")
        for dir in [a, b] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return Env(
            paths: DirectaPaths(dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            projectA: a.path, projectB: b.path)
    }

    private func handle<P: Codable & Sendable, R: Codable & Sendable>(
        _ router: Router, _ method: WireMethod, _ params: P, _ expecting: R.Type
    ) async -> Result<R, WireError> {
        do {
            let line = try NDJSON.encodeLine(WireRequest(id: "t", method: method.rawValue, params: params))
            let data = await router.handle(line: line)
            let response = try JSONCoding.decoder().decode(WireResponse<R>.self, from: data)
            if response.ok, let result = response.result { return .success(result) }
            return .failure(response.error ?? WireError(code: .internalError, message: "no result"))
        } catch let error as WireError {
            return .failure(error)
        } catch {
            return .failure(WireError(code: .internalError, message: "\(error)"))
        }
    }

    /** A long-lived sleeper with a declared port. It never binds the port, so any
        refusal comes from directa's own bookkeeping (managed holder or persisted
        row), never from the loopback listener probe. */
    private func sleeperSpec(name: String, port: Int) -> ServerSpec {
        ServerSpec(command: ["/bin/sh", "-c", "sleep 60"], name: name, port: port)
    }

    @Test func ensureRefusesAPortAnotherProjectHolds() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45001))
        try await registry.register(project: env.projectB, spec: sleeperSpec(name: "web", port: 45001))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = await handle(router, .serverStart, ServerTargetParams(name: "web", project: env.projectA), ServerResult.self)
        let refused = await handle(
            router, .serverEnsure, EnsureParams(name: "web", project: env.projectB, timeoutSeconds: 3),
            EnsureResult.self)
        guard case .failure(let error) = refused else {
            Issue.record("expected the second checkout to be refused")
            return
        }
        #expect(error.code == .portHeld)
        /** The message names the holding project, not a bare number. */
        #expect(error.message.contains("45001"))
        #expect(error.message.contains(env.projectA))
        await teardown(router, env.projectA, "web")
    }

    @Test func groupUpRefusesWhenTheDeclaredPortIsHeld() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45002))
        /** Checkout B brings its server up through directa up, the path that used
            to skip the pre-check entirely. */
        try writeDevserversPort(project: env.projectB, name: "web", port: 45002)
        try await registry.setTrusted(project: env.projectB)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = await handle(router, .serverStart, ServerTargetParams(name: "web", project: env.projectA), ServerResult.self)
        let refused = await handle(
            router, .groupUp, GroupParams(project: env.projectB, timeoutSeconds: 3), GroupResult.self)
        guard case .failure(let error) = refused else {
            Issue.record("expected group up to refuse the held port")
            return
        }
        #expect(error.code == .portHeld)
        await teardown(router, env.projectA, "web")
    }

    @Test func aRunningTargetIsNotRefusedAgainstItself() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45003))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = await handle(router, .serverStart, ServerTargetParams(name: "web", project: env.projectA), ServerResult.self)
        /** Ensuring the same already-up server must not trip the port check on its
            own listener. */
        let again = await handle(
            router, .serverEnsure, EnsureParams(name: "web", project: env.projectA, timeoutSeconds: 3),
            EnsureResult.self)
        guard case .success = again else {
            Issue.record("re-ensuring a running server should not be refused")
            return
        }
        await teardown(router, env.projectA, "web")
    }

    @Test func aHolderWithNoResidentSupervisorStillRefuses() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        /** A holder from before this daemon started: it has a persisted running
            row and a spec, but no supervisor in the pool. Model that with a real
            sleeping process whose pid the row records. */
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["60"]
        try holder.run()
        defer { holder.terminate() }
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45004))
        let idA = serverID(project: env.projectA, name: "web")
        try await registry.updateState(serverID: idA, writer: .router) { entry in
            entry.phase = .running
            entry.pid = Int(holder.processIdentifier)
        }
        try await registry.register(project: env.projectB, spec: sleeperSpec(name: "web", port: 45004))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        /** B is the first thing this router touches, so A never becomes resident. */
        let refused = await handle(
            router, .serverEnsure, EnsureParams(name: "web", project: env.projectB, timeoutSeconds: 3),
            EnsureResult.self)
        guard case .failure(let error) = refused else {
            Issue.record("expected refusal from the persisted holder")
            return
        }
        #expect(error.code == .portHeld)
        #expect(error.message.contains(env.projectA))
    }

    /** The same holder running on the port its checkout's `directa.local.json`
        gives it, with no rebind recorded: the listener there is that managed
        server's, named as such, never an unmanaged squatter. */
    @Test func aHolderWithNoResidentSupervisorIsFoundOnItsOverlayPort() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["60"]
        try holder.run()
        defer { holder.terminate() }
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45020))
        try Data(#"{"servers":{"web":{"port":45021}}}"#.utf8)
            .write(to: LocalOverlay.overlayURL(project: env.projectA))
        try await registry.updateState(serverID: serverID(project: env.projectA, name: "web"), writer: .router) {
            entry in
            entry.phase = .running
            entry.pid = Int(holder.processIdentifier)
        }
        try await registry.register(project: env.projectB, spec: sleeperSpec(name: "web", port: 45021))
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths,
            portProbe: PortProbe { $0 == 45021 }, registry: registry)

        let refused = await handle(
            router, .serverEnsure, EnsureParams(name: "web", project: env.projectB, timeoutSeconds: 3),
            EnsureResult.self)
        guard case .failure(let error) = refused else {
            Issue.record("expected refusal from the persisted holder on its overlay port")
            return
        }
        #expect(error.code == .portHeld)
        #expect(
            error.message
                == "port 45021 is held by managed server 'web' in \(canonicalProjectPath(env.projectA))")
    }

    /** `why` is the command a reader reaches for after a refusal, so it has to
        name the holder itself rather than answering only "not running
        (stopped)". That requires it to annotate latent conflicts the way the
        status handler does. */
    @Test func whyNamesTheHolderOfAStoppedServersPort() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45005))
        try await registry.register(project: env.projectB, spec: sleeperSpec(name: "web", port: 45005))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = await handle(router, .serverStart, ServerTargetParams(name: "web", project: env.projectA), ServerResult.self)

        let answer = await handle(
            router, .serverWhy, ServerTargetParams(name: "web", project: env.projectB), WhyResult.self)
        guard case .success(let why) = answer else {
            Issue.record("why should answer for a stopped server")
            await teardown(router, env.projectA, "web")
            return
        }
        let rootCause = try #require(why.rootCause)
        #expect(rootCause.contains("45005"))
        #expect(rootCause.contains(env.projectA))
        /** The holder belongs in the root cause, not only buried in evidence. */
        #expect(!rootCause.hasSuffix("not running (stopped)"))
        await teardown(router, env.projectA, "web")
    }

    /** The machine-wide sweep feeds `doctor` and the menu bar app, and skipped
        the annotation entirely. */
    @Test func statusAcrossAllProjectsAnnotatesTheHeldPort() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45006))
        try await registry.register(project: env.projectB, spec: sleeperSpec(name: "web", port: 45006))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = await handle(router, .serverStart, ServerTargetParams(name: "web", project: env.projectA), ServerResult.self)

        let listed = await handle(
            router, .serverStatus, ProjectParams(project: ""), ServerListResult.self)
        guard case .success(let all) = listed else {
            Issue.record("machine-wide status should answer")
            await teardown(router, env.projectA, "web")
            return
        }
        /** The registry canonicalizes project paths, so compare in that form. */
        let stopped = try #require(
            all.servers.first { $0.project == canonicalProjectPath(env.projectB) })
        let conflict = try #require(stopped.portConflict)
        #expect(conflict.state == .held)
        #expect(conflict.message.contains(env.projectA))
        await teardown(router, env.projectA, "web")
    }

    /** Waits for a phase, polling rather than sleeping a fixed span. */
    private func settle(
        _ supervisor: ServerSupervisor, until predicate: @Sendable (ServerStatus) -> Bool
    ) async -> ServerStatus {
        var status = await supervisor.status()
        for _ in 0..<60 where !predicate(status) {
            try? await Task.sleep(for: .milliseconds(100))
            status = await supervisor.status()
        }
        return status
    }

    /** The failure that motivated this check: another project's server holds the
        port, answers the healthcheck, and every liveness signal reads green while
        this server is not serving at all. */
    @Test func aHealthcheckAnsweredByAForeignProcessFailsTheServer() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let port = 45007
        let registry = Registry(paths: env.paths)
        /** The thief is another server this daemon supervises, which is what the
            real incident looked like: two projects, one port, whichever bound
            first answers for both. */
        let thiefSpec = ServerSpec(
            command: [fixture, "--listen-tcp", String(port)], name: "web", port: port)
        try await registry.register(project: env.projectB, spec: thiefSpec)
        let thief = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectB,
            registry: registry, spec: thiefSpec)
        _ = await thief.start()
        _ = await settle(thief) { $0.phase == .running }

        /** The victim never binds anything, so the only listener on the port
            belongs to the thief, yet its TCP healthcheck still passes. */
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web", port: port)
        try await registry.register(project: env.projectA, spec: spec)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectA,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let settled = await settle(supervisor) { $0.phase == .failed }
        #expect(settled.phase == .failed)
        let conflict = try #require(settled.portConflict)
        #expect(conflict.state == .foreign)
        #expect(conflict.message.contains("\(port)"))
        /** Names the managed server, not just a pid, so the reader can act. */
        #expect(conflict.holder?.contains(env.projectB) == true)
        #expect(settled.spawnError?.message.contains("\(port)") == true)
        _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
        _ = await thief.stop(graceSeconds: 2, reason: "test cleanup")
    }

    /** A server failed for its port keeps its process running (the failure is
        a finding, not a teardown), so stopping it stops that process, and
        starting it again stops the old run before spawning a new one: two
        copies never run side by side, and the old run's exit never
        overwrites the new run's state. */
    @Test(arguments: [(45011, false), (45012, true)])
    func aPortFailedServerIsReallyStoppedAndRestarted(port: Int, restart: Bool) async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let thiefSpec = ServerSpec(
            command: [fixture, "--listen-tcp", String(port)], name: "web", port: port)
        try await registry.register(project: env.projectB, spec: thiefSpec)
        let thief = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectB,
            registry: registry, spec: thiefSpec)
        _ = await thief.start()
        _ = await settle(thief) { $0.phase == .running }

        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web", port: port)
        try await registry.register(project: env.projectA, spec: spec)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectA,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let failed = await settle(supervisor) { $0.phase == .failed }
        #expect(failed.phase == .failed)
        let oldPid = try #require(failed.pid)
        defer { kill(pid_t(oldPid), SIGKILL) }
        _ = await thief.stop(graceSeconds: 2, reason: "test cleanup")

        let after: ServerStatus
        if restart {
            after = await supervisor.start()
        } else {
            after = await supervisor.stop(graceSeconds: 2, reason: "test")
        }
        defer { if let pid = after.pid, pid != oldPid { kill(pid_t(pid), SIGKILL) } }
        var gone = kill(pid_t(oldPid), 0) != 0
        for _ in 0..<50 where !gone {
            try await Task.sleep(for: .milliseconds(20))
            gone = kill(pid_t(oldPid), 0) != 0
        }
        #expect(gone, "the failed run \(oldPid) kept running")
        if restart {
            let newPid = try #require(after.pid)
            #expect(newPid != oldPid)
            #expect(after.phase == .starting)
            let persisted = await registry.persistedState(
                serverID: serverID(project: env.projectA, name: "web"))
            #expect(persisted?.pid == newPid)
            #expect(persisted?.phase == .starting)
            _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
        } else {
            #expect(after.phase == .stopped)
            #expect(after.pid == nil)
        }
    }

    /** Forgetting a vanished checkout whose server failed for its port stops
        that live process through its own exit, which posts the one `stopped`
        event; the teardown's own post is only for a server with nothing left
        running. */
    @Test func forgettingAPortFailedServerStopsItWithOneStoppedEvent() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let port = 45013
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.projectA,
            spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web", port: port))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let target = ServerTargetParams(name: "web", project: env.projectA)
        let start = await handle(router, .serverStart, target, ServerResult.self)
        guard case .success(let started) = start else {
            Issue.record("the victim did not start")
            return
        }
        let victim = try #require(started.server.pid)
        defer { kill(pid_t(victim), SIGKILL) }

        /** Started after the victim so the victim's port pre-check passes; its
            listener then answers the victim's healthcheck. */
        let thiefSpec = ServerSpec(
            command: [fixture, "--listen-tcp", String(port)], name: "web", port: port)
        let thief = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectB,
            registry: registry, spec: thiefSpec)
        _ = await thief.start()
        var phase: ServerPhase?
        for _ in 0..<60 where phase != .failed {
            try await Task.sleep(for: .milliseconds(100))
            let listed = await handle(
                router, .serverStatus, ProjectParams(name: "web", project: env.projectA),
                ServerListResult.self)
            if case .success(let result) = listed {
                phase = result.servers.first?.phase
            }
        }
        #expect(phase == .failed)
        _ = await thief.stop(graceSeconds: 2, reason: "test cleanup")

        let canonicalProject = canonicalProjectPath(env.projectA)
        try FileManager.default.removeItem(atPath: env.projectA)
        let now = Date()
        await router.pruneMissingProjects(now: now)
        await router.pruneMissingProjects(
            now: now.addingTimeInterval(Router.missingProjectSweepIntervalSeconds))

        var gone = kill(pid_t(victim), 0) != 0
        for _ in 0..<50 where !gone {
            try await Task.sleep(for: .milliseconds(20))
            gone = kill(pid_t(victim), 0) != 0
        }
        #expect(gone, "the port-failed run \(victim) outlived its forgotten project")
        let queried = await handle(
            router, .eventsQuery, EventsQueryParams(project: canonicalProject), EventsQueryResult.self)
        guard case .success(let events) = queried else {
            Issue.record("events query failed")
            return
        }
        #expect(events.events.filter { $0.kind == .stopped }.map(\.detail) == ["project path gone"])
    }

    /** Brings a router-started server to a port failure with its run still
        alive: a thief (another managed server) binds the victim's effective
        port after the victim's pre-check passed, answers its healthcheck, and
        the listen scan fails the victim for it. Polls through the router's
        status handler, the path every reader takes. */
    private func portFailedVictim(
        router: Router, registry: Registry, env: Env, port: Int, overridePort: Int? = nil
    ) async throws -> (failed: ServerStatus, thief: ServerSupervisor) {
        let fixture = try #require(fixtureServerExecutable())
        let target = ServerTargetParams(name: "web", port: overridePort, project: env.projectA)
        let start = await handle(router, .serverStart, target, ServerResult.self)
        guard case .success(let started) = start else {
            Issue.record("the victim did not start: \(start)")
            throw WireError(code: .internalError, message: "victim did not start")
        }
        #expect(started.server.pid != nil)
        let thiefPort = overridePort ?? port
        let thiefSpec = ServerSpec(
            command: [fixture, "--listen-tcp", String(thiefPort)], name: "web", port: thiefPort)
        let thief = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectB,
            registry: registry, spec: thiefSpec)
        _ = await thief.start()
        var latest: ServerStatus?
        for _ in 0..<60 where latest?.phase != .failed {
            try await Task.sleep(for: .milliseconds(100))
            let listed = await handle(
                router, .serverStatus, ProjectParams(name: "web", project: env.projectA),
                ServerListResult.self)
            if case .success(let result) = listed {
                latest = result.servers.first
            }
        }
        let failed = try #require(latest)
        #expect(failed.phase == .failed)
        #expect(failed.pid != nil)
        return (failed: failed, thief: thief)
    }

    /** A port-failed run is still a live process holding whatever the resource
        guards, so a pausing lock stops it and a non-pausing lock reports it as
        live, exactly like a running declarer. */
    @Test(arguments: [(45014, true), (45015, false)])
    func aLockPausesOrReportsALivePortFailedDeclarer(port: Int, pause: Bool) async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.projectA,
            spec: ServerSpec(
                command: ["/bin/sh", "-c", "sleep 30"], locks: [LockDeclaration(name: "data")],
                name: "web", port: port))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let (failed, thief) = try await portFailedVictim(
            router: router, registry: registry, env: env, port: port)
        let victim = try #require(failed.pid)
        defer { kill(pid_t(victim), SIGKILL) }
        _ = await thief.stop(graceSeconds: 2, reason: "test cleanup")

        let acquired = await handle(
            router, .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: pause, project: env.projectA, resource: "data",
                resumeTimeoutSeconds: 1),
            LockResult.self)
        guard case .success(let lock) = acquired else {
            Issue.record("lock acquire failed: \(acquired)")
            return
        }
        if pause {
            #expect(lock.paused == ["web"])
            #expect(lock.live == nil)
            var gone = kill(pid_t(victim), 0) != 0
            for _ in 0..<50 where !gone {
                try await Task.sleep(for: .milliseconds(20))
                gone = kill(pid_t(victim), 0) != 0
            }
            #expect(gone, "the paused port-failed run \(victim) kept running")
        } else {
            #expect(lock.paused == [])
            #expect(lock.live == ["web"])
        }
        _ = await handle(
            router, .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.projectA, resource: "data",
                resumeTimeoutSeconds: 1),
            LockResult.self)
        await teardown(router, env.projectA, "web")
    }

    /** A drifted run listens on a claimed secondary port instead of its
        primary. Ensuring it again must read that listener as the server's own
        live run (which `start` then replaces), never as an unmanaged squatter
        named by its own pid. */
    @Test func ensuringADriftedServerDoesNotCallItsOwnListenerUnmanaged() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let port = 45016
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.projectA,
            spec: ServerSpec(
                command: [fixture, "--listen-tcp", String(port + 1)],
                healthcheck: HealthCheckSpec(type: .none), name: "web", port: port,
                portSpan: 2))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let target = ServerTargetParams(name: "web", project: env.projectA)
        _ = await handle(router, .serverStart, target, ServerResult.self)
        var latest: ServerStatus?
        for _ in 0..<60 where latest?.phase != .failed {
            try await Task.sleep(for: .milliseconds(100))
            let listed = await handle(
                router, .serverStatus, ProjectParams(name: "web", project: env.projectA),
                ServerListResult.self)
            if case .success(let result) = listed {
                latest = result.servers.first
            }
        }
        let drifted = try #require(latest)
        #expect(drifted.phase == .failed)
        #expect(drifted.portConflict?.state == .drift)
        #expect(drifted.observedPort == port + 1)
        let oldPid = try #require(drifted.pid)
        defer { kill(pid_t(oldPid), SIGKILL) }

        let again = await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.projectA, timeoutSeconds: 5), EnsureResult.self)
        guard case .success(let result) = again else {
            Issue.record("ensure refused the server's own live run: \(again)")
            return
        }
        let newPid = try #require(result.server.pid)
        #expect(newPid != oldPid)
        #expect(kill(pid_t(oldPid), 0) != 0, "the drifted run \(oldPid) kept running")
        await teardown(router, env.projectA, "web")
    }

    /** A status read re-resolves committed config for a server with no live
        run. A port-failed run is live and was spawned from a materialized spec
        (here an overridden port rewrote the url), so reading its status must
        leave that spec alone. Its own foreign conflict also stays in place of
        a latent-conflict annotation. */
    @Test func aStatusReadKeepsALivePortFailedRunsSpawnSpec() async throws {
        let env = try makeEnv()
        let port = 45018
        let overridePort = 45019
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.projectA,
            spec: ServerSpec(
                command: ["/bin/sh", "-c", "sleep 30"], name: "web", port: port,
                url: "http://127.0.0.1:{port}/"))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let (failed, thief) = try await portFailedVictim(
            router: router, registry: registry, env: env, port: port, overridePort: overridePort)
        let victim = try #require(failed.pid)
        defer { kill(pid_t(victim), SIGKILL) }
        /** Read again: the read that first saw `.failed` may have checked the
            phase a moment before the failure landed. */
        let reread = await handle(
            router, .serverStatus, ProjectParams(name: "web", project: env.projectA),
            ServerListResult.self)
        guard case .success(let list) = reread else {
            Issue.record("status read failed: \(reread)")
            return
        }
        let status = try #require(list.servers.first)
        #expect(status.phase == .failed)
        #expect(status.url == "http://127.0.0.1:\(overridePort)/")
        #expect(status.specStale != true)
        #expect(status.portConflict?.state == .foreign)
        _ = await thief.stop(graceSeconds: 2, reason: "test cleanup")
        await teardown(router, env.projectA, "web")
    }

    /** The control. Same shape, except the supervised process owns the port, so
        the check must stay silent. Without this a probe that always reported a
        foreign owner would pass the test above and look like a working feature. */
    @Test func aServerThatOwnsItsPortStaysHealthy() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let port = 45008
        let registry = Registry(paths: env.paths)
        let spec = ServerSpec(
            command: [fixture, "--listen-tcp", String(port)], name: "web", port: port)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectA,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        /** The listen scan runs in its own task after health promotion, so wait
            for the scan's result rather than for `running` alone. */
        let settled = await settle(supervisor) {
            ($0.phase == .running && $0.observedPort != nil) || $0.phase == .failed
        }
        #expect(settled.phase == .running)
        #expect(settled.portConflict == nil)
        #expect(settled.observedPort == port)
        _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
    }

    /** ATTACK: the server's own listener lives outside its process tree. A
        container-backed server (docker compose) is the common shape: the
        listening socket belongs to the runtime, never to our children. Modelled
        here by a middle process that exits, reparenting the listener to launchd
        and out of the ppid chain the descendant sweep walks. Nothing was stolen,
        so failing this server would be wrong. */
    @Test func aServerWhoseListenerLeftTheProcessTreeIsNotTheft() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let port = 45009
        let registry = Registry(paths: env.paths)
        /** The inner shell exits at once, so the listener reparents away. The
            outer shell stays alive as the supervised root. */
        let spec = ServerSpec(
            command: [
                "/bin/sh", "-c",
                "/bin/sh -c '\(fixture) --listen-tcp \(port) >/dev/null 2>&1 &' ; sleep 30",
            ],
            name: "web", port: port)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectA,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let settled = await settle(supervisor) {
            $0.phase == .failed || ($0.phase == .running && $0.portConflict != nil)
        }
        _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
        /** The reparented listener outlives the supervised tree by construction. */
        for stray in await PortGuard.listenerPids(port: port) { kill(pid_t(stray), SIGKILL) }
        #expect(settled.phase != .failed)
    }

    /** ATTACK: a stale state row names a pid that macOS later handed to an
        unrelated process. Matching on the number alone would accuse an innocent
        managed server and fail this one for it. The row here claims a start time
        an hour before the listener actually started, which is what a recycled
        pid looks like. */
    @Test func aRecycledPidIsNotMistakenForAManagedThief() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let port = 45010
        let registry = Registry(paths: env.paths)
        /** An unmanaged listener, started now. */
        let stranger = Process()
        stranger.executableURL = URL(fileURLWithPath: fixture)
        stranger.arguments = ["--listen-tcp", String(port)]
        stranger.standardOutput = FileHandle.nullDevice
        stranger.standardError = FileHandle.nullDevice
        try stranger.run()
        defer { stranger.terminate() }
        try await Task.sleep(for: .milliseconds(400))

        /** A stale row for another project claiming that very pid, recorded an
            hour ago: the pid matches, the identity cannot. */
        try await registry.register(project: env.projectB, spec: sleeperSpec(name: "web", port: port))
        try await registry.updateState(serverID: serverID(project: env.projectB, name: "web"), writer: .router) {
            entry in
            entry.phase = .running
            entry.pid = Int(stranger.processIdentifier)
            entry.startedAt = Date().addingTimeInterval(-3600)
        }

        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web", port: port)
        try await registry.register(project: env.projectA, spec: spec)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectA,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let settled = await settle(supervisor) {
            $0.phase == .failed || ($0.phase == .running && $0.portConflict != nil)
        }
        _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
        /** Annotated, never failed: the accusation could not be substantiated. */
        #expect(settled.phase != .failed)
        #expect(settled.portConflict?.state == .foreign)
    }

    private func teardown(_ router: Router, _ project: String, _ name: String) async {
        _ = await handle(router, .serverStop, ServerTargetParams(name: name, project: project), ServerResult.self)
    }

    private func writeDevserversPort(project: String, name: String, port: Int) throws {
        let body = """
        {
          "servers": {
            "\(name)": { "command": ["/bin/sh", "-c", "sleep 60"], "port": \(port) }
          },
          "version": 1
        }
        """
        try Data(body.utf8).write(to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
    }
}
