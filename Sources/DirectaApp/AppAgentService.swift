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

    /** Idempotent when never registered. A failure is logged, not thrown:
        every caller goes on to its next step either way. */
    nonisolated static func unregister() {
        guard agent.status != .notRegistered else { return }
        do {
            try agent.unregister()
            DirectaLog.app.info("app agent unregistered")
        } catch {
            DirectaLog.app.error("app agent unregister: \(error.localizedDescription)")
        }
    }

    nonisolated static var legacyLoginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /** What the Settings toggle shows; see `AppAgentPolicy.startsAtLogin`. */
    nonisolated static var startsAtLogin: Bool {
        AppAgentPolicy.startsAtLogin(agentStatus: policyStatus, legacyLoginItemEnabled: legacyLoginItemEnabled)
    }

    /** Unregister the pre-migration `SMAppService.mainApp` login item when it
        is enabled; a no-op status read otherwise. A failure is logged, not
        thrown: a kept legacy item is read again at the next launch, which
        retries this. */
    nonisolated static func unregisterLegacyLoginItem(because reason: String) {
        let item = SMAppService.mainApp
        guard item.status == .enabled else { return }
        do {
            try item.unregister()
            DirectaLog.app.info("Start at Login item unregistered: \(reason)")
        } catch {
            DirectaLog.app.error("Start at Login item unregister (\(reason)): \(error.localizedDescription)")
        }
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
        item's status is read before `unregisterLegacyLoginItem`: a read after
        would always be false and record Off for someone who had Start at
        login on. Registration runs before that unregister, so a registration
        that does not end with the agent enabled keeps the legacy item. */
    nonisolated static func ensureRegisteredAtLaunch(paths: DirectaPaths = DirectaPaths()) {
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
            do {
                try register()
                DirectaLog.app.info("app agent register at launch: \(statusDescription)")
            } catch {
                DirectaLog.app.error("app agent register at launch: \(error.localizedDescription)")
            }
            if AppAgentPolicy.retiresLegacyLoginItem(agentStatusAfterRegister: policyStatus) {
                unregisterLegacyLoginItem(because: "the app agent now starts directa at login")
            } else {
                DirectaLog.app.error(
                    "app agent register at launch left the agent \(statusDescription); kept the Start at Login item so the next launch retries"
                )
            }
        }
    }

    /** Settings toggle Off: unregister the agent and any legacy item a
        registration kept (either one alone would still start the app at
        login), then record the marker so a later launch does not silently
        turn it back on. */
    nonisolated static func disableAtUserRequest(paths: DirectaPaths = DirectaPaths()) {
        unregister()
        unregisterLegacyLoginItem(because: "Start at login turned off in Settings")
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
