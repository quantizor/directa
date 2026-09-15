import Foundation

/** Decide whether app launch should register the app's own KeepAlive
    LaunchAgent (`dev.quantizor.directa.app`): the fix for a login item that
    does not relaunch mid-session after a TAL idle-cull or a jetsam kill. Pure
    so the decision is testable without SMAppService or a bundle. */
public enum AppAgentPolicy {
    /** `bundleHasPlist` false means this copy predates the in-bundle app
        LaunchAgent (an old install, or a build without `make app`), so there
        is nothing to register. `runningOutsideApplications` true means this
        is the volume/DMG copy or a Downloads copy: registering from there
        races the relocate handoff (SetupPerformer.quitIfTwinIsRunning,
        AppInstancePolicy) and can bind BTM to the wrong path, exactly the
        guard the daemon agent already applies. `deliberatelyDisabled` is the
        user's own "Start at login" off, recorded via a marker file so the
        default (marker absent) stays resilient without a toggle click. */
    public static func shouldRegisterAtLaunch(
        deliberatelyDisabled: Bool, runningOutsideApplications: Bool, bundleHasPlist: Bool
    ) -> Bool {
        guard bundleHasPlist, !runningOutsideApplications else { return false }
        return !deliberatelyDisabled
    }
}
