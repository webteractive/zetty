import Foundation

public enum AgentRegistry {
    public static let all: [AgentDescriptor] = [
        AgentDescriptor(kind: .claude,   displayName: "Claude Code", binaryNames: ["claude"],   honorsHooks: true,  idleAfter: 5),
        AgentDescriptor(kind: .codex,    displayName: "Codex",       binaryNames: ["codex"],    honorsHooks: false, idleAfter: 5),
        AgentDescriptor(kind: .opencode, displayName: "opencode",    binaryNames: ["opencode"], honorsHooks: false, idleAfter: 5),
        AgentDescriptor(kind: .aider,    displayName: "Aider",       binaryNames: ["aider"],    honorsHooks: false, idleAfter: 5),
        AgentDescriptor(kind: .gemini,   displayName: "Gemini",      binaryNames: ["gemini"],   honorsHooks: false, idleAfter: 5),
        AgentDescriptor(kind: .hermes,   displayName: "hermes",      binaryNames: ["hermes"],   honorsHooks: false, idleAfter: 5),
    ]

    /// Resolves a foreground command (bare name or full path) to a descriptor by
    /// matching the last path component against `binaryNames`, case-insensitively.
    public static func match(command: String) -> AgentDescriptor? {
        let leaf = (command as NSString).lastPathComponent.lowercased()
        guard !leaf.isEmpty else { return nil }
        return all.first { $0.binaryNames.contains { $0.lowercased() == leaf } }
    }
}
