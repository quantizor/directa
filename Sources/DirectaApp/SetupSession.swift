import AppKit
import DirectaKit
import Observation
import SwiftUI

/** Shared first-run / upgrade gate evaluated once at launch. */
@Observable
final class SetupSession {
    var cliOwnedByBrew = false
    var installAppToApplications = false
    var migration = false
    var offers: [HarnessOffer] = []
    var pathWarning = false
    var replacingApplicationsApp = false
    var shouldPresent = false

    /** The cheap presentation decision (which panel, what to offer). Run off the
        main thread because it reads files and shells `directa --version`, then
        published on the MainActor. */
    func evaluate() async {
        let eval = await Task.detached(priority: .userInitiated) {
            SetupPerformer.evaluatePresentation()
        }.value
        cliOwnedByBrew = eval.cliOwnedByBrew
        installAppToApplications = eval.installAppToApplications
        migration = eval.migration
        offers = eval.offers
        replacingApplicationsApp = eval.replacingApplicationsApp
        shouldPresent = eval.shouldPresent
    }

    /** The PATH warning, sourced separately because it spawns a login shell that
        sources `.zshrc` under a 12s ceiling. Running it on the main thread froze
        launch; instead the panel opens on `evaluate()` and this fills the warning
        label in when the probe returns. */
    func refreshPathWarning() async {
        pathWarning = await Task.detached(priority: .userInitiated) {
            SetupPerformer.evaluatePathWarning()
        }.value
    }
}

/** Opens the setup window from a view that has `openWindow` (the menu bar label). */
struct SetupWindowOpener: View {
    @Environment(\.openWindow) private var openWindow
    var session: SetupSession
    @State private var didStart = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard !didStart else { return }
                didStart = true
                /** The volume/DMG copy hides its menu bar item but the label
                    still renders, so this opener still runs. It presents setup
                    through its own delegate-hosted window instead, so opening the
                    SwiftUI setup window here too would show two dialogs. */
                guard !SetupPerformer.runningFromMountedVolume() else { return }
                Task { @MainActor in
                    await session.evaluate()
                    guard session.shouldPresent else { return }
                    AppFocus.promote()
                    openWindow(id: "setup")
                    await session.refreshPathWarning()
                }
            }
    }
}

/** Close the setup SwiftUI window by id. */
enum SetupWindowCloser {
    static func close() {
        for window in NSApp.windows where window.identifier?.rawValue == "setup" {
            window.close()
        }
    }
}
