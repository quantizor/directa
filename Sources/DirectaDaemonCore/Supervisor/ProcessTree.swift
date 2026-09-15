import Darwin
import Foundation

/** A process identity that survives PID reuse: pid alone is not enough across a
    grace window, because macOS can recycle the number. Start time comes from
    `kinfo_proc.kp_proc.p_starttime`. */
public struct ProcessIdentity: Hashable, Sendable, Equatable {
    public let pid: pid_t
    public let startMicroseconds: suseconds_t
    public let startSeconds: time_t

    public init(pid: pid_t, startSeconds: time_t, startMicroseconds: suseconds_t) {
        self.pid = pid
        self.startMicroseconds = startMicroseconds
        self.startSeconds = startSeconds
    }

    init(_ info: kinfo_proc) {
        self.pid = info.kp_proc.p_pid
        self.startMicroseconds = info.kp_proc.p_starttime.tv_usec
        self.startSeconds = info.kp_proc.p_starttime.tv_sec
    }

    /** The kernel start time as a wall-clock `Date`, for comparison against a
        wall-clock timestamp like `PersistedServerState.startedAt`. */
    public var wallClockStart: Date {
        Date(timeIntervalSince1970: TimeInterval(startSeconds) + TimeInterval(startMicroseconds) / 1_000_000)
    }
}

/** Result of a descendant sweep. Failure must not look like "no children": a
    silent empty list drops the escaped-descendant half of teardown. */
public enum DescendantsResult: Sendable, Equatable {
    case failed(errno: Int32)
    case ok([ProcessIdentity])

    public var identities: [ProcessIdentity] {
        switch self {
        case .failed: []
        case .ok(let ids): ids
        }
    }

    public var pids: [pid_t] { identities.map(\.pid) }
}

/** Descendant enumeration via sysctl KERN_PROC_ALL. Group-directed signals miss
    processes that changed their own group (Foundation Process children setpgid;
    daemonizers setsid), so teardown signals the group AND every live descendant
    found by walking the parent-pid chain. The snapshot must be taken before the
    parent dies: orphans reparent to launchd and fall out of the chain. */
public enum ProcessTree {
    /** All live descendants of `pid` (children, grandchildren, ...), excluding
        `pid` itself. Best-effort: a process spawned after the snapshot is missed. */
    public static func descendants(of pid: pid_t) -> DescendantsResult {
        switch fetchProcessTable() {
        case .failed(let errno):
            return .failed(errno: errno)
        case .ok(let table):
            var childrenByParent: [pid_t: [ProcessIdentity]] = [:]
            for identity in table {
                childrenByParent[identity.parent, default: []].append(identity.process)
            }
            var found: [ProcessIdentity] = []
            var queue: [pid_t] = [pid]
            while let parent = queue.popLast() {
                for child in childrenByParent[parent] ?? [] where child.pid != parent {
                    found.append(child)
                    queue.append(child.pid)
                }
            }
            return .ok(found)
        }
    }

    /** Live processes belonging to `session`, excluding the session leader and
        this process's own session.

        This is the one handle on an escaped descendant that does not depend on
        when a snapshot was taken. A child that setpgid's out of the group (every
        Foundation `Process` child does) still inherits the session, and unlike
        the parent-pid chain, session membership survives the root exiting and
        the orphan reparenting to launchd. So a descendant missed by the snapshot
        because it appeared moments before the crash is still reachable here.

        The safety guard is the whole design. `sessionLeaderPid` must equal
        `session`, which is true exactly when the spawn used createSession and
        the root really is its own session leader. Without that check, a root
        sharing the daemon's session would turn this into a sweep of the daemon
        and everything the daemon owns, so the caller's session is refused
        outright rather than trusted to differ. */
    public static func sessionMembers(of session: pid_t, sessionLeaderPid: pid_t)
        -> DescendantsResult
    {
        guard session == sessionLeaderPid, session != getsid(getpid()), session > 0 else {
            return .ok([])
        }
        switch fetchProcessTable() {
        case .failed(let errno):
            return .failed(errno: errno)
        case .ok(let table):
            let mine = getpid()
            return .ok(
                table.map(\.process).filter { identity in
                    identity.pid != session && identity.pid != mine
                        && getsid(identity.pid) == session
                })
        }
    }

