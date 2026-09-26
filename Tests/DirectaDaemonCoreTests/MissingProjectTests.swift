import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** `forgetMissingProject`'s event trail for a vanished checkout. A live server's
    `stop()` already runs `recordOutcome`, which posts its own `.stopped` event
    with the same "project path gone" detail this teardown reports; a server
    already terminal never reaches `recordOutcome` at all, since `stop()` no-ops
    for one. The manual post belongs to the terminal case only, or a live
    server's stop is recorded twice. */
@Suite struct MissingProjectTests {
    private struct Env {
        let paths: DirectaPaths
        let project: String
    }

    private func makeEnv() throws -> Env {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-missing-project-\(UUID().uuidString)")
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

    /** Never binds a port and exits only on signal, so starting it proves
        nothing about health or port ownership, only that a supervisor exists. */
    private func sleeperSpec(name: String) -> ServerSpec {
        ServerSpec(command: ["/bin/sh", "-c", "sleep 60"], name: name)
    }

    @Test func forgottenLiveServerPostsExactlyOneStoppedEvent() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await handle(
            router, .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)

        /** Captured while the checkout still exists, matching the reasoning in
            `LogDirCleanupTests`: `canonicalProjectPath` resolves the on-disk
            path while it exists and falls back to a lexical resolution once it
            does not, so querying with `env.project` after the `removeItem`
            below could silently miss the events posted under the canonical
            spelling recorded while the directory was still there. */
        let canonicalProject = canonicalProjectPath(env.project)
        try FileManager.default.removeItem(atPath: env.project)
        await router.pruneMissingProjects()

        let events = try await handle(
            router, .eventsQuery, EventsQueryParams(project: canonicalProject),
            EventsQueryResult.self)
        let stopped = events.events.filter { $0.kind == .stopped }
        #expect(stopped.count == 1)
        #expect(stopped.first?.detail == "project path gone")
        #expect(events.events.filter { $0.kind == .unregistered }.count == 1)
    }

    @Test func forgottenTerminalServerStillPostsAStoppedEvent() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        /** A plain status query lazily creates a resident supervisor (so
            `forgetMissingProject` finds one in `supervisors`) that never spawned
            anything, leaving it at the terminal `.stopped` phase `stop()`
            no-ops on. */
        _ = try await handle(
            router, .serverStatus, ProjectParams(project: env.project), ServerListResult.self)

        let canonicalProject = canonicalProjectPath(env.project)
        try FileManager.default.removeItem(atPath: env.project)
        await router.pruneMissingProjects()

        let events = try await handle(
            router, .eventsQuery, EventsQueryParams(project: canonicalProject),
            EventsQueryResult.self)
        let stopped = events.events.filter { $0.kind == .stopped }
        #expect(stopped.count == 1)
        #expect(stopped.first?.detail == "project path gone")
        #expect(events.events.filter { $0.kind == .unregistered }.count == 1)
    }
}
