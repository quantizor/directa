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

    /** Every shared lane, in the order telemetry reports them. */
    public static let all = [repository, system]

    private struct Pending {
        let enqueuedAt: ContinuousClock.Instant
        let job: @Sendable () -> Void
    }

    private struct State {
        var draining = 0
        var pending: [Pending] = []
        var running = 0
    }

    private let activity: DaemonActivity
    /** The label's last component (`repository`, `system`), as telemetry
        names the lane. */
    public let name: String
    private let queue: DispatchQueue
    /** A job that waited longer than this for a thread is reported to
        `activity`, which telemetry turns into a mark. */
    private let slowWaitSeconds: Double
    private let state = OSAllocatedUnfairLock(initialState: State())
    public let width: Int

    public init(
        label: String, width: Int, activity: DaemonActivity = .shared,
        slowWaitSeconds: Double = TelemetryCadence.slowOperationSeconds
    ) {
        self.activity = activity
        self.name = label.split(separator: ".").last.map(String.init) ?? label
        self.queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
        self.slowWaitSeconds = slowWaitSeconds
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

    /** How busy the lane is right now, read under the lane's own lock so it
        answers from any thread without waiting on the lane's work. */
    public func pressure(now: ContinuousClock.Instant = .now) -> LanePressure {
        let (running, queued, oldest) = state.withLock { state in
            (state.running, state.pending.count, state.pending.first?.enqueuedAt)
        }
        return LanePressure(
            name: name, oldestQueuedSeconds: oldest.map { DaemonActivity.seconds($0.duration(to: now)) } ?? 0,
            queued: queued, running: running, width: width)
    }

    private func submit(_ job: @escaping @Sendable () -> Void) {
        let entry = Pending(enqueuedAt: .now, job: job)
        let startsDrainer = state.withLock { state in
            state.pending.append(entry)
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
        var finishedOne = false
        while let entry = nextJob(finishedOne: finishedOne) {
            let waited = DaemonActivity.seconds(entry.enqueuedAt.duration(to: .now))
            if waited > slowWaitSeconds {
                activity.recordLaneWait(lane: name, seconds: waited)
            }
            entry.job()
            finishedOne = true
        }
    }

    private func nextJob(finishedOne: Bool) -> Pending? {
        state.withLock { state in
            if finishedOne { state.running -= 1 }
            guard !state.pending.isEmpty else {
                state.draining -= 1
                return nil
            }
            state.running += 1
            return state.pending.removeFirst()
        }
    }
}
