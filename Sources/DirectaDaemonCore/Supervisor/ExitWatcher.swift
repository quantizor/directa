import Darwin
import DirectaKit
import Foundation
import os

/** Outcome of arming the shared exit watch for one pid. `statusKnown` is false
    only for the `NOTE_EXIT`-only fallback (`ExitWatcher.arm`'s EACCES path),
    where the eventual `wait(pid:)` result is `.exitedStatusUnknown`. */
enum ExitArm {
    case armed(statusKnown: Bool)
    case failed(SpawnError)
}

/** One process-wide `EVFILT_PROC` exit watcher: a single kqueue serviced by
    exactly one dedicated thread, so watching every launchd-run dev server
    costs one thread and one kqueue fd total, never one per server. A blocking
    `kevent` wait per pid would park a thread (and hold an fd) for each
    server's whole life, against Swift's cooperative pool sized to the core
    count and the daemon's launchd jetsam thread limit of 32.
    `ExitWatcherTests.watchingMoreProcessesThanCoresNeverOpensASecondKqueue`
    pins the single shared kqueue.

    `arm(pid:)` is synchronous: it records this watcher's own bookkeeping slot
    for the pid before the kernel registration call, so an exit that fires the
    instant registration succeeds always finds somewhere to land (a slot
    created after the kernel call could receive a delivery for a slot that does
    not exist yet, and that delivery would be lost). `wait(pid:)` is async and
    may be called long after `arm`; it resumes immediately if the exit already
    arrived, or stores a continuation for the dedicated thread to resume later.
    Every successful `arm(pid:)` in this codebase is followed by exactly one
    `wait(pid:)` call (inside `LaunchdJobLauncher.run`, and on the adopt path
    `LaunchdJobLauncher.prepareAdopt` arms while `.adopt` waits), so a slot is
    always eventually consumed; nothing here reaps an unconsumed slot. */
final class ExitWatcher: Sendable {
    static let shared = ExitWatcher()

    /** One pid's bookkeeping: a continuation waiting for the exit outcome, or
        the outcome itself if it arrived before anything was waiting for it.
        Exactly one of the two is ever set at a time. */
    private struct Slot {
        var continuation: CheckedContinuation<ProcessOutcome, Never>?
        var outcome: ProcessOutcome?
    }

    private struct State {
        var kq: Int32?
        var slots: [pid_t: Slot] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    /** The shared kqueue's file descriptor, once the first `arm(pid:)` call
        has created it; nil before that. A stable fd number across every later
        `arm(pid:)` call is the observable form of "one shared kqueue, never
        one per pid": `ExitWatcherTests` arms a warm-up pid to force creation,
        then confirms arming many more pids never changes this value. */
    var sharedQueueDescriptorForTesting: Int32? {
        state.withLock { $0.kq }
    }

    /** Pids armed and not yet consumed by `wait(pid:)`, for telemetry. */
    var watchedCount: Int {
        state.withLock { $0.slots.count }
    }

    /** Registers interest in `pid`'s exit. Requests `NOTE_EXIT |
        NOTE_EXITSTATUS` first; the kqueue man page calls `NOTE_EXITSTATUS`
        "valid only on child processes", but the gate actually measured is
        Darwin's signal-permission check (whatever this process may `kill()`,
        same user or root), independent of parentage: a launchd job run as the
        same user arms fine despite never being this process's child, while a
        process owned by another user (pid 1, another user's `sudo`'d server)
        fails with EACCES. On EACCES, re-arms with `NOTE_EXIT` alone so the pid
        is still watched, logs once, and the eventual exit decodes as
        `.exitedStatusUnknown` (`ExitWatcher.decode` reads the granted note
        straight off the fired event's `fflags`, so no separate bookkeeping is
        needed to remember which mode a pid armed under). */
    func arm(pid: pid_t) -> ExitArm {
        state.withLock { $0.slots[pid] = Slot() }
        let kq: Int32
        switch ensureQueue() {
        case .success(let queue):
            kq = queue
        case .failure(let failure):
            state.withLock { $0.slots[pid] = nil }
            return .failed(SpawnError(errno: Int(failure.errno), message: "kqueue failed for pid \(pid)"))
        }
        if let err = Self.register(kq: kq, pid: pid, fflags: NOTE_EXIT | UInt32(NOTE_EXITSTATUS)) {
            guard err == EACCES else {
                state.withLock { $0.slots[pid] = nil }
                return .failed(SpawnError(errno: Int(err), message: "cannot watch pid \(pid) for exit"))
            }
            if let fallbackErr = Self.register(kq: kq, pid: pid, fflags: NOTE_EXIT) {
                state.withLock { $0.slots[pid] = nil }
                return .failed(
                    SpawnError(errno: Int(fallbackErr), message: "cannot watch pid \(pid) for exit"))
            }
            DirectaLog.supervisor.error(
                "pid \(pid) exit status unavailable: NOTE_EXITSTATUS refused (EACCES), this daemon may not signal that process (different user); watching exit only, the exit status will come from launchd's record of the job, else report as status-unknown"
            )
            return .armed(statusKnown: false)
        }
        return .armed(statusKnown: true)
    }

