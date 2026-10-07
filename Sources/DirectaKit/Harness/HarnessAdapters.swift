import Foundation

/** Antigravity: PreInvocation hook merged into ~/.gemini/config/hooks.json without
    clobbering existing entries. Emits {"injectSteps": [{"ephemeralMessage": ...}]}. */
public struct AntigravityAdapter: HarnessAdapter {
    public var displayName: String { "Antigravity" }
    var home: URL
    public let name = "antigravity"
    /** Overridable so tests can point at a scratch file; nil means
        `<home>/.gemini/config/hooks.json`. */
    var settingsURLOverride: URL?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        settingsURLOverride: URL? = nil
    ) {
        self.home = home
        self.settingsURLOverride = settingsURLOverride
    }

    /** The conversation file for this harness. The id is the one Antigravity
        sends. The scope keeps it off another harness's file. */
    public static func conversationFileKey(payload: HookPayload?) -> String {
        HookSnapshotStore.fileKey(scope: "antigravity", session: payload?.conversationId)
    }

    public var harnessPresent: Bool {
        let parent = settingsURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) { return true }
        let grandparent = parent.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: grandparent.path)
    }

    public var settingsURL: URL {
        settingsURLOverride ?? home.appending(path: ".gemini/config/hooks.json")
    }

    public func install(cliPath: String) throws -> String {
        let command = "\(cliPath) hook antigravity-session-start"
        let post = "\(cliPath) hook antigravity-post-invocation"
        var settings = try loadSettings()
        var directaGroup = settings["directa"] as? [String: Any] ?? [:]
        var preInvocation = directaGroup["PreInvocation"] as? [[String: Any]] ?? []
        let repaired = repairAntigravityPreInvocation(preInvocation: &preInvocation, command: command)
        let sessionPresent = preInvocation.contains { ($0["command"] as? String) == command }
        if !sessionPresent { preInvocation.append(["command": command, "type": "command"]) }
        var postInvocation = directaGroup["PostInvocation"] as? [[String: Any]] ?? []
        let postPresent = postInvocation.contains { ($0["command"] as? String) == post }
        if !postPresent { postInvocation.append(["command": post, "type": "command"]) }
        if repaired != nil || !sessionPresent || !postPresent {
            directaGroup["PostInvocation"] = postInvocation
            directaGroup["PreInvocation"] = preInvocation
            settings["directa"] = directaGroup
            try writeSettings(settings)
        }
        if let repaired { return repaired }
        if !sessionPresent || !postPresent {
            return "Antigravity PreInvocation hook installed in \(settingsURL.path)"
        }
        return "Antigravity PreInvocation hook already installed (\(settingsURL.path))"
    }

    public func uninstall() throws -> String {
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
        var postInvocation = directaGroup["PostInvocation"] as? [[String: Any]] ?? []
        let postBefore = postInvocation.count
        postInvocation.removeAll { entry in
            ((entry["command"] as? String) ?? "").contains("directa hook antigravity-post-invocation")
        }
        guard preInvocation.count != before || postInvocation.count != postBefore else {
            return "Antigravity hook not present (\(settingsURL.path))"
        }
        if preInvocation.isEmpty {
            directaGroup.removeValue(forKey: "PreInvocation")
        } else {
            directaGroup["PreInvocation"] = preInvocation
        }
        if postInvocation.isEmpty {
            directaGroup.removeValue(forKey: "PostInvocation")
        } else {
            directaGroup["PostInvocation"] = postInvocation
        }
        if directaGroup.isEmpty {
            settings.removeValue(forKey: "directa")
        } else {
            settings["directa"] = directaGroup
        }
        try writeSettings(settings)
        return "Antigravity hook removed from \(settingsURL.path)"
    }

    public func hookState() -> HarnessHookState {
        guard harnessPresent else { return .harnessAbsent }
        guard let settings = try? loadSettings(),
            let directaGroup = settings["directa"] as? [String: Any],
            let path = recordedAntigravityPath(
                in: directaGroup["PreInvocation"], suffix: " hook antigravity-session-start"),
            recordedAntigravityPath(
                in: directaGroup["PostInvocation"], suffix: " hook antigravity-post-invocation") != nil
        else { return .notInstalled }
        return .installed(path: path, pathExists: FileManager.default.isExecutableFile(atPath: path))
    }

    private func recordedAntigravityPath(in value: Any?, suffix: String) -> String? {
        for entry in (value as? [[String: Any]]) ?? [] {
            if let command = entry["command"] as? String,
                let path = recordedPath(from: command, suffix: suffix)
            {
                return path
            }
        }
        return nil
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
public struct ClaudeCodeAdapter: HarnessAdapter {
    public var displayName: String { "Claude Code" }
    var home: URL
    public let name = "claude"
    /** Overridable so tests can point at a scratch file; nil means
        `<home>/.claude/settings.json`. */
    var settingsURLOverride: URL?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        settingsURLOverride: URL? = nil
    ) {
        self.home = home
        self.settingsURLOverride = settingsURLOverride
    }

    public static func conversationFileKey(payload: HookPayload?, environment: [String: String]) -> String {
        HookSnapshotStore.fileKey(
            scope: "claude", session: payload?.sessionId ?? environment["CLAUDE_CODE_SESSION_ID"])
    }

    public var settingsURL: URL {
        settingsURLOverride ?? home.appending(path: ".claude/settings.json")
    }

    public func install(cliPath: String) throws -> String {
        let command = "\(cliPath) hook claude-session-start"
        let post = "\(cliPath) hook claude-post-tool"
        var settings = try loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var sessionStart = hooks["SessionStart"] as? [[String: Any]] ?? []
        let repaired = repairClaudeSessionStart(sessionStart: &sessionStart, command: command)
        let sessionPresent = sessionStart.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains { hook in
                (hook["command"] as? String) == command
            }
        }
        if !sessionPresent {
            sessionStart.append([
                "hooks": [["command": command, "type": "command"]],
                "matcher": "startup|resume|clear|compact",
            ])
        }
        let postAdded = ensureClaudePostTool(&hooks, command: post)
        if repaired != nil || !sessionPresent || postAdded {
            hooks["SessionStart"] = sessionStart
            settings["hooks"] = hooks
            try writeSettings(settings)
        }
        if let repaired { return repaired }
        if !sessionPresent || postAdded {
            return "Claude Code SessionStart hook installed (matcher startup|resume|clear|compact) in \(settingsURL.path)"
        }
        return "Claude Code SessionStart hook already installed (\(settingsURL.path))"
    }

    public func uninstall() throws -> String {
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
                let command = (hook["command"] as? String) ?? ""
                return command.contains("directa hook claude-session-start")
                    || command.contains("directa hook claude-post-tool")
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
        if var postTool = hooks["PostToolUse"] as? [[String: Any]] {
            postTool = postTool.compactMap { entry in
                guard var entryHooks = entry["hooks"] as? [[String: Any]] else { return entry }
                let before = entryHooks.count
                entryHooks.removeAll { hook in
                    ((hook["command"] as? String) ?? "").contains("directa hook claude-post-tool")
                }
                if entryHooks.count != before { removed = true }
                if entryHooks.isEmpty { return nil }
                var updated = entry
                updated["hooks"] = entryHooks
                return updated
            }
            if postTool.isEmpty {
                hooks.removeValue(forKey: "PostToolUse")
            } else {
                hooks["PostToolUse"] = postTool
            }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings)
        return "Claude Code SessionStart hook removed from \(settingsURL.path)"
    }

    public func hookState() -> HarnessHookState {
        guard harnessPresent else { return .harnessAbsent }
        guard let settings = try? loadSettings(),
            let hooks = settings["hooks"] as? [String: Any],
            let path = recordedClaudePath(in: hooks["SessionStart"], suffix: " hook claude-session-start"),
            recordedClaudePath(in: hooks["PostToolUse"], suffix: " hook claude-post-tool") != nil
        else { return .notInstalled }
        return .installed(path: path, pathExists: FileManager.default.isExecutableFile(atPath: path))
    }

    private func recordedClaudePath(in value: Any?, suffix: String) -> String? {
        for entry in (value as? [[String: Any]]) ?? [] {
            for hook in (entry["hooks"] as? [[String: Any]]) ?? [] {
                if let command = hook["command"] as? String,
                    let path = recordedPath(from: command, suffix: suffix)
                {
                    return path
                }
            }
        }
        return nil
    }

    private func ensureClaudePostTool(_ hooks: inout [String: Any], command: String) -> Bool {
        var groups = hooks["PostToolUse"] as? [[String: Any]] ?? []
        let present = groups.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains { hook in
                (hook["command"] as? String) == command
            }
        }
        if present { return false }
        groups.append([
            "hooks": [["command": command, "type": "command"]],
            "matcher": "*",
        ])
        hooks["PostToolUse"] = groups
        return true
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
public struct CursorAdapter: HarnessAdapter {
    public var displayName: String { "Cursor" }
    var home: URL
    public let name = "cursor"
    /** Overridable so tests can point at a scratch file; nil means
        `<home>/.cursor/hooks.json`. */
    var settingsURLOverride: URL?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        settingsURLOverride: URL? = nil
    ) {
        self.home = home
        self.settingsURLOverride = settingsURLOverride
    }

    public static func conversationFileKey(payload: HookPayload?) -> String {
        HookSnapshotStore.fileKey(scope: "cursor", session: payload?.cursorConversationId)
    }

    public var settingsURL: URL {
        settingsURLOverride ?? home.appending(path: ".cursor/hooks.json")
    }

    public func install(cliPath: String) throws -> String {
        let command = "\(cliPath) hook cursor-session-start"
        let post = "\(cliPath) hook cursor-post-tool"
        var settings = try loadSettings()
        if settings["version"] == nil { settings["version"] = 1 }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var sessionStart = hooks["sessionStart"] as? [[String: Any]] ?? []
        let repaired = repairCursorSessionStart(sessionStart: &sessionStart, command: command)
        let sessionPresent = sessionStart.contains { ($0["command"] as? String) == command }
        if !sessionPresent { sessionStart.append(["command": command]) }
        var postTool = hooks["postToolUse"] as? [[String: Any]] ?? []
        let postPresent = postTool.contains { ($0["command"] as? String) == post }
        if !postPresent { postTool.append(["command": post]) }
        if repaired != nil || !sessionPresent || !postPresent {
            hooks["postToolUse"] = postTool
            hooks["sessionStart"] = sessionStart
            settings["hooks"] = hooks
            try writeSettings(settings)
        }
        if let repaired { return repaired }
        if !sessionPresent || !postPresent {
            return "Cursor sessionStart hook installed in \(settingsURL.path)"
        }
        return "Cursor sessionStart hook already installed (\(settingsURL.path))"
    }

    public func uninstall() throws -> String {
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
        var postTool = hooks["postToolUse"] as? [[String: Any]] ?? []
        let postBefore = postTool.count
        postTool.removeAll { entry in
            ((entry["command"] as? String) ?? "").contains("directa hook cursor-post-tool")
        }
        guard sessionStart.count != before || postTool.count != postBefore else {
            return "Cursor sessionStart hook not present (\(settingsURL.path))"
        }
        if sessionStart.isEmpty {
            hooks.removeValue(forKey: "sessionStart")
        } else {
            hooks["sessionStart"] = sessionStart
        }
        if postTool.isEmpty {
            hooks.removeValue(forKey: "postToolUse")
        } else {
            hooks["postToolUse"] = postTool
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

    public func hookState() -> HarnessHookState {
        guard harnessPresent else { return .harnessAbsent }
        guard let settings = try? loadSettings(),
            let hooks = settings["hooks"] as? [String: Any],
            let path = recordedCursorPath(in: hooks["sessionStart"], suffix: " hook cursor-session-start"),
            recordedCursorPath(in: hooks["postToolUse"], suffix: " hook cursor-post-tool") != nil
        else { return .notInstalled }
        return .installed(path: path, pathExists: FileManager.default.isExecutableFile(atPath: path))
    }

    private func recordedCursorPath(in value: Any?, suffix: String) -> String? {
        for entry in (value as? [[String: Any]]) ?? [] {
            if let command = entry["command"] as? String,
                let path = recordedPath(from: command, suffix: suffix)
            {
                return path
            }
        }
        return nil
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
public struct GrokAdapter: HarnessAdapter {
    public var displayName: String { "Grok Build" }
    var home: URL
    public let name = "grok"
    static let registeredEvents = GrokWiring.registeredEvents
    /** Overridable so tests can point at a scratch file; nil means
        `<home>/.grok/hooks/directa.json`. */
    var settingsURLOverride: URL?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        settingsURLOverride: URL? = nil
    ) {
        self.home = home
        self.settingsURLOverride = settingsURLOverride
    }

    /** Sibling of the hooks file: `…/.grok/hooks/directa.json` → `…/.grok/rules/directa.md`. */
    var rulesURL: URL {
        settingsURL.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "rules").appending(path: "directa.md")
    }

    public var harnessPresent: Bool {
        let parent = settingsURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) { return true }
        let grandparent = parent.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: grandparent.path)
    }

    public static func conversationFileKey(payload: HookPayload?, environment: [String: String]) -> String {
        HookSnapshotStore.fileKey(
            scope: "grok", session: environment["GROK_SESSION_ID"] ?? payload?.sessionId)
    }

    public var settingsURL: URL {
        settingsURLOverride ?? home.appending(path: ".grok/hooks/directa.json")
    }

    public func install(cliPath: String) throws -> String {
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

    public func uninstall() throws -> String {
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

    public func hookState() -> HarnessHookState {
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
                        GrokWiring.isOurCommand(existing),
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
        for event in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                guard var entryHooks = group["hooks"] as? [[String: Any]] else { return group }
                let before = entryHooks.count
                entryHooks.removeAll { hook in
                    GrokWiring.isOurCommand((hook["command"] as? String) ?? "")
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
public struct OpenCodeAdapter: HarnessAdapter {
    public var displayName: String { "OpenCode" }
    var home: URL
    public let name = "opencode"
    /** Overridable so tests can point at a scratch file standing in for one of
        the real global config names (OpenCodeWiring.globalLoadOrder); nil means
        the real global config (OpenCodeWiring.settingsURL(inHome:)). */
    var settingsURLOverride: URL?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        settingsURLOverride: URL? = nil
    ) {
        self.home = home
        self.settingsURLOverride = settingsURLOverride
    }

    public var settingsURL: URL {
        settingsURLOverride ?? OpenCodeWiring.settingsURL(inHome: home)
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
            hint: "run: directa hook install",
            message:
                "OpenCode's config directory is overridden by OPENCODE_CONFIG_DIR "
                + "(\(overridden)), which changes how OpenCode merges its global config, so "
                + "directa wires only the default location. Unset OPENCODE_CONFIG_DIR and "
                + "rerun, or wire it by hand: put the standing instruction in \(managed.path) "
                + "and add \"\(entry)\" to the instructions array of the config OpenCode loads"
        )
    }

    public func install(cliPath: String) throws -> String {
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
                hint: "run: directa hook install",
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

    public func uninstall() throws -> String {
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

    public func hookState() -> HarnessHookState {
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
                hint: "run: directa hook install",
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
