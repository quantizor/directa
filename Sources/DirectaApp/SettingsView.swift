import AppKit
import DirectaKit
import ServiceManagement
import SwiftUI

/** Whether the app checks for a newer release in the background. Read by the
    update poll and toggled in Settings; defaults on. */
enum UpdatePreference {
    static let key = "check for updates"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func set(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/** The Settings window, opened from the gear at the bottom of the popover. Holds
    the path back to agent hooks after first run, the login item, the update
    preference, and uninstall. Hook state and actions go through the CLI: the app
    links DirectaKit but not the CLI target, and directa never edits a harness's
    settings without a deliberate click here. */
struct SettingsView: View {
    @State private var offers: [HarnessOffer] = []
    @State private var busyHarness: String?
    @State private var hookError: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var checkForUpdates = UpdatePreference.enabled
    @State private var confirmingUninstall = false

    private var owner: CLIOwner { SetupPlanner.cliOwner() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hooksSection
                Divider()
                generalSection
                Divider()
                uninstallSection
            }
            .padding(20)
        }
        .frame(width: 460)
        .onAppear {
            AppFocus.promote()
            refreshOffers()
        }
    }

    // MARK: Hooks

    private var hooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Agent hooks")
            Text(
                "directa feeds each session the project's server status. Turn a harness's hook on or off; directa only edits these files when you click."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if offers.isEmpty {
                Text("No supported agent harnesses detected on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(offers, id: \.harness) { offer in
                    HStack(spacing: 10) {
                        Text(offer.displayName)
                            .font(.callout)
                        Spacer(minLength: 8)
                        if busyHarness == offer.harness {
                            ProgressView().controlSize(.small)
                        } else if offer.alreadyInstalled {
                            Button("Remove") { toggleHook(offer, install: false) }
                                .controlSize(.small)
                        } else {
                            Button("Install") { toggleHook(offer, install: true) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            if let hookError {
                Text(hookError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("General")
            Toggle("Start at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, wanted in
                    do {
                        if wanted {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Check for updates in the background", isOn: $checkForUpdates)
                .toggleStyle(.checkbox)
                .onChange(of: checkForUpdates) { _, wanted in
                    UpdatePreference.set(wanted)
                }
        }
    }

    // MARK: Uninstall

    private var uninstallSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Uninstall")
            if owner.isHomebrew {
                Text(
                    "This copy is managed by Homebrew. Remove it, its hooks, and its data with:"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(DirectaDistribution.brewUninstallCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Uninstall in Terminal…") {
                    TerminalRunner.run(
                        title: "directa uninstall", command: DirectaDistribution.brewUninstallCommand)
                }
                .controlSize(.small)
            } else {
                Text(
                    "Removes the background agent, Start at Login, agent hooks, and the CLI, then moves this app to the Trash. Running servers keep going; your data is kept."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Uninstall directa…", role: .destructive) {
                    confirmingUninstall = true
                }
                .controlSize(.small)
                .confirmationDialog(
                    "Uninstall directa?", isPresented: $confirmingUninstall, titleVisibility: .visible
                ) {
                    Button("Uninstall", role: .destructive) { performLocalUninstall() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "This removes the agent, Start at Login, hooks, and CLI and moves directa.app to the Trash. Your data is kept unless you remove it by hand."
                    )
                }
            }
        }
    }

    // MARK: Actions

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    private func refreshOffers() {
        let cliPath = owner.cliPath.path
        Task { @MainActor in
            offers = await Task.detached(priority: .userInitiated) {
                SetupPlanner.harnessOffers(installedCLIPath: cliPath)
            }.value
        }
    }

    /** Runs the bundled CLI for the hook action, recording the owner's CLI path
        so a brew install points hooks at the stable shim rather than the internal
        bundle path the CLI would otherwise resolve to. */
    private func toggleHook(_ offer: HarnessOffer, install: Bool) {
        guard let cli = SetupPerformer.resourceURLs()?.cli else {
            hookError = "This copy of directa.app is missing its bundled CLI."
            return
        }
        busyHarness = offer.harness
        hookError = nil
        let recordPath = owner.cliPath.path
        let harness = offer.harness
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                install
                    ? LaunchdAdmin.shell(
                        cli.path,
                        ["hook", "install", "--harness", harness, "--cli-path", recordPath])
                    : LaunchdAdmin.shell(cli.path, ["hook", "uninstall", "--harness", harness])
            }.value
            if result.status != 0 {
                hookError = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            busyHarness = nil
            refreshOffers()
        }
    }

    /** Non-Homebrew uninstall: drop launch items in-process (this is already
        the hosting app), then shell the CLI for hooks and binaries, then move
        this bundle to the Trash and quit. A running bundle can be trashed
        because the process holds the inode. */
    private func performLocalUninstall() {
        guard let cli = SetupPerformer.resourceURLs()?.cli else {
            hookError = "This copy of directa.app is missing its bundled CLI."
            return
        }
        Task { @MainActor in
            _ = await Task.detached(priority: .userInitiated) {
                try? await AgentService.unregisterAllLaunchItems()
                LaunchdAdmin.shell(cli.path, ["uninstall"])
            }.value
            try? FileManager.default.trashItem(
                at: Bundle.main.bundleURL, resultingItemURL: nil)
            NSApp.terminate(nil)
        }
    }
}
