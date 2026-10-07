import Foundation

/** What `directa doctor` found about one harness's hook. Reporting only: doctor
    names the fix but never edits a file the user owns. */
public enum HarnessHookState: Equatable, Sendable {
    /** The harness itself is not installed on this machine; nothing to say. */
    case harnessAbsent
    /** A directa hook is present, recording this command path; `pathExists` is
        whether that path still resolves to an executable on disk. */
    case installed(path: String, pathExists: Bool)
    /** The harness is present but carries no directa hook. */
    case notInstalled

    /** A directa hook is recorded, whether or not that path still exists. The
        setup checkbox uses this. `isLive` is the stronger check doctor uses,
        because a recorded path that is gone is a finding, not a finished install. */
    public var isConfigured: Bool {
        if case .installed = self { return true }
        return false
    }

    /** A directa hook is installed and its recorded path still exists. */
    public var isLive: Bool {
        if case .installed(_, pathExists: true) = self { return true }
        return false
    }
}

/** A harness adapter owns one agent harness's settings format and injection
    mechanism. Adding a harness = one new conformer + a registry entry (see
    CONTRIBUTING.md). The context payload itself is harness-agnostic. */
public protocol HarnessAdapter: Sendable {
    /** The name a person sees on the setup panel. */
    var displayName: String { get }
    /** The harness is present when its settings directory exists, which is how
        `SetupPlanner.harnessOffers` decides a harness is worth offering. A
        conformer overrides this when presence is a parent of that directory
        (Antigravity's `~/.gemini`, Grok's `~/.grok`). It is a requirement so
        the override is the one `any HarnessAdapter` calls. */
    var harnessPresent: Bool { get }
    /** What doctor should report about this harness's hook, read-only. */
    func hookState() -> HarnessHookState
    /** Idempotently wires the session hook into the harness's settings. Returns
        a human summary of what changed. */
    func install(cliPath: String) throws -> String
    var name: String { get }
    /** The harness's own settings file. directa edits it in place and never owns
        it, so everything directa does not recognize has to survive the write. */
    var settingsURL: URL { get }
    /** Idempotently removes directa's session hook from the harness's settings,
        leaving everything else the file holds untouched. Returns a human summary,
        including the no-op case where no directa hook was present. */
    func uninstall() throws -> String
}

/** Reading and writing a settings file directa does not own. Both halves live
    here rather than in each adapter because the pair is one mechanism: `install`
    merges into whatever `loadSettings` returns and hands the whole result to
    `writeSettings`, so a read that answers "empty" for a file that exists turns
    the merge into a replacement. Keeping them together also means a harness
    added later gets the safe version without knowing why it matters. */
extension HarnessAdapter {
    public var displayName: String { name }

    public var harnessPresent: Bool {
        FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path)
    }

    /** Absent means an empty seed. Present but unreadable is refused, because
        the caller writes back everything this returns: collapsing the two is
        what let one malformed byte in the user's settings take every other
        hook, permission and key in the file with it on the next write. */
    func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            throw refusal(because: error.localizedDescription)
        }
        /** A zero-byte file is a seed, not a loss: there is nothing in it to erase. */
        guard !data.isEmpty else { return [:] }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw refusal(because: error.localizedDescription)
        }
        guard let object = parsed as? [String: Any] else {
            throw refusal(because: "its top level is not a JSON object")
        }
        return object
    }

    /** Extract the recorded command path from a hook command of the form
        `<path> hook <name>-session-start`, robust to spaces in the path. */
    func recordedPath(from command: String, suffix: String) -> String? {
        guard command.hasSuffix(suffix) else { return nil }
        return String(command.dropLast(suffix.count))
    }

    /** First directa command in a flat hook list (`[{command}]`), or nil. */
    func flatRecordedPath(in value: Any?, suffix: String) -> String? {
        for entry in (value as? [[String: Any]]) ?? [] {
            if let command = entry["command"] as? String,
                let path = recordedPath(from: command, suffix: suffix)
            {
                return path
            }
        }
        return nil
    }

    func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try AtomicFile.write(data, to: settingsURL)
    }

    private func refusal(because reason: String) -> WireError {
        WireError(
            code: .configInvalid,
            hint: "run: directa hook install",
            message:
                "\(settingsURL.path) exists but could not be read (\(reason)), so directa left it "
                + "alone. Installing the hook rewrites the whole file from what it reads back, so "
                + "merging into a file it cannot parse would delete every other setting in it. "
                + "Repair that file, then rerun")
    }
}

/** One adapter per harness directa knows, reading and writing under `home`.
    Tests pass a scratch directory; the default is this user's real home. */
public func harnessAdapters(
    inHome home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> [any HarnessAdapter] {
    [
        AntigravityAdapter(home: home),
        ClaudeCodeAdapter(home: home),
        CursorAdapter(home: home),
        GrokAdapter(home: home),
        OpenCodeAdapter(home: home),
    ]
}
