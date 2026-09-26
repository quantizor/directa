import Darwin
import Foundation
import Testing

@testable import DirectaKit

@Suite struct LaunchdJobsTests {
    @Test func parseAgentPrintReadsJetsamExitAndRunCount() {
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
        let status = LaunchdJobs.parseAgentPrint(printed)
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
    @Test func parseAgentPrintReadsAnExitedJobsLastExitCode() {
        let printed = """
            gui/501/dev.quantizor.directa.test-job.probe = {
            state = not running
            runs = 1
            last exit code = 7
            }
            """
        #expect(
            LaunchdJobs.parseAgentPrint(printed)
                == LaunchdJobs.AgentStatus(lastExitCode: 7, runs: 1, state: "not running"))
    }

    /** Before its first exit launchd prints `(never exited)`, which is no code. */
    @Test func parseAgentPrintReadsNeverExitedAsNoCode() {
        let printed = """
            state = running
            runs = 1
            pid = 99
            last exit code = (never exited)
            """
        #expect(
            LaunchdJobs.parseAgentPrint(printed)
                == LaunchdJobs.AgentStatus(pid: 99, runs: 1, state: "running"))
    }

    @Test func parseAgentPrintWithoutJetsamIsNotJetsammed() {
        let printed = """
            state = running
            runs = 1
            pid = 99
            """
        let status = LaunchdJobs.parseAgentPrint(printed)
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
        #expect(jobs[0] == LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.live", lastExitStatus: 0, pid: 48080))
        #expect(jobs[1] == LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.dead", lastExitStatus: -15, pid: nil))
    }

    @Test func staleKeepsOnlyPidsTheDaemonStillSupervises() {
        let live = LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.a", pid: 10)
        let ghostRunning = LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.b", pid: 11)
        let ghostGone = LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.c", lastExitStatus: -15)
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

    @Test func staleWithNoLivePidsReapsEveryChildJob() {
        let jobs = [
            LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.a", pid: 10),
            LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.b"),
        ]
        #expect(LaunchdJobs.stale(jobs, keepingPids: []).count == 2)
    }
}
