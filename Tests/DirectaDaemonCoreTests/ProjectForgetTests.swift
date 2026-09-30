import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

/** `project.forget` is the explicit, single-project counterpart to the
    automatic missing-project sweep (`forgetMissingProject`, driven by
    `pruneMissingProjects`): `doctor --fix` calls it for
    a project it believes is stale rather than re-implementing the teardown.
    It must never act on a project whose checkout still exists (that would
    drop trust and delete logs for something still live), and must refuse a
    path directa never registered rather than silently succeeding. */
@Suite(.temporaryTree) struct ProjectForgetTests {
    private func makeEnv() throws -> RouterEnv {
        try makeRouterEnv(named: "project-forget")
    }

    /** Never binds a port and exits only on signal, so starting it proves
        nothing about health or port ownership, only that a supervisor exists. */
    private func sleeperSpec(name: String) -> ServerSpec {
        ServerSpec(command: ["/bin/sh", "-c", "sleep 60"], name: name)
    }

    /** A project whose checkout still exists must be refused, even though it
        carries both trust and an ad hoc server: forgetting it would drop
        trust for something a person is still actively working in, the exact
        harm the daemon's automatic sweep avoids by checking `fileExists`
        before ever calling `forgetMissingProject`. */
    @Test func refusesAProjectWhosePathStillExists() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let outcome = try await router.attempt(
            .projectForget, ProjectOnlyParams(project: env.project),
            ProjectForgetResult.self)
        guard case .failure(let error) = outcome else {
            Issue.record("project.forget acted on a project whose checkout still exists")
            return
        }
        #expect(error.code == .projectStillExists)

