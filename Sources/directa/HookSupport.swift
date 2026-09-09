import DirectaKit
import Darwin
import Foundation

/** Absolute path of this running `directa` binary. Prefer over
    CommandLine.arguments[0], which is often a bare PATH name and would resolve
    relative to cwd (breaking `hook install` when invoked as `directa` from a
    project directory). */
enum CLISelf {
    static var path: String {
        if let raw = mainExecutablePath() {
            return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        }
        return fallbackPath()
    }

    /** The ddirecta that shipped alongside this directa; the preferred install
        source because it is version-matched to this binary. */
    static var daemonSibling: URL {
        URL(fileURLWithPath: path).deletingLastPathComponent().appending(path: "ddirecta")
    }

    /** The running binary's image path from `Bundle.main.executableURL` (the
        kernel image, not argv[0]); the `path` accessor resolves any symlink. Nil
        only when the bundle has no executable URL, when `fallbackPath` takes over. */
    private static func mainExecutablePath() -> String? {
        Bundle.main.executableURL?.path
    }

    /** Last resort when dyld refuses: absolute arg0, else first PATH hit. */
    private static func fallbackPath() -> String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") {
            return URL(fileURLWithPath: arg0).resolvingSymlinksInPath().path
        }
        let name = URL(fileURLWithPath: arg0).lastPathComponent
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath().path
            }
        }
        return URL(fileURLWithPath: arg0).resolvingSymlinksInPath().path
    }
}

/** Fetches the trusted project's server list over the socket and hands it to the
    pure renderer in DirectaKit (AgentContext.render). Kept thin and side-effect
    free: a session start must stay fast, must never bootstrap the daemon, and
    stays silent when the daemon is unreachable. */
enum HookContext {
    static func render(project: String) async -> String? {
        let client = DaemonClient(socketPath: DirectaPaths().socketPath)
        guard
            let list = try? await client.request(
                .serverStatus, params: ProjectParams(project: project), expecting: ServerListResult.self)
        else { return nil }
        return AgentContext.render(list: list)
    }
}

/** What `directa doctor` found about one harness's hook. Reporting only: doctor
    names the fix but never edits a file the user owns. */
enum HarnessHookState: Equatable, Sendable {
    /** The harness itself is not installed on this machine; nothing to say. */
    case harnessAbsent
    /** A directa hook is present, recording this command path; `pathExists` is
        whether that path still resolves to an executable on disk. */
    case installed(path: String, pathExists: Bool)
    /** The harness is present but carries no directa hook. */
    case notInstalled
}

/** A harness adapter owns one agent harness's settings format and injection
    mechanism. Adding a harness = one new conformer + a registry entry (see
    CONTRIBUTING.md). The context payload itself is harness-agnostic. */
protocol HarnessAdapter: Sendable {
    /** Idempotently wires the session hook into the harness's settings. Returns
        a human summary of what changed. */
    func install(cliPath: String) throws -> String
    /** What doctor should report about this harness's hook, read-only. */
    func hookState() -> HarnessHookState
    var name: String { get }
    /** Idempotently removes directa's session hook from the harness's settings,
        leaving everything else the file holds untouched. Returns a human summary,
        including the no-op case where no directa hook was present. */
    func uninstall() throws -> String
    /** The harness's own settings file. directa edits it in place and never owns
        it, so everything directa does not recognize has to survive the write. */
    var settingsURL: URL { get }
}

/** Reading and writing a settings file directa does not own. Both halves live
    here rather than in each adapter because the pair is one mechanism: `install`
    merges into whatever `loadSettings` returns and hands the whole result to
    `writeSettings`, so a read that answers "empty" for a file that exists turns
    the merge into a replacement. Keeping them together also means a harness
    added later gets the safe version without knowing why it matters. */
extension HarnessAdapter {
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

    func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try AtomicFile.write(data, to: settingsURL)
    }

    /** The harness is "present" when its settings directory exists, which is how
        `SetupPlanner.harnessOffers` decides a harness is worth offering. */
    var harnessPresent: Bool {
        FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path)
    }

    /** Extract the recorded command path from a hook command of the form
        `<path> hook <name>-session-start`, robust to spaces in the path. */
    func recordedPath(from command: String, suffix: String) -> String? {
        guard command.hasSuffix(suffix) else { return nil }
        return String(command.dropLast(suffix.count))
    }

    private func refusal(because reason: String) -> WireError {
        WireError(
            code: .configInvalid,
            hint: "directa hook install",
            message:
                "\(settingsURL.path) exists but could not be read (\(reason)), so directa left it "
                + "alone. Installing the hook rewrites the whole file from what it reads back, so "
                + "merging into a file it cannot parse would delete every other setting in it. "
                + "Repair that file, then rerun")
    }
}

