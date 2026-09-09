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

    @Test func staleWithNoLivePidsReapsEveryChildJob() {
        let jobs = [
            LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.a", pid: 10),
            LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.b"),
        ]
        #expect(LaunchdJobs.stale(jobs, keepingPids: []).count == 2)
    }
}
