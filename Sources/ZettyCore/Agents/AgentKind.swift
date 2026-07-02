public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case opencode
    case aider
    case gemini
    case hermes

    /// Human-readable name (used for the tab title when this agent is running).
    public var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .codex:    return "Codex"
        case .opencode: return "opencode"
        case .aider:    return "Aider"
        case .gemini:   return "Gemini"
        case .hermes:   return "Hermes"
        }
    }
}
