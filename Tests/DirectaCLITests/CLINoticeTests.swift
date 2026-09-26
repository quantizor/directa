import DirectaKit
import Foundation
import Testing

@testable import directa

/** `CLIRunner.emitFailure` prepends "directa: " to every message it prints, so
    a message that itself led with "ddirecta" (the daemon binary's own name)
    used to read as "directa: ddirecta …", easy to misread as a doubled or
    misspelled word. Both strings here name the daemon in plain English so the
    prefixed form reads as one sentence. */
@Suite struct CLINoticeTests {
    @Test func deliberatelyStoppedNamesTheDaemonNotDdirecta() {
        #expect(CLINotice.daemonDeliberatelyStopped == "the daemon was deliberately stopped")
        #expect(!CLINotice.daemonDeliberatelyStopped.contains("ddirecta"))
    }

    @Test func restoringNoticeReadsAsOneSentenceWithThePrefix() {
        #expect(
            CLINotice.daemonRestoring == "directa: the daemon is restoring supervised servers; waiting…")
        #expect(!CLINotice.daemonRestoring.contains("ddirecta"))
    }
}
