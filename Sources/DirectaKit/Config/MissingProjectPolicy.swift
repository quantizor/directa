import Foundation

/** Whether a registered project whose checkout path failed a stat should be
    forgotten yet. Pure and clock-driven, mirroring `WatchPolicy`, so the
    two-consecutive-miss debounce is exercised without sleeping on a real
    timer. One rule serves every automatic trigger (boot restore, machine-wide
    status, the timer sweep): a project is forgotten only once its path has
    been observed missing continuously for at least the sweep interval, never
    on the first miss, so a network mount blip or a slow unmount does not cost
    a project its trust and log history. */
public enum MissingProjectPolicy {
    public enum Decision: Equatable, Sendable {
        /** The path exists; any earlier miss should be cleared. */
        case present
        /** The path is missing but `sweepIntervalSeconds` has not elapsed since
            `since`; not yet forgotten. */
        case waiting(since: Date)
        /** The path has been missing continuously for at least the sweep
            interval; safe to forget. */
        case forget
    }

    public static func decide(
        exists: Bool, firstMissedAt: Date?, now: Date, sweepIntervalSeconds: Double
    ) -> Decision {
        guard !exists else { return .present }
        let since = firstMissedAt ?? now
        guard now.timeIntervalSince(since) >= sweepIntervalSeconds else { return .waiting(since: since) }
        return .forget
    }
}
