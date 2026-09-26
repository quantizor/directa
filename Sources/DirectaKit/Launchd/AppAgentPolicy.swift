import Foundation

/** Decide what app launch does about the app's own KeepAlive LaunchAgent
    (`dev.quantizor.directa.app`), the "Start at login" that also relaunches
    the app after a TAL idle-cull or a jetsam kill. Start at login is opt-in:
    a launch registers only to carry forward a legacy login item that was
    already on. Pure so the decision is testable without SMAppService or a
    bundle. */
public enum AppAgentPolicy {
    /** Mirrors the `SMAppService.Status` cases so tests never touch Service
        Management. `unknown` stands for a case a future macOS adds and
        always leaves everything alone, a legacy login item included. */
    public enum AgentStatus: Equatable, Sendable {
        case enabled
        case notFound
        case notRegistered
        case requiresApproval
        case unknown
    }

    /** A Bool cannot tell "do nothing" from "record off", and only the
        latter writes the marker. */
    public enum LaunchAction: Equatable, Sendable {
        /** Touch nothing: no migration, no registration, no marker. */
        case leaveAlone
        /** Write the off marker. Service Management reads `notRegistered`
            both for a user who never turned the legacy login item on and for
            one who turned it off, so both are recorded as off. */
        case recordOff
        /** Migrate off the legacy login item, then register the agent. */
        case register
    }

    /** `bundleHasPlist` false means this copy predates the in-bundle app
        LaunchAgent (an old install, or a build without `make app`), so there
        is nothing to register. `runningOutsideApplications` true means this
        is the volume/DMG copy or a Downloads copy: registering from there
        races the relocate handoff (SetupPerformer.quitIfTwinIsRunning,
        AppInstancePolicy) and can bind BTM to the wrong path, the guard the
        daemon agent already applies. `legacyLoginItemEnabled` must be read
        before any migration runs, since migrating unregisters that item.
        `legacyLoginItemEnabled` wins over `agentStatus`: an agent already
        enabled beside a legacy item still migrates, or the legacy item stays
        registered next to it. `requiresApproval` records nothing, so the next
        launch decides again once the user answers the approval prompt. */
    public static func launchAction(
        agentStatus: AgentStatus,
        bundleHasPlist: Bool,
        legacyLoginItemEnabled: Bool,
        markerPresent: Bool,
        runningOutsideApplications: Bool
    ) -> LaunchAction {
        guard bundleHasPlist, !runningOutsideApplications, !markerPresent else { return .leaveAlone }
        switch agentStatus {
        case .unknown: return .leaveAlone
        case _ where legacyLoginItemEnabled: return .register
        case .enabled, .requiresApproval: return .leaveAlone
        case .notFound, .notRegistered: return .recordOff
        }
    }
}
