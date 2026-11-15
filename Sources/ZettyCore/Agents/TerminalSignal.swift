import Foundation

/// Something a pane's terminal reported that can say what its agent is doing
/// (spec 2026-11-14, section 7). Live, local panes only: signals reach Zetty
/// only while a pane is attached, and a remote pane's are its serving Mac's.
public enum TerminalSignal: Equatable, Sendable {
    /// OSC 9 / OSC 777 desktop notification.
    case notification(title: String?, body: String?)
    /// OSC 9;4 progress: `false` when the program cleared it, else `true`.
    case progress(active: Bool)
    /// OSC 133;D: the shell's command finished (only with shell integration).
    case commandFinished(exitCode: Int?)
    /// BEL.
    case bell
}