        let entry = try #require(await registry.project(env.project))
        #expect(entry.trusted == true)
        #expect(entry.servers.keys.contains("web"))
    }

    /** A path directa never registered (never trusted, never an ad hoc
        target) is refused `not-found` rather than treated as a no-op
        success: `doctor --fix` must learn its `project` string was wrong
        instead of reporting a fix that never happened. */
    @Test func refusesAProjectDirectaNeverRegistered() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let outcome = try await router.attempt(
            .projectForget, ProjectOnlyParams(project: env.project),
            ProjectForgetResult.self)
        guard case .failure(let error) = outcome else {
            Issue.record("project.forget acted on a project directa never registered")
            return
        }
        #expect(error.code == .notFound)
    }

    /** The scenario `Registry.unregister` no longer serves once it keeps a
        trusted project's row alive: a stale checkout trusted through its
        committed devservers.json, with a live resident supervisor for the
        config-declared server, is fully forgotten in one call, row and trust
        and log directory together, not just the ad hoc entries `serverUnregister`
        is limited to. */
    @Test func fullyForgetsAStaleTrustedProjectWithAConfigDeclaredServer() async throws {
        let env = try makeEnv()
        try Data(
            #"{"servers":{"api":{"command":["/bin/sh","-c","sleep 60"]}},"version":1}"#.utf8
        ).write(to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await router.call(
            .serverStart, ServerTargetParams(name: "api", project: env.project),
            ServerResult.self)
        #expect(await registry.project(env.project)?.trusted == true)

        /** The `project` string a prior `server.status` returned, which is
            what a real caller holds once the checkout is gone. */
        let canonicalProject = canonicalProjectPath(env.project)
        try FileManager.default.removeItem(atPath: env.project)

        let result = try await router.call(
            .projectForget, ProjectOnlyParams(project: canonicalProject),
            ProjectForgetResult.self)
        #expect(result.servers == ["api"])

        #expect(await registry.project(canonicalProject) == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: env.paths.projectLogDir(project: canonicalProject).path))
    }

    /** Any spelling of the recorded path that canonicalizes to it (a trailing
        slash here) forgets the whole project: its running server is stopped
        and its supervisor, lock, and log directory go with the row, not only
        the registry entries that normalize the path themselves. */
    @Test func forgetsEveryPieceOfAProjectGivenATrailingSlashSpelling() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let started = try await router.call(
            .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        let pid = pid_t(try #require(started.server.pid))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        _ = try await router.call(
            .lockAcquire,
            LockParams(holderPid: Int(getpid()), project: env.project, resource: "db"), LockResult.self)

        let canonicalProject = canonicalProjectPath(env.project)
        try FileManager.default.removeItem(atPath: env.project)
        let result = try await router.call(
            .projectForget, ProjectOnlyParams(project: canonicalProject + "/"),
            ProjectForgetResult.self)

        #expect(result.servers == ["web"])
        #expect(kill(pid, 0) != 0, "the forgotten project's server \(pid) is still running")
        #expect(await registry.project(canonicalProject) == nil)
        let lock = try await router.call(
            .lockStatus, LockStatusParams(project: canonicalProject, resource: "db"),
            LockStatusResult.self)
        #expect(lock.holder == nil)
        let events = try await router.call(
            .eventsQuery, EventsQueryParams(project: canonicalProject), EventsQueryResult.self)
        #expect(events.events.filter { $0.kind == .stopped }.map(\.detail) == ["project path gone"])
        #expect(
            !FileManager.default.fileExists(atPath: env.paths.projectLogDir(project: canonicalProject).path))
    }

    /** A vanished checkout asked for through the `/var` link finds the key
        recorded under `/private/var` while the checkout existed, so its row
        and trust go rather than the request being refused as unknown. */
    @Test func forgetsAVanishedProjectGivenItsVarSpelling() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let recorded = canonicalProjectPath(env.project)
        try #require(recorded.hasPrefix("/private/var/"), "the temporary tree is not under /private/var: \(recorded)")
        try FileManager.default.removeItem(atPath: env.project)

        let outcome = try await router.attempt(
            .projectForget, ProjectOnlyParams(project: String(recorded.dropFirst("/private".count))),
            ProjectForgetResult.self)

        #expect((try? outcome.get()) != nil, "project.forget refused the /var spelling: \(outcome)")
        #expect(await registry.project(recorded) == nil)
    }

    /** A `project.forget` that lands while the automatic sweep is still
        tearing the same project down (suspended in its server's stop) runs no
        second teardown: the project's servers are stopped and unregistered
        once, and the late request reports nothing it did. */
    @Test func aForgetLandingDuringTheSweepsForgetTearsDownOnce() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let gate = AdoptGate()
        let router = Router(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, registry: registry,
            stopTiming: StopTiming(graceSeconds: 0.3, overtimeSeconds: 0.3))
        _ = try await router.call(
            .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        let canonicalProject = canonicalProjectPath(env.project)
        let serverLog = env.paths.structuredLogFile(project: canonicalProject, server: "web")
        try FileManager.default.removeItem(atPath: env.project)
        let now = Date()
        await router.pruneMissingProjects(now: now)

        async let sweep = router.pruneMissingProjects(
            now: now.addingTimeInterval(Router.missingProjectSweepIntervalSeconds))
        /** The stop writes its reason into the server's log before it waits,
            so the sweep is suspended inside the teardown from here on. */
        let stopping = try await eventually(within: .seconds(5)) {
            let text = (try? String(contentsOf: serverLog, encoding: .utf8)) ?? ""
            return text.contains("stopping: \(RemovalReason.projectPathGone)")
        }
        try #require(stopping, "the sweep never began stopping the server")
        let late = try await router.call(
            .projectForget, ProjectOnlyParams(project: canonicalProject), ProjectForgetResult.self)
        #expect(await sweep == 1)

        #expect(late.servers.isEmpty)
        let events = try await router.call(
            .eventsQuery, EventsQueryParams(project: canonicalProject), EventsQueryResult.self)
        #expect(events.events.filter { $0.kind == .unregistered }.map(\.server) == ["web"])
        #expect(await registry.project(canonicalProject) == nil)
        await gate.signal(.signaled(signal: Int(SIGKILL)))
        #expect(try await awaitStoppedEvents(router, project: canonicalProject) != nil)
    }

    /** An ad hoc-only project (never trusted, no devservers.json at all) is
        forgotten the same way: trust is not a precondition for the teardown,
        only a thing it also drops when present. */
    @Test func fullyForgetsAnAdHocOnlyStaleProject() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let canonicalProject = canonicalProjectPath(env.project)
        try FileManager.default.removeItem(atPath: env.project)

        let result = try await router.call(
            .projectForget, ProjectOnlyParams(project: canonicalProject),
            ProjectForgetResult.self)
        #expect(result.servers == ["web"])

        #expect(await registry.project(canonicalProject) == nil)
        #expect(await registry.isTrusted(project: canonicalProject) == false)
    }
}
