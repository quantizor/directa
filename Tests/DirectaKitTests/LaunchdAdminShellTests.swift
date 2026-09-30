import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaKit

/** The synchronous forms under test block their thread on the child, so each
    runs through `offPool`, never on the test's own pool thread. */
@Suite struct LaunchdAdminShellTests {
    @Test func capturesStatusAndOutput() async {
        let result = await offPool { LaunchdAdmin.shell("/bin/echo", ["hello"]) }
        #expect(result.status == 0)
        #expect(result.output == "hello\n")
    }

    @Test func nonZeroExitIsReported() async {
        let result = await offPool { LaunchdAdmin.shell("/usr/bin/false", []) }
        #expect(result.status != 0)
    }

    /** A child that writes more than one pipe buffer (macOS defaults to 64 KB)
        before exiting must not deadlock the caller: waiting for the child to
        exit before reading the pipe blocks the child on a full buffer it can
        never drain, and blocks this process on an exit that can now never
        happen. `shell` reads the pipe to its end before waiting, so the
        child's writes always have somewhere to go. */
    @Test func aChildWritingPastOnePipeBufferStillReturnsInFull() async {
        let target = 200_000
        let result = await offPool { LaunchdAdmin.shell("/bin/sh", ["-c", "yes | head -c \(target)"]) }
        #expect(result.status == 0)
        #expect(result.output.utf8.count == target)
    }

    /** The timed path polls the pipe on the calling thread up to its
        deadline; it returns the same full output. */
    @Test func aTimedChildWritingPastOnePipeBufferStillReturnsInFull() async {
        let target = 200_000
        let result = await offPool {
            LaunchdAdmin.shell("/bin/sh", ["-c", "yes | head -c \(target)"], timeoutSeconds: 10)
        }
        #expect(result.status == 0)
        #expect(result.output.utf8.count == target)
    }

    @Test func aCommandThatCannotStartReportsMinusOneOnEitherPath() async {
        let missing = "/nonexistent/directa-shell-\(UUID().uuidString)"
        #expect(await offPool { LaunchdAdmin.shell(missing, []) }.status == -1)
        #expect(await offPool { LaunchdAdmin.shell(missing, [], timeoutSeconds: 1) }.status == -1)
    }

    @Test func theOutcomeOfAFinishedChildCarriesItsStatusAndOutput() async {
        let timed = await offPool {
            LaunchdAdmin.shellOutcome("/bin/sh", ["-c", "echo hello; exit 3"], timeoutSeconds: 10)
        }
        let untimed = await offPool { LaunchdAdmin.shellOutcome("/bin/echo", ["hi"]) }
        #expect(timed == .exited(status: 3, output: "hello\n"))
        #expect(untimed == .exited(status: 0, output: "hi\n"))
    }

    @Test func aChildThatCannotStartIsNotAnExit() async {
        let missing = "/nonexistent/directa-shell-\(UUID().uuidString)"
        for timeout in [nil, 1.0] {
            let outcome = await offPool { LaunchdAdmin.shellOutcome(missing, [], timeoutSeconds: timeout) }
            guard case .failedToRun = outcome else {
                Issue.record("a missing executable read as \(outcome)")
                continue
            }
        }
    }

    /** A timed-out child keeps what it wrote before the deadline, so a slow
        `log show` still yields the lines it found. */
    @Test func aTimedOutChildKeepsItsPartialOutput() async {
        let (outcome, elapsed) = await offPool {
            let started = ContinuousClock.now
            let outcome = LaunchdAdmin.shellOutcome("/bin/sh", ["-c", "echo early; sleep 5"], timeoutSeconds: 0.5)
            return (outcome, started.duration(to: .now))
        }
        #expect(outcome == .timedOut(partialOutput: "early\n"))
        #expect(elapsed < .seconds(3))
    }

    /** The `(status, output)` form says a timeout happened, with the deadline,
        instead of answering a bare -1 and an empty string, and appends what
        the child wrote first. */
    @Test func aTimedOutChildReportsTheDeadlineAndItsPartialOutput() async {
        let result = await offPool {
            LaunchdAdmin.shell("/bin/sh", ["-c", "echo early; sleep 5"], timeoutSeconds: 0.5)
        }
        #expect(result.status == -1)
        #expect(result.output == "timed out after 0.5 seconds; output so far: early\n")
    }