    /** Awaits the outcome for a pid armed by a prior `arm(pid:)` call. */
    func wait(pid: pid_t) async -> ProcessOutcome {
        await withCheckedContinuation { continuation in
            let immediate: ProcessOutcome? = state.withLock { state in
                if let outcome = state.slots[pid]?.outcome {
                    state.slots.removeValue(forKey: pid)
                    return outcome
                }
                state.slots[pid, default: Slot()].continuation = continuation
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    /** Lazily creates the shared kqueue and starts its dedicated reader thread
        on first use, so a daemon that never watches a launchd job never pays
        for either. A creation failure (fd exhaustion) is not cached: the next
        `arm` call retries, since the pressure may have cleared. The failure
        carries `kqueue`'s errno, read before anything else can overwrite it. */
    private func ensureQueue() -> Result<Int32, QueueFailure> {
        let created: Result<(kq: Int32, isNew: Bool), QueueFailure> = state.withLock { state in
            if let kq = state.kq { return .success((kq, false)) }
            let kq = kqueue()
            guard kq >= 0 else { return .failure(QueueFailure(errno: errno)) }
            state.kq = kq
            return .success((kq, true))
        }
        return created.map { created in
            if created.isNew {
                let thread = Thread { [self] in runLoop(kq: created.kq) }
                thread.name = "dev.quantizor.directa.exit-watcher"
                thread.start()
            }
            return created.kq
        }
    }

    private struct QueueFailure: Error {
        let errno: Int32
    }

    /** The one dedicated thread: blocks in `kevent` for real (non-receipt)
        exit events and dispatches each to its slot. Registration calls
        (`arm`, via `register(kq:pid:fflags:)`) run on whichever thread calls
        `arm`, concurrently with this loop; `EV_RECEIPT` is what keeps a
        registration call from also draining a real pending event meant for
        this loop (confirmed empirically, since the man page's "without
        draining any pending events" is the only documentation of that
        guarantee). A read that keeps failing backs off (`readRetryDelay`)
        instead of spinning, and logs once per run of the same error. */
    private func runLoop(kq: Int32) {
        var events: [kevent] = Array(repeating: kevent(), count: 32)
        var failures = 0
        var loggedError: Int32?
        while true {
            let n = kevent(kq, nil, 0, &events, Int32(events.count), nil)
            if n < 0 {
                let error = errno
                if error == EINTR { continue }
                if error != loggedError {
                    DirectaLog.supervisor.error(
                        "exit watcher cannot read its kqueue: errno \(error) (\(String(cString: strerror(error)))); exits of watched servers wait until the read recovers"
                    )
                    loggedError = error
                }
                failures += 1
                Thread.sleep(forTimeInterval: Self.readRetryDelay(afterFailures: failures) / .seconds(1))
                continue
            }
            failures = 0
            loggedError = nil
            for index in 0..<Int(n) {
                deliver(event: events[index])
            }
        }
    }

    /** The pause after `failures` consecutive failed `kevent` reads: doubling
        from 10 ms, capped at one second. */
    static func readRetryDelay(afterFailures failures: Int) -> Duration {
        let ceiling = Duration.seconds(1)
        guard failures > 0 else { return .zero }
        guard failures <= 7 else { return ceiling }
        return min(.milliseconds(10 << (failures - 1)), ceiling)
    }

    private func deliver(event: kevent) {
        let pid = pid_t(event.ident)
        let outcome = Self.decode(event: event, pid: pid)
        let toResume: CheckedContinuation<ProcessOutcome, Never>? = state.withLock { state in
            if let continuation = state.slots[pid]?.continuation {
                state.slots.removeValue(forKey: pid)
                return continuation
            }
            state.slots[pid, default: Slot()].outcome = outcome
            return nil
        }
        toResume?.resume(returning: outcome)
    }

    /** `EV_RECEIPT` always returns `EV_ERROR`; `data` is the registration
        errno on failure and zero on success (kqueue(2)). Returns the errno on
        failure, nil on success. */
    private static func register(kq: Int32, pid: pid_t, fflags: UInt32) -> Int32? {
        var change = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT | EV_RECEIPT),
            fflags: fflags, data: 0, udata: nil)
        var receipt = kevent()
        if kevent(kq, &change, 1, &receipt, 1, nil) == -1 {
            return errno
        }
        if receipt.data != 0 {
            return Int32(receipt.data)
        }
        return nil
    }

    /** Decodes a fired exit event. Whether `NOTE_EXITSTATUS` was actually
        granted is read straight off the event's own `fflags` rather than
        tracked separately, since the kernel only sets that bit on an event it
        is reporting real status for. Darwin does not export the `WIFEXITED`
        macros as Swift functions, so the wait(2) layout is decoded here. */
    private static func decode(event: kevent, pid: pid_t) -> ProcessOutcome {
        guard event.fflags & UInt32(NOTE_EXITSTATUS) != 0 else {
            return .exitedStatusUnknown
        }
        guard let status = Int32(exactly: event.data) else {
            return .spawnFailed(
                SpawnError(
                    errno: nil, message: "exit status for pid \(pid) does not fit wait(2)"))
        }
        if (status & 0o177) == 0 {
            return .exited(code: Int((status >> 8) & 0xff))
        }
        let signal = status & 0o177
        if signal != 0, signal != 0o177 {
            return .signaled(signal: Int(signal))
        }
        return .exited(code: Int((status >> 8) & 0xff))
    }
}
