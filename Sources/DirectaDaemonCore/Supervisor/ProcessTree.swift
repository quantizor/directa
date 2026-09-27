import Darwin
import DirectaKit
import Foundation

/** A process identity that survives PID reuse: pid alone is not enough across a
    grace window, because macOS can recycle the number. Start time comes from
    `kinfo_proc.kp_proc.p_starttime`; `uniqueID` is the kernel's never-reused
    id (`ProcessUniqueIDs`), nil only when that read failed. Every identity is
    built through `ProcessTree`, which reads all three the same way, so two
    reads of one live process compare equal and a recycled pid never does. */
public struct ProcessIdentity: Hashable, Sendable, Equatable {
    public let pid: pid_t
    public let startMicroseconds: suseconds_t
    public let startSeconds: time_t
    public let uniqueID: UInt64?

    public init(
        pid: pid_t, startMicroseconds: suseconds_t, startSeconds: time_t, uniqueID: UInt64?
    ) {
        self.pid = pid
        self.startMicroseconds = startMicroseconds
        self.startSeconds = startSeconds
        self.uniqueID = uniqueID
    }

    init(_ info: kinfo_proc, uniqueID: UInt64?) {
        self.pid = info.kp_proc.p_pid
        self.startMicroseconds = info.kp_proc.p_starttime.tv_usec
        self.startSeconds = info.kp_proc.p_starttime.tv_sec
        self.uniqueID = uniqueID
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
            var childrenByParent: [pid_t: [TableRow]] = [:]
            for row in table {
                childrenByParent[row.parent, default: []].append(row)
            }
            var found: [ProcessIdentity] = []
            var queue: [pid_t] = [pid]
            while let parent = queue.popLast() {
                for child in childrenByParent[parent] ?? [] where child.pid != parent {
                    found.append(child.identity)
                    queue.append(child.pid)
                }
            }
            return .ok(found)
        }
    }

    /** Live members of the session `leader` leads (a session id is its
        leader's pid), excluding the leader and this process's own session.

        This is the one handle on an escaped descendant that does not depend on
        when a snapshot was taken. A child that setpgid's out of the group (every
        Foundation `Process` child does) still inherits the session, and unlike
        the parent-pid chain, session membership survives the root exiting and
        the orphan reparenting to launchd. So a descendant missed by the snapshot
        because it appeared moments before the crash is still reachable here.

        Every launcher spawns the root as a session leader, so its pid is the
        session to sweep, never a `getsid` read that answers ESRCH once a
        short-lived root has exited. A root that somehow did not lead a session
        names none, since the kernel never hands out a pid still in use as a
        session id, so the sweep then finds nothing rather than a stranger. The
        caller's own session is refused outright rather than trusted to differ:
        sweeping it would signal the daemon and everything it owns. */
    public static func sessionMembers(of leader: pid_t) -> DescendantsResult {
        let session = leader
        guard session > 0, session != getsid(getpid()) else {
            return .ok([])
        }
        switch fetchProcessTable() {
        case .failed(let errno):
            return .failed(errno: errno)
        case .ok(let table):
            let mine = getpid()
            return .ok(
                table.filter { row in
                    row.pid != session && row.pid != mine && getsid(row.pid) == session
                }.map(\.identity))
        }
    }

    /** One process as the lineage walk reads it: its identity, whose
        `uniqueID` is the key, and the unique id of the process that forked it. */
    public struct LineageRow: Equatable, Sendable {
        public let parentUniqueID: UInt64
        public let process: ProcessIdentity

        public init(parentUniqueID: UInt64, process: ProcessIdentity) {
            self.parentUniqueID = parentUniqueID
            self.process = process
        }
    }

    /** Every row descended from a seed through parent unique ids, walked to a
        fixed point so a grandchild of an escaped child is found too. Seeds are
        never returned themselves.

        This is the one handle on a child that escaped every other source at
        once: it called setsid (out of the group and the session), its parent
        exited (the kernel reparented it to launchd, so the parent-pid chain
        lost it), and it appeared after the last snapshot refresh. The kernel
        keeps its parent unique id through that reparenting, and unique ids are
        never reused within a boot, so the match is exact rather than a pid
        that may since name somebody else.

        `daemon` is the caller's own unique id. Neither it nor any ancestor of
        it (walked up the rows) is ever a seed or a result, and neither is 0,
        the kernel's own id and launchd's parent: a seed naming the daemon
        would sweep every server it supervises, and one naming launchd or the
        kernel would sweep the machine. */
    public static func lineage(
        of seeds: Set<UInt64>, in rows: [LineageRow], daemon: UInt64
    ) -> [ProcessIdentity] {
        var byUniqueID: [UInt64: LineageRow] = [:]
        var childrenByParent: [UInt64: [LineageRow]] = [:]
        for row in rows {
            guard let id = row.process.uniqueID else { continue }
            byUniqueID[id] = row
            childrenByParent[row.parentUniqueID, default: []].append(row)
        }
        var refused: Set<UInt64> = [0, daemon]
        var cursor = daemon
        while let row = byUniqueID[cursor], !refused.contains(row.parentUniqueID) {
            refused.insert(row.parentUniqueID)
            cursor = row.parentUniqueID
        }
        var queue = Array(seeds.subtracting(refused))
        var seen = refused.union(queue)
        var found: [ProcessIdentity] = []
        while let parent = queue.popLast() {
            for child in childrenByParent[parent] ?? [] {
                guard let id = child.process.uniqueID, !seen.contains(id) else { continue }
                seen.insert(id)
                found.append(child.process)
                queue.append(id)
            }
        }
        return found
    }

    /** `lineage` over the live process table, excluding any member of this
        process's own session (the same refusal the session sweep makes). Reads
        every process's unique ids, one `proc_pidinfo` each, which is why only
        teardown runs it and the startup refreshes do not. Refuses outright
        when this process's own unique id cannot be read, since the
        refusals above cannot be proven without it. */
    public static func lineageMembers(of seeds: Set<UInt64>) -> DescendantsResult {
        guard !seeds.isEmpty, let daemon = ProcessUniqueIDs.read(of: getpid())?.process else {
            return .ok([])
        }
        switch fetchProcessTable() {
        case .failed(let errno):
            return .failed(errno: errno)
        case .ok(let table):
            let rows = table.compactMap { row -> LineageRow? in
                guard let ids = ProcessUniqueIDs.read(of: row.pid) else { return nil }
                return LineageRow(parentUniqueID: ids.parent, process: row.identity(uniqueID: ids.process))
            }
            let daemonSession = getsid(getpid())
            return .ok(
                lineage(of: seeds, in: rows, daemon: daemon).filter { getsid($0.pid) != daemonSession })
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
        sweep, the members of the session the root leads, which kept it after
        setpgid/setsid took them out of the group, and the lineage walk from
        the root's unique id and every unique id the other three found, which
        reaches a setsid child that reparented after the last snapshot
        refresh. No single source is enough (see the note on
        ServerSupervisor.startDescendantWatch), so both the deliberate-stop and
        crash paths union all four and revalidate each pid at signal time. A
        failed sweep contributes nothing rather than throwing.

        `rootIdentity` is the root as recorded while it was alive (nil when
        that read failed). The two sweeps keyed on `rootPid` are skipped while
        that pid names a different live process: a recycled pid's children and
        session belong to a stranger. Once no process wears the pid, both still
        run, since a session outlives its leader and nothing can be parented by
        a pid that names no process.

        `priorCandidates` carries the identities an earlier pass already
        signaled, so an escalation pass can re-signal a descendant that
        answered that pass by ignoring it (SIG_IGN is inherited across
        fork/exec when a root passes it down) and then became invisible to
        every live source: setsid gave it a session of its own, the dead root
        broke the parent chain, and it was younger than the last snapshot
        refresh. Revalidation still applies, so a recycled pid is never hit. */
    public static func liveDescendants(
        rootPid: pid_t, rootIdentity: ProcessIdentity?, snapshot: [ProcessIdentity],
        priorCandidates: [ProcessIdentity] = []
    ) -> [ProcessIdentity] {
        var byPid: [pid_t: ProcessIdentity] = [:]
        for identity in priorCandidates { byPid[identity.pid] = identity }
        for identity in snapshot { byPid[identity.pid] = identity }
        let wearer = identity(of: rootPid)
        if rootIdentity == nil || wearer == nil || wearer == rootIdentity {
            for identity in descendants(of: rootPid).identities { byPid[identity.pid] = identity }
            for identity in sessionMembers(of: rootPid).identities { byPid[identity.pid] = identity }
        }
        var seeds = Set(byPid.values.compactMap(\.uniqueID))
        if let rootUniqueID = rootIdentity?.uniqueID { seeds.insert(rootUniqueID) }
        for identity in lineageMembers(of: seeds).identities { byPid[identity.pid] = identity }
        return Array(byPid.values)
    }

    /** A `kinfo_proc` reduced to what the sweeps read. The unique id is not
        here: it costs a `proc_pidinfo` per process, so each sweep reads it only
        for the rows it keeps (`identity`), except the lineage sweep, which
        needs every row's. */
    private struct TableRow: Sendable {
        let parent: pid_t
        let pid: pid_t
        let startMicroseconds: suseconds_t
        let startSeconds: time_t

        func identity(uniqueID: UInt64?) -> ProcessIdentity {
            ProcessIdentity(
                pid: pid, startMicroseconds: startMicroseconds, startSeconds: startSeconds,
                uniqueID: uniqueID)
        }

        var identity: ProcessIdentity {
            identity(uniqueID: ProcessUniqueIDs.read(of: pid)?.process)
        }
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
                    TableRow(
                        parent: info.kp_eproc.e_ppid, pid: info.kp_proc.p_pid,
                        startMicroseconds: info.kp_proc.p_starttime.tv_usec,
                        startSeconds: info.kp_proc.p_starttime.tv_sec)
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
        return ProcessIdentity(info, uniqueID: ProcessUniqueIDs.read(of: pid)?.process)
    }
}
