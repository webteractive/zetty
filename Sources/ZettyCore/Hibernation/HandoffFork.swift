import Foundation

/// The headless fork that writes a pane's handoff.
public enum HandoffFork {
    public static func supports(_ kind: AgentKind) -> Bool {
        kind == .claude || kind == .codex
    }
}
