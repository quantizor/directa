import DirectaKit
import Foundation

/** The one home for the monotonic timestamp clamp a time-sorted file (a log,
    events.log) keeps, and for when that clamp has run too far ahead of the
    clock to keep.

    A clamp more than `toleranceSeconds` ahead of now is treated as a record
    stamped before the clock was corrected back; `settle` has the owner rotate
    its file and restarts the clamp at now, because keeping the clamp would
    stamp every later record in the future. The rule cannot tell a file ahead
    from a clock behind (a start before network time sync), so the second case
    rotates a correct history into the `.1` file. Accepted: that history stays
    readable there, and a wrong clock that is never corrected is the worse
    outcome. */
struct TimestampClamp {
    /** A minute covers NTP steps and brief drift. */
    static let toleranceSeconds: TimeInterval = 60

    private var newest = Date.distantPast
    /** Set once the owner's rotation has failed: retrying on every append
        would shift the older rotations (losing one per attempt) and log per
        line, so the clamp stays ahead for the rest of this run instead. */
    private var rotationRefused = false

    /** The only per-append cost on the happy path. */
    func isAhead(of now: Date) -> Bool {
        !rotationRefused && newest > now.addingTimeInterval(Self.toleranceSeconds)
    }

    /** Runs `rotate` when the clamp is ahead of `now`, then restarts at `now`
        when it moved the live file aside (answering true, so the owner can
        start the fresh file) or keeps the clamp and refuses further rotations
        when it could not, since the future records stay in the file and it
        must stay sorted. */
    @discardableResult
    mutating func settle(now: Date, rotate: () -> Bool) -> Bool {
        guard isAhead(of: now) else { return false }
        guard rotate() else {
            rotationRefused = true
            return false
        }
        newest = now
        return true
    }

    /** Raises the clamp to a record time read off disk. */
    mutating func resume(at recorded: Date) {
        newest = max(newest, recorded)
    }

    /** `date`, or the newest stamp so far when that is later, to the millisecond. */
    mutating func stamp(_ date: Date) -> Date {
        let stamped = JSONCoding.canonicalMs(max(date, newest))
        newest = stamped
        return stamped
    }
}
