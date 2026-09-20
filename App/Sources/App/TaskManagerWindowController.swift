import AppKit
import ZettyCore

// MARK: - TaskManagerWindowController

/// The detached form of the Sessions view: a thin window that hosts
/// `SessionsView` and nothing else.
///
/// Everything visible lives in that view, shared with the bottom drawer, so
/// the two forms cannot drift apart.
@MainActor
final class TaskManagerWindowController: NSWindowController, NSWindowDelegate {

    private let sessions: SessionsView

    init(sessions: SessionsView) {
        self.sessions = sessions
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sessions"
        window.isReleasedWhenClosed = false
        window.appearance = ZTheme.current.appearance
        window.backgroundColor = ZTheme.current.bg1Color
        window.contentMinSize = NSSize(width: 480, height: 240)
        super.init(window: window)
        window.delegate = self

        if let content = window.contentView {
            content.addSubview(sessions)
            NSLayoutConstraint.activate([
                sessions.topAnchor.constraint(equalTo: content.topAnchor),
                sessions.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                sessions.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                sessions.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show() {
        sessions.setActive(true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        sessions.setActive(false)
    }
}