let harnessAdapters: [any HarnessAdapter] = [
    AntigravityAdapter(), ClaudeCodeAdapter(), CursorAdapter(), GrokAdapter(),
    OpenCodeAdapter(),
]

/** Resolve the project directory a session-start hook should introspect. Antigravity
    carries workspacePaths; Cursor carries workspace_roots (and CURSOR_PROJECT_DIR);
    Claude Code carries cwd; Grok carries cwd, workspaceRoot, and GROK_WORKSPACE_ROOT.
    Fall back to the process cwd when the payload is empty or malformed. */
enum HookSessionCwd {
    static func resolve(stdin: Data) -> String {
        if let payload = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] {
            if let roots = payload["workspace_roots"] as? [String], let first = roots.first,
                !first.isEmpty
            {
                return first
            }
            if let paths = payload["workspacePaths"] as? [String], let first = paths.first,
                !first.isEmpty
            {
                return first
            }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { return cwd }
            if let root = payload["workspaceRoot"] as? String, !root.isEmpty { return root }
        }
        if let env = ProcessInfo.processInfo.environment["CURSOR_PROJECT_DIR"], !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["GROK_WORKSPACE_ROOT"], !env.isEmpty {
            return env
        }
        return FileManager.default.currentDirectoryPath
    }
}

/** Antigravity: PreInvocation hook merged into ~/.gemini/config/hooks.json without
    clobbering existing entries. Emits {"injectSteps": [{"ephemeralMessage": ...}]}. */
struct AntigravityAdapter: HarnessAdapter {
    let name = "antigravity"
    /** Overridable so tests can point at a scratch file; nil means the real
        `~/.gemini/config/hooks.json`. */
    var settingsURLOverride: URL?

    var settingsURL: URL {
        settingsURLOverride
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(
                path: ".gemini/config/hooks.json")
    }

    var harnessPresent: Bool {
        let parent = settingsURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) { return true }
        let grandparent = parent.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: grandparent.path)
    }

    func install(cliPath: String) throws -> String {
        let command = "\(cliPath) hook antigravity-session-start"
        var settings = try loadSettings()
        var directaGroup = settings["directa"] as? [String: Any] ?? [:]
        var preInvocation = directaGroup["PreInvocation"] as? [[String: Any]] ?? []
        if let repaired = repairAntigravityPreInvocation(
            preInvocation: &preInvocation, command: command)
        {
            directaGroup["PreInvocation"] = preInvocation
            settings["directa"] = directaGroup
            try writeSettings(settings)
            return repaired
        }
        let alreadyInstalled = preInvocation.contains { entry in
            (entry["command"] as? String) == command
        }
        if alreadyInstalled {
            return "Antigravity PreInvocation hook already installed (\(settingsURL.path))"
        }
        preInvocation.append(["command": command, "type": "command"])
        directaGroup["PreInvocation"] = preInvocation
        settings["directa"] = directaGroup
        try writeSettings(settings)
        return "Antigravity PreInvocation hook installed in \(settingsURL.path)"
    }

    func uninstall() throws -> String {
        var settings = try loadSettings()
        guard var directaGroup = settings["directa"] as? [String: Any],
            var preInvocation = directaGroup["PreInvocation"] as? [[String: Any]]
        else {
            return "Antigravity hook not present (\(settingsURL.path))"
        }
        let before = preInvocation.count
        preInvocation.removeAll { entry in
            ((entry["command"] as? String) ?? "").contains("directa hook antigravity-session-start")
        }
        guard preInvocation.count != before else {
            return "Antigravity hook not present (\(settingsURL.path))"
        }
        if preInvocation.isEmpty {
            directaGroup.removeValue(forKey: "PreInvocation")
        } else {
            directaGroup["PreInvocation"] = preInvocation
        }
        if directaGroup.isEmpty {
            settings.removeValue(forKey: "directa")
        } else {
            settings["directa"] = directaGroup
        }
        try writeSettings(settings)
        return "Antigravity hook removed from \(settingsURL.path)"
    }

    func hookState() -> HarnessHookState {
        guard harnessPresent else { return .harnessAbsent }
        let suffix = " hook antigravity-session-start"
        guard let settings = try? loadSettings(),
            let directaGroup = settings["directa"] as? [String: Any],
            let preInvocation = directaGroup["PreInvocation"] as? [[String: Any]]
        else { return .notInstalled }
        for entry in preInvocation {
            if let command = entry["command"] as? String,
                let path = recordedPath(from: command, suffix: suffix)
            {
                return .installed(
                    path: path, pathExists: FileManager.default.isExecutableFile(atPath: path))
            }
        }
        return .notInstalled
    }

    private func repairAntigravityPreInvocation(
        preInvocation: inout [[String: Any]], command: String
    ) -> String? {
        var changed = false
        for i in preInvocation.indices {
            guard let existing = preInvocation[i]["command"] as? String,
                existing.contains("directa hook antigravity-session-start"),
                existing != command
            else { continue }
            preInvocation[i]["command"] = command
            changed = true
        }
        return changed
            ? "Antigravity PreInvocation hook path repaired in \(settingsURL.path)" : nil
    }
}

