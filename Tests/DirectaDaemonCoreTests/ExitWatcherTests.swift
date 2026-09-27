import Darwin
import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** A `spawnBare` child with its signal mask and dispositions reset to default
    (`POSIX_SPAWN_SETSIGMASK` / `POSIX_SPAWN_SETSIGDEF` with an empty mask and
    a full default-set), the same pair `swift-subprocess` passes on every spawn
    (`Subprocess+Darwin.swift`): the `swift test` runner blocks `SIGTERM` in its
    own mask, which a bare `posix_spawn` otherwise inherits unchanged, so a
    child spawned without this reset never notices `kill(pid, SIGTERM)`. */
private func spawnWithDefaultSignals(_ argv: [String]) throws -> pid_t {
    try spawnBare(argv, flags: POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF) { attr in
        var noSignals = sigset_t()
        var allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
    }
}

/** Spawns a bare throwaway child and reaps it on a dedicated background
    thread, exactly like `TestSupport.spawnSurvivor`'s reaper (a bare
    `posix_spawn` has no one else reaping it, and an unreaped exit leaves a
    zombie for the rest of the test run). The returned semaphore signals once
    `waitpid` has actually reaped the child, letting a caller that needs the
    exit to have already happened (not just be imminent) block on a real
    kernel confirmation instead of a guessed sleep duration. Reaping races
    `ExitWatcher`'s kqueue delivery on a real spawned child by design here
    (both read the same kernel-captured exit status independently), which a
    throwaway probe confirmed is safe in either order. */
private func spawnAndReap(_ argv: [String]) throws -> (pid: pid_t, exited: DispatchSemaphore) {
    let spawned = try spawnWithDefaultSignals(argv)
    let exited = DispatchSemaphore(value: 0)
    let reaper = Thread {
        var reapedStatus: Int32 = 0
        waitpid(spawned, &reapedStatus, 0)
        exited.signal()
    }
    reaper.start()
    return (spawned, exited)
}

/** `DispatchSemaphore.wait()` is unavailable from any async context, since
    `Task.detached` still schedules onto the cooperative pool rather than
    guaranteeing a dedicated thread. A throwaway `Thread` does own a dedicated
    thread, so the blocking wait happens there and only resumes the
    continuation (never itself blocking) back on the caller's task. */
private func waitSynchronously(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        let thread = Thread {
            semaphore.wait()
            continuation.resume()
        }
        thread.start()
    }
}

/** Spawns `count` bare children, reaped by a single background thread's
    sequential `waitpid` loop (one thread total, never one per child): a
    reaper thread per child (`spawnAndReap`'s pattern, needed there so a
    caller can synchronize on one specific pid's exit) would itself scale with
    `count` and confound a signal meant to isolate `ExitWatcher`'s own cost.
    Each `waitpid` call names its own pid, never `-1`, so this can never reap a
    child another concurrently-running test's own reaper is waiting on. */
