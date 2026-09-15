import Darwin
import DirectaKit
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
        let mine = getsid(getpid())
        #expect(
            ProcessTree.sessionMembers(of: mine, sessionLeaderPid: mine).identities.isEmpty)
    }

    /** A root that is not its own session leader cannot have had createSession
        applied, so its session belongs to somebody else and is not ours to
        sweep. */
    @Test func sessionSweepRefusesARootThatIsNotTheSessionLeader() {
        #expect(
            ProcessTree.sessionMembers(of: 1, sessionLeaderPid: 4242).identities.isEmpty)
        #expect(ProcessTree.sessionMembers(of: 0, sessionLeaderPid: 0).identities.isEmpty)
    }

    /** The positive control, and the reason it uses posix_spawn directly:
        Foundation's `Process` starts a new process GROUP but not a new session,
        so a shell launched through it is not a session leader and the guard
        above refuses it. A control written that way passes in a millisecond
        without ever reaching the code it claims to cover, which is
        indistinguishable from a sweep that always returns nothing.

        POSIX_SPAWN_SETSID reproduces what the daemon's launcher does with
        createSession. The shell then backgrounds a sleep, giving the session a
        second member that the sweep must find. */
    @Test func sessionSweepFindsAMemberThatIsNotTheLeader() throws {
        var attributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        #expect(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) == 0)

        var leader: pid_t = 0
        let script = "/bin/sleep 5 & sleep 5"
        let argv: [String] = ["/bin/sh", "-c", script]
        var cArgs = argv.map { strdup($0) } + [nil]
        defer { for arg in cArgs where arg != nil { free(arg) } }
        let spawned = posix_spawn(&leader, "/bin/sh", nil, &attributes, &cArgs, environ)
        try #require(spawned == 0, "posix_spawn failed: \(spawned)")
        defer {
            kill(-leader, SIGKILL)
            kill(leader, SIGKILL)
            var status: Int32 = 0
            waitpid(leader, &status, 0)
        }

        /** The premise: without SETSID taking effect there is no session to
            sweep and the rest of this test would prove nothing. */
        #expect(getsid(leader) == leader)

        var members: [pid_t] = []
        for _ in 0..<50 {
            members = ProcessTree.sessionMembers(of: leader, sessionLeaderPid: leader)
                .identities.map(\.pid)
            if !members.isEmpty { break }
            usleep(50_000)
        }
        #expect(!members.isEmpty, "session sweep found no members of session \(leader)")
        #expect(members.contains(leader) == false, "the leader itself must not be returned")
    }

    @Test func shouldSignalRejectsMissingAndReusedPid() {
        let snap = ProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 5)
        #expect(ProcessTree.shouldSignal(snapshotted: snap, live: nil) == false)
        let reused = ProcessIdentity(pid: 42, startSeconds: 200, startMicroseconds: 0)
        #expect(ProcessTree.shouldSignal(snapshotted: snap, live: reused) == false)
        #expect(ProcessTree.shouldSignal(snapshotted: snap, live: snap) == true)
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
            pid: pid, startSeconds: identity.startSeconds &+ 1, startMicroseconds: 0)
        #expect(
            ProcessTree.shouldSignal(snapshotted: forged, live: ProcessTree.identity(of: pid))
                == false)
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
        var attributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        #expect(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) == 0)
        if disclaim {
            typealias DisclaimFn =
                @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
            let symbol = dlsym(
                UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
            let ptr = try #require(symbol)
            let fn = unsafeBitCast(ptr, to: DisclaimFn.self)
            let rc = fn(&attributes, 1)
            try #require(rc == 0, "disclaim returned \(rc)")
        }
        var child: pid_t = 0
        let argv: [String] = ["/bin/sleep", "8"]
        var cArgs = argv.map { strdup($0) } + [nil]
        defer { for arg in cArgs where arg != nil { free(arg) } }
        let spawned = posix_spawn(&child, "/bin/sleep", nil, &attributes, &cArgs, environ)
        try #require(spawned == 0, "posix_spawn failed: \(spawned)")
        return child
    }

    private func reap(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}
