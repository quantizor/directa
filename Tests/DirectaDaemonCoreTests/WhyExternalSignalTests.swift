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
    private func makeEnv() throws -> RouterEnv {
        let env = try makeRouterEnv(named: "why-signal")
        try Data(
            #"{"servers":{"web":{"command":["/bin/sh","-c","sleep 60"]}},"version":1}"#.utf8
        ).write(to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))
        return env
    }

    @Test func whySummaryNamesAnExternalSignalOnceItLandsStopped() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let started = try await router.call(
            .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        let pid = try #require(started.server.pid)

        kill(pid_t(pid), SIGTERM)
        let stopped = try await eventually(within: .seconds(5)) {
            try await router.call(
                .serverStatus, ProjectParams(name: "web", project: env.project), ServerListResult.self
            ).servers.first?.phase == .stopped
        }
        #expect(stopped)

        let why = try await router.call(
            .serverWhy, ServerTargetParams(name: "web", project: env.project),
            WhyResult.self)
        #expect(
            why.findings.first?.summary
                == "not running (stopped by signal 15 sent from outside directa)")
    }

    @Test func whySummaryStaysBareAfterADirectaRequestedStop() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await router.call(
            .serverStart, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)

        let why = try await router.call(
            .serverWhy, ServerTargetParams(name: "web", project: env.project),
            WhyResult.self)
        #expect(why.findings.first?.summary == "not running (stopped)")
    }
}