    @Test func aTimedOutChildWithNoOutputReportsOnlyTheDeadline() async {
        let result = await offPool { LaunchdAdmin.shell("/bin/sleep", ["5"], timeoutSeconds: 1) }
        #expect(result.status == -1)
        #expect(result.output == "timed out after 1 seconds")
    }

    /** The deadline a caller never named (launchctl's default) reads as a whole
        number of seconds. */
    @Test func aDefaultDeadlineReadsWithoutADecimal() {
        #expect(
            LaunchdAdmin.timedOutOutput(deadlineSeconds: HelperCommand.launchctlTimeoutSeconds, partialOutput: "")
                == "timed out after 10 seconds")
    }

    /** `capturedPath` reads a timed-out shell, or one that never started, as
        no answer, never as the partial output or the error reason, so the
        PATH floor applies. */
    @Test func aPathCaptureWithoutAnExitFallsBackToTheFloor() {
        #expect(
            LaunchdAdmin.capturedPath(from: .timedOut(partialOutput: "/partial/bin:")) == LaunchdAdmin.pathFloor)
        #expect(
            LaunchdAdmin.capturedPath(from: .failedToRun("The file “zsh” doesn’t exist."))
                == LaunchdAdmin.pathFloor)
        #expect(
            LaunchdAdmin.capturedPath(from: .exited(status: 0, output: "/usr/bin:/opt/bin\n")) == "/usr/bin:/opt/bin")
        #expect(LaunchdAdmin.capturedPath(from: .exited(status: 0, output: "\n")) == LaunchdAdmin.pathFloor)
    }

    /** A child that exits while a process it started still holds the output
        open ends at the deadline rather than waiting on that process. The
        call is timed on the thread that makes it, so a busy pool delaying the
        test's resumption is not counted. */
    @Test func anOutputHeldOpenPastTheDeadlineEndsTheWait() async {
        let (outcome, elapsed) = await offPool {
            let started = ContinuousClock.now
            let outcome = LaunchdAdmin.shellOutcome(
                "/bin/sh", ["-c", "echo started; sleep 4 & exit 0"], timeoutSeconds: 0.5)
            return (outcome, started.duration(to: .now))
        }
        #expect(outcome == .timedOut(partialOutput: "started\n"))
        #expect(elapsed < .seconds(3))
    }

    /** A runaway writer is killed at the output cap, on the timed and the
        untimed path alike, and answers the first cap's worth of what it wrote
        long before its deadline. */
    @Test(arguments: [nil, 5.0])
    func aRunawayWriterIsKilledAtTheOutputCap(timeout: Double?) async {
        let (outcome, elapsed) = await offPool {
            let started = ContinuousClock.now
            let outcome = LaunchdAdmin.shellOutcome("/usr/bin/yes", [], timeoutSeconds: timeout)
            return (outcome, started.duration(to: .now))
        }
        guard case .outputLimitExceeded(let partialOutput) = outcome else {
            Issue.record("a child writing without end read as \(String("\(outcome)".prefix(60)))")
            return
        }
        #expect(partialOutput.utf8.count == HelperCommand.outputLimitBytes)
        #expect(elapsed < .seconds(3))
    }

    /** Exactly the cap is an answer; one byte more is a runaway. */
    @Test func theOutputCapAdmitsExactlyItsOwnSize() async {
        let cap = HelperCommand.outputLimitBytes
        let atCap = await offPool {
            LaunchdAdmin.shellOutcome("/bin/sh", ["-c", "yes | head -c \(cap)"], timeoutSeconds: 30)
        }
        let pastCap = await offPool {
            LaunchdAdmin.shellOutcome("/bin/sh", ["-c", "yes | head -c \(cap + 1)"], timeoutSeconds: 30)
        }
        guard case .exited(status: 0, let output) = atCap else {
            Issue.record("output exactly at the cap read as \(String("\(atCap)".prefix(60)))")
            return
        }
        #expect(output.utf8.count == cap)
        guard case .outputLimitExceeded(let partialOutput) = pastCap else {
            Issue.record("output one byte past the cap read as \(String("\(pastCap)".prefix(60)))")
            return
        }
        #expect(partialOutput.utf8.count == cap)
    }

    /** The `(status, output)` form names the cap and leaves the partial
        output out, so an error message built from it stays small. */
    @Test func aRunawayWriterReportsTheCapInTheStatusForm() async {
        let result = await offPool { LaunchdAdmin.shell("/usr/bin/yes", [], timeoutSeconds: 5) }
        #expect(result.status == -1)
        #expect(result.output == "output exceeded \(HelperCommand.outputLimitBytes) bytes")
    }

    /** `capturedPath` reads a runaway shell as no answer too. */
    @Test func aPathCaptureThatRanAwayFallsBackToTheFloor() {
        #expect(
            LaunchdAdmin.capturedPath(from: .outputLimitExceeded(partialOutput: "/partial/bin:"))
                == LaunchdAdmin.pathFloor)
    }

    /** The helpers the daemon runs on a fixed-width lane get a deadline when
        the caller names none, so a hung one cannot hold a lane thread forever;
        a launchctl verb that waits for a job to exit gets room for launchd's
        60-second `ExitTimeOut` ceiling. Everything else still waits. */
    @Test func helpersTheDaemonRunsGetADeadlineByDefault() {
        let launchctl = "/bin/launchctl"
        #expect(
            HelperCommand.defaultTimeoutSeconds(executable: launchctl, arguments: ["list"])
                == HelperCommand.launchctlTimeoutSeconds)
        #expect(
            HelperCommand.defaultTimeoutSeconds(executable: launchctl, arguments: ["print", "gui/501/x"])
                == HelperCommand.launchctlTimeoutSeconds)
        #expect(
            HelperCommand.defaultTimeoutSeconds(executable: launchctl, arguments: ["kickstart", "gui/501/x"])
                == HelperCommand.launchctlTimeoutSeconds)
        #expect(
            HelperCommand.defaultTimeoutSeconds(executable: launchctl, arguments: ["bootout", "gui/501/x"])
                == HelperCommand.launchctlJobExitTimeoutSeconds)
        #expect(
            HelperCommand.defaultTimeoutSeconds(executable: launchctl, arguments: ["kickstart", "-k", "gui/501/x"])
                == HelperCommand.launchctlJobExitTimeoutSeconds)
        #expect(HelperCommand.launchctlJobExitTimeoutSeconds > 60)
        #expect(
            HelperCommand.defaultTimeoutSeconds(executable: "/usr/sbin/lsof", arguments: ["-nP"])
                == HelperCommand.lsofTimeoutSeconds)
        #expect(
            HelperCommand.defaultTimeoutSeconds(executable: "/bin/ps", arguments: ["-p", "1"])
                == HelperCommand.psTimeoutSeconds)
        #expect(HelperCommand.defaultTimeoutSeconds(executable: "/usr/bin/git", arguments: ["fetch"]) == nil)
        #expect(HelperCommand.defaultTimeoutSeconds(executable: "/usr/bin/open", arguments: ["x"]) == nil)
    }

    /** Output parsed as a value (a `--version` string) excludes stderr, so a
        warning on stderr cannot corrupt it; the default keeps both. */
    @Test func stdoutAloneWhenStderrIsExcluded() async {
        let script = ["-c", "echo warning >&2; echo 1.2.3"]
        for timeout in [nil, 10.0] {
            let alone = await offPool {
                LaunchdAdmin.shell("/bin/sh", script, includeStderr: false, timeoutSeconds: timeout).output
            }
            let merged = await offPool { LaunchdAdmin.shell("/bin/sh", script, timeoutSeconds: timeout).output }
            #expect(alone == "1.2.3\n")
            #expect(merged == "warning\n1.2.3\n")
        }
    }

    @Test func theAsyncFormExcludesStderrToo() async {
        let script = ["-c", "echo warning >&2; echo 1.2.3"]
        #expect(await LaunchdAdmin.shell("/bin/sh", script, includeStderr: false).output == "1.2.3\n")
    }

    /** The form async code calls answers exactly like the synchronous one. */
    @Test func theAsyncFormReturnsStatusAndFullOutput() async {
        let target = 200_000
        let result = await LaunchdAdmin.shell("/bin/sh", ["-c", "yes | head -c \(target); exit 4"])
        #expect(result.status == 4)
        #expect(result.output.utf8.count == target)
    }
}
