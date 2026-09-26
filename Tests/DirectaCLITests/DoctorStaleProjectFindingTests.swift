import ArgumentParser
import DirectaKit
import Foundation
import Testing

@testable import directa

/** `Doctor.staleProjectFixFinding` turns a `project.forget` outcome into the
    `stale-project` finding `doctor --fix` reports: a plural-aware success
    message, and an old daemon's "unknown method" refusal rewritten into a
    restart hint rather than the raw wire error. Pure, so both are asserted
    without a live socket. */
@Suite struct DoctorStaleProjectFindingTests {
    @Test func oneServerIsSingular() {
        let finding = Doctor.staleProjectFixFinding(
            project: "/p", outcome: .success(ProjectForgetResult(servers: ["web"])))
        #expect(finding.detail == "forgot /p (1 server)")
        #expect(finding.kind == "stale-project")
        #expect(finding.severity == "fixed")
    }

    @Test func multipleServersArePlural() {
        let finding = Doctor.staleProjectFixFinding(
            project: "/p", outcome: .success(ProjectForgetResult(servers: ["api", "web"])))
        #expect(finding.detail == "forgot /p (2 servers)")
    }

    @Test func zeroServersIsPlural() {
        let finding = Doctor.staleProjectFixFinding(
            project: "/p", outcome: .success(ProjectForgetResult(servers: [])))
        #expect(finding.detail == "forgot /p (0 servers)")
    }

    /** The exact `usage` message an older daemon (one built before
        `project.forget` existed) answers with, rewritten into a restart hint
        rather than shown as a raw "unknown method" error the reader cannot
        act on. */
    @Test func anOlderDaemonThatLacksTheMethodGetsARestartHint() {
        let error = WireError(
            code: .usage,
            message: WireError.unknownMethodMessage(WireMethod.projectForget.rawValue))
        let finding = Doctor.staleProjectFixFinding(project: "/p", outcome: .failure(error))
        #expect(finding.severity == "error")
        #expect(finding.detail == "could not forget /p: the running daemon predates project.forget; run: directa daemon restart")
    }

    /** Every other failure (the checkout reappeared, an internal error) keeps
        the daemon's own message verbatim rather than being swept into the
        old-daemon rewrite. */
    @Test func everyOtherFailureKeepsTheDaemonsOwnMessage() {
        let error = WireError(code: .projectStillExists, message: "/p still exists on disk")
        let finding = Doctor.staleProjectFixFinding(project: "/p", outcome: .failure(error))
        #expect(finding.detail == "could not forget /p: /p still exists on disk")
        #expect(finding.severity == "error")
    }
}
