import DirectaKit
import Foundation
import Testing

@testable import directa

/** `Switch.run()` records trust before running the branch's lifecycle
    playbook, the same explicit-invocation-is-approval bargain `prepareSpawn`
    honors for ensure/start. A failed trust write is deliberately non-fatal
    (this warning prints and the playbook still runs), since refusing at that
    point would not undo the git switch or the drained servers that already
    happened; it would only leave the project's approval state confusing
    without fixing anything. */
@Suite struct SwitchTests {
    @Test func trustRecordingFailedWarningNamesTheExactRemediation() {
        let warning = Switch.trustRecordingFailedWarning(
            WireError(code: .daemonUnreachable, message: "cannot connect to the daemon at /tmp/x.sock: connection refused"))
        #expect(warning.contains("trust was not recorded for this project"))
        #expect(warning.contains("run: directa trust"))
    }
}