private func spawnManyWithOneReaper(_ argv: [String], count: Int) throws -> [pid_t] {
    let pids = try (0..<count).map { _ in try spawnWithDefaultSignals(argv) }
    let reaper = Thread {
        for pid in pids {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }
    reaper.start()
    return pids
}

@Suite struct ExitWatcherTests {
    /** Watching more pids than the cooperative thread pool has cores never
        opens a second kqueue: `ExitWatcher`'s shared queue keeps the same fd
        number no matter how many more pids arm after it exists. This is a
        white-box check (`sharedQueueDescriptorForTesting` reads the internal
        fd directly) rather than an OS-level resource count, because both
        candidates for a black-box signal proved unreliable inside the full
        suite's 71 concurrently-running suites: a live thread count is swamped
        by libdispatch's own ambient pool churn, and this process's total open
        fd count swings by dozens as sibling suites open and close their own
        sockets and spool files in the same window. Measured directly instead
        (a throwaway standalone probe, run outside the suite specifically to
        avoid that cross-suite noise): arming 30 pids through the old per-pid
        design (`LaunchdJobLauncher` before `ExitWatcher`, one dedicated
        kqueue armed per pid) raised that process's open fd count by exactly
        30, while `ExitWatcher` raised it by at most 1 regardless of pid count
        (0 to 96 tried). The warm-up pid forces the shared queue into
        existence first, since `ExitWatcher` is a process-wide singleton other
        tests in this suite also use and may have already created it. */
    @Test func watchingMoreProcessesThanCoresNeverOpensASecondKqueue() async throws {
        let warmup = try spawnAndReap(["/bin/sleep", "1"])
        defer { if kill(warmup.pid, 0) == 0 { kill(warmup.pid, SIGKILL) } }
        guard case .armed = ExitWatcher.shared.arm(pid: warmup.pid) else {
            Issue.record("failed to arm warm-up pid \(warmup.pid)")
            return
        }
        let before = ExitWatcher.shared.sharedQueueDescriptorForTesting
        try #require(before != nil)

        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let pids = try spawnManyWithOneReaper(["/bin/sleep", "2"], count: count)
        defer { for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        for pid in pids {
            guard case .armed = ExitWatcher.shared.arm(pid: pid) else {
                Issue.record("failed to arm pid \(pid)")
                return
            }
        }
        let waiters = pids.map { pid in Task { await ExitWatcher.shared.wait(pid: pid) } }

        #expect(ExitWatcher.shared.sharedQueueDescriptorForTesting == before)

        kill(warmup.pid, SIGKILL)
        _ = await ExitWatcher.shared.wait(pid: warmup.pid)
        for pid in pids { kill(pid, SIGKILL) }
        for waiter in waiters { _ = await waiter.value }
    }

    /** A child that exits nonzero reports its real exit code. The pause keeps
        the child alive until it is armed: a child that exits first is refused
        with ESRCH, which is a different case. */
    @Test func exitCodeIsReported() async throws {
        let child = try spawnAndReap(["/bin/sh", "-c", "sleep 0.3; exit 3"])
        guard case .armed = ExitWatcher.shared.arm(pid: child.pid) else {
            Issue.record("failed to arm pid \(child.pid)")
            return
        }
        let outcome = await ExitWatcher.shared.wait(pid: child.pid)
        switch outcome {
        case .exited(let code):
            #expect(code == 3)
        case .exitedStatusUnknown, .signaled, .spawnFailed:
            Issue.record("expected .exited(code: 3), got \(outcome)")
        }
    }

    /** A child killed by `SIGTERM` reports that signal, not an exit code. */
    @Test func signalIsReported() async throws {
        let child = try spawnAndReap(["/bin/sleep", "5"])
        guard case .armed = ExitWatcher.shared.arm(pid: child.pid) else {
            Issue.record("failed to arm pid \(child.pid)")
            return
        }
        kill(child.pid, SIGTERM)
        let outcome = await ExitWatcher.shared.wait(pid: child.pid)
        switch outcome {
        case .signaled(let signal):
            #expect(signal == Int(SIGTERM))
        case .exited, .exitedStatusUnknown, .spawnFailed:
            Issue.record("expected .signaled(signal: \(SIGTERM)), got \(outcome)")
        }
    }

    /** A pid that exits before anything calls `wait(pid:)` still yields its
        status: the exit is not lost between arming and the eventual await.
        `exited.wait()` blocks on the reaper thread's real `waitpid` return, so
        the process is confirmed dead (not merely presumed dead after a guessed
        delay) before `wait(pid:)` runs. The pause only keeps the child alive
        until it is armed. */
    @Test func exitBeforeTheAwaitIsNotLost() async throws {
        let child = try spawnAndReap(["/bin/sh", "-c", "sleep 0.3; exit 7"])
        guard case .armed = ExitWatcher.shared.arm(pid: child.pid) else {
            Issue.record("failed to arm pid \(child.pid)")
            return
        }
        await waitSynchronously(child.exited)
        let outcome = await ExitWatcher.shared.wait(pid: child.pid)
        switch outcome {
        case .exited(let code):
            #expect(code == 7)
        case .exitedStatusUnknown, .signaled, .spawnFailed:
            Issue.record("expected .exited(code: 7), got \(outcome)")
        }
    }

    /** A `kevent` read that keeps failing must not spin the watcher thread:
        each consecutive failure waits longer than the last, from a short first
        pause up to a ceiling, so a persistent error costs a few wakeups a
        second rather than a whole core. */
    @Test func aFailingReadBacksOffToACeiling() {
        let delays = (1...10).map { ExitWatcher.readRetryDelay(afterFailures: $0) }
        #expect(delays == [
            .milliseconds(10), .milliseconds(20), .milliseconds(40), .milliseconds(80),
            .milliseconds(160), .milliseconds(320), .milliseconds(640), .seconds(1), .seconds(1),
            .seconds(1),
        ])
        #expect(ExitWatcher.readRetryDelay(afterFailures: Int.max) == .seconds(1))
    }

    /** `NOTE_EXITSTATUS` is refused (EACCES) for a process this daemon may not
        signal; pid 1 (launchd, root-owned) is always available and never
        exits, so arming it exercises the fallback without waiting on a real
        exit. The arm result itself, not a log side channel, is the assertion:
        `DirectaLog.backend` is a process-global the daemon's log tests already
        swap under `.serialized`, and a second suite touching it here would
        race them. */
    @Test func permissionDeniedFallsBackToExitOnly() {
        switch ExitWatcher.shared.arm(pid: 1) {
        case .armed(let statusKnown):
            #expect(statusKnown == false)
        case .failed(let error):
            Issue.record("expected .armed(statusKnown: false), got .failed(\(error.message))")
        }
    }
}
