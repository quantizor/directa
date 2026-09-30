import Darwin
import Foundation

/** Jetsam and resource coalition ids from `proc_pidinfo`. Distinct from a
    POSIX session: `createSession` does not change these. */
public struct CoalitionIDs: Equatable, Hashable, Sendable {
    public let jetsam: UInt64
    public let resource: UInt64

    public init(jetsam: UInt64, resource: UInt64) {
        self.jetsam = jetsam
        self.resource = resource
    }

    /** Flavor 20 is xnu `PROC_PIDCOALITIONINFO`; the public `proc_info.h` skips
        it (16 then 19). Layout is two `uint64` ids (resource, jetsam) plus three
        reserved words, matching the 40-byte return on macOS 26. Nil on a short
        or failed read, never a trap: a missing flavor is the same as "we cannot
        see coalitions on this kernel." */
    public static func read(of pid: pid_t) -> CoalitionIDs? {
        guard
            let info = readProcInfo(
                pid: pid, flavor: ProcPIDCoalitionInfo.flavor, argument: 0,
                into: ProcPIDCoalitionInfo()),
            info.resource != 0 || info.jetsam != 0
        else { return nil }
        return CoalitionIDs(jetsam: info.jetsam, resource: info.resource)
    }
}

/** xnu `struct proc_pidcoalitioninfo` for flavor 20, 40 bytes. Not in the
    public SDK. Field order is the kernel's `coalition_id[COALITION_NUM_TYPES]`
    (resource then jetsam) plus reserved words, not alphabetical. `proc_pidinfo`
    itself comes from Darwin (`libproc.h`); only this layout is private. The
    reserved words stay: `proc_pidinfo` refuses a buffer smaller than the
    kernel's. */
private struct ProcPIDCoalitionInfo {
    static let flavor: Int32 = 20
    var resource: UInt64 = 0
    var jetsam: UInt64 = 0
    /* periphery:ignore - kernel layout */
    var reserved1: UInt64 = 0
    /* periphery:ignore - kernel layout */
    var reserved2: UInt64 = 0
    /* periphery:ignore - kernel layout */
    var reserved3: UInt64 = 0
}
