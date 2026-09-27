import Darwin
import Foundation

/** Formats and recognizes the `daemon-restart` event-detail marker
    `ControlServer`'s bounce and adopt paths stamp on an event when a daemon
    restart, not a real crash, reset a server. Shared by every writer and
    reader so a watch-change detail (`"watch change in <path>"`,
    `"watch suspended: <paths>"`) that happens to embed the literal substring
    "daemon-restart" in a project's own file path is never misread as one:
    `matches` checks the marker's exact position in each of the three shapes
    the writers produce, never a bare `contains`. */
public enum DaemonRestartDetail {
    private static let marker = "daemon-restart"

    /** `ControlServer.recoverAtStartup`'s crash marker for a resumed server
        that was already down at boot (no live pid to adopt or bounce). */
    public static let crashed = marker

    /** `ControlServer.bounceOrphan`'s crash marker: the same daemon-restart
        crash, naming the orphan pid it had to signal down. */
    public static func orphanBounced(pid: pid_t) -> String {
        "\(marker): orphan pid \(pid) bounced"
    }

    /** `ServerSupervisor.adopt`'s started-event marker: a live child a prior
        daemon spawned, re-attached across this restart instead of bounced. */
    public static func adopted(pid: pid_t) -> String {
        "adopted pid \(pid) across \(marker)"
    }

    /** True for exactly the three shapes above, never a detail that merely
        contains the marker text somewhere in the middle (a watched path
        component literally named "daemon-restart", for instance). */
    public static func matches(_ detail: String) -> Bool {
        detail == crashed
            || isPid(detail, between: "\(marker): orphan pid ", and: " bounced")
            || isPid(detail, between: "adopted pid ", and: " across \(marker)")
    }

    private static func isPid(_ detail: String, between prefix: String, and suffix: String) -> Bool {
        guard detail.hasPrefix(prefix), detail.hasSuffix(suffix),
            detail.count > prefix.count + suffix.count
        else { return false }
        return pid_t(detail.dropFirst(prefix.count).dropLast(suffix.count)) != nil
    }
}

/** Formats and recognizes the `signal=N (external)` marker `ServerSupervisor`
    writes on a `.stopped` event's detail for a graceful signal (SIGTERM,
    SIGINT, SIGHUP) it did not itself request. Shared by the writer and every
    reader (`Why.swift`) so a watch-change detail naming a path that happens
    to contain the literal substring "(external)" is never misread as one:
    `matches` requires the whole detail to be "signal=" followed by digits and
    the exact " (external)" suffix, never a bare `contains`. */
public enum ExternalSignalDetail {
    public static func format(signal: Int) -> String {
        "signal=\(signal) (external)"
    }

    public static func matches(_ detail: String) -> Bool {
        let suffix = " (external)"
        guard detail.hasSuffix(suffix) else { return false }
        let prefix = detail.dropLast(suffix.count)
        guard prefix.hasPrefix("signal=") else { return false }
        return Int(prefix.dropFirst("signal=".count)) != nil
    }
}