/** Claude Code: SessionStart hook with the compact matcher (fires right after
    compaction, exactly when agents forget), merged into user settings without
    clobbering existing hooks. */
struct ClaudeCodeAdapter: HarnessAdapter {
    let name = "claude"
    /** Overridable so tests can point at a scratch file; nil means the real
        `~/.claude/settings.json`. */
    var settingsURLOverride: URL?

    var settingsURL: URL {
        settingsURLOverride
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(
                path: ".claude/settings.json")
    }

    func install(cliPath: String) throws -> String {
        let command = "\(cliPath) hook claude-session-start"
        var settings = try loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var sessionStart = hooks["SessionStart"] as? [[String: Any]] ?? []
        if let repaired = repairClaudeSessionStart(sessionStart: &sessionStart, command: command) {
            hooks["SessionStart"] = sessionStart
            settings["hooks"] = hooks
            try writeSettings(settings)
            return repaired
        }
        let alreadyInstalled = sessionStart.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains { hook in
                (hook["command"] as? String) == command
            }
        }
        if alreadyInstalled {
            return "Claude Code SessionStart hook already installed (\(settingsURL.path))"
        }
        sessionStart.append([
            "hooks": [["command": command, "type": "command"]],
            "matcher": "startup|resume|clear|compact",
        ])
        hooks["SessionStart"] = sessionStart
        settings["hooks"] = hooks
        try writeSettings(settings)
        return "Claude Code SessionStart hook installed (matcher startup|resume|clear|compact) in \(settingsURL.path)"
    }

    func uninstall() throws -> String {
        var settings = try loadSettings()
        guard var hooks = settings["hooks"] as? [String: Any],
            var sessionStart = hooks["SessionStart"] as? [[String: Any]]
        else {
            return "Claude Code SessionStart hook not present (\(settingsURL.path))"
        }
        var removed = false
        sessionStart = sessionStart.compactMap { entry in
            guard var entryHooks = entry["hooks"] as? [[String: Any]] else { return entry }
            let before = entryHooks.count
            entryHooks.removeAll { hook in
                ((hook["command"] as? String) ?? "").contains("directa hook claude-session-start")
            }
            if entryHooks.count != before { removed = true }
            /** An entry left with no hooks held only directa's, so drop it whole
                rather than leaving a matcher pointing at nothing. */
            if entryHooks.isEmpty { return nil }
            var updated = entry
            updated["hooks"] = entryHooks
            return updated
        }
        guard removed else {
            return "Claude Code SessionStart hook not present (\(settingsURL.path))"
        }
        if sessionStart.isEmpty {
            hooks.removeValue(forKey: "SessionStart")
        } else {
            hooks["SessionStart"] = sessionStart
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings)
        return "Claude Code SessionStart hook removed from \(settingsURL.path)"
    }

    func hookState() -> HarnessHookState {
        guard harnessPresent else { return .harnessAbsent }
        let suffix = " hook claude-session-start"
        guard let settings = try? loadSettings(),
            let hooks = settings["hooks"] as? [String: Any],
            let sessionStart = hooks["SessionStart"] as? [[String: Any]]
        else { return .notInstalled }
        for entry in sessionStart {
            for hook in (entry["hooks"] as? [[String: Any]]) ?? [] {
                if let command = hook["command"] as? String,
                    let path = recordedPath(from: command, suffix: suffix)
                {
                    return .installed(
                        path: path, pathExists: FileManager.default.isExecutableFile(atPath: path))
                }
            }
        }
        return .notInstalled
    }

    /** Rewrite a prior install whose command path no longer resolves (e.g. a
        bare `directa` that was resolved relative to cwd at install time). */
    private func repairClaudeSessionStart(sessionStart: inout [[String: Any]], command: String)
        -> String?
    {
        var changed = false
        for i in sessionStart.indices {
            guard var entryHooks = sessionStart[i]["hooks"] as? [[String: Any]] else { continue }
            for j in entryHooks.indices {
                guard let existing = entryHooks[j]["command"] as? String,
                    existing.contains("directa hook claude-session-start"),
                    existing != command
                else { continue }
                entryHooks[j]["command"] = command
                changed = true
            }
            if changed { sessionStart[i]["hooks"] = entryHooks }
        }
        return changed
            ? "Claude Code SessionStart hook path repaired in \(settingsURL.path)" : nil
    }
}

