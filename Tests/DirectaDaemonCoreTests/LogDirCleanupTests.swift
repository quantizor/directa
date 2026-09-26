import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** A project's log directory used to survive both an explicit unregister down
    to zero servers and the missing-project sweep; only `uninstall --purge`
    removed it. `ControlServer`'s `serverUnregister` arm and
    `forgetMissingProject` are the two paths that now clean it up, each proven
    here against real files on disk rather than a mocked FileManager.
    `serverUnregister` only ever removes an ad hoc registry entry, never a
    project's recorded trust: a project keeps its row, and this directory,
    as long as either an ad hoc server or trust survives, so unregistering an
    unrelated or already-absent name, or the last ad hoc entry on a project
    trusted through its committed devservers.json, must never delete logs a
    live, merely un-registered, supervisor is still writing to. */
@Suite struct LogDirCleanupTests {
    private struct Env {
        let paths: DirectaPaths
        let project: String
    }

    private func makeEnv() throws -> Env {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-logdir-\(UUID().uuidString)")
        let project = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return Env(
            paths: DirectaPaths(
                dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            project: project.path)
    }

    private func handle<P: Codable & Sendable, R: Codable & Sendable>(
        _ router: Router, _ method: WireMethod, _ params: P, _ expecting: R.Type
    ) async throws -> R {
        let line = try NDJSON.encodeLine(WireRequest(id: "t", method: method.rawValue, params: params))
        let data = await router.handle(line: line)
        let response = try JSONCoding.decoder().decode(WireResponse<R>.self, from: data)
        return try #require(response.result)
    }

    /** Returns the decoded result, or the `WireError` when the daemon refused,
        for a call expected to fail. */
    private func send<P: Codable & Sendable, R: Codable & Sendable>(
        _ router: Router, _ method: WireMethod, _ params: P, _ expecting: R.Type
    ) async throws -> Result<R, WireError> {
        let line = try NDJSON.encodeLine(WireRequest(id: "t", method: method.rawValue, params: params))
        let data = await router.handle(line: line)
        let response = try JSONCoding.decoder().decode(WireResponse<R>.self, from: data)
        if response.ok, let result = response.result { return .success(result) }
        return .failure(response.error ?? WireError(code: .internalError, message: "no result"))
    }

    /** Plants a real file under a server's log directory so removal is proven
        against disk, not a path nothing ever wrote to. */
    private func plantLogFile(paths: DirectaPaths, project: String, server: String) throws {
        let dir = paths.serverLogDir(project: project, server: server)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appending(path: "current.log"))
    }

    /** Never binds a port and exits only on signal, so starting it proves
        nothing about health or port ownership, only that a supervisor exists. */
    private func sleeperSpec(name: String) -> ServerSpec {
        ServerSpec(command: ["/bin/sh", "-c", "sleep 60"], name: name)
    }

    @Test func unregisteringTheLastServerRemovesTheProjectLogDirectory() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        try plantLogFile(paths: env.paths, project: env.project, server: "web")
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await handle(
            router, .serverUnregister, ServerTargetParams(name: "web", project: env.project),
            WireEmpty.self)

