import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

/** `daemon.info`'s `claimedProjects` is what `directa doctor`'s orphan-log-dir
    finding scans against instead of machine-wide server status, which drops a
    trusted project the instant its devservers.json cannot be parsed (mid-edit,
    or deleted): that project still claims its log directory, even though it
    has no servers to list right now. */
@Suite(.temporaryTree) struct ClaimedProjectsTests {
    private func configURL(project: String) -> URL {
        URL(fileURLWithPath: project).appending(path: "devservers.json")
    }

    @Test func aTrustedProjectWithAnInvalidConfigButALiveSupervisorIsStillClaimed() async throws {
        let env = try makeRouterEnv(named: "claimed-projects")
        try Data(
            #"{"servers":{"api":{"command":["/bin/sh","-c","sleep 60"]}},"version":1}"#.utf8
        ).write(to: configURL(project: env.project))
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await router.call(
            .serverStart, ServerTargetParams(name: "api", project: env.project),
            ServerResult.self)
        let canonicalProject = canonicalProjectPath(env.project)

        /** devservers.json is now unreadable (a mid-edit save, or a syntax
            error): the project is still trusted and its supervisor still
            resident, so it must still be a claimed project. */
        try Data("not json".utf8).write(to: configURL(project: env.project))

        let info = try await router.call(
            .daemonInfo, WireEmpty(), DaemonInfo.self)
        #expect(info.claimedProjects?.contains(canonicalProject) == true)

        /** Restore before stopping: `serverStop` re-resolves the spec through
            `mergedSpecs`, which would itself fail against the still-corrupt
            file. */
        try Data(
            #"{"servers":{"api":{"command":["/bin/sh","-c","sleep 60"]}},"version":1}"#.utf8
        ).write(to: configURL(project: env.project))
        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "api", project: env.project),
            ServerResult.self)
    }

    @Test func anAdHocRegisteredProjectWithNoResidentSupervisorIsStillClaimed() async throws {
        let env = try makeRouterEnv(named: "claimed-projects")
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.project, spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 60"], name: "web"))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let info = try await router.call(.daemonInfo, WireEmpty(), DaemonInfo.self)
        #expect(info.claimedProjects?.contains(canonicalProjectPath(env.project)) == true)
    }

    @Test func anUnrelatedProjectIsNotClaimed() async throws {
        let env = try makeRouterEnv(named: "claimed-projects")
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let info = try await router.call(.daemonInfo, WireEmpty(), DaemonInfo.self)
        #expect(info.claimedProjects?.contains("/nowhere") == false)
        #expect(info.claimedProjects == [])
    }
}