    /** Whether a snapshotted identity still names the same process. A nil live
        identity means the pid is gone; a start-time mismatch means reuse. */
    public static func shouldSignal(snapshotted: ProcessIdentity, live: ProcessIdentity?) -> Bool {
        guard let live else { return false }
        return snapshotted == live
    }

    /** Whether a live process's kernel start time is consistent with being the
        same run `persistedStartedAt` recorded, the identity check adoption needs
        before it re-attaches supervision to a bare pid match. A nil
        `persistedStartedAt` is pre-feature state with no baseline to check
        against, so it passes. Otherwise the process must not have started
        meaningfully *after* the moment it was recorded running: `recordSpawn`
        stamps `startedAt` a hair after the real kernel start (so a genuine
        survivor's `processStart` is at or slightly before `persistedStartedAt`,
        a small negative delta is normal), while a pid recycled during the
        daemon-down window started tens of seconds to minutes later. `tolerance`
        absorbs the pid-publish-to-timestamp gap without opening a window wide
        enough to accept a genuinely recycled pid. */
    public static func startTimeConsistent(
        processStart: Date, persistedStartedAt: Date?, tolerance: TimeInterval = 10
    ) -> Bool {
        guard let persistedStartedAt else { return true }
        return processStart <= persistedStartedAt.addingTimeInterval(tolerance)
    }

    /** Round a probed byte count up to whole `kinfo_proc` entries with 12.5%
        headroom, then return capacity and the exact allocated byte count to
        pass to sysctl (never advertise past the allocation). */
    public static func allocation(forProbedBytes probed: Int) -> (capacity: Int, byteCount: Int) {
        let stride = MemoryLayout<kinfo_proc>.stride
        guard probed > 0, stride > 0 else { return (0, 0) }
        let withHeadroom = probed + probed / 8
        let capacity = max(1, (withHeadroom + stride - 1) / stride)
        return (capacity, capacity * stride)
    }

    /** Signals the process group and every stray descendant outside it.
        When `revalidate` is true, skip the root group signal and any descendant
        whose start time no longer matches (PID reuse after a grace window).
        `rootIdentity` is required for a revalidated group kill; without it only
        matching descendants are signaled. */
    public static func signalTree(
        descendants: [ProcessIdentity],
        revalidate: Bool = false,
        rootIdentity: ProcessIdentity? = nil,
        rootPid: pid_t,
        signal: Int32
    ) {
        let rootStillOurs: Bool
        if revalidate {
            if let rootIdentity {
                rootStillOurs = shouldSignal(
                    snapshotted: rootIdentity, live: identity(of: rootPid))
            } else {
                rootStillOurs = false
            }
        } else {
            rootStillOurs = true
        }
        if rootStillOurs {
            kill(-rootPid, signal)
        }
        for identity in descendants {
            if revalidate {
                let live = self.identity(of: identity.pid)
                guard shouldSignal(snapshotted: identity, live: live) else { continue }
            }
            /** Skip a group member only when the group itself was signaled;
                otherwise (the root is gone or recycled, so `kill(-rootPid)` was
                withheld) a member still in that group would be missed, and it
                must be signaled individually instead. */
            if !rootStillOurs || getpgid(identity.pid) != rootPid {
                kill(identity.pid, signal)
            }
        }
    }

