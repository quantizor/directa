import DirectaKit
import SwiftUI

/** First-run / upgrade panel: clear checklist of what Confirm will do, then
    opt-in harness hooks (default checked when install is still needed). */
struct SetupPanel: View {
    let cliOwnedByBrew: Bool
    let installAppToApplications: Bool
    let migration: Bool
    let offers: [HarnessOffer]
    let pathWarning: Bool
    let replacingApplicationsApp: Bool
    var onFinished: () -> Void

    @State private var busy = false
    @State private var errorText: String?
    @State private var finishedSummary: String?
    @State private var selected: Set<String>
    @State private var willRelaunch = false

    init(
        cliOwnedByBrew: Bool,
        installAppToApplications: Bool,
        migration: Bool,
        offers: [HarnessOffer],
        pathWarning: Bool,
        replacingApplicationsApp: Bool,
        onFinished: @escaping () -> Void
    ) {
        self.cliOwnedByBrew = cliOwnedByBrew
        self.installAppToApplications = installAppToApplications
        self.migration = migration
        self.offers = offers
        self.pathWarning = pathWarning
        self.replacingApplicationsApp = replacingApplicationsApp
        self.onFinished = onFinished
        _selected = State(
            initialValue: Set(offers.filter(\.defaultChecked).map(\.harness)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(migration || replacingApplicationsApp ? "Upgrade directa" : "Install directa")
                .font(.title3.weight(.semibold))

            /** Only on a first install. Someone upgrading has been running this
                for a while and does not need to be told what it is. */
            if !(migration || replacingApplicationsApp) {
                Text("An agent-friendly coordinator for many devservers and their unique configurations.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Confirm to apply the changes below. Nothing runs until you confirm.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("This will:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if installAppToApplications {
                    bullet(
                        replacingApplicationsApp
                            ? "Quit the running menu bar app (if any), then replace /Applications/directa.app with this version"
                            : "Install the menu bar app at /Applications/directa.app")
                }
                /** Under a Homebrew install the cask owns the CLI symlink, so
                    directa neither installs nor updates it and says so instead. */
                if cliOwnedByBrew {
                    bullet("Leave the CLI to Homebrew (installed in brew's bin)")
                } else {
                    bullet(
                        migration
                            ? "Update the CLI at \(SetupPlanner.defaultCLIDirectory().path)"
                            : "Install the CLI at \(SetupPlanner.defaultCLIDirectory().path)")
                }
                bullet(
                    "Install or update the background daemon and restart it (your running servers stay)")
                if selected.isEmpty {
                    bullet("Leave agent hooks unchanged (none selected below)")
                } else {
                    let names = offers.filter { selected.contains($0.harness) }.map(\.displayName)
                    bullet("Install agent hooks for: \(names.joined(separator: ", "))")
                }
                if installAppToApplications {
                    bullet("Relaunch from Applications when finished")
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if pathWarning {
                Label(SetupPlanner.pathRemedy, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !offers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agent hooks (optional)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(offers, id: \.harness) { offer in
                        Toggle(isOn: binding(for: offer)) {
                            HStack(spacing: 6) {
                                Text("Install \(offer.displayName) hook")
                                if offer.alreadyInstalled {
                                    Text("already installed")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(busy || offer.alreadyInstalled)
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let finishedSummary {
                Text(finishedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if finishedSummary == nil {
                    Button(busy ? "Working…" : "Confirm") { runSetup() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                } else if willRelaunch {
                    Button("Relaunch from Applications") {
                        SetupPerformer.relaunchFromApplicationsAndQuit()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { onFinished() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .opacity(busy ? 0.7 : 1)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(for offer: HarnessOffer) -> Binding<Bool> {
        Binding(
            get: { selected.contains(offer.harness) },
            set: { on in
                if on { selected.insert(offer.harness) } else { selected.remove(offer.harness) }
            })
    }

    private func runSetup() {
        busy = true
        errorText = nil
        let harnesses = selected
        let relocate = installAppToApplications
        Task { @MainActor in
            if relocate {
                /** Drop the SMAppService registration while the on-disk helper
                    still matches BTM's CDHash. Replacing the ad-hoc signed
                    bundle first, then re-registering, is what produced the
                    Launch Constraint Violation crashes. */
                if replacingApplicationsApp {
                    /** Record the stand-down first so a recovery poll cannot
                        re-register while we wait for launchd to drop the job. */
                    try? AtomicFile.write(Data(), to: DirectaPaths().stoppedIntentFile)
                    await SetupPerformer.requestApplicationsDaemonControl(.unregister)
                    let unloaded = await LaunchdAdmin.waitUntilAgentUnloaded()
                    if !unloaded {
                        errorText =
                            "Could not stop the background agent before replacing the app. Quit quantizor/directa from Activity Monitor (or turn it off in Login Items), then try again."
                        busy = false
                        return
                    }
                    do {
                        try LaunchdAdmin.markAgentRebindNeeded()
                    } catch {
                        errorText =
                            "Could not prepare the daemon rebind marker: \(error.localizedDescription)"
                        busy = false
                        return
                    }
                    /** Unregister wrote stopped.intent; clear it so the
                        Applications copy is allowed to register after settle. */
                    try? FileManager.default.removeItem(at: DirectaPaths().stoppedIntentFile)
                }
                guard await SetupPerformer.quitOtherInstances() else {
                    errorText =
                        "Another copy of directa is still running, so replacing /Applications/directa.app would leave it running code that is no longer on disk. Quit quantizor/directa from Activity Monitor, then try again."
                    busy = false
                    return
                }
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await SetupPerformer.run(
                        selectedHarnesses: harnesses,
                        installAppToApplications: relocate)
                }.value
                let lines = result.notes + result.harnessSummaries
                let summary = lines.isEmpty ? "Setup complete." : lines.joined(separator: "\n")
                finishedSummary = summary
                willRelaunch = result.relocatedToApplications
                busy = false
                if result.relocatedToApplications {
                    /** Short beat so the summary is readable, then hand off. */
                    try? await Task.sleep(for: .milliseconds(600))
                    SetupPerformer.relaunchFromApplicationsAndQuit()
                }
            } catch {
                errorText = error.localizedDescription
                busy = false
            }
        }
    }
}
