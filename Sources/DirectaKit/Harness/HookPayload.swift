import Foundation

/** A harness's hook or statusline stdin JSON, decoded once and shared by
    every decision the invocation makes. Lenient by design: every field is
    optional and a field of the wrong type reads as absent rather than failing
    the whole decode, since the payload belongs to a harness directa does not
    control. `parse` answers nil for anything that is not a JSON object. */
public struct HookPayload: Decodable, Equatable {
    /** Antigravity's conversation, stable across the messages inside it. */
    public var conversationId: String?
    /** Cursor's conversation, the `conversation_id` field. */
    public var cursorConversationId: String?
    /** Claude Code's and Grok's session directory. */
    public var cwd: String?
    /** Whether the payload names `cursor_version` at all, with any value:
        every Cursor hook payload carries it and no Claude Code payload does. */
    public var hasCursorVersion: Bool
    /** How far along Antigravity's conversation is. The count grows with the
        conversation and drops when the harness shortens it. */
    public var initialNumSteps: Int?
    /** Antigravity's 0-indexed model call number, as a number (never a
        boolean or a string). It restarts at 0 on each message. */
    public var invocationNumber: Double?
    /** Claude Code's `session_id`. */
    public var sessionId: String?
    /** The statusline's `workspace.current_dir`. */
    public var workspaceCurrentDir: String?
    /** Antigravity's workspace list. */
    public var workspacePaths: [String]?
    /** Grok's workspace root. */
    public var workspaceRoot: String?
    /** Cursor's workspace list. */
    public var workspaceRoots: [String]?

    private enum CodingKeys: String, CodingKey {
        case conversationId
        case cursorConversationId = "conversation_id"
        case cursorVersion = "cursor_version"
        case cwd
        case initialNumSteps
        case invocationNumber = "invocationNum"
        case sessionId = "session_id"
        case workspace
        case workspacePaths
        case workspaceRoot
        case workspaceRoots = "workspace_roots"
    }

    private enum WorkspaceKeys: String, CodingKey {
        case currentDir = "current_dir"
    }

    public static func parse(_ stdin: Data) -> HookPayload? {
        try? JSONCoding.decoder().decode(HookPayload.self, from: stdin)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try? container.decodeIfPresent(String.self, forKey: .conversationId)
        cursorConversationId = try? container.decodeIfPresent(String.self, forKey: .cursorConversationId)
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        hasCursorVersion = container.contains(.cursorVersion)
        initialNumSteps = try? container.decodeIfPresent(Int.self, forKey: .initialNumSteps)
        invocationNumber = try? container.decodeIfPresent(Double.self, forKey: .invocationNumber)
        sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
        workspaceCurrentDir =
            (try? container.nestedContainer(keyedBy: WorkspaceKeys.self, forKey: .workspace))
            .flatMap { try? $0.decodeIfPresent(String.self, forKey: .currentDir) }
        workspacePaths = try? container.decodeIfPresent([String].self, forKey: .workspacePaths)
        workspaceRoot = try? container.decodeIfPresent(String.self, forKey: .workspaceRoot)
        workspaceRoots = try? container.decodeIfPresent([String].self, forKey: .workspaceRoots)
    }
}

/** Resolve the project directory a session-start hook should introspect. Antigravity
    carries workspacePaths; Cursor carries workspace_roots (and CURSOR_PROJECT_DIR);
    Claude Code carries cwd; Grok carries cwd, workspaceRoot, and GROK_WORKSPACE_ROOT.
    Fall back to the process cwd when the payload is empty or malformed. */
public enum HookSessionCwd {
    public static func resolve(
        _ payload: HookPayload?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let candidates = [
            payload?.workspaceRoots?.first, payload?.workspacePaths?.first, payload?.cwd,
            payload?.workspaceRoot, environment["CURSOR_PROJECT_DIR"], environment["GROK_WORKSPACE_ROOT"],
        ]
        for case let candidate? in candidates where !candidate.isEmpty {
            return candidate
        }
        return FileManager.default.currentDirectoryPath
    }
}

/** Whether a session hook speaks for this invocation, decided from the stdin
    payload. Anything unparseable or unexpected answers true for the hooks that
    have no conversation record: a missing context block costs the agent more
    than a duplicate one. */
public enum HookPayloadGate {
    /** Cursor runs the hooks in `~/.claude/settings.json` as well as its own
        (its third-party hooks setting, on by default), so a machine with both
        the claude and cursor hooks installed would inject the block twice into
        a Cursor session. `cursor_version` is in the base of every Cursor hook
        payload and in no Claude Code payload, so it is the stand-down signal.
        The `CURSOR_VERSION` environment variable is not used: a Claude Code
        session started from Cursor's integrated terminal can inherit Cursor's
        environment, and would then lose its only context block. The hook
        stands down only while directa's own Cursor hook is installed, so a
        machine with just the claude hook still gets the block in Cursor.
        `cursorHookInstalled` reads Cursor's settings file, so it is asked
        only for a payload that came from Cursor. */
    public static func claudeHookShouldEmit(
        _ payload: HookPayload?, cursorHookInstalled: () -> Bool
    ) -> Bool {
        guard payload?.hasCursorVersion == true else { return true }
        return !cursorHookInstalled()
    }

}

/** A session hook's stdout: one JSON object in the shape its harness reads,
    through `JSONCoding`. */
public enum HookOutput {
    /** Antigravity's PreInvocation answer; an empty `injectSteps` says nothing. */
    public struct Antigravity: Encodable {
        public struct Step: Encodable {
            public var ephemeralMessage: String

            public init(ephemeralMessage: String) {
                self.ephemeralMessage = ephemeralMessage
            }
        }

        public var injectSteps: [Step]
        /** Set by Antigravity when new err lines should bring the model back.
            Omitted from the JSON when nil, so a quiet answer stays `{"injectSteps":[]}`. */
        public var terminationBehavior: String?

        private enum CodingKeys: String, CodingKey {
            case injectSteps
            case terminationBehavior
        }

        public init(injectSteps: [Step], terminationBehavior: String? = nil) {
            self.injectSteps = injectSteps
            self.terminationBehavior = terminationBehavior
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(injectSteps, forKey: .injectSteps)
            if let terminationBehavior {
                try container.encode(terminationBehavior, forKey: .terminationBehavior)
            }
        }
    }

    /** Claude Code's and Grok's `hookSpecificOutput`. */
    public struct AdditionalContext: Encodable {
        public struct Body: Encodable {
            public var additionalContext: String
            public var hookEventName: String

            public init(additionalContext: String, hookEventName: String) {
                self.additionalContext = additionalContext
                self.hookEventName = hookEventName
            }
        }

        public var hookSpecificOutput: Body

        public init(hookSpecificOutput: Body) {
            self.hookSpecificOutput = hookSpecificOutput
        }
    }

    /** Cursor's snake_case sessionStart answer. */
    public struct Cursor: Encodable {
        private enum CodingKeys: String, CodingKey {
            case additionalContext = "additional_context"
        }

        public var additionalContext: String

        public init(additionalContext: String) {
            self.additionalContext = additionalContext
        }
    }

    public static func encoded(_ value: some Encodable) -> Data? {
        try? JSONCoding.encoder().encode(value)
    }

    public static func write(_ value: some Encodable) {
        guard let data = encoded(value) else { return }
        FileHandle.standardOutput.write(data)
    }
}
