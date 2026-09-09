import Foundation

/** First-run / upgrade planning for the menu bar app installer. Pure decisions
    only: the app performs copies and shells out to the installed CLI. Layout
    matches `make install` (`~/.local/bin`) so DMG and source installs converge. */
public enum SetupPlanner {
    public static let applicationsAppPath = "/Applications/directa.app"
    public static let cliBinaryName = "directa"
    public static let daemonBinaryName = "ddirecta"
    public static let stampFileName = "setup.stamp"

    /** Canonical CLI directory shared with `make install` (`PREFIX/bin`). */
    public static func defaultCLIDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL
    {
        home.appending(path: ".local/bin")
    }

    /** The two prefixes a Homebrew install can live under: Apple Silicon and
        Intel. A cask's `binary` symlink always lands in `<prefix>/bin`, which
        `brew shellenv` puts on the user's PATH. */
    public static let homebrewPrefixes = ["/opt/homebrew", "/usr/local"]

    /** Which install owns the CLI, decided from where the running app bundle
        actually lives on disk rather than from any substring of its path.

        Homebrew moves the app to `/Applications` and leaves a symlink behind in
        `<prefix>/Caskroom/directa/<version>/directa.app` pointing back at it, so a
        `/Caskroom/` substring test on the resolved bundle path is always false
        for a normally-installed cask. The reliable signal is realpath equality:
        the running bundle and the Caskroom symlink resolve to the same directory
        only under a brew install. */
    public static func cliOwner(
        bundle: Bundle = .main, fileManager: FileManager = .default
    ) -> CLIOwner {
        let runningRealpath = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let staged: [(prefix: String, bundleRealpaths: [String])] = homebrewPrefixes.map { prefix in
            let caskDir = URL(fileURLWithPath: prefix).appending(path: "Caskroom/directa")
            let versionDirs =
                (try? fileManager.contentsOfDirectory(
                    at: caskDir, includingPropertiesForKeys: nil)) ?? []
            let bundles = versionDirs.compactMap { versionDir -> String? in
                let candidate = versionDir.appending(path: "\(cliBinaryName).app")
                guard fileManager.fileExists(atPath: candidate.path) else { return nil }
                return candidate.resolvingSymlinksInPath().standardizedFileURL.path
            }
            return (prefix: prefix, bundleRealpaths: bundles)
        }
        return resolveCLIOwner(runningBundleRealpath: runningRealpath, caskStagedBundles: staged)
    }

    /** The pure decision behind `cliOwner`, taking the disk facts as data so it
        is testable without a real Caskroom. `caskStagedBundles` pairs each brew
        prefix with the realpaths of the `directa.app` symlinks found under its
        Caskroom; a match against the running bundle means brew owns the CLI in
        that prefix's bin. */
    public static func resolveCLIOwner(
        runningBundleRealpath: String,
        caskStagedBundles: [(prefix: String, bundleRealpaths: [String])],
        cliDirectory: URL = defaultCLIDirectory()
    ) -> CLIOwner {
        for entry in caskStagedBundles
        where entry.bundleRealpaths.contains(runningBundleRealpath) {
            return .homebrew(
                shim: URL(fileURLWithPath: entry.prefix).appending(path: "bin/\(cliBinaryName)"))
        }
        return .directa(directory: cliDirectory)
    }

    public static func stampURL(paths: DirectaPaths) -> URL {
        paths.dataDir.appending(path: stampFileName)
    }

    public static func installedCLIURL(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL
    {
        defaultCLIDirectory(home: home).appending(path: cliBinaryName)
    }

    /** Owner of `/Applications/directa.app`, or nil when that copy is absent.
        Full uninstall trashes a copy directa itself installed and leaves a
        Homebrew cask's bundle for brew to remove. */
    public static func applicationsAppOwner(fileManager: FileManager = .default) -> CLIOwner? {
        let url = URL(fileURLWithPath: applicationsAppPath)
        guard fileManager.fileExists(atPath: url.path), let bundle = Bundle(url: url) else {
            return nil
        }
        return cliOwner(bundle: bundle, fileManager: fileManager)
    }

    public static func installedDaemonSiblingURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        defaultCLIDirectory(home: home).appending(path: daemonBinaryName)
    }

