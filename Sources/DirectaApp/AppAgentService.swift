import DirectaKit
import Foundation
import ServiceManagement

/** SMAppService registration for the app's own in-bundle KeepAlive LaunchAgent
    (`dev.quantizor.directa.app`), mirroring `AgentService`'s daemon-agent
    pattern but for the app process itself.

    The problem this closes: a plain `SMAppService.mainApp` login item has no
    KeepAlive, so Transparent Application Lifecycle idle-culling a windowless
    MenuBarExtra, or a memory-pressure jetsam pass in the login-item band
    (100), kills the app and it stays dead for the rest of the session. A
    `KeepAlive { SuccessfulExit: false }` LaunchAgent relaunches within
    launchd's throttle after an abnormal exit (a TAL cull or a jetsam SIGKILL,
    both non-zero/signaled), never after a deliberate Quit (`NSApp.terminate`
    exits 0), and runs in the daemon jetsam band (40) instead of 100, where
    it is far less likely to be chosen at all.

    Must run inside the app process, same as `AgentService`: `SMAppService`
    resolves the plist relative to `Bundle.main`. Nonisolated for the same
    reason. */
enum AppAgentService {
    nonisolated static let plistName = "dev.quantizor.directa.app.plist"

    enum Failure: Error, LocalizedError, Sendable {
        case missingPlist
        case needsApproval

        var errorDescription: String? {
            switch self {
            case .missingPlist:
                return
                    "This copy of directa.app is missing \(AppAgentService.plistName). Reinstall from the DMG or run make app."
            case .needsApproval:
                return
                    "macOS is waiting for you to allow directa to start automatically. Turn on quantizor/directa in System Settings > General > Login Items & Extensions."
            }
        }
    }

    private nonisolated static var agent: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    nonisolated static var status: SMAppService.Status { agent.status }

    nonisolated static var statusDescription: String {
        switch agent.status {
        case .enabled: "enabled"
        case .notFound: "not found"
        case .notRegistered: "not registered"
        case .requiresApproval: "requires approval"
        @unknown default: "unknown"
        }
    }

    /** True when this process ships the in-bundle app LaunchAgent plist. A
        copy built before this feature, or a debug build assembled without
        `make app`'s plist write, has none: registering then would throw on a
        plist `SMAppService` cannot find. */
    nonisolated static var bundleHasPlist: Bool {
        let url = Bundle.main.bundleURL
            .appending(path: "Contents/Library/LaunchAgents")
            .appending(path: plistName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /** Register the agent. Tolerates an already-registered job (registering
        twice throws), same idempotence guard as `AgentService.register`. */
    nonisolated static func register() throws {
        guard bundleHasPlist else { throw Failure.missingPlist }
        if agent.status != .enabled {
            do {
                try agent.register()
            } catch {
                if agent.status != .requiresApproval { throw error }
            }
        }
        if agent.status == .requiresApproval {
            throw Failure.needsApproval
        }
    }

    /** Idempotent when never registered. */
    nonisolated static func unregister() {
        guard agent.status != .notRegistered else { return }
        try? agent.unregister()
        DirectaLog.app.info("app agent unregistered")
    }

    /** Drop the pre-migration login item once. Best effort: `mainApp`'s own
        `unregister()` can throw for reasons that do not matter here (already
        gone, a transient Service Management error), and the app agent
        registration that follows is what actually matters going forward, so a
        failure here is not worth surfacing. Idempotent: a copy with no
        legacy item registered is a fast no-op status read. */
    nonisolated static func migrateFromLoginItem() {
        let item = SMAppService.mainApp
        guard item.status == .enabled else { return }
        try? item.unregister()
        DirectaLog.app.info("migrated off the Start at Login item to the app agent")
    }

    /** At launch: migrate off the legacy login item, then register the app
        agent unless the user deliberately turned it off, this copy predates
        the in-bundle plist, or this is the volume/DMG copy (registering
        there races the relocate handoff, the same guard
        `AgentService.ensureAtLaunchIfNeeded` applies to the daemon agent). */
    nonisolated static func ensureRegisteredAtLaunch(paths: DirectaPaths = DirectaPaths()) {
        migrateFromLoginItem()
        guard
            AppAgentPolicy.shouldRegisterAtLaunch(
                deliberatelyDisabled: FileManager.default.fileExists(
                    atPath: paths.appAutostartDisabledFile.path),
                runningOutsideApplications: SetupPlanner.isRunningOutsideApplications(
                    bundlePath: Bundle.main.bundlePath),
                bundleHasPlist: bundleHasPlist)
        else { return }
        do {
            try register()
            DirectaLog.app.info("app agent register at launch: \(statusDescription)")
        } catch {
            DirectaLog.app.error("app agent register at launch: \(error.localizedDescription)")
        }
    }

    /** Settings toggle Off: unregister and record the marker so a later
        launch does not silently turn it back on. */
    nonisolated static func disableAtUserRequest(paths: DirectaPaths = DirectaPaths()) {
        unregister()
        try? AtomicFile.write(Data(), to: paths.appAutostartDisabledFile)
    }

    /** Settings toggle On: clear the marker, then register. Throws exactly as
        `register()` does, so the caller can resync the toggle to the real
        status on failure the same way the pre-migration code did. */
    nonisolated static func enableAtUserRequest(paths: DirectaPaths = DirectaPaths()) throws {
        try? FileManager.default.removeItem(at: paths.appAutostartDisabledFile)
        try register()
    }
}
