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
        public var log: TelemetryLog
        public var policy: TelemetryCadence.Policy
        /** The launchd thread limit, once known; read on every sample. */
        public var threadLimit: @Sendable () -> Int?

        public init(
            activity: DaemonActivity, exitWatches: @escaping @Sendable () -> Int, log: TelemetryLog,
            policy: TelemetryCadence.Policy, threadLimit: @escaping @Sendable () -> Int?
        ) {
            self.activity = activity
            self.exitWatches = exitWatches
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
        let identity = ProcessTree.identity(of: getpid())
        self.processStart =
            identity.map {
                Date(timeIntervalSince1970: Double($0.startSeconds) + Double($0.startMicroseconds) / 1e6)
            } ?? Date()
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
        var lastThreadsTriggerAt: ContinuousClock.Instant?
        var lastThresholdAt: ContinuousClock.Instant?
        let pid = getpid()
        var previousAboveThreshold = false
    }

    /** Takes and writes one snapshot; returns the seconds until the next. */
    private func sampleOnce(sampler: ProcessSampler, loop: inout LoopState) -> Double {
        let began = ContinuousClock.now
        let limit = configuration.threadLimit()
        var threads = sampler.threads(limit: limit, withDetail: false)
        let trigger = configuration.activity.triggerState()
        let lastTrigger = [trigger.lastAt, loop.lastThreadsTriggerAt].compactMap { $0 }.max()
        let decision = TelemetryCadence.decide(
            TelemetryCadence.Input(
                previousAboveThreshold: loop.previousAboveThreshold,
                secondsSinceTrigger: lastTrigger.map { DaemonActivity.seconds($0.duration(to: began)) },
                secondsSinceThresholdSnapshot: loop.lastThresholdAt.map {
                    DaemonActivity.seconds($0.duration(to: began))
                },
                threadCount: threads?.sample.total, threadLimit: limit,
                triggerInFlight: trigger.inFlight),
            policy: configuration.policy)
        if decision.threadsTrigger { loop.lastThreadsTriggerAt = began }
        if decision.reason == .threshold {
            loop.lastThresholdAt = began
            threads = sampler.threads(limit: limit, withDetail: true) ?? threads
        }
        let activity = configuration.activity.snapshot(now: began)
        let snapshot = TelemetrySnapshot(
            activity: activity, daemonPid: loop.pid, exitWatches: configuration.exitWatches(),
            fileDescriptors: sampler.fileDescriptors(), memory: sampler.memory(), reason: decision.reason,
            sampleMicroseconds: Self.microseconds(began.duration(to: .now)),
            system: sampler.system(),
            threadDetail: decision.reason == .threshold ? threads?.detail : nil,
            threads: threads?.sample, time: Date(),
            uptimeSeconds: (Date().timeIntervalSince(processStart) * 1000).rounded() / 1000)
        configuration.log.append(snapshot)
        if decision.reason == .threshold, let total = threads?.sample.total {
            recordThreshold(total: total, limit: limit, activity: activity, pid: loop.pid)
        }
        loop.previousAboveThreshold = decision.aboveThreshold
        return decision.nextSampleSeconds
    }

    static func microseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1_000_000 + Int(attoseconds / 1_000_000_000_000)
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
