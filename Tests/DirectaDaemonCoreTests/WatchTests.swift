import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** A dev server reused across sessions keeps running its old config, so a
    correct config fix looks like it did nothing and a harness keeps asserting
    against stale behavior. A server can now name the files it reads at boot.

    Every case drives `sweepWatches(now:)` with an explicit clock rather than
    sleeping out the settle and quiet windows. */
@Suite(.serialized) struct WatchTests {
    private func env(port: Int, watch: String?, locks: Bool = false) throws -> (
        paths: DirectaPaths, project: String
    ) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-watch-\(UUID().uuidString)")
        let project = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("v1\n".utf8).write(to: project.appending(path: "app.config.json"))
        let fixture = try #require(Self.fixtureServerPath())
        let watchKey = watch.map { "\"watch\": [\"\($0)\"]," } ?? ""
        let locksKey = locks ? "\"locks\": [\"data\"]," : ""
        let body = """
            {
              "servers": {
                "web": {
                  "command": ["\(fixture)", "--listen-tcp", "\(port)"],
                  "healthcheck": { "type": "tcp", "port": \(port) },
                  \(locksKey)
                  \(watchKey)
                  "port": \(port)
                }
              },
              "version": 1
            }
            """
        try Data(body.utf8).write(to: project.appending(path: "devservers.json"))
        return (
            paths: DirectaPaths(
                dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            project: project.path
        )
    }

    private func handle<P: Codable & Sendable, R: Codable & Sendable>(
        _ router: Router, _ method: WireMethod, _ params: P, _ expecting: R.Type
    ) async throws -> R {
        let line = try NDJSON.encodeLine(
            WireRequest(id: "t", method: method.rawValue, params: params))
        let data = await router.handle(line: line)
        let response = try JSONCoding.decoder().decode(WireResponse<R>.self, from: data)
        if response.ok, let result = response.result { return result }
        throw response.error ?? WireError(code: .internalError, message: "no result")
    }

