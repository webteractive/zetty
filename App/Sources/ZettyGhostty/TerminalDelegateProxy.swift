import Foundation
import GhosttyTerminal

/// Sits in a terminal view's delegate slot in front of its `TerminalViewState`.
///
/// It forwards every delegate callback the state takes, and passes on the
/// ones that can say what an agent is doing as `onSignal`.
///
/// Not quite transparent: the pinned wrapper also casts its delegate to
/// `TerminalViewState` directly in two places (`AppTerminalView+Lifecycle`:
/// replaying a pending `requestFocus()` on attach, and adopting the system
/// color scheme through the state). With the proxy in the slot both take their
/// other branch. Zetty uses neither — it never calls the state's
/// `requestFocus()`, and the other branch still sets the scheme on the
/// controller — but check both casts on every bump. It also takes OSC 9;4 progress, which the state does not
/// publish at all (the wrapper only hands it to a delegate adopting
/// `TerminalSurfaceProgressReportDelegate`).
///
/// It adopts exactly the protocols `TerminalViewState` adopts at the pinned
/// libghostty-spm (2.2.2026110702, `TerminalViewState+Delegate.swift`), plus
/// progress. The wrapper dispatches with `as?` casts, so adopting one more
/// (say, open-URL handling) would change its behaviour; check this list on
/// every bump.
///
/// The view's delegate slot is weak: `TerminalViewPair.delegateProxy` is
/// this object's only strong owner.
@MainActor
public final class TerminalDelegateProxy:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceScrollbarDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceClipboardConfirmationDelegate,
    TerminalSurfaceColorChangeDelegate,
    TerminalSurfaceFontSizeDelegate,
    TerminalSurfaceProgressReportDelegate
{
    private let state: TerminalViewState
    /// Set by the registry; nil until then (and in a registry that doesn't
    /// want signals, such as a remote project's).
    public var onSignal: ((TerminalSignal) -> Void)?

    public init(state: TerminalViewState) {
        self.state = state
    }

    public func terminalDidChangeTitle(_ title: String) { state.terminalDidChangeTitle(title) }
    public func terminalDidResize(_ size: TerminalGridMetrics) { state.terminalDidResize(size) }
    public func terminalDidChangeFocus(_ focused: Bool) { state.terminalDidChangeFocus(focused) }
    public func terminalDidClose(processAlive: Bool) { state.terminalDidClose(processAlive: processAlive) }
    public func terminalDidChangeWorkingDirectory(_ path: String) { state.terminalDidChangeWorkingDirectory(path) }
    public func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) { state.terminalDidUpdateScrollbar(scrollbar) }
    public func terminalDidAttachSurface(_ surface: TerminalSurface) { state.terminalDidAttachSurface(surface) }
    public func terminalDidDetachSurface() { state.terminalDidDetachSurface() }
    public func terminalDidChangeColor(_ change: TerminalColorChange) { state.terminalDidChangeColor(change) }
    public func terminalDidChangeFontSize(_ fontSize: Float) { state.terminalDidChangeFontSize(fontSize) }
    public func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        state.terminalDidRequestClipboardConfirmation(request)
    }

    public func terminalDidRingBell() {
        state.terminalDidRingBell()
        onSignal?(.bell)
    }

    public func terminalDidRequestDesktopNotification(title: String, body: String) {
        state.terminalDidRequestDesktopNotification(title: title, body: body)
        onSignal?(.notification(title: title.isEmpty ? nil : title, body: body.isEmpty ? nil : body))
    }

    public func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        state.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
        onSignal?(.commandFinished(exitCode: exitCode))
    }

    /// OSC 9;4: set (1), error (2) and indeterminate (3) mean working;
    /// remove (0) means done. Pause (4) says neither, so it reports nothing.
    public func terminalDidReportProgress(state progress: TerminalProgressState, percent: Int?) {
        switch progress {
        case .remove: onSignal?(.progress(active: false))
        case .set, .error, .indeterminate: onSignal?(.progress(active: true))
        case .pause: break
        }
    }
}
