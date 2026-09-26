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
        /** Register the agent, then migrate off the legacy login item only
            when `retiresLegacyLoginItem` says the agent now carries the
            user's choice. */
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
        registered next to it, and an agent waiting on approval beside a kept
        legacy item registers again. `requiresApproval` alone records nothing,
        so the next launch decides again once the user answers the approval
        prompt. */
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

    /** After a `.register` launch action, whether the legacy login item may
        be unregistered, read from the agent's status once registration has
        run. Only `enabled` retires it. An agent waiting on approval starts
        nothing at login until the user allows it in System Settings, so
        retiring the legacy item then would silently turn Start at login off.
        Any status but `enabled` keeps the legacy item, so the user keeps
        Start at login and the next launch reads it on and retries. */
    public static func retiresLegacyLoginItem(agentStatusAfterRegister: AgentStatus) -> Bool {
        switch agentStatusAfterRegister {
        case .enabled: true
        case .notFound, .notRegistered, .requiresApproval, .unknown: false
        }
    }

    /** Whether anything starts the app at login, which is what the Settings
        toggle shows. A legacy item still enabled means a registration has not
        taken over yet, and it still starts the app. An agent waiting on
        approval starts nothing until the user allows it. */
    public static func startsAtLogin(agentStatus: AgentStatus, legacyLoginItemEnabled: Bool) -> Bool {
        agentStatus == .enabled || legacyLoginItemEnabled
    }
}
