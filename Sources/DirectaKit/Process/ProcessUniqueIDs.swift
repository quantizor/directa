import Darwin
import Foundation

/** A process's kernel unique id and its parent's, from `proc_pidinfo`. Unlike
    a pid, a unique id is 64-bit and never reused within a boot, and `parent`
    keeps naming the process that forked this one after that parent exits and
    the kernel reparents this one to launchd (its ppid becomes 1, `parent`
    does not change). */
public struct ProcessUniqueIDs: Equatable, Hashable, Sendable {
    public let parent: UInt64
    public let process: UInt64

    public init(parent: UInt64, process: UInt64) {
        self.parent = parent
        self.process = process
    }

    /** Flavor 17 is xnu `PROC_PIDUNIQIDENTIFIERINFO`, declared only in the
        private `proc_info_private.h`; the public `proc_info.h` skips it. The
        argument 1 asks the kernel to answer for a zombie too, so the ids of a
        root that has exited but is not yet reaped still read, the same as
        `kinfo_proc` answers for it. Nil on a short or failed read (the pid is
        gone), never a trap. */
    public static func read(of pid: pid_t) -> ProcessUniqueIDs? {
        guard
            let info = readProcInfo(
                pid: pid, flavor: ProcUniqIdentifierInfo.flavor, argument: 1,
                into: ProcUniqIdentifierInfo()),
            info.uniqueID != 0
        else { return nil }
        return ProcessUniqueIDs(parent: info.parentUniqueID, process: info.uniqueID)
    }
}

/** xnu `struct proc_uniqidentifierinfo` for flavor 17, 56 bytes. Not in the
    public SDK. Field order is the kernel's (executable UUID, unique id, parent
    unique id, pid version, reserved words), not alphabetical, because this
    struct is the kernel's byte layout. `proc_pidinfo` itself comes from Darwin
    (`libproc.h`); only this layout is private. The fields never read stay:
    `proc_pidinfo` refuses a buffer smaller than the kernel's, and they fix the
    offsets of the ids that are read. */
private struct ProcUniqIdentifierInfo {
    static let flavor: Int32 = 17
    /* periphery:ignore - kernel layout */
    var executableUUID: (UInt64, UInt64) = (0, 0)
    var uniqueID: UInt64 = 0
    var parentUniqueID: UInt64 = 0
    /* periphery:ignore - kernel layout */
    var pidVersion: Int32 = 0
    /* periphery:ignore - kernel layout */
    var reserved2: UInt32 = 0
    /* periphery:ignore - kernel layout */
    var reserved3: UInt64 = 0
    /* periphery:ignore - kernel layout */
    var reserved4: UInt64 = 0
}
