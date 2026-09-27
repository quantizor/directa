import Foundation
import Testing

@testable import DirectaKit

@Suite struct LaunchdAdminShellTests {
    @Test func capturesStatusAndOutput() {
        let result = LaunchdAdmin.shell("/bin/echo", ["hello"])
        #expect(result.status == 0)
        #expect(result.output == "hello\n")
    }

    @Test func nonZeroExitIsReported() {
        let result = LaunchdAdmin.shell("/usr/bin/false", [])
        #expect(result.status != 0)
    }

    /** A child that writes more than one pipe buffer (macOS defaults to 64 KB)
        before exiting must not deadlock the caller: waiting for the child to
        exit before reading the pipe blocks the child on a full buffer it can
        never drain, and blocks this process on an exit that can now never
        happen. `shell` reads the pipe to its end before waiting, so the
        child's writes always have somewhere to go. */
    @Test func aChildWritingPastOnePipeBufferStillReturnsInFull() {
        let target = 200_000
        let result = LaunchdAdmin.shell("/bin/sh", ["-c", "yes | head -c \(target)"])
        #expect(result.status == 0)
        #expect(result.output.utf8.count == target)
    }

    /** The timed path polls the pipe on the calling thread up to its
        deadline; it returns the same full output. */
    @Test func aTimedChildWritingPastOnePipeBufferStillReturnsInFull() {
        let target = 200_000
        let result = LaunchdAdmin.shell(
            "/bin/sh", ["-c", "yes | head -c \(target)"], timeoutSeconds: 10)
        #expect(result.status == 0)
        #expect(result.output.utf8.count == target)
    }

    @Test func aCommandThatCannotStartReportsMinusOneOnEitherPath() {
        let missing = "/nonexistent/directa-shell-\(UUID().uuidString)"
        #expect(LaunchdAdmin.shell(missing, []).status == -1)
        #expect(LaunchdAdmin.shell(missing, [], timeoutSeconds: 1).status == -1)
    }

    @Test func theOutcomeOfAFinishedChildCarriesItsStatusAndOutput() {
        #expect(
            LaunchdAdmin.shellOutcome("/bin/sh", ["-c", "echo hello; exit 3"], timeoutSeconds: 10)
                == .exited(status: 3, output: "hello\n"))
        #expect(LaunchdAdmin.shellOutcome("/bin/echo", ["hi"]) == .exited(status: 0, output: "hi\n"))
    }

    @Test func aChildThatCannotStartIsNotAnExit() {
        let missing = "/nonexistent/directa-shell-\(UUID().uuidString)"
        for timeout in [nil, 1.0] {
            guard case .failedToRun = LaunchdAdmin.shellOutcome(missing, [], timeoutSeconds: timeout) else {
                Issue.record("a missing executable read as \(LaunchdAdmin.shellOutcome(missing, []))")
                continue
            }
        }
    }

    /** A timed-out child keeps what it wrote before the deadline, so a slow
        `log show` still yields the lines it found. */
    @Test func aTimedOutChildKeepsItsPartialOutput() {
        let started = ContinuousClock.now
        let outcome = LaunchdAdmin.shellOutcome("/bin/sh", ["-c", "echo early; sleep 5"], timeoutSeconds: 0.5)
        #expect(outcome == .timedOut(partialOutput: "early\n"))
        #expect(started.duration(to: .now) < .seconds(3))
    }

    /** A child that exits while a process it started still holds the output
        open ends at the deadline rather than waiting on that process. */
    @Test func anOutputHeldOpenPastTheDeadlineEndsTheWait() {
        let started = ContinuousClock.now
        let outcome = LaunchdAdmin.shellOutcome(
            "/bin/sh", ["-c", "echo started; sleep 4 & exit 0"], timeoutSeconds: 0.5)
        #expect(outcome == .timedOut(partialOutput: "started\n"))
        #expect(started.duration(to: .now) < .seconds(3))
    }

    /** The form async code calls answers exactly like the synchronous one. */
    @Test func theAsyncFormReturnsStatusAndFullOutput() async {
        let target = 200_000
        let result = await LaunchdAdmin.shell("/bin/sh", ["-c", "yes | head -c \(target); exit 4"])
        #expect(result.status == 4)
        #expect(result.output.utf8.count == target)
    }
}
