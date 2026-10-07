import Foundation

/// Whether one pane keeps its project awake under `hibernate-after`.
///
/// This replaces "any foreground process is busy", which exempted every
/// project with an agent open: an idle Claude at its prompt has foreground
/// `claude`, and those are the projects holding the most memory.
public enum HibernationEligibility {

    public struct Pane: Equatable, Sendable {
        /// The foreground probe's answer: nil is not probed, "" an idle shell.
        public var foreground: String?
        /// The hook state, never the displayed one: `errored` is a display
        /// state over an agent that is idle underneath.
        public var agentStatus: AgentStatus?
        /// nil when the box was not read, or could not be.
        public var promptBoxEmpty: Bool?

        public init(foreground: String?, agentStatus: AgentStatus?, promptBoxEmpty: Bool? = nil) {
            self.foreground = foreground
            self.agentStatus = agentStatus
            self.promptBoxEmpty = promptBoxEmpty
        }
    }

    public static func keepsAwake(_ pane: Pane) -> Bool {
        if pane.agentStatus == .running || pane.agentStatus == .needsAttention { return true }
        guard let foreground = pane.foreground, !foreground.isEmpty else { return false }
        // Something holds the foreground. Only an agent that can leave a
        // handoff, PROVEN idle, at an empty prompt box, may be put away.
        guard isHandoffAgent(foreground) else { return true }
        return !(pane.agentStatus == .idle && pane.promptBoxEmpty == true)
    }

    /// Whether reading this pane's screen could change the answer, so the
    /// caller only pays for `zmx history` where it matters.
    public static func needsPromptBox(_ pane: Pane) -> Bool {
        guard let foreground = pane.foreground, isHandoffAgent(foreground) else { return false }
        return pane.agentStatus == .idle
    }

    private static func isHandoffAgent(_ foreground: String) -> Bool {
        AgentKind(rawValue: foreground).map(HandoffFork.supports) ?? false
    }
}