    /** Every way a live descendant of a run can be found, deduped by pid: the
        snapshot taken while the root still parented them, a fresh parent-chain
        sweep, and the session members that kept the root's session after
        setpgid/setsid took them out of the group. No single source is enough
        (see the note on ServerSupervisor.startDescendantWatch), so both the
        deliberate-stop and crash paths union all three and revalidate each pid
        at signal time. A failed sweep contributes nothing rather than throwing.

        `priorSignaled` carries the identities an earlier pass already signaled,
        so an escalation pass can re-signal a descendant that answered that pass
        by ignoring it (SIG_IGN is inherited across fork/exec when a root passes
        it down) and then became invisible to every live source: setsid gave it
        a session of its own, the dead root broke the parent chain, and it was
        younger than the last snapshot refresh. Revalidation still applies, so a
        recycled pid is never hit. */
    public static func liveDescendants(
        rootPid: pid_t, sessionID: pid_t?, snapshot: [ProcessIdentity],
        priorSignaled: [ProcessIdentity] = []
    ) -> [ProcessIdentity] {
        var byPid: [pid_t: ProcessIdentity] = [:]
        for identity in priorSignaled { byPid[identity.pid] = identity }
        for identity in snapshot { byPid[identity.pid] = identity }
        for identity in descendants(of: rootPid).identities { byPid[identity.pid] = identity }
        if let sessionID {
            for identity in sessionMembers(of: sessionID, sessionLeaderPid: rootPid).identities {
                byPid[identity.pid] = identity
            }
        }
        return Array(byPid.values)
    }

    private struct TableRow: Sendable {
        let parent: pid_t
        let process: ProcessIdentity
    }

    private enum TableResult {
        case failed(errno: Int32)
        case ok([TableRow])
    }

    /** QA1123 shape: 3-level MIB, size probe, rounded allocation, retry ENOMEM. */
    private static func fetchProcessTable() -> TableResult {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<8 {
            var probed = 0
            guard sysctl(&mib, 3, nil, &probed, nil, 0) == 0, probed > 0 else {
                return .failed(errno: errno)
            }
            let plan = allocation(forProbedBytes: probed)
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: plan.capacity)
            var length = plan.byteCount
            let status = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                sysctl(&mib, 3, ptr.baseAddress, &length, nil, 0)
            }
            if status == 0 {
                let count = length / MemoryLayout<kinfo_proc>.stride
                let rows = buffer.prefix(count).map { info in
                    TableRow(parent: info.kp_eproc.e_ppid, process: ProcessIdentity(info))
                }
                return .ok(rows)
            }
            if errno == ENOMEM { continue }
            return .failed(errno: errno)
        }
        return .failed(errno: ENOMEM)
    }

    /** Narrow a pid that came from outside this process to the `Int32` the
        signalling and sysctl calls take, or nil when no process could wear that
        number.

        Pids reach the daemon as unbounded `Int`: out of `state.json` and
        `registry.json`, and off the wire in a lock holder record. `pid_t(_:)`
        traps on anything past `Int32`, and a trap under launchd `KeepAlive` is a
        crash loop, because boot restore re-reads the same file and dies again on
        every relaunch. That is the failure the defensive-load rule exists to
        prevent, and narrowing quietly reopened it after JSON parsing had already
        let the value through.

        Answering nil costs nothing: every caller already handles a pid that
        names no live process, which is the same conclusion by a different route.
        Zero and negatives are refused too, since both are process-group and
        wildcard selectors to `kill(2)` rather than processes: `kill(0, sig)`
        signals the caller's own group, which for the daemon is every server it
        supervises. */
    public static func narrowed(_ pid: Int) -> pid_t? {
        guard let narrow = pid_t(exactly: pid), narrow > 0 else { return nil }
        return narrow
    }

    /** Is some process currently wearing this pid. A number no process can wear
        answers false, which is the same answer callers already act on for a pid
        whose process has exited. Says nothing about whether it is the SAME
        process the caller recorded: that needs `identity(of:)` and a start-time
        compare. */
    public static func isAlive(_ pid: Int) -> Bool {
        guard let narrow = narrowed(pid) else { return false }
        return kill(narrow, 0) == 0
    }

    /** Live identity for `pid`, or nil if gone / not readable. */
    public static func identity(of pid: pid_t) -> ProcessIdentity? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var length = MemoryLayout<kinfo_proc>.stride
        var info = kinfo_proc()
        guard sysctl(&mib, 4, &info, &length, nil, 0) == 0, length >= MemoryLayout<kinfo_proc>.stride
        else { return nil }
        guard info.kp_proc.p_pid == pid else { return nil }
        return ProcessIdentity(info)
    }
}
