import Darwin
import Foundation
import Testing

@testable import DirectaKit

@Suite struct LaunchdJobsTests {
    @Test func parseJobPrintReadsJetsamExitAndRunCount() {
        let printed = """
            gui/501/dev.quantizor.directa = {
            state = running
            program identifier = Contents/Helpers/ddirecta (mode: 2)
            runs = 13
            pid = 46668
            last exit reason = OS_REASON_JETSAM
            last jetsam exit details = OS_REASON_JETSAM
            jetsam coalition = {
            state = active
            }
            }
            """
        let status = LaunchdJobs.parseJobPrint(printed)
        #expect(status.state == "running")
        #expect(status.pid == 46668)
        #expect(status.runs == 13)
        #expect(status.lastExitReason == "OS_REASON_JETSAM")
        #expect(status.jetsammed)
    }

    /** A one-shot job that already ran and exited: launchd drops its pid and
        keeps the run count and exit code, which is how the launcher tells an
        instant exit from a job that has not started yet. Captured from a real
        `launchctl print` of an `exit 7` job. */
    @Test func parseJobPrintReadsAnExitedJobsLastExitCode() {
        let printed = """
            gui/501/dev.quantizor.directa.test-job.probe = {
            state = not running
            runs = 1
            last exit code = 7
            }
            """
        #expect(
            LaunchdJobs.parseJobPrint(printed)
                == LaunchdJobs.JobStatus(lastExitCode: 7, runs: 1, state: "not running"))
    }

    /** For an exit code with a sysexits.h name, launchd appends it after the
        number. Every line here is verbatim from a real `launchctl print` of a
        `/bin/sh -c "exit N"` job. */
    @Test(arguments: [
        ("last exit code = 0", 0),
        ("last exit code = 64: EX_USAGE", 64),
        ("last exit code = 69: EX_UNAVAILABLE", 69),
        ("last exit code = 77: EX_NOPERM", 77),
        ("last exit code = 78: EX_CONFIG", 78),
        ("last exit code = 127", 127),
    ])
    func parseJobPrintReadsTheLeadingExitCodeNumber(line: String, code: Int) {
        let printed = """
            state = not running
            runs = 1
            \(line)
            """
        #expect(
            LaunchdJobs.parseJobPrint(printed)
                == LaunchdJobs.JobStatus(lastExitCode: code, runs: 1, state: "not running"))
    }

    /** A job a signal ended prints no exit code line at all, only the signal
        by name and number. Both lines verbatim from a real `launchctl print`
        of `/bin/sh -c "kill -9 $$"` and `"kill -15 $$"`. */
    @Test(arguments: [
        ("last terminating signal = Killed: 9", 9),
        ("last terminating signal = Terminated: 15", 15),
    ])
    func parseJobPrintReadsTheTerminatingSignalNumber(line: String, signal: Int) {
        let printed = """
            state = not running
            runs = 1
            \(line)
            """
        #expect(
            LaunchdJobs.parseJobPrint(printed)
                == LaunchdJobs.JobStatus(lastTerminatingSignal: signal, runs: 1, state: "not running"))
    }

    /** Before its first exit launchd prints `(never exited)`, which is no code. */
    @Test func parseJobPrintReadsNeverExitedAsNoCode() {
        let printed = """
            state = running
            runs = 1
            pid = 99
            last exit code = (never exited)
            """
        #expect(
            LaunchdJobs.parseJobPrint(printed)
                == LaunchdJobs.JobStatus(pid: 99, runs: 1, state: "running"))
    }

    @Test func parseJobPrintWithoutJetsamIsNotJetsammed() {
        let printed = """
            state = running
            runs = 1
            pid = 99
            """
        let status = LaunchdJobs.parseJobPrint(printed)
        #expect(status.jetsammed == false)
        #expect(status.lastExitReason == nil)
        #expect(status.runs == 1)
    }

    @Test func parseChildJobsSkipsTheAgentAndReadsPidDashAsGone() {
        let listed = """
            PID\tStatus\tLabel
            46668\t-9\tdev.quantizor.directa
            48080\t0\tdev.quantizor.directa.job.live
            -\t-15\tdev.quantizor.directa.job.dead
            12\t0\tcom.apple.something
            """
        let jobs = LaunchdJobs.parseChildJobs(fromList: listed)
        #expect(jobs.count == 2)
        #expect(jobs[0] == LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.live", pid: 48080))
        #expect(jobs[1] == LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.dead", pid: nil))
    }

    @Test func staleKeepsOnlyPidsTheDaemonStillSupervises() {
        let live = LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.a", pid: 10)
        let ghostRunning = LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.b", pid: 11)
        let ghostGone = LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.c")
        let stale = LaunchdJobs.stale([live, ghostRunning, ghostGone], keepingPids: [10])
        #expect(stale.map(\.label) == [
            "dev.quantizor.directa.job.b", "dev.quantizor.directa.job.c",
        ])
    }

    /** A job bootstrapped under test uses a distinct label prefix
        (`dev.quantizor.directa.test-job.`, injected on `LaunchdJobLauncher`),
        never the production `dev.quantizor.directa.job.` this parse matches,
        so a concurrently running real daemon's `doctor` and leftover-job reap
        never see a test's throwaway jobs as their own leftovers. */
    @Test func parseChildJobsNeverMatchesATestPrefixedJob() {
        let listed = """
            PID\tStatus\tLabel
            48080\t0\tdev.quantizor.directa.test-job.abc
            """
        #expect(LaunchdJobs.parseChildJobs(fromList: listed).isEmpty)
    }

    /** Only a print that never answered is `unresponsive`: a nonzero exit or a
        launchctl that would not start is an answer with no job. */
    @Test func aPrintOutcomeIsUnresponsiveOnlyWhenLaunchctlNeverAnswered() {
        let printed = "state = running\npid = 4242\n"
        #expect(
            LaunchdJobs.jobPrint(from: .exited(status: 0, output: printed))
                == .found(LaunchdJobs.JobStatus(pid: 4242, state: "running")))
        #expect(LaunchdJobs.jobPrint(from: .exited(status: 113, output: "Could not find service")) == .absent)
        #expect(LaunchdJobs.jobPrint(from: .failedToRun("no such file")) == .absent)
        #expect(LaunchdJobs.jobPrint(from: .timedOut(partialOutput: "state = running\n")) == .unresponsive)
        #expect(LaunchdJobs.jobPrint(from: .outputLimitExceeded(partialOutput: printed)) == .unresponsive)
    }

    @Test func staleWithNoLivePidsReapsEveryChildJob() {
        let jobs = [
            LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.a", pid: 10),
            LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.b"),
        ]
        #expect(LaunchdJobs.stale(jobs, keepingPids: []).count == 2)
    }
}
