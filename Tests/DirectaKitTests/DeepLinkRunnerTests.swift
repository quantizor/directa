import Foundation
import Testing

@testable import DirectaKit

/** A daemon stand-in: fixed project list plus a per-server status, and canned
    ensure/stop/why results. Records nothing beyond what the runner returns. */
private struct MockDaemon: DeepLinkDaemon {
    var projectPaths: [String] = ["/Users/x/code/myproj"]
    var status: ServerStatus?
    var ensureResult: EnsureResult?
    var stopResult: ServerResult?
    var whyResult: WhyResult?

    /** Other projects that define the asked-for name, answered to a
        machine-wide read that names one. */
    var definingProjects: [String] = []

    func statusList(project: String, name: String?) async throws -> ServerListResult {
        if project.isEmpty, let name {
            return ServerListResult(
                servers: definingProjects.map {
                    ServerStatus(logPath: "", phase: .stopped, project: $0, server: name)
                })
        }
        if project.isEmpty {
            // Machine-wide slug resolution: one status per project path.
            return ServerListResult(
                servers: projectPaths.map {
                    ServerStatus(logPath: "", phase: .running, project: $0, server: "any")
                })
        }
        guard let status else { return ServerListResult(servers: []) }
        return ServerListResult(servers: [status])
    }

    func ensure(_ params: EnsureParams) async throws -> EnsureResult {
        ensureResult ?? EnsureResult(
            server: ServerStatus(logPath: "", phase: .running, project: params.project, server: params.name))
    }

    func stop(_ target: ServerTargetParams) async throws -> ServerResult {
        stopResult ?? ServerResult(
            server: ServerStatus(logPath: "", phase: .stopped, project: target.project, server: target.name))
    }

    func why(_ target: ServerTargetParams) async throws -> WhyResult {
        whyResult ?? WhyResult(findings: [])
    }
}

private actor RecordingEffects: DeepLinkEffects {
    private(set) var opened: [URL] = []
    private(set) var pasteboard: [String] = []
    private(set) var notifications: [(title: String, body: String)] = []

    func copyToPasteboard(_ text: String) async { pasteboard.append(text) }
    func notify(title: String, body: String) async { notifications.append((title, body)) }
    func openBrowser(_ url: URL) async { opened.append(url) }
}

@Suite struct DeepLinkRunnerTests {
    private func runner(_ daemon: MockDaemon, _ effects: RecordingEffects) -> DeepLinkRunner {
        DeepLinkRunner(daemon: daemon, effects: effects)
    }

    @Test func ensureReportsPhase() async throws {
        let daemon = MockDaemon(
            ensureResult: EnsureResult(
                server: ServerStatus(logPath: "", phase: .running, project: "/Users/x/code/myproj", server: "cms")))
        let effects = RecordingEffects()
        let result = try await runner(daemon, effects).run(
            DeepLink(verb: .ensure, projectSlug: "myproj", server: "cms"))
        #expect(result == DeepLinkRunResult(verb: .ensure, projectPath: "/Users/x/code/myproj", detail: "running"))
    }

    @Test func ensureReportsFellShort() async throws {
        let daemon = MockDaemon(
            ensureResult: EnsureResult(
                reason: .timeout,
                server: ServerStatus(logPath: "", phase: .starting, project: "/Users/x/code/myproj", server: "cms")))
        let result = try await runner(daemon, RecordingEffects()).run(
            DeepLink(verb: .ensure, projectSlug: "myproj", server: "cms"))
        #expect(result.detail == "fell short: timeout")
    }

    @Test func stopReportsPhase() async throws {
        let result = try await runner(MockDaemon(), RecordingEffects()).run(
            DeepLink(verb: .stop, projectSlug: "myproj", server: "cms"))
        #expect(result == DeepLinkRunResult(verb: .stop, projectPath: "/Users/x/code/myproj", detail: "stopped"))
    }