    /** Semver-ish compare: `"1.2.0"`, optionally with a trailing build label.
        Missing/unparseable sides sort as older than a concrete version. */
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parseVersion(lhs)
        let right = parseVersion(rhs)
        if left.isEmpty && right.isEmpty { return .orderedSame }
        if left.isEmpty { return .orderedAscending }
        if right.isEmpty { return .orderedDescending }
        let count = max(left.count, right.count)
        for i in 0..<count {
            let a = i < left.count ? left[i] : 0
            let b = i < right.count ? right[i] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    /** Whether the setup / upgrade panel should appear. */
    public static func shouldPresent(
        bundledVersion: String,
        installedCLIVersion: String?,
        stampVersion: String?,
        resourcesPresent: Bool,
        runningOutsideApplications: Bool = false
    ) -> Bool {
        guard resourcesPresent else { return false }
        /** Opening from a DMG or Downloads always offers install: the app must
            land in /Applications so login items and deep links keep working. */
        if runningOutsideApplications { return true }
        if stampVersion == nil { return true }
        if installedCLIVersion == nil { return true }
        if let installed = installedCLIVersion,
            compareVersions(bundledVersion, installed) == .orderedDescending
        {
            return true
        }
        if let stamped = stampVersion,
            compareVersions(bundledVersion, stamped) == .orderedDescending
        {
            return true
        }
        return false
    }

    /** True when this process is not already `/Applications/directa.app`. */
    public static func isRunningOutsideApplications(bundlePath: String) -> Bool {
        let running = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath()
            .standardizedFileURL.path
        let apps = URL(fileURLWithPath: applicationsAppPath).resolvingSymlinksInPath()
            .standardizedFileURL.path
        return running != apps
    }

    /** True when an on-disk CLI or LaunchAgent-era install already exists. */
    public static func isMigration(
        installedCLIExists: Bool,
        stampExists: Bool,
        launchAgentExists: Bool
    ) -> Bool {
        installedCLIExists || stampExists || launchAgentExists
    }

    /** Detect agent harnesses and whether their hooks still need installing. */
    public static func harnessOffers(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        installedCLIPath: String
    ) -> [HarnessOffer] {
        var offers: [HarnessOffer] = []
        let antigravityDir = home.appending(path: ".gemini")
        if FileManager.default.fileExists(atPath: antigravityDir.path) {
            let installed = HookPresence.antigravityHookInstalled(
                settingsURL: antigravityDir.appending(path: "config/hooks.json"),
                expectedCLIPath: installedCLIPath)
            offers.append(
                HarnessOffer(
                    alreadyInstalled: installed,
                    defaultChecked: !installed,
                    displayName: "Antigravity",
                    harness: "antigravity"))
        }
        let claudeDir = home.appending(path: ".claude")
        if FileManager.default.fileExists(atPath: claudeDir.path) {
            let installed = HookPresence.claudeHookInstalled(
                settingsURL: claudeDir.appending(path: "settings.json"),
                expectedCLIPath: installedCLIPath)
            offers.append(
                HarnessOffer(
                    alreadyInstalled: installed,
                    defaultChecked: !installed,
                    displayName: "Claude Code",
                    harness: "claude"))
        }
        let cursorDir = home.appending(path: ".cursor")
        if FileManager.default.fileExists(atPath: cursorDir.path) {
            let installed = HookPresence.cursorHookInstalled(
                settingsURL: cursorDir.appending(path: "hooks.json"),
                expectedCLIPath: installedCLIPath)
            offers.append(
                HarnessOffer(
                    alreadyInstalled: installed,
                    defaultChecked: !installed,
                    displayName: "Cursor",
                    harness: "cursor"))
        }
        let grokDir = home.appending(path: ".grok")
        if FileManager.default.fileExists(atPath: grokDir.path) {
            let installed = HookPresence.grokHookInstalled(
                settingsURL: grokDir.appending(path: "hooks/directa.json"),
                expectedCLIPath: installedCLIPath)
            offers.append(
                HarnessOffer(
                    alreadyInstalled: installed,
                    defaultChecked: !installed,
                    displayName: "Grok Build",
                    harness: "grok"))
        }
        let opencodeDir = OpenCodeWiring.configDirectory(home: home)
        if FileManager.default.fileExists(atPath: opencodeDir.path) {
            let installed = HookPresence.opencodeHookInstalled(home: home)
            offers.append(
                HarnessOffer(
                    alreadyInstalled: installed,
                    defaultChecked: !installed,
                    displayName: "OpenCode",
                    harness: "opencode"))
        }
        return offers.sorted { $0.harness < $1.harness }
    }

    /** What to tell someone whose shell cannot find `directa`. Carries the whole
        command rather than describing it, because the reader is being asked to
        edit a shell profile and the shape of that line is the part worth getting
        right. directa does not write it: nothing here edits files a user owns. */
    public static let pathRemedy =
        "\(defaultCLIDirectory().path) is not on your PATH, so shells and agents will not find `directa`. "
        + "Add it with: echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zprofile"

    /** Whether the CLI directory is on the PATH the user actually has.

        Two wrong answers are easy to reach here and both were shipped. The menu
        bar app is launched by Finder, so its own `ProcessInfo` PATH is launchd's
        and never contains `~/.local/bin`: asking that warned everyone. A login
        shell is closer but still skips `.zshrc`, which is where the directory is
        usually added, so it warned everyone too, for a different reason.
        `capturedPath` is the one home for the right answer. */
    /** The PATH check for a specific owner: brew's bin is put on PATH by
        `brew shellenv`, so a brew-owned CLI never warrants the warning, while a
        `~/.local/bin` install still does until the user adds it. */
    public static func cliDirectoryOnUserPATH(owner: CLIOwner) -> Bool {
        cliDirectoryOnPATH(pathEnv: LaunchdAdmin.capturedPath(), cliDirectory: owner.cliDirectory)
    }

    /** The pure half, taking the PATH to inspect so it stays testable. Callers
        outside a shell want `cliDirectoryOnUserPATH` instead: passing this
        process's own PATH is the mistake described above. */
    public static func cliDirectoryOnPATH(
        pathEnv: String?,
        cliDirectory: URL = defaultCLIDirectory()
    ) -> Bool {
        let needle = cliDirectory.path
        let path = pathEnv ?? ""
        return path.split(separator: ":").contains { String($0) == needle }
    }

    /** Read a prior setup stamp (plain version string). */
    public static func readStamp(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /** Persist the installed bundled version after a successful setup. */
    public static func writeStamp(version: String, to url: URL) throws {
        try AtomicFile.write(Data("\(version)\n".utf8), to: url)
    }

    /** Stage-and-rename a Mach-O into place (never overwrite a running signed binary). */
    public static func installBinary(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).staged-\(getpid())")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: staged.path)
        _ = try fm.replaceItemAt(destination, withItemAt: staged)
    }

    /** Stage-and-replace an .app bundle into /Applications (or `destination`).
        Caller must quit any process still holding the destination first. */
    public static func installAppBundle(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).staged-\(getpid())")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        clearQuarantine(at: staged)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        clearQuarantine(at: destination)
    }

