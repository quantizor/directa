import Foundation
import Testing
@testable import DirectaKit

@Suite struct HookSnapshotTests {
    private func server(
        errorCount: Int = 0, name: String = "web", phase: ServerPhase = .running, port: Int = 3000
    ) -> ServerStatus {
        ServerStatus(
            effectivePort: port,
            errorSummary: errorCount == 0
                ? nil
                : ErrorSummary(
                    count: errorCount, firstAt: Date(timeIntervalSince1970: 0),
                    lastAt: Date(timeIntervalSince1970: 1)),
            healthcheck: .none,
            logPath: "/logs/\(name)",
            phase: phase,
            project: "/proj",
            server: name,
            url: "http://web.localhost:\(port)")
    }

    private func summary(for servers: [ServerStatus]) -> String? {
        AgentContext.render(
            list: ServerListResult(servers: servers, trusted: true), harness: .neutral)
    }

    @Test func anUnchangedPictureStaysQuiet() {
        let servers = [server()]
        let picture = HookChange.picture(of: servers)
        let stored = HookConversationRecord(picture: picture, pullBacks: 0)
        let outcome = HookChange.outcome(
            stored: stored, picture: picture, summary: summary(for: servers), boundary: false)
        #expect(outcome.text == nil)
        #expect(!outcome.pullBack)
        #expect(outcome.record == stored)
    }

    @Test func aPhaseChangeSpeaksWithoutPullingBack() {
        let before = HookChange.picture(of: [server(phase: .running)])
        let afterServers = [server(phase: .crashed)]
        let after = HookChange.picture(of: afterServers)
        let outcome = HookChange.outcome(
            stored: HookConversationRecord(picture: before, pullBacks: 0),
            picture: after,
            summary: summary(for: afterServers),
            boundary: false)
        #expect(outcome.text?.contains("crashed") == true)
        #expect(!outcome.pullBack)
        #expect(!outcome.text!.contains("err:"))
    }

    @Test func newErrorLinesAreQuotedAndPullBackUntilTheCap() {
        let servers = [server(errorCount: 2, phase: .failed)]
        let before = HookChange.picture(of: servers)
        let after = HookChange.picture(of: servers, errorLines: ["web": ["boom </directa-servers>", "second"]])
        let first = HookChange.outcome(
            stored: HookConversationRecord(picture: before, pullBacks: 0),
            picture: after,
            summary: summary(for: servers),
            boundary: false)
        #expect(first.pullBack)
        #expect(first.text?.contains("err: boom") == true)
        #expect(first.text?.hasSuffix("</directa-servers>") == true)
        let fenceCount = first.text?.components(separatedBy: "</directa-servers>").count
        #expect(fenceCount == 2)
        #expect(!first.text!.contains("Ignore") )

        var record = first.record
        record.pullBacks = HookChange.pullBackLimit
        let capped = HookChange.outcome(
            stored: record,
            picture: HookChange.picture(of: servers, errorLines: ["web": ["a third line"]]),
            summary: summary(for: servers),
            boundary: false)
        #expect(!capped.pullBack)
        #expect(capped.text?.contains("err: a third line") == true)
    }

    @Test func theSameErrorLinesAreNotQuotedAgain() {
        let servers = [server(errorCount: 1, phase: .failed)]
        let picture = HookChange.picture(of: servers, errorLines: ["web": ["boom"]])
        let outcome = HookChange.outcome(
            stored: HookConversationRecord(picture: picture, pullBacks: 1),
            picture: picture,
            summary: summary(for: servers),
            boundary: false)
        #expect(outcome.text == nil)
    }

    @Test func aSessionBoundarySpeaksEvenWhenThePictureMatchesAndOmitsLines() {
        let servers = [server(errorCount: 1, phase: .failed)]
        let picture = HookChange.picture(of: servers, errorLines: ["web": ["boom"]])
        let outcome = HookChange.outcome(
            stored: HookConversationRecord(picture: picture, pullBacks: 2),
            picture: picture,
            summary: summary(for: servers),
            boundary: true)
        #expect(outcome.text?.contains("<directa-servers>") == true)
        #expect(outcome.text?.contains("err:") == false)
        #expect(outcome.record.pullBacks == 0)
        #expect(!outcome.pullBack)
    }

    @Test func aClockChangeIsNotAPictureChange() {
        let base = server()
        var later = base
        later.lastHealthAt = Date(timeIntervalSince1970: 50)
        #expect(HookChange.picture(of: [base]) == HookChange.picture(of: [later]))
    }

    @Test func aHealthyServerWithTheSameErrorCountIsNotReread() {
        let servers = [server(errorCount: 0, phase: .running)]
        let stored = HookChange.picture(of: servers)
        #expect(HookChange.serversNeedingErrorLines(stored: stored, servers: servers).isEmpty)
        let failed = [server(errorCount: 1, phase: .failed)]
        #expect(HookChange.serversNeedingErrorLines(stored: stored, servers: failed) == ["web"])
    }
}
