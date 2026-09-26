import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** `daemon.info`'s `claimedProjects` is what `directa doctor`'s orphan-log-dir
    finding scans against instead of machine-wide server status, which drops a
    trusted project the instant its devservers.json cannot be parsed (mid-edit,
    or deleted): that project still claims its log directory, even though it
    has no servers to list right now. */
@Suite struct ClaimedProjectsTests {
    private struct Env {
        let paths: DirectaPaths
        let project: String
    }

    private func makeEnv() throws -> Env {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-claimed-projects-\(UUID().uuidString)")
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

    private func configURL(project: String) -> URL {
        URL(fileURLWithPath: project).appending(path: "devservers.json")
    }

    @Test func aTrustedProjectWithAnInvalidConfigButALiveSupervisorIsStillClaimed() async throws {
        let env = try makeEnv()
        try Data(
            #"{"servers":{"api":{"command":["/bin/sh","-c","sleep 60"]}},"version":1}"#.utf8
        ).write(to: configURL(project: env.project))
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await handle(
            router, .serverStart, ServerTargetParams(name: "api", project: env.project),
            ServerResult.self)
        let canonicalProject = canonicalProjectPath(env.project)

        /** devservers.json is now unreadable (a mid-edit save, or a syntax
            error): the project is still trusted and its supervisor still
            resident, so it must still be a claimed project. */
        try Data("not json".utf8).write(to: configURL(project: env.project))

        let info = try await handle(
            router, .daemonInfo, WireEmpty(), DaemonInfo.self)
        #expect(info.claimedProjects?.contains(canonicalProject) == true)

        /** Restore before stopping: `serverStop` re-resolves the spec through
            `mergedSpecs`, which would itself fail against the still-corrupt
            file. */
        try Data(
            #"{"servers":{"api":{"command":["/bin/sh","-c","sleep 60"]}},"version":1}"#.utf8
        ).write(to: configURL(project: env.project))
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "api", project: env.project),
            ServerResult.self)
    }

    @Test func anAdHocRegisteredProjectWithNoResidentSupervisorIsStillClaimed() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.project, spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 60"], name: "web"))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let info = try await handle(router, .daemonInfo, WireEmpty(), DaemonInfo.self)
        #expect(info.claimedProjects?.contains(canonicalProjectPath(env.project)) == true)
    }

    @Test func anUnrelatedProjectIsNotClaimed() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let info = try await handle(router, .daemonInfo, WireEmpty(), DaemonInfo.self)
        #expect(info.claimedProjects?.contains("/nowhere") == false)
        #expect(info.claimedProjects == [])
    }
}
