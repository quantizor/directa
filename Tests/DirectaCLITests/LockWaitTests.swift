import DirectaKit
import Foundation
import Testing

@testable import directa

/** A contended acquire used to block for up to five minutes with nothing on
    stdout, which reads as a hung gate. The reflex that invites is killing
    whichever run holds the lock, and that run is the one making progress. */
@Suite struct LockWaitTests {
    private let since = Date(timeIntervalSince1970: 1_752_868_000)
    private var now: Date { since.addingTimeInterval(125) }

    @Test func contendedNoticeNamesTheHolderItsAgeAndWhatItPaused() {
        let holder = LockHolder(
            pause: true, paused: ["db", "web"], pid: 4242, since: since)
        let text = LockNotice.contended(
            budgetSeconds: 300, holder: holder, now: now, resource: "d1")
        #expect(
            text == """
                directa lock: 'd1' is held by pid 4242, running for 2m 05s (it paused db, web).
                directa lock: waiting up to 5m 00s for that run to finish. It is the one making progress, so check it with `ps -p 4242` before killing anything.
                """)
    }

    @Test func contendedNoticeSaysWhichServersAHolderLeftRunning() {
        let holder = LockHolder(live: ["db"], pause: false, paused: [], pid: 77, since: since)
        let text = LockNotice.contended(
            budgetSeconds: 300, holder: holder, now: now, resource: "d1")
        #expect(text.contains("(it left db running)"))
    }

    /** The default hold with nothing running left no servers up, so saying it did
        would mislead whoever is debugging the contention. */
    @Test func contendedNoticeDoesNotClaimServersWereLeftRunningWhenNoneWere() {
        let holder = LockHolder(pause: false, paused: [], pid: 77, since: since)
        let text = LockNotice.contended(
            budgetSeconds: 300, holder: holder, now: now, resource: "d1")
        #expect(text.contains("(nothing was running to leave up)"))
        #expect(!text.contains("left declaring servers running"))
    }

    /** An empty paused set is ambiguous without the pause bit, so it gets its
        own sentence rather than reading as "it paused nothing you care about". */
    @Test func contendedNoticeDistinguishesNothingRunningFromNoPause() {
        let holder = LockHolder(pause: true, paused: [], pid: 9, since: since)
        let text = LockNotice.contended(
            budgetSeconds: 60, holder: holder, now: now, resource: "d1")
        #expect(text.contains("(nothing was running to pause)"))
    }

    /** A holder written by an older daemon has no pause bit at all. */
    @Test func contendedNoticeReadsSensiblyForAPreFeatureHolder() {
        let holder = LockHolder(paused: ["db"], pid: 5, since: since)
        let text = LockNotice.contended(
            budgetSeconds: 300, holder: holder, now: now, resource: "d1")
        #expect(text.contains("(it paused db)"))
    }

    /** A bare-named lock (no state path) left over live declarers has no
        fingerprint fallback for the pause that no longer runs by default, so the
        hold warns that the corruption guard is off, naming which server
        declares the lock and the exact devservers.json object to add. */
    @Test func unguardedWarnsWhenNoStatePathAndDeclarersStayLive() {
        let text = LockNotice.unguarded(resource: "d1", live: ["web", "db"], statePath: nil)
        #expect(
            text == """
                directa lock: note: 'd1' declares no state path, so a change made while db, web stay running cannot be detected.
                directa lock: give db's 'd1' entry in devservers.json a path, e.g. {"name": "d1", "path": "<path to d1's state>"}, or run with --pause.
                """)
    }

    @Test func unguardedIsSilentWhenAStatePathCanBeFingerprinted() {
        #expect(LockNotice.unguarded(resource: "d1", live: ["db"], statePath: "/p/state") == nil)
    }

    @Test func unguardedIsSilentWhenNoDeclarerStayedLive() {
        #expect(LockNotice.unguarded(resource: "d1", live: [], statePath: nil) == nil)
    }

    @Test func unguardedUsesSingularForOneServer() {
        let text = LockNotice.unguarded(resource: "d1", live: ["db"], statePath: nil)
        #expect(text?.contains("while db stays running") == true)
    }

    @Test func stillWaitingCountsElapsedAndRemaining() {
        let holder = LockHolder(pause: true, paused: [], pid: 4242, since: since)
        let text = LockNotice.stillWaiting(
            elapsedSeconds: 45, holder: holder, remainingSeconds: 255, resource: "d1")
        #expect(
            text
                == "directa lock: still waiting on 'd1' (pid 4242), 45s elapsed, 4m 15s left.")
    }

    /** Budget 0 is the fail-fast form a script wants. The old `while` condition
        never entered its body there, so it failed with no holder named. */
    @Test func zeroBudgetMakesExactlyOneAttempt() {
        let schedule = LockAcquireSchedule(budgetSeconds: 0)
        #expect(schedule.shouldRetry(afterElapsed: 0) == false)
    }

    @Test func budgetRetriesUntilExhausted() {
        let schedule = LockAcquireSchedule(budgetSeconds: 300)
        #expect(schedule.shouldRetry(afterElapsed: 299))
        #expect(schedule.shouldRetry(afterElapsed: 300) == false)
        #expect(schedule.shouldRetry(afterElapsed: 300.1) == false)
    }

    /** A `resource-locked` answer with nobody holding the resource is a
        `--pause` whose declarer would not stop: waiting only repeats the
        attempt on servers already paused once. */
    @Test func aRefusalWithNoHolderIsNotWorthWaitingOut() {
        let holder = LockHolder(pause: true, paused: [], pid: 9, since: since)
        #expect(LockAcquireSchedule.refusalIsContention(lookup: LockStatusResult(holder: holder)))
        #expect(!LockAcquireSchedule.refusalIsContention(lookup: LockStatusResult(holder: nil)))
        #expect(LockAcquireSchedule.refusalIsContention(lookup: nil))
    }

    @Test func stillWaitingAnnouncesOnceEveryInterval() {
        let schedule = LockAcquireSchedule(budgetSeconds: 300)
        #expect(schedule.shouldAnnounceStillWaiting(atElapsed: 0, lastAnnouncedElapsed: nil) == false)
        #expect(schedule.shouldAnnounceStillWaiting(atElapsed: 14, lastAnnouncedElapsed: 0) == false)
        #expect(schedule.shouldAnnounceStillWaiting(atElapsed: 15, lastAnnouncedElapsed: 0))
        #expect(schedule.shouldAnnounceStillWaiting(atElapsed: 16, lastAnnouncedElapsed: 15) == false)
        #expect(schedule.shouldAnnounceStillWaiting(atElapsed: 30, lastAnnouncedElapsed: 15))
    }

    // MARK: the acquire wait, over a scripted daemon

    private static let refused = WireError(
        code: .resourceLocked, hint: "run: ps -p 9", message: "resource 'd1' is locked by pid 9")

    /** Each call answers from its own queue, in order; an empty queue is a test
        bug and fails loudly. Every call is logged. */
    private actor ScriptedDaemon: LockRequesting {
        var acquires: [Result<LockResult, WireError>]
        var calls: [String] = []
        var statuses: [LockStatusResult?]

        init(acquires: [Result<LockResult, WireError>], statuses: [LockStatusResult?] = []) {
            self.acquires = acquires
            self.statuses = statuses
        }

        func acquire() async throws -> LockResult {
            calls.append("acquire")
            guard !acquires.isEmpty else {
                Issue.record("unscripted acquire call")
                throw WireError(code: .internalError, message: "unscripted acquire")
            }
            return try acquires.removeFirst().get()
        }

        func status() async -> LockStatusResult? {
            calls.append("status")
            guard !statuses.isEmpty else {
                Issue.record("unscripted status call")
                return nil
            }
            return statuses.removeFirst()
        }
    }

    /** Time that only moves when the wait sleeps. */
    private actor VirtualLockClock: LockClock {
        var current: Date
        var sleeps: [Double] = []

        init(start: Date) { current = start }

        func now() async -> Date { current }

        func sleep(seconds: Double) async {
            sleeps.append(seconds)
            current = current.addingTimeInterval(seconds)
        }
    }

    private final class Notices: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func add(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    private func holder(since: Date? = nil) -> LockStatusResult {
        LockStatusResult(
            holder: LockHolder(pause: false, paused: [], pid: 9, since: since ?? self.since))
    }

    private let nobody = LockStatusResult(holder: nil)

    private func acquirer(
        _ daemon: ScriptedDaemon, clock: VirtualLockClock, budget: Double, notices: Notices = Notices()
    ) -> LockAcquirer {
        LockAcquirer(
            budgetSeconds: budget, clock: clock, notice: { notices.add($0) }, requester: daemon,
            resource: "d1")
    }

    /** The holder released between the refused acquire and the holder lookup:
        the resource is free, so the CLI asks again at once rather than failing
        a lock nobody holds. */
    @Test func aHolderThatReleasesBetweenTheCallsIsRetriedAtOnce() async throws {
        let daemon = ScriptedDaemon(
            acquires: [.failure(Self.refused), .success(LockResult(live: ["db"]))], statuses: [nobody])
        let clock = VirtualLockClock(start: since)
        let result = try await acquirer(daemon, clock: clock, budget: 300).acquire()
        #expect(result == LockResult(live: ["db"]))
        #expect(await daemon.calls == ["acquire", "status", "acquire"])
        #expect(await clock.sleeps.isEmpty)
    }

    /** A second refusal with nobody holding it is not a race: it is a
        `--pause` whose declarer would not stop, which no wait clears. */
    @Test func aRefusalThatStaysHolderlessFailsAfterOneImmediateRetry() async throws {
        let daemon = ScriptedDaemon(
            acquires: [.failure(Self.refused), .failure(Self.refused)], statuses: [nobody, nobody])
        let clock = VirtualLockClock(start: since)
        await #expect(throws: WireError.self) {
            try await acquirer(daemon, clock: clock, budget: 300).acquire()
        }
        #expect(await daemon.calls == ["acquire", "status", "acquire", "status"])
        #expect(await clock.sleeps.isEmpty)
    }

    /** The holder appears on the immediate retry's lookup: ordinary contention
        from there on, announced and waited out. */
    @Test func aHolderSeenOnTheRetryIsWaitedOut() async throws {
        let daemon = ScriptedDaemon(
            acquires: [.failure(Self.refused), .failure(Self.refused), .success(LockResult())],
            statuses: [nobody, holder()])
        let clock = VirtualLockClock(start: since)
        let notices = Notices()
        _ = try await acquirer(daemon, clock: clock, budget: 300, notices: notices).acquire()
        #expect(await daemon.calls == ["acquire", "status", "acquire", "status", "acquire"])
        #expect(await clock.sleeps == [1])
        #expect(notices.all.count == 1)
        #expect(notices.all[0].hasPrefix("directa lock: 'd1' is held by pid 9"))
    }

    /** The holder is looked up when a notice is due (the first refusal, then
        every 15 seconds), not on each one-second retry. */
    @Test func theHolderIsLookedUpOnlyWhenANoticeIsDue() async throws {
        let refusals = Array(repeating: Result<LockResult, WireError>.failure(Self.refused), count: 31)
        let daemon = ScriptedDaemon(
            acquires: refusals + [.success(LockResult())], statuses: [holder(), holder(), holder()])
        let clock = VirtualLockClock(start: since)
        let notices = Notices()
        _ = try await acquirer(daemon, clock: clock, budget: 300, notices: notices).acquire()
        let calls = await daemon.calls
        #expect(calls.filter { $0 == "status" }.count == 3)
        #expect(calls.filter { $0 == "acquire" }.count == 32)
        #expect(notices.all.count == 3)
        #expect(notices.all[1] == "directa lock: still waiting on 'd1' (pid 9), 15s elapsed, 4m 45s left.")
        #expect(notices.all[2] == "directa lock: still waiting on 'd1' (pid 9), 30s elapsed, 4m 30s left.")
    }

    /** An older daemon cannot say who holds the resource: the wait goes on in
        silence rather than failing the acquire. */
    @Test func aDaemonWithoutLockStatusIsWaitedOutQuietly() async throws {
        let daemon = ScriptedDaemon(
            acquires: [.failure(Self.refused), .failure(Self.refused), .success(LockResult())],
            statuses: [nil, nil])
        let clock = VirtualLockClock(start: since)
        let notices = Notices()
        _ = try await acquirer(daemon, clock: clock, budget: 300, notices: notices).acquire()
        #expect(await clock.sleeps == [1, 1])
        #expect(notices.all.isEmpty)
    }

    @Test func aZeroBudgetMakesOneAttemptAgainstAHolderAndFails() async throws {
        let daemon = ScriptedDaemon(acquires: [.failure(Self.refused)], statuses: [holder()])
        let clock = VirtualLockClock(start: since)
        let notices = Notices()
        await #expect(throws: WireError.self) {
            try await acquirer(daemon, clock: clock, budget: 0, notices: notices).acquire()
        }
        #expect(await daemon.calls == ["acquire", "status"])
        #expect(await clock.sleeps.isEmpty)
        #expect(notices.all.count == 1)
    }

    @Test func theBudgetEndsTheWaitWithTheLastRefusal() async throws {
        let daemon = ScriptedDaemon(
            acquires: Array(repeating: .failure(Self.refused), count: 3),
            statuses: [holder()])
        let clock = VirtualLockClock(start: since)
        do {
            _ = try await acquirer(daemon, clock: clock, budget: 2).acquire()
            Issue.record("acquired a resource that stayed held")
        } catch let error as WireError {
            #expect(error == Self.refused)
        }
        #expect(await daemon.calls == ["acquire", "status", "acquire"])
        #expect(await clock.sleeps == [1, 1])
    }

    @Test func aFailureOtherThanContentionPropagatesAtOnce() async throws {
        let broken = WireError(code: .configInvalid, hint: "run: directa config check", message: "bad")
        let daemon = ScriptedDaemon(acquires: [.failure(broken)])
        let clock = VirtualLockClock(start: since)
        do {
            _ = try await acquirer(daemon, clock: clock, budget: 300).acquire()
            Issue.record("a config failure was swallowed")
        } catch let error as WireError {
            #expect(error == broken)
        }
        #expect(await daemon.calls == ["acquire"])
    }

    @Test func durationTextIsExact() {
        #expect(DurationText.brief(seconds: 0) == "0s")
        #expect(DurationText.brief(seconds: 59) == "59s")
        #expect(DurationText.brief(seconds: 60) == "1m 00s")
        #expect(DurationText.brief(seconds: 125) == "2m 05s")
        #expect(DurationText.brief(seconds: 3720) == "1h 02m")
    }
}
