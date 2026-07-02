import Foundation

/// A coding-agent harness whose lifecycle hooks quertty can install.
public enum Harness: String, CaseIterable, Sendable {
    case claude
    case codex
    case hermes

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .hermes: return "Hermes"
        }
    }

    /// The `AgentKind` events from this harness are reported as.
    public var agentKind: AgentKind {
        switch self {
        case .claude: return .claude
        case .codex:  return .codex
        case .hermes: return .hermes
        }
    }

    /// All three harnesses expose a config-file hook mechanism quertty can
    /// install into: Claude `settings.json` hooks, Codex `notify`, Hermes
    /// `config.yaml` hooks.
    public var supportsAutoInstall: Bool { true }
}