        #expect(
            !FileManager.default.fileExists(
                atPath: env.paths.projectLogDir(project: env.project).path))
    }

    /** "api" is committed config, never written into registry.json (per the
        codebase's own rule); starting it records trust for the project. Once
        "web" (the project's only ad hoc entry) is unregistered, the registry
        row must survive on trust alone, with no ad hoc servers left, and the
        directory must survive with it: dropping trust here would let a later
        autonomous restore refuse "api" outright, and would orphan its log
        directory while "api" still holds a resident, log-writing supervisor. */
    @Test func unregisteringTheLastAdHocServerOnATrustedConfigProjectKeepsTrust() async throws {
        let env = try makeEnv()
        try Data(
            #"{"servers":{"api":{"command":["/bin/sh","-c","sleep 60"]}},"version":1}"#.utf8
        ).write(to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        try plantLogFile(paths: env.paths, project: env.project, server: "web")
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await handle(
            router, .serverStart, ServerTargetParams(name: "api", project: env.project),
            ServerResult.self)
        _ = try await handle(
            router, .serverUnregister, ServerTargetParams(name: "web", project: env.project),
            WireEmpty.self)

        let entry = try #require(await registry.project(env.project))
        #expect(entry.trusted == true)
        #expect(entry.servers.isEmpty)

        #expect(
            FileManager.default.fileExists(
                atPath: env.paths.projectLogDir(project: env.project).path))

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "api", project: env.project),
            ServerResult.self)
    }

    /** "ghost" was never registered ad hoc, and is not named in the committed
        devservers.json either: unregistering it must refuse rather than
        silently succeed and drop the project's recorded trust as a side
        effect of "web" already sitting empty (a project can be trusted with
        zero ad hoc servers at all, purely through a committed server having
        been started once). */
    @Test func unregisteringAnUnknownNameOnATrustedConfigOnlyProjectIsRefused() async throws {
        let env = try makeEnv()
        try Data(
            #"{"servers":{"api":{"command":["/bin/sh","-c","sleep 60"]}},"version":1}"#.utf8
        ).write(to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await handle(
            router, .serverStart, ServerTargetParams(name: "api", project: env.project),
            ServerResult.self)
        try plantLogFile(paths: env.paths, project: env.project, server: "api")
        #expect(await registry.project(env.project)?.trusted == true)

        let outcome = try await send(
            router, .serverUnregister, ServerTargetParams(name: "ghost", project: env.project),
            WireEmpty.self)
        guard case .failure(let error) = outcome else {
            Issue.record("unregister accepted a name that was never registered ad hoc")
            return
        }
        #expect(error.code == .notFound)

        #expect(await registry.project(env.project)?.trusted == true)
        #expect(
            FileManager.default.fileExists(
                atPath: env.paths.projectLogDir(project: env.project).path))

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "api", project: env.project),
            ServerResult.self)
    }

    /** Unregistering a server that is actually running used to just drop the
        supervisor and remove the log directory out from under it, leaving the
        real process alive and writing to a spool file on an unlinked
        directory. `serverUnregister` must stop it through the normal stop
        path first and wait for it to actually exit before dropping anything. */
    @Test func unregisteringARunningServerStopsItFirst() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let started = try await handle(
            router, .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        let pid = try #require(started.server.pid)
        #expect(kill(pid_t(pid), 0) == 0)

        _ = try await handle(
            router, .serverUnregister, ServerTargetParams(name: "web", project: env.project),
            WireEmpty.self)

        #expect(kill(pid_t(pid), 0) != 0)
        #expect(
            !FileManager.default.fileExists(
                atPath: env.paths.projectLogDir(project: env.project).path))
        /** The stop finished, so its own recordOutcome cleared the boot intent
            and posted the one `stopped` event; unregister adds nothing twice. */
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.project, name: "web"))
        #expect(persisted?.phase == .stopped)
        #expect(persisted?.resumeOnBoot == nil)
        let events = try await handle(
            router, .eventsQuery, EventsQueryParams(project: env.project), EventsQueryResult.self)
        #expect(events.events.filter { $0.kind == .stopped }.map(\.detail) == ["unregistered"])
        #expect(events.events.filter { $0.kind == .unregistered }.count == 1)
    }

    /** Unregistering a server whose stop never finishes (also declared in the
        committed devservers.json, so the next daemon launch would restore it
        from its state row) retires that row as stopped with no boot intent,
        keeping the run's pid and start time so a later daemon launch can
        still prove and bounce a process that outlived the stop, and the exit
        that finally lands afterward cannot write it back. `lastExit` is the
        marker a late write would leave. */
    @Test func unregisteringAServerWhoseStopHangsRetiresItsStateRow() async throws {
        let env = try makeEnv()
        try Data(
            #"{"servers":{"web":{"command":["/bin/sh","-c","sleep 60"]}},"version":1}"#.utf8
        ).write(to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let gate = AdoptGate()
        let router = Router(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, registry: registry,
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 0.1))
        let id = serverID(project: env.project, name: "web")

        let started = try await handle(
            router, .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        let pid = try #require(started.server.pid)
        let running = try #require(await registry.persistedState(serverID: id))
        #expect(running.resumeOnBoot == true)
        let startedAt = try #require(running.startedAt)

        _ = try await handle(
            router, .serverUnregister, ServerTargetParams(name: "web", project: env.project),
            WireEmpty.self)
        let retired = try #require(await registry.persistedState(serverID: id))
        #expect(retired.phase == .stopped)
        #expect(retired.pid == pid)
        #expect(retired.startedAt == startedAt)
        #expect(retired.resumeOnBoot == nil)
        #expect(retired.lastExit == nil)

        await gate.signal(.signaled(signal: Int(SIGKILL)))
        try await awaitStoppedEvent(router: router, project: env.project, detail: "unregistered")
        for _ in 0..<10 {
            let row = await registry.persistedState(serverID: id)
            #expect(row?.phase == .stopped)
            #expect(row?.pid == pid)
            #expect(row?.resumeOnBoot == nil)
            #expect(row?.lastExit == nil)
            try await Task.sleep(for: .milliseconds(50))
        }
        let events = try await handle(
            router, .eventsQuery, EventsQueryParams(project: env.project), EventsQueryResult.self)
        #expect(events.events.filter { $0.kind == .unregistered }.count == 1)
    }

    /** Unregistering the last server of an untrusted project whose stop hangs
        leaves the project's log directory in place: the process may still be
        writing there. Doctor's leftover-log finding covers it later. */
    @Test func unregisterKeepsTheLogDirectoryWhenTheStopHangs() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let gate = AdoptGate()
        let router = Router(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, registry: registry,
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 0.1))
        let target = ServerTargetParams(name: "web", project: env.project)
        defer { Task { await gate.signal(.signaled(signal: Int(SIGKILL))) } }

        _ = try await handle(router, .serverStart, target, ServerResult.self)
        let logDir = env.paths.projectLogDir(project: env.project).path
        #expect(FileManager.default.fileExists(atPath: logDir))
        _ = try await handle(router, .serverUnregister, target, WireEmpty.self)

        #expect(await registry.project(env.project) == nil)
        #expect(FileManager.default.fileExists(atPath: logDir))
    }

    /** An unregister that lands while a restart's stop is still in flight: the
        restart's `ensure` then runs on a supervisor the router already dropped,
        and must not spawn there (nothing would ever supervise that run), and
        the row must carry no boot intent afterward. */
    @Test func unregisteringDuringARestartSpawnsNothingAndLeavesNoBootIntent() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let gate = AdoptGate()
        let router = Router(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, registry: registry,
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 0.1))
        let id = serverID(project: env.project, name: "web")
        let target = ServerTargetParams(name: "web", project: env.project)

        _ = try await handle(router, .serverStart, target, ServerResult.self)
        #expect(await gate.callCount == 1)
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        async let restart = send(
            router, .serverRestart,
            RestartParams(names: ["web"], project: env.project, timeoutSeconds: 3),
            GroupResult.self)
        var phase: ServerPhase?
        for _ in 0..<100 where phase != .stopping {
            phase = try await handle(
                router, .serverStatus, ProjectParams(name: "web", project: env.project),
                ServerListResult.self
            ).servers.first?.phase
            if phase != .stopping { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(phase == .stopping)
        _ = try await handle(router, .serverUnregister, target, WireEmpty.self)
        await gate.signal(.signaled(signal: Int(SIGKILL)))
        let restarted = try await restart
        if case .success(let group) = restarted {
            for pid in group.results.compactMap(\.server.pid) { kill(pid_t(pid), SIGKILL) }
        }

        #expect(await gate.callCount == 1)
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == nil)
    }

    /** Unregister clears boot intent even with no resident supervisor (a row a
        prior daemon left, a server never touched since this daemon started),
        so the name cannot come back on the next launch through a committed
        devservers.json entry of the same name. */
    @Test func unregisterClearsBootIntentWithNoResidentSupervisor() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let id = serverID(project: env.project, name: "web")
        try await registry.updateState(serverID: id) { entry in
            entry.phase = .crashed
            entry.resumeOnBoot = true
        }
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await handle(
            router, .serverUnregister, ServerTargetParams(name: "web", project: env.project),
            WireEmpty.self)

        let row = try #require(await registry.persistedState(serverID: id))
        #expect(row.resumeOnBoot == nil)
        #expect(row.phase == .crashed)
    }

    /** Retiring a hung server's row covers only that supervisor: a server of
        the same name registered again afterward gets a new supervisor whose
        pid and boot intent persist, or a later daemon restart would leave it
        unsupervised. */
    @Test func reRegisteringAfterAHungUnregisterPersistsTheNewRun() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let gate = AdoptGate()
        let router = Router(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, registry: registry,
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 0.1))
        let id = serverID(project: env.project, name: "web")
        let target = ServerTargetParams(name: "web", project: env.project)

        _ = try await handle(router, .serverStart, target, ServerResult.self)
        _ = try await handle(router, .serverUnregister, target, WireEmpty.self)
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == nil)

        _ = try await handle(
            router, .serverRegister, RegisterParams(project: env.project, spec: sleeperSpec(name: "web")),
            ServerResult.self)
        await gate.signal(.signaled(signal: Int(SIGKILL)))
        let restarted = try await handle(router, .serverStart, target, ServerResult.self)
        let pid = try #require(restarted.server.pid)
        defer { kill(pid_t(pid), SIGKILL) }

        let row = try #require(await registry.persistedState(serverID: id))
        #expect(row.pid == pid)
        #expect(row.resumeOnBoot == true)
        _ = try await send(router, .serverStop, target, ServerResult.self)
    }

    /** A retirement that cannot be saved (state.json refuses the write) is
        logged at error level and the unregister still completes: the
        retirement already holds in memory, so the late exit of the dropped
        supervisor still cannot put boot intent back. */
    @Test func unregisterCompletesWhenTheRetirementCannotBeSaved() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let gate = AdoptGate()
        let router = Router(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, registry: registry,
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 0.1))
        let id = serverID(project: env.project, name: "web")
        let target = ServerTargetParams(name: "web", project: env.project)
        guard let recorder = DirectaLog.backend as? RecordingBackend else {
            Issue.record("expected the swift-test host's default backend to be a RecordingBackend")
            return
        }

        let started = try await handle(router, .serverStart, target, ServerResult.self)
        let pid = try #require(started.server.pid)
        let stateFile = env.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: stateFile)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: stateFile) }

        let result = try await send(router, .serverUnregister, target, WireEmpty.self)
        if case .failure(let error) = result {
            Issue.record("unregister failed: \(error.message)")
        }
        #expect(await registry.spec(project: env.project, name: "web") == nil)
        #expect(
            recorder.entries.contains { entry in
                entry.level == .error && entry.message.contains(canonicalProjectPath(env.project))
                    && entry.message.contains("web")
            })

        await gate.signal(.signaled(signal: Int(SIGKILL)))
        try await awaitStoppedEvent(router: router, project: env.project, detail: "unregistered")
        let row = try #require(await registry.persistedState(serverID: id))
        #expect(row.resumeOnBoot == nil)
        #expect(row.pid == pid)
        #expect(row.lastExit == nil)
    }

    /** Polls until the late `recordOutcome` has posted its `stopped` event,
        the last thing it does before its (abandoned) state write. */
    private func awaitStoppedEvent(router: Router, project: String, detail: String) async throws {
        for _ in 0..<100 {
            let events = try await handle(
                router, .eventsQuery, EventsQueryParams(project: project), EventsQueryResult.self)
            if events.events.contains(where: { $0.kind == .stopped && $0.detail == detail }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("no stopped event with detail '\(detail)' after the gate opened")
    }

    /** A log directory removal that fails (a permission error, here, from a
        read-only logs root) must not vanish silently: the daemon leaves the
        directory for doctor's orphan-log-dir finding to catch, but logs the
        failure at error level so it is not lost entirely. */
    @Test func unregisterLogsAFailedLogDirectoryRemovalRatherThanSwallowingIt() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        try plantLogFile(paths: env.paths, project: env.project, server: "web")
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let logsRoot = env.paths.logsDir
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: logsRoot.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: logsRoot.path)
        }

        guard let recorder = DirectaLog.backend as? RecordingBackend else {
            Issue.record("expected the swift-test host's default backend to be a RecordingBackend")
            return
        }

        _ = try await handle(
            router, .serverUnregister, ServerTargetParams(name: "web", project: env.project),
            WireEmpty.self)

        #expect(
            FileManager.default.fileExists(
                atPath: env.paths.projectLogDir(project: env.project).path),
            "the read-only logs root should have blocked removal")
        #expect(
            recorder.entries.contains { entry in
                entry.level == .error && entry.message.contains(env.project)
                    && entry.message.contains("could not remove log directory")
            })
    }

    @Test func missingProjectSweepRemovesTheProjectLogDirectory() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        try plantLogFile(paths: env.paths, project: env.project, server: "web")
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        /** Captured while the checkout still exists: `canonicalProjectPath`
            resolves the on-disk case and symlinks of a path that exists, and
            falls back to a lexical resolution once it does not, so recomputing
            this after the `removeItem` below would silently check a different
            (never-created) directory instead of the one `plantLogFile` wrote to. */
        let logDir = env.paths.projectLogDir(project: env.project).path
        try FileManager.default.removeItem(atPath: env.project)
        let now = Date()
        /** First miss only starts the debounce; forgetting needs a second
            check a full sweep interval later (`MissingProjectPolicy`). */
        await router.pruneMissingProjects(now: now)
        await router.pruneMissingProjects(
            now: now.addingTimeInterval(Router.missingProjectSweepIntervalSeconds))

        #expect(!FileManager.default.fileExists(atPath: logDir))
    }

    /** Same failure mode as the unregister path, for `forgetMissingProject`'s
        own log directory removal: a permission error must not vanish
        silently. */
    @Test func missingProjectSweepLogsAFailedLogDirectoryRemovalRatherThanSwallowingIt() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        try plantLogFile(paths: env.paths, project: env.project, server: "web")
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let canonicalProject = canonicalProjectPath(env.project)
        let logDir = env.paths.projectLogDir(project: env.project).path
        try FileManager.default.removeItem(atPath: env.project)

        let logsRoot = env.paths.logsDir
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: logsRoot.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: logsRoot.path)
        }

        guard let recorder = DirectaLog.backend as? RecordingBackend else {
            Issue.record("expected the swift-test host's default backend to be a RecordingBackend")
            return
        }

        let now = Date()
        await router.pruneMissingProjects(now: now)
        await router.pruneMissingProjects(
            now: now.addingTimeInterval(Router.missingProjectSweepIntervalSeconds))

        #expect(
            FileManager.default.fileExists(atPath: logDir),
            "the read-only logs root should have blocked removal")
        #expect(
            recorder.entries.contains { entry in
                entry.level == .error && entry.message.contains(canonicalProject)
                    && entry.message.contains("could not remove log directory")
            })
    }
}
