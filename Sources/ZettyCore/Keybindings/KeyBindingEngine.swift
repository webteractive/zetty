import Foundation

// MARK: - KeyMode

/// The key layer's modal state.
public enum KeyMode: Equatable, Sendable {
    /// Keys flow to the terminal; only the prefix chord is intercepted.
    case normal
    /// The prefix was pressed; the next key resolves via the prefix table.
    case prefixArmed
    /// Copy mode owns every key until yank/exit.
    case copyMode
}

// MARK: - KeyResolution

/// What the interceptor should do with one key press.
public enum KeyResolution: Equatable, Sendable {
    /// Deliver the event to the app/terminal untouched.
    case passthrough
    /// Swallow the event and dispatch this command.
    case consume(BindingCommand)
    /// Swallow the event, nothing to dispatch (arming, unbound key flash).
    case consumeNoop
}

// MARK: - KeyBindingEngine

/// The pure decision core of the prefix-key layer: a three-mode state machine
/// over the prefix and copy-mode binding tables. AppKit-free — the app layer
/// translates `NSEvent`s into `KeyChord`s and executes the returned commands.
public final class KeyBindingEngine {

    public private(set) var mode: KeyMode = .normal

    /// The active prefix chord (normalized) — the app layer needs it to send
    /// the literal prefix bytes on prefix-twice.
    public var prefixChord: KeyChord { prefix }

    private let prefix: KeyChord
    private let prefixTable: [KeyChord: BindingCommand]
    private let copyTable: [KeyChord: BindingCommand]

    public init(
        prefix: KeyChord,
        prefixTable: [KeyChord: BindingCommand],
        copyTable: [KeyChord: BindingCommand]
    ) {
        self.prefix = prefix.normalized
        self.prefixTable = prefixTable
        self.copyTable = copyTable
    }

    /// Resolve one key press against the current mode. Mutates `mode` per the
    /// design-doc transitions.
    public func handle(_ chord: KeyChord) -> KeyResolution {
        let pressed = chord.normalized
        switch mode {
        case .normal:
            guard pressed == prefix else { return .passthrough }
            mode = .prefixArmed
            return .consumeNoop

        case .prefixArmed:
            mode = .normal
            if pressed == prefix { return .consume(.sendPrefixLiteral) }
            if pressed == KeyChord(key: .named(.escape), modifiers: []) {
                return .consume(.cancelPrefix)
            }
            guard let command = prefixTable[pressed] else { return .consumeNoop }
            if command == .enterCopyMode { mode = .copyMode }
            return .consume(command)

        case .copyMode:
            guard let command = copyTable[pressed] else { return .consumeNoop }
            if command == .copyYank || command == .copyExit { mode = .normal }
            return .consume(command)
        }
    }

    /// Back to `.normal` from any mode (config reload, focus loss).
    public func reset() {
        mode = .normal
    }

    /// Leave copy mode after an external exit (pane closed, focus changed);
    /// no-op in other modes.
    public func exitCopyMode() {
        if mode == .copyMode { mode = .normal }
    }
}