    private func start(_ router: Router, _ project: String) async throws -> ServerStatus {
        try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: project, timeoutSeconds: 10), EnsureResult.self
        ).server
    }

    private func stop(_ router: Router, _ project: String) async {
        _ = try? await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: project),
            ServerResult.self)
    }

    /** Sweeps from an armed baseline through the quiet window, which is what a
        real daemon does at its own cadence. */
    private func settle(_ router: Router, from: Date) async -> [String] {
        var restarted: [String] = []
        for offset in [3.0, 4.0, 6.0] {
            restarted += await router.sweepWatches(now: from.addingTimeInterval(offset))
        }
        return restarted
    }

    @Test func aWatchedFileChangeRestartsTheServer() async throws {
        let env = try env(port: 45420, watch: "app.config.json")
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let first = try await start(router, env.project)
        let now = Date()
        /** Arms the baseline once the run is past the settle window. */
        _ = await router.sweepWatches(now: now.addingTimeInterval(3))

        try Data("v2\n".utf8)
            .write(to: URL(fileURLWithPath: env.project).appending(path: "app.config.json"))
        let restarted = await settle(router, from: now)
        #expect(restarted.count == 1)

        let after = try await handle(
            router, .serverStatus, ProjectParams(project: env.project), ServerListResult.self)
        let server = try #require(after.servers.first)
        #expect(server.phase == .running)
        #expect(server.pid != first.pid)
        await stop(router, env.project)
    }

    /** The reason a watch restart tore the server down must survive in the
        server's own log (OSLog does not persist) and on the `stopped` event,
        naming the file that changed, not just "code=0". */
    @Test func aWatchRestartLogsAndEventsTheChangedPathAsTheReason() async throws {
        let env = try env(port: 45427, watch: "app.config.json")
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await start(router, env.project)
        let now = Date()
        _ = await router.sweepWatches(now: now.addingTimeInterval(3))
        try Data("v2\n".utf8)
            .write(to: URL(fileURLWithPath: env.project).appending(path: "app.config.json"))
        #expect(await settle(router, from: now).count == 1)

        let logs = try await handle(
            router, .logsQuery,
            LogsQueryParams(name: "web", project: env.project, streams: [.sys]),
            LogsQueryResult.self)
        #expect(logs.lines.contains { $0.text == "stopping: watch change in app.config.json" })

        let events = try await handle(
            router, .eventsQuery, EventsQueryParams(project: env.project), EventsQueryResult.self)
        let stopped = try #require(events.events.last { $0.kind == .stopped })
        #expect(stopped.detail == "watch change in app.config.json")
        await stop(router, env.project)
    }

    /** The baseline is taken after the settle window, so a write that lands
        while the server is still booting (very often the server generating its
        own config) is folded into the baseline instead of bouncing it. */
    @Test func aWriteInsideTheSettleWindowDoesNotRestart() async throws {
        let env = try env(port: 45426, watch: "app.config.json")
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let first = try await start(router, env.project)
        let now = Date()
        /** Written before any sweep gets past the settle window. */
        try Data("v2\n".utf8)
            .write(to: URL(fileURLWithPath: env.project).appending(path: "app.config.json"))
        #expect(await settle(router, from: now).isEmpty)
        let after = try await handle(
            router, .serverStatus, ProjectParams(project: env.project), ServerListResult.self)
        #expect(try #require(after.servers.first).pid == first.pid)
        await stop(router, env.project)
    }

    /** The declare-nothing contract: a server whose framework reloads its own
        config must behave exactly as it did before this feature existed. */
    @Test func aServerWithNoWatchIsNeverRestarted() async throws {
        let env = try env(port: 45421, watch: nil)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let first = try await start(router, env.project)
        let now = Date()
        _ = await router.sweepWatches(now: now.addingTimeInterval(3))
        try Data("v2\n".utf8)
            .write(to: URL(fileURLWithPath: env.project).appending(path: "app.config.json"))
        #expect(await settle(router, from: now).isEmpty)

        let after = try await handle(
            router, .serverStatus, ProjectParams(project: env.project), ServerListResult.self)
        #expect(try #require(after.servers.first).pid == first.pid)
        await stop(router, env.project)
    }

    /** A stopped server has no armed watch, so an edit does not resurrect one
        somebody deliberately took down. */
    @Test func aStoppedServerIsNotResurrectedByAnEdit() async throws {
        let env = try env(port: 45422, watch: "app.config.json")
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await start(router, env.project)
        let now = Date()
        _ = await router.sweepWatches(now: now.addingTimeInterval(3))
        await stop(router, env.project)

        try Data("v2\n".utf8)
            .write(to: URL(fileURLWithPath: env.project).appending(path: "app.config.json"))
        #expect(await settle(router, from: now).isEmpty)
        let after = try await handle(
            router, .serverStatus, ProjectParams(project: env.project), ServerListResult.self)
        #expect(try #require(after.servers.first).phase == .stopped)
    }

    /** A watch hit must not bounce a server a harness is holding a lock against,
        and the pending edit must survive to fire once the hold releases. */
    @Test func aWatchHitUnderALiveLockIsDeferredNotDropped() async throws {
        let env = try env(port: 45423, watch: "app.config.json", locks: true)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let first = try await start(router, env.project)
        let now = Date()
        _ = await router.sweepWatches(now: now.addingTimeInterval(3))
        _ = try await handle(
            router, .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: false, project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)

        try Data("v2\n".utf8)
            .write(to: URL(fileURLWithPath: env.project).appending(path: "app.config.json"))
        #expect(await settle(router, from: now).isEmpty)
        let held = try await handle(
            router, .serverStatus, ProjectParams(project: env.project), ServerListResult.self)
        #expect(try #require(held.servers.first).pid == first.pid)

        _ = try await handle(
            router, .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)
        /** Continue the same synthetic timeline: a fresh wall clock would be
            earlier than the timestamps already injected, so the quiet window
            would never elapse. The edit is still pending, so it fires now that
            the hold is gone. */
        #expect(await settle(router, from: now.addingTimeInterval(10)).count == 1)
        let resumed = try await handle(
            router, .serverStatus, ProjectParams(project: env.project), ServerListResult.self)
        #expect(try #require(resumed.servers.first).pid != first.pid)
        await stop(router, env.project)
    }

    @Test func theKillSwitchStopsTheSweepEntirely() async throws {
        let env = try env(port: 45424, watch: "app.config.json")
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths, registry: registry,
            watchEnabled: false)
        let first = try await start(router, env.project)
        let now = Date()
        try Data("v2\n".utf8)
            .write(to: URL(fileURLWithPath: env.project).appending(path: "app.config.json"))
        #expect(await settle(router, from: now).isEmpty)
        let after = try await handle(
            router, .serverStatus, ProjectParams(project: env.project), ServerListResult.self)
        #expect(try #require(after.servers.first).pid == first.pid)
        await stop(router, env.project)
    }

    /** A watch hit is not a spec change, so it must not also raise specStale:
        the two answer different questions and conflating them would make a
        vite.config edit look like a devservers.json edit. */
    @Test func aWatchRestartDoesNotSetSpecStale() async throws {
        let env = try env(port: 45425, watch: "app.config.json")
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await start(router, env.project)
        let now = Date()
        _ = await router.sweepWatches(now: now.addingTimeInterval(3))
        try Data("v2\n".utf8)
            .write(to: URL(fileURLWithPath: env.project).appending(path: "app.config.json"))
        #expect(await settle(router, from: now).count == 1)
        let after = try await handle(
            router, .serverStatus, ProjectParams(project: env.project), ServerListResult.self)
        #expect(try #require(after.servers.first).specStale != true)
        await stop(router, env.project)
    }

    private static func fixtureServerPath() -> String? { fixtureServerExecutable() }
}
