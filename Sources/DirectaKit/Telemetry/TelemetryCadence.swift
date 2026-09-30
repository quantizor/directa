import Foundation

/** When the telemetry sampler takes its next snapshot and whether this one
    carries per-thread detail. A pure function of what the sampler observed,
    so every branch is testable without a clock. */
public enum TelemetryCadence {
    /** Used for the thread fractions when launchd reports no limit (the
        daemon is not running as the agent): the limit the agent gets. */
    public static let assumedThreadLimit = 32

    public struct Policy: Equatable, Sendable {
        public var baselineSeconds: Double
        public var burstSeconds: Double
        /** At or above this fraction of the thread limit, sampling is fast. */
        public var burstThreadFraction: Double
        /** How long the fast cadence outlasts the last trigger. */
        public var burstTailSeconds: Double
        /** The least time between two threshold snapshots, so writing detail
            while threads are high cannot become its own feedback loop. */
        public var thresholdCooldownSeconds: Double
        /** Crossing this fraction of the thread limit takes a threshold
            snapshot. */
        public var thresholdThreadFraction: Double

        public init(
            baselineSeconds: Double, burstSeconds: Double, burstThreadFraction: Double,
            burstTailSeconds: Double, thresholdCooldownSeconds: Double, thresholdThreadFraction: Double
        ) {
            self.baselineSeconds = baselineSeconds
            self.burstSeconds = burstSeconds
            self.burstThreadFraction = burstThreadFraction
            self.burstTailSeconds = burstTailSeconds
            self.thresholdCooldownSeconds = thresholdCooldownSeconds
            self.thresholdThreadFraction = thresholdThreadFraction
        }

        public static let standard = Policy(
            baselineSeconds: 10, burstSeconds: 1, burstThreadFraction: 0.5, burstTailSeconds: 60,
            thresholdCooldownSeconds: 60, thresholdThreadFraction: 0.75)

        public func burstThreads(limit: Int) -> Int {
            Int((Double(limit) * burstThreadFraction).rounded(.up))
        }

        public func thresholdThreads(limit: Int) -> Int {
            Int((Double(limit) * thresholdThreadFraction).rounded(.up))
        }
    }

    public struct Input: Equatable, Sendable {
        /** True when the previous sample was already at or above the
            threshold, so only a rising edge takes a threshold snapshot. */
        public var previousAboveThreshold: Bool
        /** Seconds since burst-triggering work last began or ended, or since
            threads were last at the burst fraction; nil for never. */
        public var secondsSinceTrigger: Double?
        public var secondsSinceThresholdSnapshot: Double?
        public var threadCount: Int?
        public var threadLimit: Int?
        public var triggerInFlight: Bool

        public init(
            previousAboveThreshold: Bool, secondsSinceTrigger: Double?, secondsSinceThresholdSnapshot: Double?,
            threadCount: Int?, threadLimit: Int?, triggerInFlight: Bool
        ) {
            self.previousAboveThreshold = previousAboveThreshold
            self.secondsSinceTrigger = secondsSinceTrigger
            self.secondsSinceThresholdSnapshot = secondsSinceThresholdSnapshot
            self.threadCount = threadCount
            self.threadLimit = threadLimit
            self.triggerInFlight = triggerInFlight
        }
    }

    public struct Decision: Equatable, Sendable {
        public var aboveThreshold: Bool
        public var nextSampleSeconds: Double
        /** This sample's reason: `threshold` on a rising edge outside the
            cooldown, else `burst` or `interval` by the cadence in force. */
        public var reason: SampleReason
        /** Threads are at the burst fraction now; the caller records this as
            a trigger for the tail. */
        public var threadsTrigger: Bool

        public init(aboveThreshold: Bool, nextSampleSeconds: Double, reason: SampleReason, threadsTrigger: Bool) {
            self.aboveThreshold = aboveThreshold
            self.nextSampleSeconds = nextSampleSeconds
            self.reason = reason
            self.threadsTrigger = threadsTrigger
        }
    }

    public static func decide(_ input: Input, policy: Policy = .standard) -> Decision {
        let limit = input.threadLimit ?? assumedThreadLimit
        let threads = input.threadCount ?? 0
        let threadsTrigger = input.threadCount != nil && threads >= policy.burstThreads(limit: limit)
        let aboveThreshold = input.threadCount != nil && threads >= policy.thresholdThreads(limit: limit)
        let inTail = input.secondsSinceTrigger.map { $0 < policy.burstTailSeconds } ?? false
        let burst = input.triggerInFlight || threadsTrigger || inTail
        let cooledDown = input.secondsSinceThresholdSnapshot.map { $0 >= policy.thresholdCooldownSeconds } ?? true
        let reason: SampleReason =
            aboveThreshold && !input.previousAboveThreshold && cooledDown
            ? .threshold : (burst ? .burst : .interval)
        return Decision(
            aboveThreshold: aboveThreshold,
            nextSampleSeconds: burst ? policy.burstSeconds : policy.baselineSeconds,
            reason: reason, threadsTrigger: threadsTrigger)
    }
}
