import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** `directa down <name>` reuses `GroupParams.only`, the field `directa up
    <name>` already threads through as shorthand for `--only <name>`. Down
    scopes `group.down` to the named server alone, never its dependents: a
    name here says what to stop, not what to bring along, the opposite of
    `--only`'s transitive pull-in under `up`. */
@Suite(.serialized) struct GroupDownOnlyTests {
    private func env() throws -> (paths: DirectaPaths, project: String) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-down-only-\(UUID().uuidString)")
        let project = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fixture = try #require(Self.fixtureServerPath())
        let body = """
            {
              "servers": {
                "api": {
                  "command": ["\(fixture)", "--listen-tcp", "45621"],
                  "healthcheck": { "type": "tcp", "port": 45621 },
                  "port": 45621
                },
                "web": {
                  "command": ["\(fixture)", "--listen-tcp", "45620"],
                  "dependsOn": ["api"],
                  "healthcheck": { "type": "tcp", "port": 45620 },
                  "port": 45620
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
        let line = try NDJSON.encodeLine(WireRequest(id: "t", method: method.rawValue, params: params))
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

    @Test func downWithOnlyStopsTheNamedServerAloneNotItsDependents() async throws {
        let env = try env()
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let up = try await handle(
            router, .groupUp, GroupParams(project: env.project, timeoutSeconds: 10), GroupResult.self)
        #expect(up.results.allSatisfy { $0.server.phase == .running })

        let down = try await handle(
            router, .groupDown, GroupParams(only: ["api"], project: env.project), GroupResult.self)
        #expect(down.results.map(\.server.server) == ["api"])
        #expect(try await phase(router, env.project, "api") == .stopped)
        #expect(try await phase(router, env.project, "web") == .running)

        _ = try await handle(router, .groupDown, GroupParams(project: env.project), GroupResult.self)
    }

    @Test func downWithOnlyNamingAnUnknownServerFailsNotFoundAndStopsNothing() async throws {
        let env = try env()
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let up = try await handle(
            router, .groupUp, GroupParams(project: env.project, timeoutSeconds: 10), GroupResult.self)
        #expect(up.results.allSatisfy { $0.server.phase == .running })

        let error = await #expect(throws: WireError.self) {
            _ = try await handle(
                router, .groupDown, GroupParams(only: ["bogus"], project: env.project), GroupResult.self)
        }
        #expect(error?.code == .notFound)
        #expect(error?.message == "no server named 'bogus' in \(canonicalProjectPath(env.project))")
        #expect(try await phase(router, env.project, "api") == .running)
        #expect(try await phase(router, env.project, "web") == .running)

        _ = try await handle(router, .groupDown, GroupParams(project: env.project), GroupResult.self)
    }

    private static func fixtureServerPath() -> String? { fixtureServerExecutable() }
}
