import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

/** Boot restore takes as long as there is state to bring back, and until it
    finished the daemon answered nothing at all: the socket was unlinked in
    `ControlServer.init` and only recreated on the way to `.ready`, so a client
    got ENOENT and reported `daemon-unreachable`. That is the same answer a
    daemon that is truly gone produces, so an agent polling across an install or
    restart bounce read a busy daemon as a dead one and tried to start a second.
    The daemon now accepts during restore and says which of the two it is. */
@Suite(.temporaryTree) struct RestoreWindowTests {
    private func makeRouter() throws -> (router: Router, project: String) {
        let base = try TemporaryTree.directory(named: "restore")
        let project = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"servers":{},"version":1}"#.utf8).write(
            to: project.appending(path: "devservers.json"))
        let paths = DirectaPaths(
            dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs"))
        try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        return (
            router: Router(
                launcher: SubprocessLauncher(), paths: paths, registry: Registry(paths: paths)),
            project: project.path
        )
    }

    private func send<P: Codable & Sendable>(
        _ router: Router, method: WireMethod, params: P
    ) async throws -> WireResponse<WireEmpty> {
        let line = try NDJSON.encodeLine(
            WireRequest(id: "t", method: method.rawValue, params: params))
        return try JSONCoding.decoder().decode(
            WireResponse<WireEmpty>.self, from: await router.handle(line: line))
    }

    private func info(_ router: Router) async throws -> DaemonInfo {
        let line = try NDJSON.encodeLine(
            WireRequest(id: "t", method: WireMethod.daemonInfo.rawValue, params: WireEmpty()))
        let response = try JSONCoding.decoder().decode(
            WireResponse<DaemonInfo>.self, from: await router.handle(line: line))
        return try #require(response.result)
    }

    @Test func workDuringRestoreIsRefusedWithAReasonAndNotSilence() async throws {
        let (router, project) = try makeRouter()
        await router.setRestoring(true)

        let response = try await send(router, method: .serverStatus, params: ProjectParams(project: project))
        #expect(response.ok == false)
        let error = try #require(response.error)
        #expect(error.code == .daemonStarting)
        #expect(error.message == "the daemon is still restoring supervised servers and is not serving requests yet")
        /** `CLIRunner.emitFailure` prepends "directa: " to this message; a
            message that itself led with "ddirecta" (the daemon binary's own
            name) would read as "directa: ddirecta …", a stutter easy to
            mistake for a typo. */
        #expect(!error.message.contains("ddirecta"))
        /** The hint has to be the literal command that reports progress, because
            every other failure hint sends the reader to `daemon status` and that
            is exactly the command that has to keep working here. */
        #expect(error.hint == "run: directa daemon status")
    }

    @Test func daemonInfoAnswersDuringRestoreAndSaysSo() async throws {
        let (router, _) = try makeRouter()
        await router.setRestoring(true)
        #expect(try await info(router).restoring == true)
    }

    /** Omitted rather than `false` once restore is done, so the existing
        `daemon.info` schema golden is unchanged for every normal response. */
    @Test func aServingDaemonOmitsTheRestoringFlagEntirely() async throws {
        let (router, _) = try makeRouter()
        await router.setRestoring(true)
        await router.setRestoring(false)
        #expect(try await info(router).restoring == nil)

        let encoded = try JSONCoding.encoder().encode(try await info(router))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("restoring") == false)
    }

    /** A wedged restore must still be stoppable, so shutdown is the one mutating
        method the gate lets through. Asserted by the gate's own verdict rather
        than by calling it, since the handler exits the process. */
    @Test func onlyInfoAndShutdownPassTheGate() async throws {
        let allowed = WireMethod.allCases.filter { Router.isServableWhileRestoring($0) }
        #expect(allowed == [.daemonInfo, .daemonShutdown])
    }

    @Test func recoveryClearsTheGateSoWorkResumes() async throws {
        let (router, project) = try makeRouter()
        await router.setRestoring(true)
        await router.recoverAtStartup()
        await router.setRestoring(false)

        let response = try await send(router, method: .serverStatus, params: ProjectParams(project: project))
        #expect(response.ok == true)
    }
}