    /** Drop the DMG/Downloads quarantine so Gatekeeper trusts the Applications copy. */
    private static func clearQuarantine(at url: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-dr", "com.apple.quarantine", url.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func parseVersion(_ raw: String) -> [Int] {
        let head = raw.split(separator: " ", maxSplits: 1).first.map(String.init) ?? raw
        let numeric = head.split(separator: "-").first.map(String.init) ?? head
        return numeric.split(separator: ".").compactMap { Int($0) }
    }
}

/** Where the CLI lives for this install, so setup neither double-installs it nor
    warns about a PATH that is already correct. Under a Homebrew cask the cask
    owns a symlink in brew's bin (already on PATH, removed on cask uninstall);
    writing a second copy to `~/.local/bin` would orphan it. */
public enum CLIOwner: Equatable, Sendable {
    /** directa installs and removes the CLI itself, at this directory. */
    case directa(directory: URL)
    /** Homebrew owns the CLI at this symlink in its bin; directa leaves it alone. */
    case homebrew(shim: URL)

    /** The directory the CLI resolves from, for the PATH check. */
    public var cliDirectory: URL {
        switch self {
        case .directa(let directory): return directory
        case .homebrew(let shim): return shim.deletingLastPathComponent()
        }
    }

    /** The CLI binary path directa should invoke and record in hooks. */
    public var cliPath: URL {
        switch self {
        case .directa(let directory): return directory.appending(path: SetupPlanner.cliBinaryName)
        case .homebrew(let shim): return shim
        }
    }

