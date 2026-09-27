import DirectaKit
import Foundation
import ServiceManagement

/** SMAppService registration for the app's own in-bundle KeepAlive
    LaunchAgent (`dev.quantizor.directa.app`), the "Start at login" setting.
    Why an agent rather than a login item, and the opt-in rules
    `AppAgentPolicy` encodes: docs/macos-lifecycle.md, "Menu bar extra". */
enum AppAgentService {
    nonisolated static let agent = BundledAgent(plistName: "dev.quantizor.directa.app.plist")

    enum Failure: Error, LocalizedError, Sendable {
        case needsApproval

        var errorDescription: String? {
            switch self {
            case .needsApproval:
                "macOS is waiting for you to allow directa to start automatically. Turn on quantizor/directa in System Settings > General > Login Items & Extensions."
            }
        }
    }

    /** Register the agent and answer the status registration ended in,
        throwing `Failure.needsApproval` when that is `requiresApproval`. */
    @discardableResult
    nonisolated static func register() throws -> AppAgentPolicy.RegistrationStatus {
        let status = try agent.registerTolerant()
        if status == .requiresApproval {
            throw Failure.needsApproval
        }
        return status
    }

    /** Idempotent when never registered. A failure is logged, not thrown:
        every caller goes on to its next step either way. */
    nonisolated static func unregister() {
        let service = agent.service
        guard service.status != .notRegistered else { return }
        do {
            try service.unregister()
            DirectaLog.app.info("app agent unregistered")
        } catch {
            DirectaLog.app.error("app agent unregister: \(error.localizedDescription)")
        }
    }

    /** What the Settings toggle shows; see `AppAgentPolicy.startsAtLogin`. */
    nonisolated static var startsAtLogin: Bool {
        AppAgentPolicy.startsAtLogin(
            agentStatus: agent.status, legacyLoginItemEnabled: SMAppService.mainApp.status == .enabled)
    }

    /** Unregister the older `SMAppService.mainApp` login item in any state
        but `notRegistered`, `requiresApproval` included, since a login item
        waiting on approval would come back on the moment the user allowed
        it. A failure is logged, not thrown: a kept item is read again at the
        next launch, which retries this. */
    nonisolated static func retireLegacyLoginItem(because reason: String) {
        let item = SMAppService.mainApp
        guard item.status != .notRegistered else { return }
        do {
            try item.unregister()
            DirectaLog.app.info("Start at Login item unregistered: \(reason)")
        } catch {
            DirectaLog.app.error("Start at Login item unregister (\(reason)): \(error.localizedDescription)")
        }
    }

    /** Everything that starts the app at login: the older login item, then
        the app agent. Unregistering the agent terminates the job's running
        process, which is this one when launchd started it, so a caller
        with work left does that work first. */
    nonisolated static func removeAll(because reason: String) {
        retireLegacyLoginItem(because: reason)
        unregister()
    }

    /** At launch, act on `AppAgentPolicy.launchAction`. Every status is read
        once, before anything changes: the legacy item's read in particular
        must come before `retireLegacyLoginItem`, or it would always read off
        and record Off for someone who had Start at login on. Registration
        runs before that retirement, so a registration that does not end with
        the agent enabled keeps the legacy item. */
    nonisolated static func ensureRegisteredAtLaunch(paths: DirectaPaths = DirectaPaths()) {
        let action = AppAgentPolicy.launchAction(
            AppAgentPolicy.LaunchInputs(
                agentStatus: agent.status,
                bundleHasPlist: agent.bundleHasPlist,
                legacyLoginItemEnabled: SMAppService.mainApp.status == .enabled,
                markerPresent: FileManager.default.fileExists(atPath: paths.appAutostartDisabledFile.path),
                runningOutsideApplications: SetupPlanner.isRunningOutsideApplications(
                    bundlePath: Bundle.main.bundlePath)))
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
            let after: AppAgentPolicy.RegistrationStatus
            do {
                after = try agent.registerTolerant()
                DirectaLog.app.info("app agent register at launch: \(after)")
            } catch {
                after = agent.status
                DirectaLog.app.error("app agent register at launch: \(error.localizedDescription)")
            }
            if AppAgentPolicy.retiresLegacyLoginItem(agentStatusAfterRegister: after) {
                retireLegacyLoginItem(because: "the app agent now starts directa at login")
            } else {
                DirectaLog.app.error(
                    "app agent register at launch left the agent \(after); kept the Start at Login item so the next launch retries"
                )
            }
        }
    }

    /** Settings toggle Off: record the marker first so a later launch does
        not silently turn Start at login back on, then `removeAll`, since
        either the agent or a legacy item a registration kept would still
        start the app at login. */
    nonisolated static func disableAtUserRequest(paths: DirectaPaths = DirectaPaths()) {
        do {
            try AtomicFile.write(Data(), to: paths.appAutostartDisabledFile)
        } catch {
            DirectaLog.app.error(
                "Start at login off: could not record the choice at \(paths.appAutostartDisabledFile.path): \(error.localizedDescription)"
            )
        }
        removeAll(because: "Start at login turned off in Settings")
    }

    /** Settings toggle On: clear the marker, then register. A registration
        waiting on approval opens the Login Items pane, where the user
        answers it. */
    nonisolated static func enableAtUserRequest(paths: DirectaPaths = DirectaPaths()) throws {
        try? FileManager.default.removeItem(at: paths.appAutostartDisabledFile)
        do {
            try register()
        } catch Failure.needsApproval {
            SMAppService.openSystemSettingsLoginItems()
            throw Failure.needsApproval
        }
    }

    /** Apply a Settings toggle change and answer what the toggle should show
        afterward, with the error to display when the change did not take.
        Acts only when `wanted` differs from what starts the app at login
        right now, so the toggle's resync to a failed On never reaches the
        Off path and never records Off for someone who asked for On. */
    nonisolated static func applyUserChoice(
        _ wanted: Bool, paths: DirectaPaths = DirectaPaths()
    ) -> (error: String?, startsAtLogin: Bool) {
        guard wanted != startsAtLogin else { return (nil, wanted) }
        var failure: String?
        if wanted {
            do {
                try enableAtUserRequest(paths: paths)
            } catch {
                DirectaLog.app.error("Start at login on: \(error.localizedDescription)")
                failure = error.localizedDescription
            }
        } else {
            disableAtUserRequest(paths: paths)
        }
        return (failure, startsAtLogin)
    }
}
