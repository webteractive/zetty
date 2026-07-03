import AppKit
import ZettyCore

// MARK: - NSEvent → KeyChord

extension KeyChord {
    /// Translates a keyDown event into the engine's chord representation.
    /// Named keys map from hardware key codes; everything else uses
    /// `charactersIgnoringModifiers` (shift is already baked into the
    /// character, matching `KeyChord`'s shift rule). Nil for events with no
    /// usable key (bare modifier changes, dead keys).
    init?(event: NSEvent) {
        var modifiers: ChordModifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.ctrl) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.alt) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.cmd) }

        let named: NamedKey?
        switch event.keyCode {
        case 123: named = .left
        case 124: named = .right
        case 125: named = .down
        case 126: named = .up
        case 53: named = .escape
        case 36, 76: named = .enter
        case 48: named = .tab
        case 49: named = .space
        case 51: named = .backspace
        default: named = nil
        }
        if let named {
            self.init(key: .named(named), modifiers: modifiers)
            return
        }
        guard let character = event.charactersIgnoringModifiers?.first else { return nil }
        self.init(key: .character(character), modifiers: modifiers)
    }
}

// MARK: - KeyInterceptor

/// The single keyDown intercept point for the prefix-key layer: an app-local
/// `NSEvent` monitor that runs before any view sees the key, asks the
/// `KeyBindingEngine` what to do, and either swallows the event (dispatching
/// the resolved command to the view controller) or lets it flow to the
/// terminal untouched.
///
/// Guards, in order: only events in the main terminal window are considered;
/// a first responder that is editing text (command palette, tab rename,
/// settings fields — all `NSTextView` field editors) forces passthrough and
/// resets the engine; active IME composition on the terminal passes through
/// so input methods are never broken.
@MainActor
final class KeyInterceptor {

    private(set) var engine: KeyBindingEngine
    private weak var viewController: TerminalViewController?
    private var monitor: Any?

    init(configuration: KeyBindingConfiguration, viewController: TerminalViewController) {
        self.engine = KeyBindingEngine(
            prefix: configuration.prefix,
            prefixTable: configuration.prefixTable,
            copyTable: configuration.copyTable
        )
        self.viewController = viewController
    }

    /// Replaces the binding tables (config reload). Any armed/copy state is
    /// abandoned — the caller is responsible for exiting copy mode first.
    func apply(configuration: KeyBindingConfiguration) {
        engine = KeyBindingEngine(
            prefix: configuration.prefix,
            prefixTable: configuration.prefixTable,
            copyTable: configuration.copyTable
        )
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let viewController,
              let window = viewController.view.window,
              event.window === window else { return event }

        // Text editing anywhere (palette, rename, settings) owns the keyboard.
        if let responder = window.firstResponder, responder is NSTextView {
            if engine.mode != .normal {
                engine.reset()
                viewController.keyModeDidChange(.normal)
            }
            return event
        }

        // Never fight the input method mid-composition.
        if let client = window.firstResponder as? NSTextInputClient, client.hasMarkedText() {
            return event
        }

        guard let chord = KeyChord(event: event) else { return event }

        let modeBefore = engine.mode
        let resolution = engine.handle(chord)
        if engine.mode != modeBefore {
            viewController.keyModeDidChange(engine.mode)
        }

        switch resolution {
        case .passthrough:
            return event
        case .consumeNoop:
            return nil
        case .consume(let command):
            viewController.perform(binding: command, interceptor: self)
            return nil
        }
    }
}

// MARK: - Command dispatch

extension TerminalViewController {

    /// Executes one resolved binding command. Pane/tab commands reuse the
    /// existing action methods; copy-mode commands forward to the
    /// `CopyModeController`.
    func perform(binding command: BindingCommand, interceptor: KeyInterceptor) {
        switch command {
        // Panes
        case .splitVertical: splitVertical(nil)
        case .splitHorizontal: splitHorizontal(nil)
        case .focusLeft: focusPane(.left)
        case .focusRight: focusPane(.right)
        case .focusUp: focusPane(.up)
        case .focusDown: focusPane(.down)
        case .cyclePanes: cyclePaneFocus(nil)
        case .closePane: closePane(nil)
        case .zoomPane: zoomPane(nil)

        // Tabs
        case .newTab: newTab(nil)
        case .nextTab: selectNextTab(nil)
        case .previousTab: selectPreviousTab(nil)
        case .selectTab(let n): selectTab(number: n)
        case .renameTab: beginRenameActiveTab()

        // Modes & misc
        case .enterCopyMode:
            if !enterCopyMode() {
                // Nothing to navigate (no live pane) — leave copy mode again.
                interceptor.engine.exitCopyMode()
                keyModeDidChange(interceptor.engine.mode)
            }
        case .paste: pasteIntoFocusedPane()
        case .sendPrefixLiteral: sendPrefixLiteral(interceptor.engine)
        case .cancelPrefix: break   // chip already cleared by the mode change

        // Copy mode
        case .copyYank, .copyExit:
            copyMode.perform(command)
        case .copyCursorLeft, .copyCursorRight, .copyCursorUp, .copyCursorDown,
             .copyWordForward, .copyWordBackward, .copyWordEnd,
             .copyLineStart, .copyLineEnd,
             .copyScrollTop, .copyScrollBottom,
             .copyHalfPageUp, .copyHalfPageDown, .copyPageUp, .copyPageDown,
             .copyBeginSelection, .copyBeginLineSelection:
            copyMode.perform(command)
        }
    }

    /// Sends the literal prefix chord to the focused pane's pty (prefix
    /// pressed twice — e.g. a nested tmux needs the real Ctrl+B).
    private func sendPrefixLiteral(_ engine: KeyBindingEngine) {
        guard case .character(let character) = engineLiteralKey(engine) else { return }
        let text: String
        if let ascii = character.asciiValue, ascii >= 97, ascii <= 122,
           enginePrefixHasCtrl(engine) {
            // ctrl+letter → C0 control byte (a=0x01 … z=0x1A).
            text = String(UnicodeScalar(ascii - 96))
        } else {
            text = String(character)
        }
        _ = sendInput(target: .focused, text: text, enter: false, keys: [])
    }

    private func engineLiteralKey(_ engine: KeyBindingEngine) -> ChordKey { engine.prefixChord.key }
    private func enginePrefixHasCtrl(_ engine: KeyBindingEngine) -> Bool {
        engine.prefixChord.modifiers.contains(.ctrl)
    }
}
