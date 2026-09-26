import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

/** End-to-end proof that `serverWhy` actually reads the event history it is
    wired to, not just that `WhyEngine.diagnose` behaves correctly when handed
    a canned closure: a real SIGTERM lands `stopped`, `ControlServer` reads
    that stop's event detail back out of a real `EventStore`, and `directa
    why`'s summary names the signal and that directa did not ask for it. */
@Suite(.temporaryTree) struct WhyExternalSignalTests {
    private struct Env {
        let paths: DirectaPaths
        let project: String
    }

    private func makeEnv() throws -> Env {
        let base = try TemporaryTree.directory(named: "why-signal")
        let project = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(
            #"{"servers":{"web":{"command":["/bin/sh","-c","sleep 60"]}},"version":1}"#.utf8
        ).write(to: URL(fileURLWithPath: project.path).appending(path: "devservers.json"))
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

    private func status(_ router: Router, project: String, name: String) async throws -> ServerStatus {
        let list = try await handle(
            router, .serverStatus, ProjectParams(project: project), ServerListResult.self)
        return try #require(list.servers.first { $0.server == name })
    }

    @Test func whySummaryNamesAnExternalSignalOnceItLandsStopped() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let started = try await handle(
            router, .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        let pid = try #require(started.server.pid)

        kill(pid_t(pid), SIGTERM)
        var current = try await status(router, project: env.project, name: "web")
        for _ in 0..<50 where current.phase != .stopped {
            try await Task.sleep(for: .milliseconds(100))
            current = try await status(router, project: env.project, name: "web")
        }
        #expect(current.phase == .stopped)

        let why = try await handle(
            router, .serverWhy, ServerTargetParams(name: "web", project: env.project),
            WhyResult.self)
        #expect(
            why.findings.first?.summary
                == "not running (stopped by signal 15 sent from outside directa)")
    }

    @Test func whySummaryStaysBareAfterADirectaRequestedStop() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await handle(
            router, .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)

        let why = try await handle(
            router, .serverWhy, ServerTargetParams(name: "web", project: env.project),
            WhyResult.self)
        #expect(why.findings.first?.summary == "not running (stopped)")
    }
}
