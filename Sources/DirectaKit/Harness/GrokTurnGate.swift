import Foundation

/** GROK_HOOK_EVENT, parsed once at the process boundary. Settings JSON uses
    PascalCase event names; the env value is snake_case. */
public enum GrokHookEvent: Equatable {
    case leftover
    case preToolUse
    case unspecified
    case userPromptSubmit

    public static func parse(_ raw: String?) -> GrokHookEvent {
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
public enum GrokSessionHook {
    public enum Action: Equatable {
        case emitAndMark
        case emitUnmarked
        case silent
        case silentPersist
    }

    /** Per-session turn gate, persisted under TMPDIR so the OS tmp reaper is
        the expiry. `emittedThisTurn` starts false so a PreToolUse that beats
        UserPromptSubmit still emits once. */
    public struct TurnState: Codable, Equatable, Sendable {
        public var emittedThisTurn: Bool
        public var turn: Int

        public init(emittedThisTurn: Bool, turn: Int) {
            self.emittedThisTurn = emittedThisTurn
            self.turn = turn
        }
    }

    public static func action(for event: GrokHookEvent, state: inout TurnState) -> Action {
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
    public static func markEmitted(_ state: inout TurnState) {
        state.emittedThisTurn = true
    }
}

/** On-disk half of `GrokSessionHook.TurnState`. Files are keyed by Grok's
    session id; `DIRECTA_GROK_HOOK_STATE_DIR` relocates the directory for tests. */
public enum GrokTurnGate {
    public static let stateDirEnvironmentKey = "DIRECTA_GROK_HOOK_STATE_DIR"
    public static let stateDirName = "directa-grok-hook"

    public static func directory(environment: [String: String]) -> URL {
        if let override = environment[stateDirEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let tmp = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: tmp).appending(path: stateDirName)
    }

    public static let fallbackKey = "nosession"
    public static let maxKeyLength = 128

    public static func sessionKey(_ raw: String?) -> String {
        let trimmed = (raw ?? "").replacing(/[^A-Za-z0-9._-]/) { _ in "" }
        let sliced = String(trimmed.prefix(maxKeyLength))
        if sliced.isEmpty || sliced == "." || sliced == ".." { return fallbackKey }
        return sliced
    }

    public static func load(sessionKey: String, directory: URL) -> GrokSessionHook.TurnState {
        let url = directory.appending(path: sessionKey)
        return AtomicFile.loadDefensively(GrokSessionHook.TurnState.self, from: url)
            ?? GrokSessionHook.TurnState(emittedThisTurn: false, turn: 0)
    }

    public static func save(
        _ state: GrokSessionHook.TurnState, sessionKey: String, directory: URL
    ) {
        let url = directory.appending(path: sessionKey)
        guard let data = try? JSONCoding.encoder().encode(state) else { return }
        try? AtomicFile.write(data, to: url)
    }
}
