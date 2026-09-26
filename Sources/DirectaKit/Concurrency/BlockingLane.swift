import Dispatch
import os

/** Runs work that blocks its thread (a subprocess wait, a socket poll) off
    Swift's cooperative pool, on at most `width` threads at once. The pool has
    one thread per core, so a handful of callers stuck in a slow `git` or
    `launchctl` would otherwise stall every actor in the process; and the
    daemon LaunchAgent's jetsam thread limit rules out one thread per blocked
    caller. Work past `width` waits in FIFO order for a free thread rather
    than adding one. Threads come from a private Dispatch queue and return to
    Dispatch while the lane is idle, so a quiet lane holds none.

    Two lanes, so the one whose commands read a user's repository (and can hang
    on its filesystem) never queues ahead of the launchd and port calls that
    spawn and supervise servers. */
public final class BlockingLane: Sendable {
    /** `git` against a project checkout. */
    public static let repository = BlockingLane(label: "dev.quantizor.directa.lane.repository", width: 2)
    /** `launchctl`, `lsof`, `ps`, and loopback connect probes. */
    public static let system = BlockingLane(label: "dev.quantizor.directa.lane.system", width: 4)

    private struct State {
        var draining = 0
        var pending: [@Sendable () -> Void] = []
    }

    private let queue: DispatchQueue
    private let state = OSAllocatedUnfairLock(initialState: State())
    public let width: Int

    public init(label: String, width: Int) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
        self.width = max(1, width)
    }

    /** Runs `work` on one of this lane's threads and resumes the caller with
        its result. The caller's task is suspended, not blocked, while it
        waits. Cancellation does not interrupt `work`. */
    public func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            submit { continuation.resume(returning: work()) }
        }
    }

    private func submit(_ job: @escaping @Sendable () -> Void) {
        let startsDrainer = state.withLock { state in
            state.pending.append(job)
            guard state.draining < width else { return false }
            state.draining += 1
            return true
        }
        if startsDrainer {
            queue.async { self.drain() }
        }
    }

    /** One of at most `width` loops: takes jobs until none are pending, then
        gives its thread back. The count drops under the same lock that finds
        the queue empty, so a job submitted concurrently either lands before
        that check or starts a new drainer. */
    private func drain() {
        while let job = nextJob() {
            job()
        }
    }

    private func nextJob() -> (@Sendable () -> Void)? {
        state.withLock { state in
            guard !state.pending.isEmpty else {
                state.draining -= 1
                return nil
            }
            return state.pending.removeFirst()
        }
    }
}