/** Cursor: sessionStart hook merged into ~/.cursor/hooks.json without clobbering
    existing entries. Emits {additional_context} (snake_case; Cursor's schema). */
struct CursorAdapter: HarnessAdapter {
    let name = "cursor"
    /** Overridable so tests can point at a scratch file; nil means the real
        `~/.cursor/hooks.json`. */
    var settingsURLOverride: URL?

    var settingsURL: URL {
        settingsURLOverride
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cursor/hooks.json")
    }

    func install(cliPath: String) throws -> String {
        let command = "\(cliPath) hook cursor-session-start"
        var settings = try loadSettings()
        if settings["version"] == nil { settings["version"] = 1 }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var sessionStart = hooks["sessionStart"] as? [[String: Any]] ?? []
        if let repaired = repairCursorSessionStart(sessionStart: &sessionStart, command: command) {
            hooks["sessionStart"] = sessionStart
            settings["hooks"] = hooks
            try writeSettings(settings)
            return repaired
        }
        let alreadyInstalled = sessionStart.contains { entry in
            (entry["command"] as? String) == command
        }
        if alreadyInstalled {
            return "Cursor sessionStart hook already installed (\(settingsURL.path))"
        }
        sessionStart.append(["command": command])
        hooks["sessionStart"] = sessionStart
        settings["hooks"] = hooks
        try writeSettings(settings)
        return "Cursor sessionStart hook installed in \(settingsURL.path)"
    }

    func uninstall() throws -> String {
        var settings = try loadSettings()
        guard var hooks = settings["hooks"] as? [String: Any],
            var sessionStart = hooks["sessionStart"] as? [[String: Any]]
        else {
            return "Cursor sessionStart hook not present (\(settingsURL.path))"
        }
        let before = sessionStart.count
        sessionStart.removeAll { entry in
            ((entry["command"] as? String) ?? "").contains("directa hook cursor-session-start")
        }
        guard sessionStart.count != before else {
            return "Cursor sessionStart hook not present (\(settingsURL.path))"
        }
        if sessionStart.isEmpty {
            hooks.removeValue(forKey: "sessionStart")
        } else {
            hooks["sessionStart"] = sessionStart
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        /** `version` is Cursor's own schema field, not directa's, so it stays. */
        try writeSettings(settings)
        return "Cursor sessionStart hook removed from \(settingsURL.path)"
    }

    func hookState() -> HarnessHookState {
        guard harnessPresent else { return .harnessAbsent }
        let suffix = " hook cursor-session-start"
        guard let settings = try? loadSettings(),
            let hooks = settings["hooks"] as? [String: Any],
            let sessionStart = hooks["sessionStart"] as? [[String: Any]]
        else { return .notInstalled }
        for entry in sessionStart {
            if let command = entry["command"] as? String,
                let path = recordedPath(from: command, suffix: suffix)
            {
                return .installed(
                    path: path, pathExists: FileManager.default.isExecutableFile(atPath: path))
            }
        }
        return .notInstalled
    }

    private func repairCursorSessionStart(sessionStart: inout [[String: Any]], command: String)
        -> String?
    {
        var changed = false
        for i in sessionStart.indices {
            guard let existing = sessionStart[i]["command"] as? String,
                existing.contains("directa hook cursor-session-start"),
                existing != command
            else { continue }
            sessionStart[i]["command"] = command
            changed = true
        }
        return changed ? "Cursor sessionStart hook path repaired in \(settingsURL.path)" : nil
    }
}

/** GROK_HOOK_EVENT, parsed once at the process boundary. Settings JSON uses
    PascalCase event names; the env value is snake_case. */
enum GrokHookEvent: Equatable {
    case leftover
    case preToolUse
    case unspecified
    case userPromptSubmit

