import Darwin
import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

@Suite struct ProcessTreeTests {
    /** A pid reaches the daemon as an unbounded `Int`, out of `state.json` or a
        lock holder record on the wire, and `pid_t(_:)` trapped on anything past
        `Int32`. Under launchd `KeepAlive` that is a crash loop rather than a
        crash: boot restore re-reads the same file and dies again on relaunch.
        Returning from these is the assertion; a trap takes the whole runner
        down rather than failing one case. */
    @Test(arguments: [Int.max, Int.min, Int(Int32.max) + 1, Int(Int32.min) - 1, 4_294_967_296])
    func aPidTooLargeForTheKernelIsRefusedRatherThanTrapping(pid: Int) {
        #expect(ProcessTree.narrowed(pid) == nil)
        #expect(!ProcessTree.isAlive(pid))
    }

    /** Zero and negatives are `kill(2)` selectors, not processes: `kill(0, sig)`
        signals the caller's own process group, which for the daemon is every
        server it supervises. Narrowing them to a live-looking pid would turn a
        corrupt state file into a fleet-wide teardown. */
    @Test(arguments: [0, -1, -42])
    func aSelectorIsNotAProcess(pid: Int) {
        #expect(ProcessTree.narrowed(pid) == nil)
        #expect(!ProcessTree.isAlive(pid))
    }

    /** The positive control. Without it the two tests above pass just as well
        against a `narrowed` that refuses everything. */
    @Test func theRunnersOwnPidIsRepresentableAndAlive() {
        let mine = Int(getpid())
        #expect(ProcessTree.narrowed(mine) == pid_t(mine))
        #expect(ProcessTree.isAlive(mine))
    }

    @Test func allocationRoundsUpAndNeverOverstatesBytes() {
        let stride = MemoryLayout<kinfo_proc>.stride
        let plan = ProcessTree.allocation(forProbedBytes: stride * 3 + 1)
        #expect(plan.capacity >= 4)
        #expect(plan.byteCount == plan.capacity * stride)
        #expect(plan.byteCount % stride == 0)
    }

    @Test func allocationZeroProbeIsEmpty() {
        let plan = ProcessTree.allocation(forProbedBytes: 0)
        #expect(plan.capacity == 0)
        #expect(plan.byteCount == 0)
    }

    /** The guard that keeps a session sweep from becoming a sweep of the daemon
        itself. Refusing the caller's own session is the load-bearing assertion:
        without it, a root spawned without createSession would share the daemon's
        session and teardown would signal the daemon and every other server it
        supervises. */
    @Test func sessionSweepRefusesTheCallersOwnSession() {
        #expect(ProcessTree.sessionMembers(of: getsid(getpid())).identities.isEmpty)
    }

    /** Zero and negatives name no session leader; `getsid` would read them as
        the caller's own session or an error, never as a root to sweep. */
    @Test(arguments: [0, -1] as [pid_t])
    func sessionSweepRefusesASelector(leader: pid_t) {
        #expect(ProcessTree.sessionMembers(of: leader).identities.isEmpty)
    }

    /** The positive control, and the reason it uses posix_spawn directly:
        Foundation's `Process` starts a new process GROUP but not a new session,
        so a shell launched through it is not a session leader and the guard
        above refuses it. A control written that way passes in a millisecond
        without ever reaching the code it claims to cover, which is
        indistinguishable from a sweep that always returns nothing.

        POSIX_SPAWN_SETSID reproduces what the daemon's launcher does with
        createSession. The shell then backgrounds a sleep, giving the session a
        second member that the sweep must find. Both sleeps outlast any wait
        a busy pool can put between the polls; the teardown kills them. */
    @Test func sessionSweepFindsAMemberThatIsNotTheLeader() async throws {
        let leader = try spawnBare(["/bin/sh", "-c", "/bin/sleep 60 & sleep 60"], flags: POSIX_SPAWN_SETSID)
        defer {
            kill(-leader, SIGKILL)
            kill(leader, SIGKILL)
            var status: Int32 = 0
            waitpid(leader, &status, 0)
        }

        /** The premise: without SETSID taking effect there is no session to
            sweep and the rest of this test would prove nothing. */
        #expect(getsid(leader) == leader)

        let members: [pid_t] = try await firstAnswer(within: .seconds(5), every: .milliseconds(50)) {
            let members = ProcessTree.sessionMembers(of: leader).identities.map(\.pid)
            return members.isEmpty ? nil : members
        } ?? []
        #expect(!members.isEmpty, "session sweep found no members of session \(leader)")
        #expect(members.contains(leader) == false, "the leader itself must not be returned")
    }

