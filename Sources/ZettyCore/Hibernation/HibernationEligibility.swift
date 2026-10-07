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
        /// The foreground program has a command of its own still running
        /// (`ForegroundProcess.hasDetachedWork`).
        public var hasBackgroundWork: Bool

        public init(foreground: String?, agentStatus: AgentStatus?, promptBoxEmpty: Bool? = nil,
                    hasBackgroundWork: Bool = false) {
            self.foreground = foreground
            self.agentStatus = agentStatus
            self.promptBoxEmpty = promptBoxEmpty
            self.hasBackgroundWork = hasBackgroundWork
        }
    }

    public static func keepsAwake(_ pane: Pane) -> Bool {
        if pane.agentStatus == .running { return true }
        guard let foreground = pane.foreground, !foreground.isEmpty else {
            // Nothing read from the pane: the hook's word is all there is.
            return pane.agentStatus == .needsAttention
        }
        // Something holds the foreground. Only an agent that can leave a
        // handoff, PROVEN to be doing nothing, at an empty prompt box, may be
        // put away.
        guard isHandoffAgent(foreground), isAtRest(pane.agentStatus) else { return true }
        // Its turn is over and something it started is not: a dev server, a
        // long build. Before handoffs any foreground process kept the project
        // awake, so that work was safe from the timer, and it still is.
        if pane.hasBackgroundWork { return true }
        return pane.promptBoxEmpty != true
    }

    /// Whether reading this pane's screen could change the answer, so the
    /// caller only pays for `zmx history` where it matters.
    public static func needsPromptBox(_ pane: Pane) -> Bool {
        guard let foreground = pane.foreground, isHandoffAgent(foreground),
              !pane.hasBackgroundWork else { return false }
        return isAtRest(pane.agentStatus)
    }

    /// `needsAttention` counts, and the screen then decides. Claude fires its
    /// notification hook after a minute of sitting at its prompt ("waiting
    /// for your input"), which arrives as the same status a permission prompt
    /// does: read as "waiting on the person", it kept every idle Claude's
    /// project awake for good. A real question replaces the prompt box with a
    /// menu, so an EMPTY box under that status is an agent with nothing to ask.
    private static func isAtRest(_ status: AgentStatus?) -> Bool {
        status == .idle || status == .needsAttention
    }

    private static func isHandoffAgent(_ foreground: String) -> Bool {
        AgentKind(rawValue: foreground).map(HandoffFork.supports) ?? false
    }
}