    static func parse(_ raw: String?) -> GrokHookEvent {
        switch raw?.lowercased() {
        case "pre_tool_use": return .preToolUse
        case "user_prompt_submit": return .userPromptSubmit
        case nil: return .unspecified
        default: return .leftover
        }
    }
}

/** What `directa hook grok-session-start` does for one Grok event. Grok
    delivers `additionalContext` from PreToolUse after the tool result, and
    discards it on SessionStart and UserPromptSubmit. Stop additionalContext
    continues the turn, so this adapter never emits there. UserPromptSubmit
    still runs: it increments a per-session turn counter so PreToolUse can skip
    later tools of the same turn (PreToolUse stdin omits promptId). SessionStart
    is leftover and silent: Grok discards that stdout, and install removes the
    registration. */
enum GrokSessionHook {
    enum Action: Equatable {
        case emitAndMark
        case emitUnmarked
        case silent
        case silentPersist
    }

    /** Per-session turn gate, persisted under TMPDIR so the OS tmp reaper is
        the expiry. `emittedThisTurn` starts false so a PreToolUse that beats
        UserPromptSubmit still emits once. */
    struct TurnState: Codable, Equatable, Sendable {
        var emittedThisTurn: Bool
        var turn: Int
    }

    static func action(for event: GrokHookEvent, state: inout TurnState) -> Action {
        switch event {
        case .leftover:
            return .silent
        case .preToolUse:
            if state.emittedThisTurn { return .silent }
            return .emitAndMark
        case .unspecified:
            return .emitUnmarked
        case .userPromptSubmit:
            state.turn += 1
            state.emittedThisTurn = false
            return .silentPersist
        }
    }

    /** Record that this turn's PreToolUse already delivered. Called only after
        stdout has been written, so a killed or empty render can still retry. */
    static func markEmitted(_ state: inout TurnState) {
        state.emittedThisTurn = true
    }
}

/** On-disk half of `GrokSessionHook.TurnState`. Files are keyed by Grok's
    session id; `DIRECTA_GROK_HOOK_STATE_DIR` relocates the directory for tests. */
enum GrokTurnGate {
    static let stateDirName = "directa-grok-hook"

    static func directory(environment: [String: String]) -> URL {
        if let override = environment["DIRECTA_GROK_HOOK_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let tmp = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: tmp).appending(path: stateDirName)
    }

    static func sessionId(in stdin: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] else {
            return nil
        }
        return (payload["sessionId"] as? String) ?? (payload["session_id"] as? String)
    }

    static let fallbackKey = "nosession"
    static let maxKeyLength = 128

    static func sessionKey(_ raw: String?) -> String {
        let trimmed = (raw ?? "").replacing(/[^A-Za-z0-9._-]/) { _ in "" }
        let sliced = String(trimmed.prefix(maxKeyLength))
        if sliced.isEmpty || sliced == "." || sliced == ".." { return fallbackKey }
        return sliced
    }

    static func load(sessionKey: String, directory: URL) -> GrokSessionHook.TurnState {
        let url = directory.appending(path: sessionKey)
        return AtomicFile.loadDefensively(GrokSessionHook.TurnState.self, from: url)
            ?? GrokSessionHook.TurnState(emittedThisTurn: false, turn: 0)
    }

    static func save(
        _ state: GrokSessionHook.TurnState, sessionKey: String, directory: URL
    ) {
        let url = directory.appending(path: sessionKey)
        guard let data = try? JSONCoding.encoder().encode(state) else { return }
        try? AtomicFile.write(data, to: url)
    }
}

/** The standing instruction shared by harnesses whose context surface is a home
    file rather than hook stdout (Grok rules, OpenCode instructions): run
    `directa context` before touching a server, described for a reader who has
    never heard of directa. The text is static on purpose: a live server snapshot
    here would be global (every session on the machine) and last-writer-wins
    across projects. Install writes it, uninstall deletes it, session hooks
    never rewrite it. */
enum HarnessStandingInstruction {
    static let preamble =
        "This machine supervises local dev servers with directa. At session start and after compaction, run `directa context` (or `directa status --json`) before starting, stopping, or curling a server. Prefer `directa ensure <name>` / `directa status` / `directa logs <name>` over launching a server directly. If a `devservers.json` exists, do not start an unmanaged process. In a git worktree, the live URL comes from status or context (same host as the main checkout; the port may be rebound)."

    static func write(to url: URL) throws {
        try AtomicFile.write(Data((preamble + "\n").utf8), to: url)
    }

