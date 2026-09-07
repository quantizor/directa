import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** `directa stop X && directa ensure X` was what twelve sessions wrote by hand.
    It has two defects a single daemon-side transition removes: another session's
    ensure can land between the two commands, and a refusal (a held resource, a
    broken config) arrives only after the server is already down. */
@Suite(.serialized) struct RestartTests {
    /** A port per test: a case that fails before its teardown would otherwise
        leave a listener behind and fail the next one for an unrelated reason. */
    private func env(port: Int) throws -> (paths: DirectaPaths, project: String) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-restart-\(UUID().uuidString)")
        let project = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writeConfig(port: port, project: project.path)
        return (
            paths: DirectaPaths(
                dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            project: project.path
        )
    }

    private func writeConfig(port: Int, project: String) throws {
        let fixture = try #require(Self.fixtureServerPath())
        let body = """
            {
              "servers": {
                "db": {
                  "command": ["\(fixture)", "--listen-tcp", "\(port)"],
                  "healthcheck": { "type": "tcp", "port": \(port) },
                  "locks": ["data"],
                  "port": \(port)
                }
              },
              "version": 1
            }
            """
        try Data(body.utf8)
            .write(to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
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

    private func phase(_ router: Router, _ project: String, _ name: String) async throws
        -> ServerPhase
    {
        let list = try await handle(
            router, .serverStatus, ProjectParams(project: project), ServerListResult.self)
        return try #require(list.servers.first { $0.server == name }).phase
    }

    @Test func restartReplacesThePidAndKeepsResumeOnBoot() async throws {
        let env = try env(port: 45411)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let first = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        #expect(first.server.phase == .running)
        let id = serverID(project: env.project, name: "db")
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        let restarted = try await handle(
            router, .serverRestart,
            RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
            GroupResult.self)
        let server = try #require(restarted.results.first?.server)
        #expect(server.phase == .running)
        #expect(server.pid != first.server.pid)
        /** A deliberate stop would clear this, so a hand-rolled stop-then-ensure
            drops the boot intent and re-sets it; restart never drops it. */
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** The headline: a stop-then-ensure pair takes the server down and is then
        refused, leaving it down. Restart refuses before touching it. */
    @Test func restartUnderALiveLockIsRefusedAndLeavesTheServerRunning() async throws {
        let env = try env(port: 45412)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        _ = try await handle(
            router, .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: false, project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)

        await #expect(throws: WireError.self) {
            _ = try await handle(
                router, .serverRestart,
                RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
        }
        #expect(try await phase(router, env.project, "db") == .running)

        _ = try await handle(
            router, .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** A server the lock already paused must not come back behind the hold. */
    @Test func restartOfAPausedServerIsRefusedAndItStaysDown() async throws {
        let env = try env(port: 45413)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        let acquired = try await handle(
            router, .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), pause: true, project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)
        #expect(acquired.paused == ["db"])

        await #expect(throws: WireError.self) {
            _ = try await handle(
                router, .serverRestart,
                RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
        }
        #expect(try await phase(router, env.project, "db") == .stopped)

        _ = try await handle(
            router, .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.project, resource: "data",
                resumeTimeoutSeconds: 10), LockResult.self)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    /** A bad save must not take a healthy server down. */
    @Test func restartWithABrokenConfigLeavesTheServerRunning() async throws {
        let env = try env(port: 45414)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        try Data("{ not json".utf8)
            .write(to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))

        await #expect(throws: WireError.self) {
            _ = try await handle(
                router, .serverRestart,
                RestartParams(names: ["db"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
        }
        /** Restore the config before reading status: the status path parses it
            too, so a broken file would fail the assertion for the wrong reason. */
        try writeConfig(port: 45414, project: env.project)
        #expect(try await phase(router, env.project, "db") == .running)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    @Test func restartOfAnUnknownNameIsNotFoundAndTouchesNothing() async throws {
        let env = try env(port: 45415)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "db", project: env.project, timeoutSeconds: 10), EnsureResult.self)
        do {
            _ = try await handle(
                router, .serverRestart,
                RestartParams(names: ["ghost"], project: env.project, timeoutSeconds: 10),
                GroupResult.self)
            Issue.record("expected not-found")
        } catch let error as WireError {
            #expect(error.code == .notFound)
        }
        #expect(try await phase(router, env.project, "db") == .running)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "db", project: env.project),
            ServerResult.self)
    }

    private static func fixtureServerPath() -> String? { fixtureServerExecutable() }
}
