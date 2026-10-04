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

    /// nil to proceed; otherwise the error to answer the CLI with.
    public static func refusal(busy: [BusyPane], force: Bool) -> String? {
        guard !busy.isEmpty, !force else { return nil }
        let one = busy.count == 1
        let list = busy.map { "\($0.pane) (\($0.command))" }.joined(separator: ", ")
        return "\(busy.count) busy \(one ? "pane" : "panes"): \(list)"
            + " — pass --force to close \(one ? "it" : "them") anyway"
    }
}