    static func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/** Grok Build: PreToolUse and UserPromptSubmit in ~/.grok/hooks/directa.json,
    plus a managed ~/.grok/rules/directa.md.

    Grok discards hook stdout on SessionStart and UserPromptSubmit, and delivers
    PreToolUse additionalContext after the tool result (once per user turn, gated
    by the UPS turn mark because PreToolUse stdin omits promptId). Home rules
    under ~/.grok/rules apply to every project, so the rule is the shared
    standing instruction (HarnessStandingInstruction) rather than a live
    snapshot: it covers the first tool of a turn and compaction, where
    PreToolUse has not yet run. Install does not register SessionStart or Stop,
    and removes this command from any event it does not register, so an older
    SessionStart-only hook is torn down rather than left beside the new one. */
struct GrokAdapter: HarnessAdapter {
    let name = "grok"
    static let registeredEvents = GrokWiring.registeredEvents
    /** Overridable so tests can point at a scratch file; nil means the real
        `~/.grok/hooks/directa.json`. */
    var settingsURLOverride: URL?

    var settingsURL: URL {
        settingsURLOverride
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(
                path: ".grok/hooks/directa.json")
    }

    /** Sibling of the hooks file: `…/.grok/hooks/directa.json` → `…/.grok/rules/directa.md`. */
    var rulesURL: URL {
        settingsURL.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "rules").appending(path: "directa.md")
    }

    var harnessPresent: Bool {
        let parent = settingsURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) { return true }
        let grandparent = parent.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: grandparent.path)
    }

    func install(cliPath: String) throws -> String {
        let command = "\(cliPath)\(GrokWiring.commandSuffix)"
        var settings = try loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let strippedLeftover = stripUnregisteredHooks(hooks: &hooks)
        let repaired = repairGrokHooks(hooks: &hooks, command: command)
        let added = ensureGrokEvents(hooks: &hooks, command: command)
        if repaired != nil || added || strippedLeftover {
            settings["hooks"] = hooks
            try writeSettings(settings)
        }
        try HarnessStandingInstruction.write(to: rulesURL)
        if let repaired {
            return repaired
        }
        if added {
            return "Grok Build hook installed in \(settingsURL.path)"
        }
        if strippedLeftover {
            return "Grok Build leftover hook removed from \(settingsURL.path)"
        }
        return "Grok Build hook already installed (\(settingsURL.path))"
    }

    func uninstall() throws -> String {
        var settings = try loadSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else {
            return "Grok Build hook not present (\(settingsURL.path))"
        }
        let removed = removeDirectaHandlers(from: &hooks, events: Array(hooks.keys))
        guard removed else {
            return "Grok Build hook not present (\(settingsURL.path))"
        }
        try HarnessStandingInstruction.remove(at: rulesURL)
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        if settings.isEmpty, FileManager.default.fileExists(atPath: settingsURL.path) {
            try FileManager.default.removeItem(at: settingsURL)
        } else {
            try writeSettings(settings)
        }
        return "Grok Build hook removed from \(settingsURL.path)"
    }

    func hookState() -> HarnessHookState {
        guard harnessPresent else { return .harnessAbsent }
        let suffix = GrokWiring.commandSuffix
        guard let settings = try? loadSettings(),
            let hooks = settings["hooks"] as? [String: Any]
        else { return .notInstalled }
        var path: String?
        for event in Self.registeredEvents {
            guard let groups = hooks[event] as? [[String: Any]],
                let found = recordedGrokPath(in: groups, suffix: suffix)
            else { return .notInstalled }
            if path == nil { path = found }
        }
        guard let path else { return .notInstalled }
        return .installed(
            path: path, pathExists: FileManager.default.isExecutableFile(atPath: path))
    }

    private static let handlerTimeoutSeconds = 10

    private func handler(command: String) -> [String: Any] {
        ["command": command, "timeout": Self.handlerTimeoutSeconds, "type": "command"]
    }

    private func ensureGrokEvents(hooks: inout [String: Any], command: String) -> Bool {
        var added = false
        for event in Self.registeredEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let present = groups.contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains { hook in
                    (hook["command"] as? String) == command
                }
            }
            if present { continue }
            groups.append(["hooks": [handler(command: command)]])
            hooks[event] = groups
            added = true
        }
        return added
    }

    private func recordedGrokPath(in groups: [[String: Any]], suffix: String) -> String? {
        for group in groups {
            for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                if let command = hook["command"] as? String,
                    let path = recordedPath(from: command, suffix: suffix)
                {
                    return path
                }
            }
        }
        return nil
    }

    private func repairGrokHooks(hooks: inout [String: Any], command: String) -> String? {
        var changed = false
        for event in Array(hooks.keys) {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            for i in groups.indices {
                guard var entryHooks = groups[i]["hooks"] as? [[String: Any]] else { continue }
                for j in entryHooks.indices {
                    guard let existing = entryHooks[j]["command"] as? String,
                        existing.contains("directa\(GrokWiring.commandSuffix)"),
                        existing != command
                    else { continue }
                    entryHooks[j]["command"] = command
                    changed = true
                }
                if changed { groups[i]["hooks"] = entryHooks }
            }
            if changed { hooks[event] = groups }
        }
        return changed ? "Grok Build hook path repaired in \(settingsURL.path)" : nil
    }

    /** Drop this command from every event it does not register. SessionStart
        stdout is discarded and Stop additionalContext continues the turn, so
        neither is written, and an older install that still has one is healed.
        Foreign handlers in those events stay. Runs before repair so a leftover
        SessionStart with a stale path is deleted rather than rewritten. */
    private func stripUnregisteredHooks(hooks: inout [String: Any]) -> Bool {
        let leftover = Array(hooks.keys).filter { !Set(Self.registeredEvents).contains($0) }
        return removeDirectaHandlers(from: &hooks, events: leftover)
    }

    private func removeDirectaHandlers(from hooks: inout [String: Any], events: [String]) -> Bool {
        var removed = false
        let needle = "directa\(GrokWiring.commandSuffix)"
        for event in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                guard var entryHooks = group["hooks"] as? [[String: Any]] else { return group }
                let before = entryHooks.count
                entryHooks.removeAll { hook in
                    ((hook["command"] as? String) ?? "").contains(needle)
                }
                if entryHooks.count != before { removed = true }
                if entryHooks.isEmpty { return nil }
                var updated = group
                updated["hooks"] = entryHooks
                return updated
            }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }
        return removed
    }
}

