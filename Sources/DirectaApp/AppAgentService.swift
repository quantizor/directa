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

    nonisolated static var policyStatus: AppAgentPolicy.AgentStatus {
        switch agent.status {
        case .enabled: .enabled
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        @unknown default: .unknown
        }
    }

    /** At launch, act on `AppAgentPolicy.launchAction`. The legacy login
        item's status is read before `migrateFromLoginItem()`, which
        unregisters it: a read after would always be false and record Off for
        someone who had Start at login on. */
    nonisolated static func ensureRegisteredAtLaunch(paths: DirectaPaths = DirectaPaths()) {
        let legacyLoginItemEnabled = SMAppService.mainApp.status == .enabled
        let action = AppAgentPolicy.launchAction(
            agentStatus: policyStatus,
            bundleHasPlist: bundleHasPlist,
            legacyLoginItemEnabled: legacyLoginItemEnabled,
            markerPresent: FileManager.default.fileExists(atPath: paths.appAutostartDisabledFile.path),
            runningOutsideApplications: SetupPlanner.isRunningOutsideApplications(
                bundlePath: Bundle.main.bundlePath))
        switch action {
        case .leaveAlone:
            return
        case .recordOff:
            do {
                try AtomicFile.write(Data(), to: paths.appAutostartDisabledFile)
                DirectaLog.app.info("app agent at launch: Start at login recorded off")
            } catch {
                DirectaLog.app.error(
                    "app agent at launch: could not record Start at login off at \(paths.appAutostartDisabledFile.path): \(error.localizedDescription)"
                )
            }
        case .register:
            migrateFromLoginItem()
            do {
                try register()
                DirectaLog.app.info("app agent register at launch: \(statusDescription)")
            } catch {
                DirectaLog.app.error("app agent register at launch: \(error.localizedDescription)")
            }
        }
    }

    /** Settings toggle Off: unregister and record the marker so a later
        launch does not silently turn it back on. */
    nonisolated static func disableAtUserRequest(paths: DirectaPaths = DirectaPaths()) {
        unregister()
        do {
            try AtomicFile.write(Data(), to: paths.appAutostartDisabledFile)
        } catch {
            DirectaLog.app.error(
                "Start at login off: could not record the choice at \(paths.appAutostartDisabledFile.path): \(error.localizedDescription)"
            )
        }
    }

    /** Settings toggle On: clear the marker, then register. Throws exactly as
        `register()` does, so the caller can resync the toggle to the real
        status on failure the same way the pre-migration code did. */
    nonisolated static func enableAtUserRequest(paths: DirectaPaths = DirectaPaths()) throws {
        try? FileManager.default.removeItem(at: paths.appAutostartDisabledFile)
        try register()
    }
}
