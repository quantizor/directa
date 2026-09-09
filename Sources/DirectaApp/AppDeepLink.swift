import AppKit
import DirectaKit
import Foundation
import UserNotifications

/** AppKit / UserNotifications side effects for `DeepLinkRunner`. */
struct AppDeepLinkEffects: DeepLinkEffects {
    func copyToPasteboard(_ text: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "directa-deeplink-\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func openBrowser(_ url: URL) async {
        /** Best effort: a browser that refuses to open is not worth failing the
            deep link over, and the caller has no recovery for it either. */
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}

/** Shared deep-link dispatch used by URL opens and notification actions. */
enum AppDeepLinkDispatch {
    static let serverAlertCategory = "dev.quantizor.directa.server-alert"
    static let userInfoProject = "project"
    static let userInfoServer = "server"
    static let userInfoHead = "head"

    static func run(_ url: URL) {
        if isDaemonControl(url) {
            Task { await executeDaemonControl(url) }
            return
        }
        switch DeepLink.parse(url: url) {
        case .failure(let error):
            DirectaLog.deeplink.error("reject \(error.message)")
            Task {
                await AppDeepLinkEffects().notify(title: "directa link failed", body: error.message)
            }
        case .success(let link):
            Task { await execute(link) }
        }
    }

    /** `directa://daemon/ensure`, `unregister`, and `unregister-all`: CLI asks the
        app to own SMAppService registration (correct Bundle.main). */
    private static func isDaemonControl(_ url: URL) -> Bool {
        DaemonControlAction.parse(url: url) != nil
    }

    private static func executeDaemonControl(_ url: URL) async {
        guard let action = DaemonControlAction.parse(url: url) else { return }
        /** The volume installer shares this bundle id. A daemon-control URL that
            lands here cannot unregister the Applications-owned SMAppService
            agent (`Bundle.main` is the DMG copy, and status reads notRegistered).
            Forward by path so the owner handles it. */
        if SetupPerformer.runningFromMountedVolume(), LaunchdAdmin.applicationsAppPresent() {
            await SetupPerformer.requestApplicationsDaemonControl(action)
            return
        }
        do {
            switch action {
            case .ensure:
                try await AgentService.ensureRunning()
                DirectaLog.app.info("deeplink daemon/ensure ok")
            case .unregister:
                try await AgentService.unregister()
                DirectaLog.app.info("deeplink daemon/unregister ok")
            case .unregisterAll:
                try await AgentService.unregisterAllLaunchItems()
                SpotlightIndexer.deleteAll()
                DirectaLog.app.info("deeplink daemon/unregister-all ok")
            }
        } catch {
            DirectaLog.app.error("deeplink daemon/\(action.rawValue): \(error.localizedDescription)")
            await AppDeepLinkEffects().notify(
                title: "directa daemon control failed", body: error.localizedDescription)
        }
    }

    static func run(_ link: DeepLink) {
        Task { await execute(link) }
    }

    private static func execute(_ link: DeepLink) async {
        let client = AppDaemon.client
        do {
            try await client.connect()
            let result = try await DeepLinkRunner(client: client, effects: AppDeepLinkEffects()).run(link)
            DirectaLog.app.info(
                "deeplink \(result.verb.rawValue) \(result.projectPath) \(result.detail ?? "")")
        } catch let error as WireError {
            DirectaLog.deeplink.error("\(error.message)")
            await AppDeepLinkEffects().notify(title: "directa link failed", body: error.message)
        } catch {
            DirectaLog.deeplink.error("\(error)")
            await AppDeepLinkEffects().notify(title: "directa link failed", body: String(describing: error))
        }
    }

    /** Register Open / Why actions once at launch. */
    static func registerNotificationCategories() {
        let open = UNNotificationAction(
            identifier: DeepLinkNotificationAction.open.rawValue, title: "Open")
        let why = UNNotificationAction(
            identifier: DeepLinkNotificationAction.why.rawValue, title: "Why")
        let category = UNNotificationCategory(
            identifier: serverAlertCategory, actions: [open, why], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