/** OpenCode: a managed ~/.config/opencode/directa.md standing instruction, wired
    in through the `instructions` array of the harness's global config.

    OpenCode has no session-start injection point: it defines no hook config,
    and plugin events carry no stdout-to-context path (the context-pushing
    plugin hooks, `session.compacting` and `chat.system.transform`, are
    experimental). What OpenCode does load into every session is the config's
    `instructions` array, snapshotted at session start, so the managed file
    holds the shared standing instruction (HarnessStandingInstruction) rather
    than a live snapshot of one project. The entry references the managed file
    tilde-relative to the home directory, so it never collides with a
    same-named file in a project (a relative entry resolves against the project
    first) and survives a synced config.

    OpenCode merges every global config file it finds and a later file's
    `instructions` array replaces an earlier file's, so the entry is written to
    the file that wins (opencode.jsonc when it exists, else opencode.json), and
    entries already effective from a losing file move into the array the winner
    carries: without that, landing the entry would switch which array is
    effective and silently deactivate the user's own instruction files.
    Uninstall needs no mirror step because the losing file is never touched.
    Which array is effective is OpenCodeWiring's rule, shared with the app's
    presence check.

    ~/.config/opencode/AGENTS.md is deliberately never written: it would shadow
    ~/.claude/CLAUDE.md, the Claude compatibility file OpenCode reads when no
    global AGENTS.md exists. */
struct OpenCodeAdapter: HarnessAdapter {
    let name = "opencode"
    /** Overridable so tests can point at a scratch file standing in for one of
        the real global config names (OpenCodeWiring.globalLoadOrder); nil means
        the real global config (OpenCodeWiring.settingsURL(inHome:)). */
    var settingsURLOverride: URL?

    var settingsURL: URL {
        settingsURLOverride
            ?? OpenCodeWiring.settingsURL(inHome: FileManager.default.homeDirectoryForCurrentUser)
    }

    /** Sibling of the config file: `…/opencode.jsonc` → `…/directa.md`. */
    var instructionsFileURL: URL {
        settingsURL.deletingLastPathComponent()
            .appending(path: OpenCodeWiring.managedFileName)
    }

    /** The `instructions` entry that references the managed file, derived from
        its location so override (tests) and the real install always agree. */
    var instructionsEntry: String {
        OpenCodeWiring.instructionsEntry(forManagedFileAt: instructionsFileURL)
    }

    /** The install refusal when OPENCODE_CONFIG_DIR moves the surface: that
        override does not merely relocate the directory, OpenCode re-loads the
        default global files alongside it with a concatenating merge, so the
        replace-on-merge model directa relies on does not hold there. Nil means
        the default location is in play. */
    static func wiringRefusal(configDirectoryOverride: String?) -> WireError? {
        guard let overridden = configDirectoryOverride, !overridden.isEmpty else { return nil }
        let managed = URL(fileURLWithPath: overridden)
            .appending(path: OpenCodeWiring.managedFileName)
        let entry = OpenCodeWiring.instructionsEntry(forManagedFileAt: managed)
        return WireError(
            code: .configInvalid,
            hint: "directa hook install",
            message:
                "OpenCode's config directory is overridden by OPENCODE_CONFIG_DIR "
                + "(\(overridden)), which changes how OpenCode merges its global config, so "
                + "directa wires only the default location. Unset OPENCODE_CONFIG_DIR and "
                + "rerun, or wire it by hand: put the standing instruction in \(managed.path) "
                + "and add \"\(entry)\" to the instructions array of the config OpenCode loads"
        )
    }

