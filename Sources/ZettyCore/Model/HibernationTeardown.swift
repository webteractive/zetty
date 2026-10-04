import Foundation

/// How hibernation ends a project's sessions: a shell sitting at its prompt is
/// asked to `exit`, so it leaves the way a person would (history written,
/// logout hooks run); whatever is still alive after `gracePeriod` is killed.
///
/// Pure — the app supplies what the foreground probe and the agent detector
/// currently say about each pane, and does the zmx IO.
public enum HibernationTeardown {

    /// Typed into an idle shell. Ctrl-E then Ctrl-U clears anything sitting at
    /// the prompt first — bash's Ctrl-U only kills BEFORE the cursor — so a
    /// half-typed command can never run glued to `exit`.
    public static let exitInput = "\u{05}\u{15}exit\r"

    /// How long idle shells get to exit before what is left is killed.
    public static let gracePeriod: TimeInterval = 3

    public struct Plan: Equatable, Sendable {
        /// Sessions at a bare shell prompt: sent `exitInput` first.
        public let exit: [String]
        /// Every session of the project, in pane order.
        public let all: [String]

        /// True once none of the exiting sessions is listed any more. Busy
        /// sessions don't hold the wait up — they are killed regardless.
        public func exitsFinished(listed: Set<String>) -> Bool {
            !exit.contains(where: listed.contains)
        }

        /// The project's sessions that are still alive, i.e. what to kill.
        public func remaining(listed: Set<String>) -> [String] {
            all.filter(listed.contains)
        }
    }

    /// - Parameters:
    ///   - foreground: the probe's command per pane. `""` means it looked and
    ///     found a bare shell; a MISSING entry means it never looked, which is
    ///     not the same — that pane gets no `exit` typed into it, since its
    ///     foreground could be an editor or an agent's prompt.
    ///   - agentBusy: panes whose agent the detector reports running or
    ///     needing attention, excluded even if the probe says shell.
    public static func plan(surfaceIDs: [UUID],
                            foreground: [UUID: String],
                            agentBusy: Set<UUID>) -> Plan {
        let exiting = surfaceIDs.filter { foreground[$0] == "" && !agentBusy.contains($0) }
        return Plan(exit: exiting.map(SessionPersistence.sessionName(for:)),
                    all: surfaceIDs.map(SessionPersistence.sessionName(for:)))
    }
}
