import Foundation
import Testing

@testable import DirectaKit

@Suite struct DaemonRestartBurstCounterTests {
    private func event(_ at: Date, detail: String?, kind: EventKind = .crashed) -> EventRecord {
        EventRecord(at: at, detail: detail, kind: kind, project: "/p", server: "web")
    }

    @Test func emptyInputAnswersZero() {
        #expect(DaemonRestartBurstCounter.count(events: [], window: 86_400, now: Date()) == 0)
    }

    @Test func aSingleRestartCountsOne() {
        let now = Date()
        let events = [event(now.addingTimeInterval(-10), detail: "daemon-restart")]
        #expect(DaemonRestartBurstCounter.count(events: events, window: 86_400, now: now) == 1)
    }

    /** One restart of three resumed servers posts three near-simultaneous
        events (bounce, bounce, adopt); they must collapse to the one restart
        that produced them, not be counted per server. */
    @Test func clusteredEventsCollapseToOneBurst() {
        let now = Date()
        let base = now.addingTimeInterval(-30)
        let events = [
            event(base, detail: "daemon-restart"),
            event(base.addingTimeInterval(1), detail: "daemon-restart: orphan pid 12 bounced"),
            event(base.addingTimeInterval(2), detail: "adopted pid 34 across daemon-restart", kind: .started),
        ]
        #expect(DaemonRestartBurstCounter.count(events: events, window: 86_400, now: now) == 1)
    }

    /** Two restarts well apart, each bouncing one server, count as two bursts. */
    @Test func widelySeparatedEventsCountAsSeparateBursts() {
        let now = Date()
        let events = [
            event(now.addingTimeInterval(-3600), detail: "daemon-restart"),
            event(now.addingTimeInterval(-10), detail: "daemon-restart"),
        ]
        #expect(DaemonRestartBurstCounter.count(events: events, window: 86_400, now: now) == 2)
    }

    @Test func eventsOutsideTheWindowAreExcluded() {
        let now = Date()
        let events = [
            event(now.addingTimeInterval(-90_000), detail: "daemon-restart"),
            event(now.addingTimeInterval(-100), detail: "daemon-restart"),
        ]
        #expect(DaemonRestartBurstCounter.count(events: events, window: 86_400, now: now) == 1)
    }

    @Test func nonRestartEventsAreIgnored() {
        let now = Date()
        let events = [
            event(now.addingTimeInterval(-10), detail: "code=1", kind: .crashed),
            event(now.addingTimeInterval(-9), detail: nil, kind: .started),
        ]
        #expect(DaemonRestartBurstCounter.count(events: events, window: 86_400, now: now) == 0)
    }

    /** A watch-change detail names an arbitrary project file path, which can
        legitimately contain the literal substring "daemon-restart" as a
        directory or file name. A bare `contains` used to count it as a
        restart burst; the anchored `DaemonRestartDetail.matches` must not. */
    @Test func aWatchChangeDetailContainingTheSubstringIsNotMisread() {
        let now = Date()
        let events = [
            event(
                now.addingTimeInterval(-10), detail: "watch change in configs/daemon-restart/app.json",
                kind: .crashed)
        ]
        #expect(DaemonRestartBurstCounter.count(events: events, window: 86_400, now: now) == 0)
    }

    @Test func unsortedInputIsStillClusteredCorrectly() {
        let now = Date()
        let base = now.addingTimeInterval(-3600)
        /** Deliberately out of chronological order: the helper must sort
            before clustering rather than relying on caller order. */
        let events = [
            event(base.addingTimeInterval(3), detail: "daemon-restart"),
            event(base, detail: "daemon-restart"),
            event(base.addingTimeInterval(1), detail: "daemon-restart"),
        ]
        #expect(DaemonRestartBurstCounter.count(events: events, window: 86_400, now: now) == 1)
    }
}
