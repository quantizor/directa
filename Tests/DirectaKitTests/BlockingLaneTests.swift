import Darwin
import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaKit

@Suite(.temporaryTree) struct BlockingLaneTests {
    /** A lane never runs more than `width` jobs at once: with every running
        job held on a gate, one more never starts, and all of them finish in
        full once the gate opens. */
    @Test func aLaneRunsAtMostWidthJobsAtOnce() async {
        let lane = BlockingLane(label: "dev.quantizor.directa.test.lane", width: 2)
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let jobs = 6
        let calls = (0..<jobs).map { index in
            Task.detached {
                await lane.run {
                    entered.signal()
                    gate.wait()
                    return index
                }
            }
        }
        let startedPastWidth = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let thread = Thread {
                entered.wait()
                entered.wait()
                let third = entered.wait(timeout: .now() + 0.2) == .success
                for _ in 0..<jobs { gate.signal() }
                continuation.resume(returning: third)
            }
            thread.name = "blocking-lane-test-gate"
            thread.start()
        }
        var results: [Int] = []
        for call in calls {
            results.append(await call.value)
        }
        #expect(!startedPastWidth, "a third job started while two held the lane's full width")
        #expect(results == Array(0..<jobs))
    }

    /** Pressure counts running and queued jobs exactly, the oldest queued
        wait grows while the lane is full, and only a job that waited past the
        lane's slow-wait bound is reported, once, with its lane name. */
    @Test func pressureAndSlowWaitsAreReported() async throws {
        let activity = DaemonActivity()
        let heard = OSAllocatedUnfairLock<[String]>(initialState: [])
        activity.setObserver { event in
            if case .laneWaited(let lane, let seconds) = event {
                heard.withLock { $0.append("\(lane) \(seconds >= 0.15)") }
            }
        }
        let lane = BlockingLane(
            label: "dev.quantizor.directa.test.pressure", width: 1, activity: activity, slowWaitSeconds: 0.15)
        #expect(lane.pressure() == LanePressure(name: "pressure", oldestQueuedSeconds: 0, queued: 0, running: 0, width: 1))
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let calls = (0..<3).map { index in
            Task.detached {
                await lane.run {
                    entered.signal()
                    gate.wait()
                    return index
                }
            }
        }
        let observed = await withCheckedContinuation { (continuation: CheckedContinuation<LanePressure?, Never>) in
            let thread = Thread {
                guard entered.wait(timeout: .now() + 5) == .success else {
                    continuation.resume(returning: nil)
                    return
                }
                let deadline = Date().addingTimeInterval(5)
                while lane.pressure().queued < 2, Date() < deadline { usleep(2_000) }
                usleep(200_000)
                let pressure = lane.pressure()
                for _ in 0..<3 { gate.signal() }
                continuation.resume(returning: pressure)
            }
            thread.name = "blocking-lane-test-pressure"
            thread.start()
        }
        var results: [Int] = []
        for call in calls {
            results.append(await call.value)
        }
        let pressure = try #require(observed)
        #expect(pressure.running == 1)
        #expect(pressure.queued == 2)
        #expect(pressure.oldestQueuedSeconds >= 0.2)
        #expect(results.sorted() == [0, 1, 2])
        #expect(lane.pressure() == LanePressure(name: "pressure", oldestQueuedSeconds: 0, queued: 0, running: 0, width: 1))
        #expect(heard.withLock { $0 } == ["pressure true", "pressure true"])
        activity.setObserver(nil)
    }

    /** Git calls against a repository whose `HEAD` is a FIFO hang in `open(2)`
        until something opens the other end, the shape of a git stuck on a
        network filesystem. Twice as many callers as the cooperative pool has
        threads must leave that pool free to run other work: a trivial task
        submitted after every caller still completes while all of them hang.
        Measured from a dedicated thread, since the test body itself runs on
        the pool it is measuring. */
    @Test func hungGitCallsLeaveTheCooperativePoolFree() async throws {
        let repo = try HungRepository()
        let callers = ProcessInfo.processInfo.activeProcessorCount * 2
        let finished = OSAllocatedUnfairLock(initialState: 0)
        let path = repo.path
        let calls = (0..<callers).map { _ in
            Task.detached {
                let answer = await CheckoutIdentity.gitCommonDir(project: path)
                finished.withLock { $0 += 1 }
                return answer
            }
        }
        let responded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let thread = Thread {
                let ran = DispatchSemaphore(value: 0)
                Task.detached { ran.signal() }
                let result = ran.wait(timeout: .now() + 1.5) == .success
                repo.release(until: { finished.withLock { $0 } == callers })
                continuation.resume(returning: result)
            }
            thread.name = "blocking-lane-test-probe"
            thread.start()
        }
        for call in calls {
            #expect(await call.value == nil)
        }
        #expect(responded, "a trivial task could not run while \(callers) git calls hung")
    }

    /** A git that never returns is terminated at its timeout and answers nil,
        so it cannot hold a lane thread forever. The release pump starts only
        far past the timeout, and whether the answer needed it is the
        assertion: elapsed time is not, since a loaded machine can delay the
        spawn itself. */
    @Test func aHungGitIsTerminatedAtItsTimeout() async throws {
        let repo = try HungRepository()
        let path = repo.path
        let answered = OSAllocatedUnfairLock(initialState: false)
        let call = Task.detached {
            let answer = await BlockingLane.repository.run {
                CheckoutIdentity.git(
                    project: path, args: ["rev-parse", "--git-common-dir"], timeoutSeconds: 0.3)
            }
            answered.withLock { $0 = true }
            return answer
        }
        let neededRelease = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let thread = Thread {
                let pumpFrom = Date().addingTimeInterval(8)
                while !answered.withLock({ $0 }), Date() < pumpFrom { usleep(10_000) }
                let pumped = !answered.withLock { $0 }
                repo.release(until: { answered.withLock { $0 } })
                continuation.resume(returning: pumped)
            }
            thread.name = "blocking-lane-test-timeout"
            thread.start()
        }
        #expect(await call.value == nil)
        #expect(!neededRelease, "a hung git answered only once its repository was released")
    }
}

/** A directory git treats as a repository candidate whose `HEAD` is a FIFO:
    every git that validates it blocks in `open(2)` until `release` opens the
    write end. */
private struct HungRepository: Sendable {
    let path: String

    init() throws {
        let root = try TemporaryTree.directory(named: "hung-repo")
        let gitDir = root.appending(path: ".git")
        try FileManager.default.createDirectory(
            at: gitDir.appending(path: "objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: gitDir.appending(path: "refs"), withIntermediateDirectories: true)
        try #require(mkfifo(gitDir.appending(path: "HEAD").path, 0o644) == 0)
        path = root.path
    }

    /** Opens and closes the FIFO's write end until `done` holds, so every git
        blocked in `open` sees end of file and exits. A write-only open without
        a reader fails with ENXIO, which only means no git is waiting yet. */
    func release(until done: () -> Bool) {
        let fifo = path + "/.git/HEAD"
        let deadline = Date().addingTimeInterval(20)
        while !done(), Date() < deadline {
            let fd = open(fifo, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
            usleep(2_000)
        }
    }
}
