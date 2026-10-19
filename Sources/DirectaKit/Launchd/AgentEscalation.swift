import Foundation

/** Why the app is about to unregister and register the daemon's agent again.
    Each reason is logged at error level, with the last hello poll's error and
    whether launchd had the job loaded, because macOS persists error level and
    drops info: a restart nobody asked for stays diagnosable afterward. */
public enum AgentEscalation: Equatable, Sendable {
    /** The agent is enabled, yet launchd has no job for it. */
    case notLoaded
    /** The first start after a replaced app never answered. */
    case spawnMissedAfterReplace
    /** The agent stayed silent after a replaced app, so the in-place repair
        launchd would try is skipped. */
    case silentAfterReplace
    /** The agent stayed silent past launchd's throttle window. */
    case silentAfterThrottle
    /** The running daemon predates this app. */
    case staleDaemon(running: String, app: String)
    /** The installer replaced the helper and plist inside the bundle. */
    case upgradeInstall

    public var reason: String {
        switch self {
        case .notLoaded:
            "the agent is enabled but launchd has not loaded its job"
        case .spawnMissedAfterReplace:
            "the first start after the app was replaced did not answer"
        case .silentAfterReplace:
            "the agent is still silent after the app was replaced"
        case .silentAfterThrottle:
            "the agent is still silent after launchd's throttle window"
        case .staleDaemon(let running, let app):
            "the running daemon is v\(running) and this app is v\(app)"
        case .upgradeInstall:
            "the installer is upgrading the agent's helper"
        }
    }

    /** The one error-level line. `pollError` is the last hello poll's failure
        (nil when no poll was made); `loaded` is launchd's answer (nil when it
        was not asked). */
    public func logLine(loaded: Bool?, pollError: String?) -> String {
        let state = loaded.map { $0 ? "yes" : "no" } ?? "unknown"
        return
            "re-registering the daemon's background agent: \(reason). Last hello poll: \(pollError ?? "none was made"). launchd job loaded: \(state)."
    }
}
