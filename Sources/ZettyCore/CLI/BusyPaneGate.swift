import Foundation

/// Whether a destructive request that arrived over the control socket may go
/// ahead. The GUI asks the user in a dialog; the socket never can, because
/// `NSAlert.runModal` on the main thread stops every other zetty command until
/// someone clicks — which is how a ritual's `scratch-clear`, issued while its
/// own agent was still busy, froze the whole CLI.
public enum BusyPaneGate {

    public struct BusyPane: Equatable, Sendable {
        /// The pane's 8-hex short id, as `status` shows it.
        public var pane: String
        /// What is running in front of its shell.
        public var command: String

        public init(pane: String, command: String) {
            self.pane = pane
            self.command = command
        }
    }

    /// What ran in front of each preserved session when a request arrived,
    /// read for that request alone.
    ///
    /// The app's own map of foreground processes is refreshed by a poll that
    /// skips every tick while Zetty is not the active app, so it freezes
    /// exactly when agents and scripts call the CLI: a `sleep` started in a
    /// pane after Zetty lost focus read as a bare shell, and an unforced
    /// `hibernate` killed it. A gated request is therefore answered from
    /// this, taken off-main as it arrives.
    public enum Reading: Equatable, Sendable {
        /// Session name → foreground tool, "" for a bare shell. A session
        /// missing from it (a pane without a preserved session) falls back to
        /// the cached map, which is all there is for it.
        case taken([String: String])
        /// `ps` failed or timed out. Busy cannot be known, so nothing that
        /// ends a session goes ahead unforced.
        case failed
    }

    /// What runs in front of the pane whose session is `session`: this
    /// request's reading when it has one, else the cached map's `cached`.
    public static func command(session: String, reading: Reading?, cached: String?) -> String? {
        if case .taken(let commands) = reading, let fresh = commands[session] { return fresh }
        return cached
    }

    /// The answer when the reading failed and nothing was forced.
    public static let unreadable =
        "could not read what is running in the panes — pass --force to close them anyway"

    /// nil to proceed; otherwise the error to answer the CLI with.
    public static func refusal(busy: [BusyPane], force: Bool) -> String? {
        guard !busy.isEmpty, !force else { return nil }
        let one = busy.count == 1
        let list = busy.map { "\($0.pane) (\($0.command))" }.joined(separator: ", ")
        return "\(busy.count) busy \(one ? "pane" : "panes"): \(list)"
            + " — pass --force to close \(one ? "it" : "them") anyway"
    }
}
