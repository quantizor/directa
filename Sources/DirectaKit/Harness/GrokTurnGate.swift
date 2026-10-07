/** GROK_HOOK_EVENT, parsed once at the process boundary. Settings JSON uses
    PascalCase event names; the env value is snake_case. PostToolUse is the
    event whose text Grok delivers. PreToolUse is the older registration, still
    accepted until `hook install` replaces it. UserPromptSubmit and everything
    else stay silent: Grok discards the first, and a Stop answer continues the turn. */
public enum GrokHookEvent: Equatable {
    case leftover
    case postToolUse
    case preToolUse
    case unspecified
    case userPromptSubmit

    public static func parse(_ raw: String?) -> GrokHookEvent {
        switch raw?.lowercased() {
        case "post_tool_use": return .postToolUse
        case "pre_tool_use": return .preToolUse
        case "user_prompt_submit": return .userPromptSubmit
        case nil: return .unspecified
        default: return .leftover
        }
    }

    /** The events whose stdout Grok can deliver without continuing the turn. */
    public var deliversContext: Bool {
        switch self {
        case .postToolUse, .preToolUse, .unspecified: true
        case .leftover, .userPromptSubmit: false
        }
    }
}
