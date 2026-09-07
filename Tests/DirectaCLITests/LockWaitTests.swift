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
        hold warns that the corruption guard is off. */
    @Test func unguardedWarnsWhenNoStatePathAndDeclarersStayLive() {
        let text = LockNotice.unguarded(resource: "d1", live: ["web", "db"], statePath: nil)
        #expect(
            text
                == "directa lock: note: 'd1' declares no state path, so a change made while db, web stay running cannot be detected. Add a `path` to the lock declaration or use --pause.")
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

    @Test func stillWaitingAnnouncesOnceEveryInterval() {
        let schedule = LockAcquireSchedule(budgetSeconds: 300)
        #expect(schedule.shouldAnnounceStillWaiting(atElapsed: 0, lastAnnouncedElapsed: nil) == false)
        #expect(schedule.shouldAnnounceStillWaiting(atElapsed: 14, lastAnnouncedElapsed: 0) == false)
        #expect(schedule.shouldAnnounceStillWaiting(atElapsed: 15, lastAnnouncedElapsed: 0))
        #expect(schedule.shouldAnnounceStillWaiting(atElapsed: 16, lastAnnouncedElapsed: 15) == false)
        #expect(schedule.shouldAnnounceStillWaiting(atElapsed: 30, lastAnnouncedElapsed: 15))
    }

    @Test func durationTextIsExact() {
        #expect(DurationText.brief(seconds: 0) == "0s")
        #expect(DurationText.brief(seconds: 59) == "59s")
        #expect(DurationText.brief(seconds: 60) == "1m 00s")
        #expect(DurationText.brief(seconds: 125) == "2m 05s")
        #expect(DurationText.brief(seconds: 3720) == "1h 02m")
    }
}
