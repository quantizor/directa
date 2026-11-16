import Foundation

/** Whether an unreachable daemon should be resurrected without being asked.

    Policy, not UI: the menu bar app retries a failed status read every couple of
    seconds, so this has to distinguish "died and should come back" from "the
    user stopped it" and from "we just tried and it failed". Recovery shells out
    to launchctl, which is why a failed attempt earns a cooldown instead of
    retrying every read. */
public enum DaemonRecoveryPolicy {
    public enum Decision: Equatable, Sendable {
        /** Socket answered: nothing to do. */
        case healthy
        /** Bring it back now. */
        case recover
        /** An attempt is already in flight. */
        case inFlight
        /** Tried too recently; wait out the cooldown. */
        case cooling
        /** `directa daemon stop` was deliberate; wait for an explicit Start. */
        case awaitUser
    }

    public static let cooldown: TimeInterval = 15

    public static func decide(
        reachable: Bool,
        stoppedOnPurpose: Bool,
        recovering: Bool,
        lastAttempt: Date?,
        now: Date = Date(),
        cooldown: TimeInterval = cooldown
    ) -> Decision {
        if reachable { return .healthy }
        /** Intent outranks liveness: resurrecting a deliberately stopped daemon
            would silently undo what the user asked for. */
        if stoppedOnPurpose { return .awaitUser }
        if recovering { return .inFlight }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < cooldown { return .cooling }
        return .recover
    }
}
