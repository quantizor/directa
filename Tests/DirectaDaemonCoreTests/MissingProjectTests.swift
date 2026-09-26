import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** `forgetMissingProject`'s event trail for a vanished checkout. A live server's
    `recordOutcome` posts its own `.stopped` event with the same "project path
    gone" detail this teardown reports, within the stop or, for a stop that
    gave up, whenever the exit lands; a server already terminal never reaches
    `recordOutcome` at all, since `stop()` no-ops for one. The manual post
    belongs to the terminal case only, or a live server's stop is recorded
    twice. */
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
        let now = Date()
        /** First miss only starts the debounce; forgetting needs a second
            check a full sweep interval later (`MissingProjectPolicy`). */
        await router.pruneMissingProjects(now: now)
        await router.pruneMissingProjects(
            now: now.addingTimeInterval(Router.missingProjectSweepIntervalSeconds))

        let events = try await handle(
            router, .eventsQuery, EventsQueryParams(project: canonicalProject),
            EventsQueryResult.self)
        let stopped = events.events.filter { $0.kind == .stopped }
        #expect(stopped.count == 1)
        #expect(stopped.first?.detail == "project path gone")
        #expect(events.events.filter { $0.kind == .unregistered }.count == 1)
    }

    /** A forgotten server whose stop never finishes: `removeState` deletes its
        row, and the exit that lands afterward must not recreate it (the row
        would otherwise carry the server's resume intent into a project directa
        no longer tracks). That late `recordOutcome` still posts the one
        `stopped` event; the teardown adds none of its own. */
    @Test func forgottenServerWhoseStopHangsStaysForgotten() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let gate = AdoptGate()
        let router = Router(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, registry: registry,
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 0.1))

        _ = try await handle(
            router, .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        let canonicalProject = canonicalProjectPath(env.project)
        let id = serverID(project: canonicalProject, name: "web")
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        try FileManager.default.removeItem(atPath: env.project)
        let now = Date()
        await router.pruneMissingProjects(now: now)
        await router.pruneMissingProjects(
            now: now.addingTimeInterval(Router.missingProjectSweepIntervalSeconds))
        #expect(await registry.persistedState(serverID: id) == nil)

        await gate.signal(.signaled(signal: Int(SIGKILL)))
        var stopped: [EventRecord] = []
        for _ in 0..<100 where stopped.isEmpty {
            stopped = try await handle(
                router, .eventsQuery, EventsQueryParams(project: canonicalProject),
                EventsQueryResult.self
            ).events.filter { $0.kind == .stopped }
            if stopped.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(stopped.map(\.detail) == ["project path gone"])
        for _ in 0..<10 {
            #expect(await registry.persistedState(serverID: id) == nil)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /** A retirement the forget cannot save (state.json refuses the write) is
        logged at error level rather than dropped silently, and the forget
        still completes. */
    @Test func forgetLogsARetirementItCannotSave() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.project, spec: sleeperSpec(name: "web"))
        let gate = AdoptGate()
        let router = Router(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, registry: registry,
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 0.1))
        guard let recorder = DirectaLog.backend as? RecordingBackend else {
            Issue.record("expected the swift-test host's default backend to be a RecordingBackend")
            return
        }

        _ = try await handle(
            router, .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        let canonicalProject = canonicalProjectPath(env.project)
        let stateFile = env.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: stateFile)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: stateFile)
            Task { await gate.signal(.signaled(signal: Int(SIGKILL))) }
        }

        try FileManager.default.removeItem(atPath: env.project)
        let now = Date()
        await router.pruneMissingProjects(now: now)
        await router.pruneMissingProjects(
            now: now.addingTimeInterval(Router.missingProjectSweepIntervalSeconds))

        #expect(await registry.project(canonicalProject) == nil)
        #expect(
            recorder.entries.contains { entry in
                entry.level == .error && entry.message.contains(canonicalProject)
                    && entry.message.contains("could not save its retired state")
            })
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
        let now = Date()
        await router.pruneMissingProjects(now: now)
        await router.pruneMissingProjects(
            now: now.addingTimeInterval(Router.missingProjectSweepIntervalSeconds))

        let events = try await handle(
            router, .eventsQuery, EventsQueryParams(project: canonicalProject),
            EventsQueryResult.self)
        let stopped = events.events.filter { $0.kind == .stopped }
        #expect(stopped.count == 1)
        #expect(stopped.first?.detail == "project path gone")
        #expect(events.events.filter { $0.kind == .unregistered }.count == 1)
    }

    /** A checkout that comes back before the sweep interval elapses (an
        unmount that resolves, a Finder move undone) clears the miss instead of
        being forgotten on the schedule the first miss started: a later check
        past that original interval sees the path present and does nothing. */
    @Test func aPathThatReappearsIsNeverForgotten() async throws {
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
            does not, so a lookup after the `removeItem` below must use this
            spelling, not `env.project` directly. */
        let canonicalProject = canonicalProjectPath(env.project)
        let now = Date()
        try FileManager.default.removeItem(atPath: env.project)
        #expect(await router.pruneMissingProjects(now: now) == 0)
        #expect(await registry.project(canonicalProject) != nil)

        try FileManager.default.createDirectory(
            atPath: env.project, withIntermediateDirectories: true)
        #expect(
            await router.pruneMissingProjects(
                now: now.addingTimeInterval(Router.missingProjectSweepIntervalSeconds)) == 0)
        #expect(await registry.project(canonicalProject) != nil)

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
    }
}
