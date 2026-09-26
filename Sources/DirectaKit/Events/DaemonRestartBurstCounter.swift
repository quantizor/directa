import Foundation

/** Collapses daemon-restart events into bursts: one restart posts one event per
    server that was bounced or adopted, all within moments of each other, and
    doctor's jetsam finding wants restarts counted, not events. Pure and
    tested; `directa doctor` is the one caller. */
public enum DaemonRestartBurstCounter {
    /** Seconds within which consecutive daemon-restart events collapse into a
        single burst. */
    private static let clusterSeconds: TimeInterval = 5

    /** Counts daemon-restart bursts among `events` in the `window` seconds
        before `now`. A daemon-restart event is any whose `detail` matches
        `DaemonRestartDetail` (`ControlServer`'s bounce and adopt paths both
        stamp one of its shapes, whichever server posted it), an exact
        anchored check rather than a bare `contains`, so a watch-change detail
        naming a path that happens to contain the literal substring
        "daemon-restart" is never counted; everything else is ignored.
        Consecutive matches less than `clusterSeconds` apart collapse into one
        burst, since a restart that bounces or adopts several servers posts one
        event per server. */
    public static func count(events: [EventRecord], window: TimeInterval, now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-window)
        let restarts = events
            .filter { event in
                guard let detail = event.detail, DaemonRestartDetail.matches(detail) else {
                    return false
                }
                return event.at >= cutoff && event.at <= now
            }
            .sorted { $0.at < $1.at }
        guard var previous = restarts.first?.at else { return 0 }
        var bursts = 1
        for event in restarts.dropFirst() {
            if event.at.timeIntervalSince(previous) > clusterSeconds {
                bursts += 1
            }
            previous = event.at
        }
        return bursts
    }
}
