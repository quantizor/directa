import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** A project's log directory used to survive both an explicit unregister down
    to zero servers and the missing-project sweep; only `uninstall --purge`
    removed it. `ControlServer`'s `serverUnregister` arm and
    `forgetMissingProject` are the two paths that now clean it up, each proven
    here against real files on disk rather than a mocked FileManager. */
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
        codebase's own rule), so unregistering "web" (the project's only ad hoc
        entry) drops the registry row entirely while "api" still holds a
        resident supervisor. The directory must survive: the registry row
        disappearing is not proof nothing is left supervising the project. */
    @Test func unregisteringOneServerKeepsTheDirectoryWhileAnotherIsStillSupervised() async throws {
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
        /** Confirms this test actually exercises the still-supervised guard
            rather than passing because the registry still names something. */
        #expect(await registry.project(env.project) == nil)

        #expect(
            FileManager.default.fileExists(
                atPath: env.paths.projectLogDir(project: env.project).path))

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "api", project: env.project),
            ServerResult.self)
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
        await router.pruneMissingProjects()

        #expect(!FileManager.default.fileExists(atPath: logDir))
    }
}