    /** A root pid that now names a different live process is a stranger's:
        its children and the session it leads are not this run's, so both
        sweeps keyed on the pid are skipped. The same live tree read with the
        root's real identity is the positive control. The sleeps outlast any
        wait a busy pool can put between the polls; the teardown kills them. */
    @Test func liveDescendantsSkipsTheRootPidSweepsWhenThePidNamesAStranger() async throws {
        let leader = try spawnBare(["/bin/sh", "-c", "/bin/sleep 60 & sleep 60"], flags: POSIX_SPAWN_SETSID)
        defer {
            kill(-leader, SIGKILL)
            kill(leader, SIGKILL)
            var status: Int32 = 0
            waitpid(leader, &status, 0)
        }
        let real = try #require(ProcessTree.identity(of: leader))
        let stranger = ProcessIdentity(
            pid: leader, startMicroseconds: real.startMicroseconds,
            startSeconds: real.startSeconds - 60, uniqueID: unissuedUniqueID)
        let found: [pid_t] = try await firstAnswer(within: .seconds(5), every: .milliseconds(50)) {
            let found = ProcessTree.liveDescendants(rootPid: leader, rootIdentity: real, snapshot: [])
                .map(\.pid)
            return found.isEmpty ? nil : found
        } ?? []
        #expect(!found.isEmpty, "the positive control found no descendants of \(leader)")
        #expect(
            ProcessTree.liveDescendants(rootPid: leader, rootIdentity: stranger, snapshot: []).isEmpty)
    }

    @Test func shouldSignalRejectsMissingAndReusedPid() {
        let snap = ProcessIdentity(pid: 42, startMicroseconds: 5, startSeconds: 100, uniqueID: 7)
        #expect(ProcessTree.shouldSignal(snapshotted: snap, live: nil) == false)
        let reused = ProcessIdentity(pid: 42, startMicroseconds: 0, startSeconds: 200, uniqueID: 9)
        #expect(ProcessTree.shouldSignal(snapshotted: snap, live: reused) == false)
        #expect(ProcessTree.shouldSignal(snapshotted: snap, live: snap) == true)
    }

    /** A unique id is never reused within a boot, so a different one under the
        same pid and start time is a different process, however the clock read. */
    @Test func shouldSignalRejectsADifferentUniqueID() {
        let snap = ProcessIdentity(pid: 42, startMicroseconds: 5, startSeconds: 100, uniqueID: 7)
        let other = ProcessIdentity(pid: 42, startMicroseconds: 5, startSeconds: 100, uniqueID: 8)
        #expect(ProcessTree.shouldSignal(snapshotted: snap, live: other) == false)
    }

    private func row(_ uniqueID: UInt64, parent: UInt64, pid: pid_t) -> ProcessTree.LineageRow {
        ProcessTree.LineageRow(
            parentUniqueID: parent,
            process: ProcessIdentity(
                pid: pid, startMicroseconds: 0, startSeconds: 1_000, uniqueID: uniqueID))
    }

    /** The shape the walk exists for: launchd (1) parents the daemon (10), which
        forked the root (20). The root's child (30) called setsid and was
        reparented to launchd when the root exited, so its ppid would say 1,
        but its parent unique id still names 20. Its own child (40) and
        grandchild (50) are found through it, while a sibling server of the
        daemon (60) and an unrelated process (70) are not. */
    @Test func lineageWalksParentUniqueIDsToAFixedPoint() {
        let rows = [
            row(1, parent: 0, pid: 1),
            row(10, parent: 1, pid: 100),
            row(30, parent: 20, pid: 300),
            row(40, parent: 30, pid: 400),
            row(50, parent: 40, pid: 500),
            row(60, parent: 10, pid: 600),
            row(70, parent: 1, pid: 700),
        ]
        let found = ProcessTree.lineage(of: [20], in: rows, daemon: 10)
        #expect(Set(found.map(\.pid)) == [300, 400, 500])
    }

    /** A seed already known (a snapshot entry) is not returned again, but its
        descendants are, and two seeds on one chain find each process once. */
    @Test func lineageSkipsSeedsAndFindsEachProcessOnce() {
        let rows = [
            row(10, parent: 1, pid: 100),
            row(30, parent: 20, pid: 300),
            row(40, parent: 30, pid: 400),
        ]
        let found = ProcessTree.lineage(of: [20, 30], in: rows, daemon: 10)
        #expect(found.map(\.pid) == [400])
    }

    /** The refusals: a seed naming the daemon, any ancestor of it (launchd
        here), or the kernel's 0 would sweep every server or the machine, so each
        finds nothing. The positive control shows the same rows do answer a
        legitimate seed. */
    @Test(arguments: [10, 1, 0] as [UInt64])
    func lineageRefusesTheDaemonItsAncestorsAndTheKernel(seed: UInt64) {
        let rows = [
            row(1, parent: 0, pid: 1),
            row(10, parent: 1, pid: 100),
            row(20, parent: 10, pid: 200),
            row(30, parent: 20, pid: 300),
            row(70, parent: 1, pid: 700),
        ]
        #expect(ProcessTree.lineage(of: [seed], in: rows, daemon: 10).isEmpty)
        #expect(ProcessTree.lineage(of: [20], in: rows, daemon: 10).map(\.pid) == [300])
    }

    /** A row whose unique id could not be read has no key to match on and is
        never returned, and the walk does not stall past it. */
    @Test func lineageIgnoresARowWithNoUniqueID() {
        let unreadable = ProcessTree.LineageRow(
            parentUniqueID: 20,
            process: ProcessIdentity(pid: 300, startMicroseconds: 0, startSeconds: 1, uniqueID: nil))
        let rows = [unreadable, row(40, parent: 20, pid: 400)]
        #expect(ProcessTree.lineage(of: [20], in: rows, daemon: 10).map(\.pid) == [400])
    }

    /** The flavor 17 layout against the live kernel: this process's parent id
        is its parent's own id, and an identity read carries the same id. */
    @Test func uniqueIDsOfSelfNameTheParent() throws {
        let mine = try #require(ProcessUniqueIDs.read(of: getpid()))
        let parent = try #require(ProcessUniqueIDs.read(of: getppid()))
        #expect(mine.parent == parent.process)
        #expect(mine.process != parent.process)
        #expect(ProcessTree.identity(of: getpid())?.uniqueID == mine.process)
        #expect(ProcessUniqueIDs.read(of: -1) == nil)
    }

    /** The real-process premise the lineage source rests on: a setsid child whose
        parent exits is reparented to launchd yet keeps naming that parent's
        unique id, and the live sweep finds it from that id alone. */
    @Test func lineageMembersFindsASetsidChildAfterItsParentExits() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let (readEnd, writeEnd) = try makeOutputPipe()
        defer { close(readEnd) }
        let root = try spawnBare(
            [fixture, "--setsid-listener", "\(TestPorts.port(488))", "--exit-after-spawn"],
            flags: POSIX_SPAWN_SETSID, stdoutFD: writeEnd)
        close(writeEnd)
        let rootIDs = ProcessUniqueIDs.read(of: root)
        let reported = await offPool { () -> pid_t? in
            var status: Int32 = 0
            waitpid(root, &status, 0)
            return readPrintedPid("setsid listener", from: readEnd)
        }
        let child = try #require(reported)
        defer { kill(child, SIGKILL) }
        let rootID = try #require(rootIDs?.process)
        /** The premise: alive, its parent reaped so the parent chain is gone,
            and in a session of its own, so no other source can reach it. */
        #expect(kill(child, 0) == 0)
        #expect(!ProcessTree.descendants(of: root).pids.contains(child))
        #expect(getsid(child) == child)
        #expect(ProcessUniqueIDs.read(of: child)?.parent == rootID)
        #expect(ProcessTree.lineageMembers(of: [rootID]).pids.contains(child))
    }


    /** The adoption identity guard: a nil baseline (pre-feature state) always
        passes, a process that started at or slightly before the recorded
        moment (the normal pid-publish-to-timestamp gap) passes, and a process
        that started well after is a recycled pid and must be rejected. */
    @Test func startTimeConsistentAcceptsNilBaselineAndCloseStarts() {
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            ProcessTree.startTimeConsistent(processStart: Date(), persistedStartedAt: nil))
        /** A process that started a moment before the timestamp was stamped:
            the ordinary case (spawn, then record). */
        #expect(
            ProcessTree.startTimeConsistent(
                processStart: recordedAt.addingTimeInterval(-1), persistedStartedAt: recordedAt))
        /** Exactly at the recorded moment. */
        #expect(
            ProcessTree.startTimeConsistent(processStart: recordedAt, persistedStartedAt: recordedAt))
        /** Within tolerance after the recorded moment: still accepted, since
            the default tolerance exists precisely to absorb this gap. */
        #expect(
            ProcessTree.startTimeConsistent(
                processStart: recordedAt.addingTimeInterval(9), persistedStartedAt: recordedAt))
    }

    @Test func startTimeConsistentRejectsAProcessThatStartedWellAfter() {
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        /** A pid recycled during the daemon-down window: this daemon never
            recorded a process starting minutes after the moment it stamped. */
        #expect(
            ProcessTree.startTimeConsistent(
                processStart: recordedAt.addingTimeInterval(300), persistedStartedAt: recordedAt)
                == false)
        /** Just past the default tolerance boundary. */
        #expect(
            ProcessTree.startTimeConsistent(
                processStart: recordedAt.addingTimeInterval(11), persistedStartedAt: recordedAt)
                == false)
    }

    @Test func startTimeConsistentHonorsACustomTolerance() {
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            ProcessTree.startTimeConsistent(
                processStart: recordedAt.addingTimeInterval(2), persistedStartedAt: recordedAt,
                tolerance: 1) == false)
        #expect(
            ProcessTree.startTimeConsistent(
                processStart: recordedAt.addingTimeInterval(2), persistedStartedAt: recordedAt,
                tolerance: 3))
    }

    @Test func identityOfSelfMatchesLiveProcess() throws {
        let pid = getpid()
        let identity = try #require(ProcessTree.identity(of: pid))
        #expect(identity.pid == pid)
        #expect(ProcessTree.shouldSignal(snapshotted: identity, live: ProcessTree.identity(of: pid)))
        let forged = ProcessIdentity(
            pid: pid, startMicroseconds: identity.startMicroseconds,
            startSeconds: identity.startSeconds &+ 1, uniqueID: identity.uniqueID)
        #expect(
            ProcessTree.shouldSignal(snapshotted: forged, live: ProcessTree.identity(of: pid))
                == false)
    }

    /** A zombie still answers `identity(of:)` but has exited, so it no longer
        runs; a recycled identity never does. */
    @Test func isRunningRejectsAZombieAndAForgedIdentity() async throws {
        let me = try #require(ProcessTree.identity(of: getpid()))
        #expect(ProcessTree.isRunning(me))
        let forged = ProcessIdentity(
            pid: me.pid, startMicroseconds: me.startMicroseconds, startSeconds: me.startSeconds - 1,
            uniqueID: me.uniqueID)
        #expect(!ProcessTree.isRunning(forged))

        let child = try spawnBare(["/usr/bin/true"])
        defer {
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }
        let exited = await offPool {
            var info = siginfo_t()
            return waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT)
        }
        try #require(exited == 0)
        let zombie = try #require(ProcessTree.identity(of: child))
        #expect(!ProcessTree.isRunning(zombie))
    }

    @Test func failedDescendantsAreNotEmptySuccess() {
        /** Live sweep against a nonsense pid still returns .ok([]) (no children),
            never .failed. Failure is a sysctl errno path; assert the result type
            distinguishes the two shapes we care about. */
        let none = DescendantsResult.ok([])
        let fail = DescendantsResult.failed(errno: ENOMEM)
        #expect(none.identities.isEmpty)
        #expect(fail.identities.isEmpty)
        #expect(none != fail)
    }

    @Test func coalitionIDsOfSelfAreReadable() throws {
        let ids = try #require(CoalitionIDs.read(of: getpid()))
        #expect(ids.jetsam != 0)
        #expect(ids.resource != 0)
    }

    /** posix_spawn inherits the parent's jetsam and resource coalitions.
        `POSIX_SPAWN_SETSID` makes a session leader and does not break that
        inheritance: the 2026-09-02 jetsam of `ddirecta` was this fact, not a
        missing setsid. */
    @Test func posixSpawnInheritsJetsamCoalition() throws {
        let parent = try #require(CoalitionIDs.read(of: getpid()))
        let child = try spawnSleep(disclaim: false)
        defer { reap(child) }
        let ids = try #require(CoalitionIDs.read(of: child))
        #expect(ids.jetsam == parent.jetsam)
        #expect(ids.resource == parent.resource)
        #expect(getpgid(child) == child)
    }

    /** `responsibility_spawnattrs_setdisclaim` is the cheap Darwin SPI Chromium
        and LLDB use for a new TCC responsibility chain. On macOS 26.6 it does
        not create a new jetsam coalition (probe 2026-09-02). If this assertion
        flips, the cheap `preSpawnProcessConfigurator` path is back. */
    @Test func disclaimDoesNotSplitJetsamCoalition() throws {
        let parent = try #require(CoalitionIDs.read(of: getpid()))
        let child = try spawnSleep(disclaim: true)
        defer { reap(child) }
        let ids = try #require(CoalitionIDs.read(of: child))
        #expect(ids.jetsam == parent.jetsam)
        #expect(ids.resource == parent.resource)
    }

    private func spawnSleep(disclaim: Bool) throws -> pid_t {
        try spawnBare(["/bin/sleep", "8"], flags: POSIX_SPAWN_SETSID) { attributes in
            guard disclaim else { return }
            typealias DisclaimFn =
                @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
            let symbol = dlsym(
                UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
            let ptr = try #require(symbol)
            let fn = unsafeBitCast(ptr, to: DisclaimFn.self)
            let rc = fn(&attributes, 1)
            try #require(rc == 0, "disclaim returned \(rc)")
        }
    }

    private func reap(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}