    @Test func openOpensServerURL() async throws {
        let daemon = MockDaemon(
            status: ServerStatus(
                logPath: "", phase: .running, project: "/Users/x/code/myproj", server: "cms",
                url: "http://myproj.localhost:3000/"))
        let effects = RecordingEffects()
        let result = try await runner(daemon, effects).run(
            DeepLink(verb: .open, projectSlug: "myproj", server: "cms"))
        #expect(await effects.opened == [URL(string: "http://myproj.localhost:3000/")!])
        #expect(result.detail == "http://myproj.localhost:3000/")
    }

    @Test func openOpensNamedHead() async throws {
        let daemon = MockDaemon(
            status: ServerStatus(
                heads: ["wren-hollow": "http://wren-hollow.localhost:3000/"],
                logPath: "", phase: .running, project: "/Users/x/code/myproj", server: "cms",
                url: "http://myproj.localhost:3000/"))
        let effects = RecordingEffects()
        _ = try await runner(daemon, effects).run(
            DeepLink(verb: .open, projectSlug: "myproj", server: "cms", head: "wren-hollow"))
        #expect(await effects.opened == [URL(string: "http://wren-hollow.localhost:3000/")!])
    }

    @Test func openMissingHeadThrows() async {
        let daemon = MockDaemon(
            status: ServerStatus(
                heads: ["wren-hollow": "http://wren-hollow.localhost:3000/"],
                logPath: "", phase: .running, project: "/Users/x/code/myproj", server: "cms"))
        do {
            _ = try await runner(daemon, RecordingEffects()).run(
                DeepLink(verb: .open, projectSlug: "myproj", server: "cms", head: "cold-brook"))
            Issue.record("expected WireError")
        } catch let error as WireError {
            #expect(error.code == .notFound)
            #expect(error.hint == "run: directa status cms --json")
            #expect(error.message.contains("known heads: wren-hollow"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func openOfAServerTheProjectLacksNamesTheProjectsThatDefineIt() async {
        let daemon = MockDaemon(definingProjects: ["/Users/x/code/other"])
        do {
            _ = try await runner(daemon, RecordingEffects()).run(
                DeepLink(verb: .open, projectSlug: "myproj", server: "cms"))
            Issue.record("expected WireError")
        } catch let error as WireError {
            #expect(
                error
                    == WireError(
                        code: .notFound,
                        hint: "run: directa status cms --project '/Users/x/code/other'",
                        message:
                            "no server named 'cms' in /Users/x/code/myproj, but the registered project /Users/x/code/other defines it; pass --project with that path"
                    ))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func openWithoutURLThrows() async {
        let daemon = MockDaemon(
            status: ServerStatus(logPath: "", phase: .running, project: "/Users/x/code/myproj", server: "cms"))
        await #expect(throws: WireError.self) {
            try await runner(daemon, RecordingEffects()).run(
                DeepLink(verb: .open, projectSlug: "myproj", server: "cms"))
        }
    }

    @Test func whyCopiesAndNotifies() async throws {
        let daemon = MockDaemon(
            whyResult: WhyResult(
                findings: [
                    WhyFinding(
                        evidence: ["exit code 1"], phase: .crashed, server: "cms",
                        summary: "crashed on boot")
                ],
                rootCause: "cms crashed on boot"))
        let effects = RecordingEffects()
        let result = try await runner(daemon, effects).run(
            DeepLink(verb: .why, projectSlug: "myproj", server: "cms"))
        #expect(result.detail == "cms crashed on boot")
        let pasteboard = await effects.pasteboard
        #expect(pasteboard.count == 1)
        #expect(pasteboard[0].contains("root cause: cms crashed on boot"))
        #expect(pasteboard[0].contains("exit code 1"))
        let notifications = await effects.notifications
        #expect(notifications.count == 1)
        #expect(notifications[0].body == "cms crashed on boot")
    }

    @Test func unknownProjectSlugThrowsBeforeDispatch() async {
        let daemon = MockDaemon(projectPaths: ["/Users/x/code/myproj"])
        await #expect(throws: WireError.self) {
            try await runner(daemon, RecordingEffects()).run(
                DeepLink(verb: .stop, projectSlug: "ghost", server: "cms"))
        }
    }
}
