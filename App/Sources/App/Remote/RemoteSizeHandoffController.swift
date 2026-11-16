import AppKit
import ZettyCore

/// This Mac's side of `RemoteSizeHandoff`: a pane shown on two Macs takes the
/// size of the screen in use, and that screen is repainted clean.
///
/// It listens for the user coming to a pane: focus moving to it, the window
/// becoming key, a click, a key typed in it, or the pointer moving or
/// scrolling over it. The pointer counts so that a hand on the trackpad
/// redraws the pane before the first key: with the window already key and the
/// pane focused, nothing else fires. It counts only in the Zetty in use
/// (`RemoteSizeHandoff.pointerClaims`): Screen Sharing in front still passes
/// the pointer over the other Zetty, and both then claimed in turn.
/// - A remote pane (another Mac's, shown here) gets the focus marker, and its
///   relay takes the size if it doesn't have it (`RelaySizeDriver`). Typing
///   there needs nothing from here: the relay sees the keys itself.
/// - A local pane that another Mac's screen drives (`remoteTookSize`) gets
///   the claim keys before the user's own key, the server tells the other
///   Mac's relay, and once the program has redrawn, the pane's attach wrapper
///   repaints it from zmx's copy (`SessionPersistence.repaintSignal`).
@MainActor
final class RemoteSizeHandoffController {
    weak var viewController: TerminalViewController?
    /// A local pane took its session's size back. Set while serving.
    /// Only touched on main; set from `AppDelegate`, which isn't main-actor isolated.
    nonisolated(unsafe) var onLocalTakeover: ((String) -> Void)?

    /// Sessions of this Mac's panes that another Mac's screen drives.
    private var remoteDriven: Set<String> = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var pointerMonitor: Any?
    /// The last focus marker the pointer sent. The pointer moves many times a
    /// second, and the relay only needs one marker to take the size.
    private var lastPointerAnnounce: TimeInterval = 0
    private static let pointerAnnounceInterval: TimeInterval = 0.5
    private var keyObserver: NSObjectProtocol?
    private static let work = DispatchQueue(label: "co.webteractive.zetty.remote-size", qos: .userInitiated)

    func install(in window: NSWindow) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            if let window, event.window === window {
                self?.engage(window.firstResponder as? NSView, typing: true)
            }
            return event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak window] event in
            guard let window, event.window === window else { return event }
            // A click can move focus first; act on wherever it lands.
            DispatchQueue.main.async { self?.engage(window.firstResponder as? NSView, typing: false) }
            return event
        }
        // The pane under the pointer, focused or not. Mouse-moved events only
        // arrive if the window opts in.
        window.acceptsMouseMovedEvents = true
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { [weak self, weak window] event in
            guard let window, event.window === window, let content = window.contentView,
                  RemoteSizeHandoff.pointerClaims(appActive: NSApp.isActive, windowKey: window.isKeyWindow)
            else { return event }
            self?.engage(content.hitTest(event.locationInWindow), typing: false, pointer: true)
            return event
        }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated { self?.engage(window?.firstResponder as? NSView, typing: false) }
        }
    }

    /// The user came to the pane holding `responder`. For a key, this runs
    /// before the key reaches the pane, so the claim goes first: zmx drops an
    /// arrow or a control key from a screen that doesn't drive the size.
    /// `pointer`: the pointer moved or scrolled over `responder`.
    func engage(_ responder: NSView?, typing: Bool, pointer: Bool = false) {
        guard let responder, let viewController else { return }
        if let remote = viewController.remoteProjectController, remote.isRemoteSurface(responder) {
            guard !typing else { return }
            if pointer {
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastPointerAnnounce >= Self.pointerAnnounceInterval else { return }
                lastPointerAnnounce = now
            }
            remote.announceFocus(responder)
            return
        }
        guard !remoteDriven.isEmpty, let surface = viewController.localSurface(containing: responder) else { return }
        let session = SessionPersistence.sessionName(for: surface.id)
        guard remoteDriven.remove(session) != nil else { return }
        viewController.typeRaw(RemoteSizeHandoff.claim, into: surface)
        onLocalTakeover?(session)
        Self.repaint(session)
    }

    /// Another Mac's screen typed into `session`, one of this Mac's panes.
    func remoteTookSize(session: String) {
        remoteDriven.insert(session)
    }

    /// The Mac that drove `session` let go. Its size is already back here
    /// (`RemoteTerminalHost.detached`); the view still shows what was drawn
    /// for the other screen.
    func remoteLetGo(session: String) {
        guard remoteDriven.remove(session) != nil else { return }
        Self.repaint(session)
    }

    /// Once the program has redrawn at this Mac's size, restarts the pane's
    /// attach under its wrapper, which clears it and replays zmx's copy.
    private static func repaint(_ session: String) {
        work.asyncAfter(deadline: .now() + RemoteSizeHandoff.settle) {
            guard let ps = ZmxRunner.psSnapshot(timeout: 2) else { return }
            for pid in ZmxAttachProcesses.repaintablePIDs(attaching: session, psOutput: ps) {
                kill(pid, SessionPersistence.repaintSignal)
            }
        }
    }
}
