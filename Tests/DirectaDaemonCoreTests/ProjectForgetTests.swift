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
    private struct Env {
        let paths: DirectaPaths
        let project: String
    }

    private func makeEnv() throws -> Env {
        let base = try TemporaryTree.directory(named: "project-forget")
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

        let outcome = try await send(
            router, .projectForget, ProjectOnlyParams(project: env.project),
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

        let outcome = try await send(
            router, .projectForget, ProjectOnlyParams(project: env.project),
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

        _ = try await handle(
            router, .serverStart, ServerTargetParams(name: "api", project: env.project),
            ServerResult.self)
        #expect(await registry.project(env.project)?.trusted == true)

        /** Captured while the checkout still exists, matching the reasoning in
            `LogDirCleanupTests`/`MissingProjectTests`: `canonicalProjectPath`
            resolves the on-disk spelling while the directory exists and falls
            back to a lexical resolution once it does not, so recomputing this
            after the `removeItem` below could disagree with the registry key
            recorded at registration and silently look up nothing. This is also
            exactly what a real caller sees: the `project` string a prior
            `server.status` returned, captured before the checkout vanished. */
        let canonicalProject = canonicalProjectPath(env.project)
        try FileManager.default.removeItem(atPath: env.project)

        let result = try await handle(
            router, .projectForget, ProjectOnlyParams(project: canonicalProject),
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
        let started = try await handle(
            router, .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        let pid = pid_t(try #require(started.server.pid))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        _ = try await handle(
            router, .lockAcquire,
            LockParams(holderPid: Int(getpid()), project: env.project, resource: "db"), LockResult.self)

        let canonicalProject = canonicalProjectPath(env.project)
        try FileManager.default.removeItem(atPath: env.project)
        let result = try await handle(
            router, .projectForget, ProjectOnlyParams(project: canonicalProject + "/"),
            ProjectForgetResult.self)

        #expect(result.servers == ["web"])
        #expect(kill(pid, 0) != 0, "the forgotten project's server \(pid) is still running")
        #expect(await registry.project(canonicalProject) == nil)
        let lock = try await handle(
            router, .lockStatus, LockStatusParams(project: canonicalProject, resource: "db"),
            LockStatusResult.self)
        #expect(lock.holder == nil)
        let events = try await handle(
            router, .eventsQuery, EventsQueryParams(project: canonicalProject), EventsQueryResult.self)
        #expect(events.events.filter { $0.kind == .stopped }.map(\.detail) == ["project path gone"])
        #expect(
            !FileManager.default.fileExists(atPath: env.paths.projectLogDir(project: canonicalProject).path))
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
        defer { Task { await gate.signal(.signaled(signal: Int(SIGKILL))) } }
        _ = try await handle(
            router, .serverStart, ServerTargetParams(name: "web", project: env.project),
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
        var stopping = false
        for _ in 0..<250 where !stopping {
            let text = (try? String(contentsOf: serverLog, encoding: .utf8)) ?? ""
            stopping = text.contains("stopping: \(RemovalReason.projectPathGone)")
            if !stopping { try await Task.sleep(for: .milliseconds(20)) }
        }
        try #require(stopping, "the sweep never began stopping the server")
        let late = try await handle(
            router, .projectForget, ProjectOnlyParams(project: canonicalProject), ProjectForgetResult.self)
        #expect(await sweep == 1)

        #expect(late.servers.isEmpty)
        let events = try await handle(
            router, .eventsQuery, EventsQueryParams(project: canonicalProject), EventsQueryResult.self)
        #expect(events.events.filter { $0.kind == .unregistered }.map(\.server) == ["web"])
        #expect(await registry.project(canonicalProject) == nil)
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

        let result = try await handle(
            router, .projectForget, ProjectOnlyParams(project: canonicalProject),
            ProjectForgetResult.self)
        #expect(result.servers == ["web"])

        #expect(await registry.project(canonicalProject) == nil)
        #expect(await registry.isTrusted(project: canonicalProject) == false)
    }
}
