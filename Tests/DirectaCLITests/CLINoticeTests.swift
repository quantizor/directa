import DirectaKit
import Foundation
import Testing

@testable import directa

/** `CLINotice` bodies print after "directa: " (`CLIRunner.noticeLine`), so a
    body names the daemon in plain English rather than as "ddirecta", which
    would read "directa: ddirecta …", and never carries the prefix itself. */
@Suite struct CLINoticeTests {
    private static let bodies = [
        CLINotice.daemonDeliberatelyStopped, CLINotice.daemonOlderThanCLI, CLINotice.daemonRestoring,
        CLINotice.daemonUninstallDeprecated, CLINotice.followUseMonitor, CLINotice.restartConnectionLost,
    ]

    @Test func deliberatelyStoppedNamesTheDaemonNotDdirecta() {
        #expect(CLINotice.daemonDeliberatelyStopped == "the daemon was deliberately stopped")
    }

    @Test func restoringNoticeReadsAsOneSentenceWithThePrefix() {
        #expect(
            CLIRunner.noticeLine(CLINotice.daemonRestoring)
                == "directa: the daemon is restoring supervised servers; waiting…")
    }

    @Test func everyBodyLeavesThePrefixToThePrinter() {
        for body in Self.bodies {
            #expect(!body.hasPrefix("directa:"), "\(body)")
            #expect(!body.contains("ddirecta"), "\(body)")
        }
    }

    /** The printed lines stay byte for byte what each command wrote before
        its body moved here. */
    @Test func thePrintedLinesAreUnchanged() {
        #expect(
            CLIRunner.noticeLine(CLINotice.restartConnectionLost)
                == "directa: the daemon connection closed during the restart; waiting for it to come back and checking the server instead of restarting it again")
        #expect(
            CLIRunner.noticeLine(CLINotice.followUseMonitor)
                == "directa: to stream a server's output into this session, run directa monitor <name> with the Monitor tool")
        #expect(
            CLIRunner.noticeLine(CLINotice.daemonUninstallDeprecated)
                == "directa: `directa daemon uninstall` is deprecated; use `directa uninstall` (or `directa uninstall --agent-only` to remove just the agent)")
    }
}