    func install(cliPath: String) throws -> String {
        if let refusal = Self.wiringRefusal(
            configDirectoryOverride: ProcessInfo.processInfo.environment["OPENCODE_CONFIG_DIR"])
        {
            throw refusal
        }
        var settings = try loadEditableSettings()
        let entries: [String]
        if settings["instructions"] == nil {
            entries = shadowedEntries()
        } else if let carried = settings["instructions"] as? [String] {
            entries = carried
        } else {
            throw WireError(
                code: .configInvalid,
                hint: "directa hook install",
                message:
                    "directa left \(settingsURL.path) alone: its instructions value is not an "
                    + "array of paths. Fix or remove the instructions key, then rerun")
        }
        try HarnessStandingInstruction.write(to: instructionsFileURL)
        if entries.contains(instructionsEntry) {
            return "OpenCode instructions entry already installed (\(settingsURL.path))"
        }
        settings["instructions"] = entries + [instructionsEntry]
        try writeSettings(settings)
        return "OpenCode instructions entry installed in \(settingsURL.path)"
    }

    func uninstall() throws -> String {
        var settings = try loadEditableSettings()
        guard let carried = settings["instructions"] as? [String],
            carried.contains(instructionsEntry)
        else {
            /** No entry to remove. A managed file left behind by a hand edit or
                a partial install is inert but stale, so it still goes. */
            if FileManager.default.fileExists(atPath: instructionsFileURL.path) {
                try HarnessStandingInstruction.remove(at: instructionsFileURL)
                return
                    "OpenCode instructions entry not present; removed the stale managed instructions file (\(instructionsFileURL.path))"
            }
            return "OpenCode instructions entry not present (\(settingsURL.path))"
        }
        let remaining = carried.filter { $0 != instructionsEntry }
        if remaining.isEmpty {
            settings.removeValue(forKey: "instructions")
        } else {
            settings["instructions"] = remaining
        }
        try HarnessStandingInstruction.remove(at: instructionsFileURL)
        if settings.isEmpty, FileManager.default.fileExists(atPath: settingsURL.path) {
            /** A file that held only directa's entry is directa's litter; a file
                holding anything else stays. */
            try FileManager.default.removeItem(at: settingsURL)
        } else {
            try writeSettings(settings)
        }
        return "OpenCode instructions entry removed from \(settingsURL.path)"
    }

    func hookState() -> HarnessHookState {
        guard harnessPresent else { return .harnessAbsent }
        guard effectiveEntryPresent() else { return .notInstalled }
        let managedExists = FileManager.default.fileExists(atPath: instructionsFileURL.path)
        return .installed(path: instructionsFileURL.path, pathExists: managedExists)
    }

    private var configDirectory: URL {
        settingsURL.deletingLastPathComponent()
    }

    private func effectiveEntryPresent() -> Bool {
        guard
            let effective = OpenCodeWiring.effectiveInstructions(inDirectory: configDirectory)
        else { return false }
        return effective.entries.contains(instructionsEntry)
    }

    /** Entries live today from a file other than the one directa edits: the
        winner's array replaces them on merge, so install moves them into the
        array it writes. */
    private func shadowedEntries() -> [String] {
        guard
            let effective = OpenCodeWiring.effectiveInstructions(inDirectory: configDirectory),
            effective.file != settingsURL
        else { return [] }
        return effective.entries
    }

    /** loadSettings with a refusal that tells the OpenCode truth: comments and
        trailing commas are legal JSONC for OpenCode and unreadable for
        JSONSerialization, and directa cannot preserve them on rewrite. */
    private func loadEditableSettings() throws -> [String: Any] {
        do {
            return try loadSettings()
        } catch is WireError {
            throw WireError(
                code: .configInvalid,
                hint: "directa hook install",
                message:
                    "directa could not read \(settingsURL.path) as JSON, so it left the file "
                    + "alone. For OpenCode this most often means JSONC comments or trailing "
                    + "commas, which are legal for OpenCode but which directa cannot preserve "
                    + "when it rewrites the file; a file missing read permission reads the "
                    + "same. Move the settings to pure JSON (and check the file is readable), "
                    + "or edit the instructions key by hand (directa's entry is \""
                    + "\(instructionsEntry)\"), then rerun")
        }
    }
}
