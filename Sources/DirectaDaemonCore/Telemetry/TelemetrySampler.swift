import DirectaKit
import Foundation
import os

/** Samples the daemon's threads, memory, descriptors, and in-flight work into
    telemetry.log on one dedicated thread. It never runs on the cooperative
    pool and never awaits an actor, because the condition it exists to record
    is a pool that has stopped making progress. */
public final class TelemetrySampler: Sendable {
    public struct Configuration: Sendable {
        public var activity: DaemonActivity
        public var exitWatches: @Sendable () -> Int
        public var lanes: [BlockingLane]
        public var log: TelemetryLog
        public var policy: TelemetryCadence.Policy
        /** The launchd thread limit, once known; read on every sample. */
        public var threadLimit: @Sendable () -> Int?

        public init(
            activity: DaemonActivity, exitWatches: @escaping @Sendable () -> Int, lanes: [BlockingLane],
            log: TelemetryLog, policy: TelemetryCadence.Policy, threadLimit: @escaping @Sendable () -> Int?
        ) {
            self.activity = activity
            self.exitWatches = exitWatches
            self.lanes = lanes
            self.log = log
            self.policy = policy
            self.threadLimit = threadLimit
        }
    }

    public static let threadName = "dev.quantizor.directa.telemetry"

    private enum Lifecycle {
        case idle
        case running
        case stopped
    }

    private let configuration: Configuration
    private let finished = DispatchSemaphore(value: 0)
    private let lifecycle = OSAllocatedUnfairLock(initialState: Lifecycle.idle)
    private let processStart: Date
    private let wake = DispatchSemaphore(value: 0)

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.processStart = ProcessTree.identity(of: getpid())?.wallClockStart ?? Date()
    }

    public func start() {
        let starting = lifecycle.withLock { state -> Bool in
            guard state == .idle else { return false }
            state = .running
            return true
        }
        guard starting else { return }
        let thread = Thread { [self] in
            run()
            finished.signal()
        }
        thread.name = Self.threadName
        /** A sample costs a fraction of a millisecond, and a loaded machine
            is exactly when its timing matters, so it is not left to compete
            at a low QoS. */
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /** Takes a sample now instead of at the next tick; called when burst
        work begins so the first seconds of a stop are on record. */
    public func wakeNow() {
        wake.signal()
    }

    /** Stops the loop and waits for the thread to leave it, so nothing is
        written after this returns. A second call, or one before `start`,
        returns at once. */
    public func stop() {
        let wasRunning = lifecycle.withLock { state -> Bool in
            defer { state = .stopped }
            return state == .running
        }
        guard wasRunning else { return }
        wake.signal()
        finished.wait()
    }

    private func run() {
        let sampler = ProcessSampler()
        var loop = LoopState()
        while lifecycle.withLock({ $0 == .running }) {
            /** A plain thread has no run loop draining autoreleased Foundation
                objects, so each sample gets its own pool; without it the heap
                grows across samples. */
            let nextSeconds = autoreleasepool { sampleOnce(sampler: sampler, loop: &loop) }
            if wake.wait(timeout: .now() + nextSeconds) == .success {
                /** Several begins in a row signal several times; one sample
                    answers all of them. */
                while wake.wait(timeout: .now()) == .success {}
            }
        }
    }

    private struct LoopState {
        /** When this loop last saw threads at the burst fraction or a lane
            with queued work: triggers only the sampler can observe. */
        var lastSampledTriggerAt: ContinuousClock.Instant?
        var lastThresholdAt: ContinuousClock.Instant?
        let pid = getpid()
        var previousAboveThreshold = false
    }

    /** Takes and writes one snapshot; returns the seconds until the next. */
    private func sampleOnce(sampler: ProcessSampler, loop: inout LoopState) -> Double {
        let began = ContinuousClock.now
        let limit = configuration.threadLimit()
        let threads = sampler.threads(limit: limit)
        let lanes = configuration.lanes.map { $0.pressure(now: began) }
        /** A queued lane job is not yet in the activity registry (its
            blocking call has not begun), so a backlog is its own trigger. */
        let laneBacklog = lanes.contains { $0.queued > 0 }
        if laneBacklog { loop.lastSampledTriggerAt = began }
        let trigger = configuration.activity.triggerState()
        let lastTrigger = [trigger.lastAt, loop.lastSampledTriggerAt].compactMap { $0 }.max()
        let decision = TelemetryCadence.decide(
            TelemetryCadence.Input(
                previousAboveThreshold: loop.previousAboveThreshold,
                secondsSinceTrigger: lastTrigger.map { $0.duration(to: began).roundedSeconds },
                secondsSinceThresholdSnapshot: loop.lastThresholdAt.map { $0.duration(to: began).roundedSeconds },
                threadCount: threads?.sample.total, threadLimit: limit,
                triggerInFlight: trigger.inFlight || laneBacklog),
            policy: configuration.policy)
        if decision.threadsTrigger { loop.lastSampledTriggerAt = began }
        if decision.reason == .threshold {
            loop.lastThresholdAt = began
        }
        let activity = configuration.activity.snapshot(now: began)
        let exitWatches = configuration.exitWatches()
        let fileDescriptors = sampler.fileDescriptors()
        let memory = sampler.memory()
        let system = sampler.system()
        let cost = began.duration(to: .now)
        let now = Date()
        let snapshot = TelemetrySnapshot(
            activity: activity, daemonPid: loop.pid, exitWatches: exitWatches, fileDescriptors: fileDescriptors,
            lanes: lanes, memory: memory, reason: decision.reason, sampleMicroseconds: cost.wholeMicroseconds,
            system: system, threadDetail: decision.reason == .threshold ? threads?.detail : nil,
            threads: threads?.sample, time: now,
            uptimeSeconds: Duration.seconds(now.timeIntervalSince(processStart)).roundedSeconds)
        configuration.log.append(snapshot)
        if decision.reason == .threshold, let total = threads?.sample.total {
            recordThreshold(total: total, limit: limit, activity: activity, pid: loop.pid)
        }
        loop.previousAboveThreshold = decision.aboveThreshold
        return decision.nextSampleSeconds
    }

    /** The one persisted OSLog line per threshold crossing (error level is
        what macOS keeps), naming the count and what has waited longest. */
    private func recordThreshold(total: Int, limit: Int?, activity: ActivitySnapshot, pid: Int32) {
        let top = activity.longestRunning.prefix(3)
            .map { "\($0.kind.rawValue) \($0.label) \($0.seconds)s" }
            .joined(separator: "; ")
        let limitText = limit.map(String.init) ?? "unknown (assumed \(TelemetryCadence.assumedThreadLimit))"
        let summary = "\(total) threads, limit \(limitText); longest in flight: \(top.isEmpty ? "none" : top)"
        DirectaLog.daemon.error("telemetry: \(summary)")
        configuration.log.append(
            TelemetryMark(daemonPid: pid, event: .threadsHigh, label: summary, time: Date()))
    }
}