    /** True when Homebrew, not directa, installs and removes the CLI and daemon. */
    public var isHomebrew: Bool {
        if case .homebrew = self { return true }
        return false
    }
}

/** One harness row on the first-run panel. */
public struct HarnessOffer: Equatable, Sendable {
    public var alreadyInstalled: Bool
    public var defaultChecked: Bool
    public var displayName: String
    public var harness: String

    public init(
        alreadyInstalled: Bool,
        defaultChecked: Bool,
        displayName: String,
        harness: String
    ) {
        self.alreadyInstalled = alreadyInstalled
        self.defaultChecked = defaultChecked
        self.displayName = displayName
        self.harness = harness
    }
}

/** Lightweight read of harness settings to decide checkbox defaults. Mirrors the
    CLI adapters' "already installed" checks without writing. */
enum HookPresence {
    static func antigravityHookInstalled(settingsURL: URL, expectedCLIPath: String) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let expected = "\(expectedCLIPath) hook antigravity-session-start"
        for (_, value) in settings {
            guard let hookGroup = value as? [String: Any],
                let preInvocation = hookGroup["PreInvocation"] as? [[String: Any]]
            else { continue }
            for handler in preInvocation {
                let command = handler["command"] as? String ?? ""
                if command == expected || command.contains("directa hook antigravity-session-start") {
                    return true
                }
            }
        }
        return false
    }

    static func claudeHookInstalled(settingsURL: URL, expectedCLIPath: String) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = settings["hooks"] as? [String: Any],
            let sessionStart = hooks["SessionStart"] as? [[String: Any]]
        else { return false }
        let expected = "\(expectedCLIPath) hook claude-session-start"
        return sessionStart.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains { hook in
                let command = hook["command"] as? String ?? ""
                return command == expected || command.contains("directa hook claude-session-start")
            }
        }
    }

    static func cursorHookInstalled(settingsURL: URL, expectedCLIPath: String) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = settings["hooks"] as? [String: Any],
            let sessionStart = hooks["sessionStart"] as? [[String: Any]]
        else { return false }
        let expected = "\(expectedCLIPath) hook cursor-session-start"
        return sessionStart.contains { entry in
            let command = entry["command"] as? String ?? ""
            return command == expected || command.contains("directa hook cursor-session-start")
        }
    }

    static func grokHookInstalled(settingsURL: URL, expectedCLIPath: String) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = settings["hooks"] as? [String: Any]
        else { return false }
        let expected = "\(expectedCLIPath)\(GrokWiring.commandSuffix)"
        func present(_ event: String) -> Bool {
            for group in (hooks[event] as? [[String: Any]]) ?? [] {
                for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                    let command = hook["command"] as? String ?? ""
                    if command == expected || command.contains("directa\(GrokWiring.commandSuffix)") {
                        return true
                    }
                }
            }
            return false
        }
        /** PreToolUse is the injection Grok delivers; UserPromptSubmit is the
            per-turn gate. SessionStart-only is the old install and does not count. */
        return GrokWiring.registeredEvents.allSatisfy { present($0) }
    }

    /** OpenCode's wiring is not a command in a hooks file: it is the managed
        instructions file plus the `instructions` entry in the global config
        that references it, so "installed" means both. Which array is effective
        is OpenCodeWiring's merge rule, the same one the CLI adapter applies. */
    static func opencodeHookInstalled(home: URL) -> Bool {
        let managed = OpenCodeWiring.managedFileURL(inHome: home)
        let entry = OpenCodeWiring.instructionsEntry(forManagedFileAt: managed)
        guard FileManager.default.fileExists(atPath: managed.path),
            let effective = OpenCodeWiring.effectiveInstructions(
                inDirectory: OpenCodeWiring.configDirectory(home: home))
        else { return false }
        return effective.entries.contains(entry)
    }
}

