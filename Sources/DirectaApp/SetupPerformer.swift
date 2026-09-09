import AppKit
import DirectaKit
import Foundation

/** Performs first-run / upgrade install from the app bundle Resources. Copies
    the app into /Applications when needed, installs CLI + daemon, then optional
    harness hooks. File I/O is nonisolated; quitting peers / relaunch is MainActor. */
enum SetupPerformer: Sendable {
    static let appBundleIdentifier = "dev.quantizor.directa.app"

    struct Result: Sendable {
        var cliOnPATH: Bool
        var harnessSummaries: [String]
        var migration: Bool
        var notes: [String]
        var relocatedToApplications: Bool
    }

    struct Presentation: Sendable {
        var cliOwnedByBrew: Bool
        var installAppToApplications: Bool
        var migration: Bool
        var offers: [HarnessOffer]
        var replacingApplicationsApp: Bool
        var shouldPresent: Bool
    }

    enum Failure: Error, LocalizedError, Sendable {
        case missingResources
        case commandFailed(command: String, status: Int32, output: String)
        case appInstallFailed(String)
        case agentRegisterFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingResources:
                return "This copy of directa.app is missing its bundled CLI and daemon. Reinstall from the DMG or run make app."
            case .commandFailed(let command, let status, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return "\(command) failed (exit \(status))."
                }
                return "\(command) failed (exit \(status)): \(detail)"
            case .appInstallFailed(let message):
                return message
            case .agentRegisterFailed(let message):
                return message
            }
        }
    }

    nonisolated static func resourceURLs(bundle: Bundle = .main) -> (cli: URL, daemon: URL)? {
        guard let cli = bundle.url(forResource: SetupPlanner.cliBinaryName, withExtension: nil),
            let daemon = bundle.url(forResource: SetupPlanner.daemonBinaryName, withExtension: nil),
            FileManager.default.isExecutableFile(atPath: cli.path),
            FileManager.default.isExecutableFile(atPath: daemon.path)
        else { return nil }
        return (cli, daemon)
    }

    nonisolated static func bundledVersion(bundle: Bundle = .main) -> String {
        if let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            !short.isEmpty
        {
            return short
        }
        return DirectaVersion.version
    }

    nonisolated static func evaluatePresentation(
        bundle: Bundle = .main, paths: DirectaPaths = DirectaPaths()
    ) -> Presentation {
        let resources = resourceURLs(bundle: bundle) != nil
        let bundled = bundledVersion(bundle: bundle)
        let owner = SetupPlanner.cliOwner(bundle: bundle)
        /** Read the installed version from the path this owner actually uses, so
            an absent `~/.local/bin/directa` under a brew install does not read as
            "never installed" and force the panel open on every launch. */
        let cliURL = owner.cliPath
        let installedVersion = readCLIVersion(at: cliURL)
        let stamp = SetupPlanner.readStamp(at: SetupPlanner.stampURL(paths: paths))
        let outside = SetupPlanner.isRunningOutsideApplications(
            bundlePath: bundle.bundleURL.path)
        let should = SetupPlanner.shouldPresent(
            bundledVersion: bundled,
            installedCLIVersion: installedVersion,
            stampVersion: stamp,
            resourcesPresent: resources,
            runningOutsideApplications: outside)
        let migration = SetupPlanner.isMigration(
            installedCLIExists: FileManager.default.isExecutableFile(atPath: cliURL.path),
            stampExists: stamp != nil,
            launchAgentExists: FileManager.default.fileExists(
                atPath: LaunchdAdmin.plistURL.path))
        let offers = SetupPlanner.harnessOffers(installedCLIPath: cliURL.path)
        return Presentation(
            cliOwnedByBrew: owner.isHomebrew,
            installAppToApplications: outside,
            migration: migration,
            offers: offers,
            replacingApplicationsApp: outside && LaunchdAdmin.applicationsAppPresent(),
            shouldPresent: should)
    }

    /** Whether to warn that the CLI directory is off the user's PATH. Split from
        `evaluatePresentation` because it sources the login shell (up to a 12s
        ceiling) and must never run on the main thread; the panel fills this in
        after it opens. Owner-aware: brew's bin is on PATH via `brew shellenv`, so
        a brew-owned CLI never warrants the warning. */
    nonisolated static func evaluatePathWarning() -> Bool {
        !SetupPlanner.cliDirectoryOnUserPATH(owner: SetupPlanner.cliOwner())
    }

    /** Install app (when needed), CLI, register the SMAppService agent from
        this process when the bundle can host it, then checked hooks.
        Call `quitOtherInstances` on the MainActor before this when relocating. */
    nonisolated static func run(
        selectedHarnesses: Set<String>,
        installAppToApplications: Bool,
        bundle: Bundle = .main
    ) async throws -> Result {
        guard let resources = resourceURLs(bundle: bundle) else { throw Failure.missingResources }
        let paths = DirectaPaths()
        let owner = SetupPlanner.cliOwner(bundle: bundle)
        /** The CLI to drive for hook install and to record in the hook command.
            Under brew this is the shim in brew's bin, which is on PATH and
            survives upgrades; under a DMG install it is `~/.local/bin/directa`. */
        let cliDest = owner.cliPath
        let daemonSibling = SetupPlanner.installedDaemonSiblingURL()
        let fm = FileManager.default
        let migration = SetupPlanner.isMigration(
            installedCLIExists: fm.isExecutableFile(atPath: cliDest.path),
            stampExists: SetupPlanner.readStamp(at: SetupPlanner.stampURL(paths: paths)) != nil,
            launchAgentExists: fm.fileExists(atPath: LaunchdAdmin.plistURL.path))

        var notes: [String] = []
        var relocated = false

        /** Running setup is intent to run the daemon, so a leftover
            deliberate-stop marker from an earlier `daemon stop` / uninstall must
            not suppress registration (in the relocated case the Applications
            copy reads this marker at launch, long after this process is gone). */
        try? fm.removeItem(at: paths.stoppedIntentFile)

        if installAppToApplications {
            let destination = URL(fileURLWithPath: SetupPlanner.applicationsAppPath)
            let replacing = fm.fileExists(atPath: destination.path)
            do {
                try SetupPlanner.installAppBundle(from: bundle.bundleURL, to: destination)
            } catch {
                throw Failure.appInstallFailed(
                    "Could not place the app at \(destination.path): \(error.localizedDescription). Quit any open copy of directa and try again.")
            }
            relocated = true
            notes.append(
                replacing
                    ? "Updated the menu bar app at \(destination.path)."
                    : "Installed the menu bar app at \(destination.path).")
        }

        if migration {
            notes.append("Migrating the existing CLI and daemon to this version.")
        }

        /** Homebrew owns the CLI symlink in its bin and the daemon runs from the
            bundle's `Contents/Helpers/ddirecta` under SMAppService, so installing a
            second copy to `~/.local/bin` would only orphan it on cask uninstall. */
        if owner.isHomebrew {
            notes.append("CLI managed by Homebrew at \(cliDest.path)")
        } else {
            try SetupPlanner.installBinary(from: resources.cli, to: cliDest)
            try SetupPlanner.installBinary(from: resources.daemon, to: daemonSibling)
            notes.append("Installed CLI to \(cliDest.path)")
        }

        /** SMAppService must run with Bundle.main as the hosting app. After a
            relocate, the Applications copy registers on launch; otherwise do it
            here (and reregister on upgrade so the helper/plist swap sticks). */
        if !relocated {
            do {
                if migration {
                    try await AgentService.reregister()
                } else {
                    try AgentService.register()
                }
                try await LaunchdAdmin.pollHello(paths: paths, timeoutSeconds: 8)
                notes.append("Daemon registered via Login Items.")
            } catch AgentService.Failure.needsApproval {
                /** Not a failed install: the job is registered and one switch
                    away from running, and Login Items is already open. */
                notes.append(AgentService.Failure.needsApproval.localizedDescription)
            } catch {
                throw Failure.agentRegisterFailed(
                    "Could not register the background agent: \(error.localizedDescription). Check System Settings > General > Login Items & Extensions.")
            }
        } else {
            notes.append(
                "The copy in Applications registers the daemon when it launches. If macOS asks, allow quantizor/directa in Login Items.")
        }

        var harnessSummaries: [String] = []
        for harness in selectedHarnesses.sorted() {
            /** `--cli-path` pins the command the hook records to this owner's
                CLI path. Without it the invoked CLI resolves its own symlink back
                into the bundle, so a brew install would record the internal
                Resources path instead of the stable shim in brew's bin. */
            let out = try runCLI(
                cliDest,
                arguments: ["hook", "install", "--harness", harness, "--cli-path", cliDest.path])
            harnessSummaries.append(out.isEmpty ? "Installed \(harness) hook" : out)
        }

        try SetupPlanner.writeStamp(
            version: bundledVersion(bundle: bundle), to: SetupPlanner.stampURL(paths: paths))

        /** Bound once: the login-shell PATH is captured by spawning a shell.
            Owner-aware, so a brew install (whose bin is already on PATH) does not
            print the `~/.local/bin` remedy. */
        let onPATH = SetupPlanner.cliDirectoryOnUserPATH(owner: owner)
        if !onPATH {
            notes.append(SetupPlanner.pathRemedy)
        }

        return Result(
            cliOnPATH: onPATH,
            harnessSummaries: harnessSummaries,
            migration: migration,
            notes: notes,
            relocatedToApplications: relocated)
    }

    /** Symlinks resolved and the path standardized, so `/Volumes/directa` and
        `/Applications` compare by what they are rather than how they were
        spelled. Every bundle-path comparison in the app goes through here. */
    nonisolated static func canonicalPath(_ url: URL?) -> String? {
        url?.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /** True when this copy is running from a mounted volume (a DMG). Such a copy
        acts as a headless installer: it draws no menu bar item, presents only the
        setup window, and hands off to /Applications, so an upgrade never shows the
        volume copy and the installed copy on the menu bar at once. Uses the same
        discriminator the daemon uses to keep its own image off the volume. */
    nonisolated static func runningFromMountedVolume(bundle: Bundle = .main) -> Bool {
        guard let path = canonicalPath(bundle.bundleURL) else { return false }
        return DaemonImagePolicy.isUnderMountedVolume(path)
    }

    /** Quit at launch when an older copy of this same bundle is already running.
        Returns whether this process is on its way out, so the caller can skip the
        rest of launch.

        The DMG copy and the Applications copy overlap for the length of the
        handoff and are both wanted, so this compares bundle paths: two copies at
        one path are the failure, and `AppInstancePolicy` decides which of them
        leaves. */
    @MainActor
    static func quitIfTwinIsRunning() -> Bool {
        guard let ownPath = canonicalPath(Bundle.main.bundleURL) else { return false }
        let current = NSRunningApplication.current
        let own = AppInstance(
            bundlePath: ownPath,
            launchDate: current.launchDate,
            processIdentifier: current.processIdentifier)
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> AppInstance? in
            guard app.bundleIdentifier == appBundleIdentifier,
                let path = canonicalPath(app.bundleURL)
            else { return nil }
            return AppInstance(
                bundlePath: path,
                launchDate: app.launchDate,
                processIdentifier: app.processIdentifier)
        }
        guard AppInstancePolicy.shouldStandDown(own: own, running: running) else { return false }
        DirectaLog.app.info("\(ownPath) is already running; this copy is standing down")
        NSApp.terminate(nil)
        return true
    }

    /** Quit every other running copy so /Applications/directa.app can be replaced.
        Returns whether the field is clear: replacing a bundle out from under a
        live process leaves that process running code that no longer exists on
        disk, so a caller that ignores a false here does real damage. */
    @MainActor
    static func quitOtherInstances() async -> Bool {
        for app in peerInstances() {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if peerInstances().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for app in peerInstances() {
            app.forceTerminate()
        }
        let forcedDeadline = Date().addingTimeInterval(2)
        while Date() < forcedDeadline {
            if peerInstances().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return peerInstances().isEmpty
    }

    /** Deliver a daemon-control URL to `/Applications/directa.app` by bundle
        path, not bundle id. The DMG copy shares `dev.quantizor.directa.app`, so
        `open -a` without a path target hands the URL to this process, which is
        not the SMAppService owner and cannot unregister the running agent. */
    @MainActor
    static func requestApplicationsDaemonControl(_ action: DaemonControlAction) async {
        guard LaunchdAdmin.applicationsAppPresent() else {
            switch action {
            case .ensure: _ = LaunchdAdmin.requestAppAgentEnsure()
            case .unregister: _ = LaunchdAdmin.requestAppAgentUnregister()
            case .unregisterAll: _ = LaunchdAdmin.requestAppLaunchItemsUnregister()
            }
            return
        }
        guard let url = URL(string: action.urlString) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.open(
                [url], withApplicationAt: LaunchdAdmin.applicationsAppURL,
                configuration: configuration)
        } catch {
            DirectaLog.app.error(
                "could not deliver \(action.urlString) to \(LaunchdAdmin.applicationsAppURL.path): \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private static func peerInstances() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == appBundleIdentifier && $0 != .current
        }
    }

    /** Open the Applications copy, then leave the mounted volume.

        Called only after a successful copy to `/Applications`. Staying alive
        from `/Volumes/...` pins the DMG (disk in use) and, if the user ejects
        anyway, SIGBUS: the kernel force-unmounts the vnode this process is
        mapped from. Setup is already on disk, so quitting is always correct;
        a missing menu bar extra is recoverable with a click on the installed
        app. Launch Services treats the DMG and Applications copies as the
        same bundle id, so `openApplication` can return this process as a
        "success": we still quit. */
    @MainActor
    static func relaunchFromApplicationsAndQuit() {
        let url = URL(fileURLWithPath: SetupPlanner.applicationsAppPath)
        let appsPath = canonicalPath(url)
        let selfPID = ProcessInfo.processInfo.processIdentifier
        Task { @MainActor in
            if applicationsPeerRunning(atPath: appsPath, otherThan: selfPID) {
                leaveMountedVolume()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            /** Force a new instance: without this, openApplication often
                "succeeds" by activating the already-running DMG copy. */
            configuration.createsNewApplicationInstance = true
            do {
                let app = try await NSWorkspace.shared.openApplication(
                    at: url, configuration: configuration)
                let launchedPath = canonicalPath(app.bundleURL)
                if app.processIdentifier != selfPID, launchedPath == appsPath {
                    leaveMountedVolume()
                    return
                }
            } catch {
                DirectaLog.app.error(
                    "relaunch from \(SetupPlanner.applicationsAppPath) failed: \(error.localizedDescription)")
            }
            DirectaLog.app.info(
                "openApplication returned self or wrong path; waiting for Applications peer")
            if await waitForPeer(atPath: appsPath, otherThan: selfPID, seconds: 8) {
                leaveMountedVolume()
                return
            }
            let open = LaunchdAdmin.shell("/usr/bin/open", [SetupPlanner.applicationsAppPath])
            if open.status == 0 {
                _ = await waitForPeer(atPath: appsPath, otherThan: selfPID, seconds: 5)
            }
            /** Copy already succeeded. Quit even if the handoff did not, so
                this process cannot pin or crash on an ejected DMG. */
            leaveMountedVolume()
        }
    }

    /** Terminate, then exit if AppKit is still running: an accessory installer
        can ignore terminate and keep the volume mapped. */
    @MainActor
    private static func leaveMountedVolume() {
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            exit(0)
        }
    }

    @MainActor
    private static func applicationsPeerRunning(atPath path: String?, otherThan selfPID: Int32)
        -> Bool
    {
        NSWorkspace.shared.runningApplications.contains { running in
            running.bundleIdentifier == appBundleIdentifier
                && running.processIdentifier != selfPID
                && canonicalPath(running.bundleURL) == path
        }
    }

    /** Poll for another process of this app running from `path`. */
    @MainActor
    private static func waitForPeer(
        atPath path: String?, otherThan selfPID: Int32, seconds: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if applicationsPeerRunning(atPath: path, otherThan: selfPID) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    nonisolated private static func readCLIVersion(at url: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    nonisolated private static func runCLI(_ cli: URL, arguments: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = cli
        proc.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw Failure.commandFailed(
                command: ([cli.path] + arguments).joined(separator: " "),
                status: -1,
                output: error.localizedDescription)
        }
        let stdout = String(
            data: (try? out.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8)
            ?? ""
        let stderr = String(
            data: (try? err.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8)
            ?? ""
        let combined = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard proc.terminationStatus == 0 else {
            throw Failure.commandFailed(
                command: ([cli.path] + arguments).joined(separator: " "),
                status: proc.terminationStatus,
                output: combined)
        }
        return combined
    }
}
