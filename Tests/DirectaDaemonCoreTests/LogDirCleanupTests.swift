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
}