/** Events and command suffix the Grok adapter writes and the setup presence
    check reads. One home so doctor and the setup panel cannot disagree. */
public enum GrokWiring {
    public static let commandSuffix = " hook grok-session-start"
    public static let registeredEvents = ["PreToolUse", "UserPromptSubmit"]
}

/** The on-disk contract OpenCode's own config loader defines, the one home for
    the paths, the merge rule, and the entry form that the CLI adapter (directa
    target) and the presence check (here) must agree on. OpenCode merges every
    global config file below, later files winning conflicting keys, and an
    `instructions` array in a later file replaces an earlier file's whole
    array. */
public enum OpenCodeWiring {
    public static let globalLoadOrder = ["config.json", "opencode.json", "opencode.jsonc"]

    public static let managedFileName = "directa.md"

    /** OpenCode resolves its config root through the XDG convention, so a set
        XDG_CONFIG_HOME moves the directory directa must edit. */
    public static func configDirectory(home: URL, xdgConfigHome: String?) -> URL {
        guard let xdg = xdgConfigHome, !xdg.isEmpty else {
            return home.appending(path: ".config/opencode")
        }
        return URL(fileURLWithPath: xdg).appending(path: "opencode")
    }

    public static func configDirectory(home: URL) -> URL {
        configDirectory(
            home: home, xdgConfigHome: ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"])
    }

    /** The `instructions` array OpenCode's merge actually applies: the first
        existing config file in `directory` (winner first) that holds the key
        decides, its array replacing every earlier file's. A file that exists
        but cannot be parsed here is skipped, because OpenCode reads JSONC that
        JSONSerialization cannot. A key that is present but not an array of
        paths is schema-invalid for OpenCode, which fails the whole config
        load, so nothing is effective. */
    public static func effectiveInstructions(
        inDirectory directory: URL
    ) -> (file: URL, entries: [String])? {
        for name in globalLoadOrder.reversed() {
            let url = directory.appending(path: name)
            guard let data = try? Data(contentsOf: url),
                let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard settings["instructions"] != nil else { continue }
            guard let entries = settings["instructions"] as? [String] else { return nil }
            return (url, entries)
        }
        return nil
    }

    /** The `instructions` entry that references the managed file: tilde-relative
        to the home directory when the file lives under it, so the entry
        survives a synced config and never collides with a same-named file in a
        project (OpenCode resolves a relative entry against the project
        directory first); absolute otherwise, which OpenCode resolves in the
        entry's own directory. OpenCode expands a leading `~/` against the
        user's home at load time, so both forms reach the same file. */
    public static func instructionsEntry(forManagedFileAt managedFileURL: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = managedFileURL.path
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    public static func managedFileURL(inHome home: URL) -> URL {
        configDirectory(home: home).appending(path: managedFileName)
    }

    /** The file OpenCode itself prefers to create and patch, so the file whose
        `instructions` array wins the merge: the first existing name in reverse
        load order, else opencode.jsonc, which is what OpenCode seeds on a
        fresh machine. */
    public static func settingsURL(inHome home: URL) -> URL {
        let dir = configDirectory(home: home)
        for name in globalLoadOrder.reversed() {
            let url = dir.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return dir.appending(path: "opencode.jsonc")
    }
}
