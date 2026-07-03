import Foundation

/// The resolved key-layer configuration: prefix chord plus the two binding
/// tables, built from the compiled-in tmux-canonical defaults with the user's
/// `prefix =` / `bind =` / `copy-bind =` lines applied per-chord (additive —
/// there is no unbind). `issues` collects human-readable messages for lines
/// that were skipped (bad chord, unknown command).
public struct KeyBindingConfiguration: Equatable, Sendable {
    public var prefix: KeyChord
    public var prefixTable: [KeyChord: BindingCommand]
    public var copyTable: [KeyChord: BindingCommand]
    public var issues: [String]
    /// The accepted user lines in canonical `key = value` form, in file order —
    /// `AppConfig.rendered()` re-emits these so runtime persists (theme
    /// switcher, settings) don't drop the user's custom bindings.
    public var sourceLines: [String]

    public init(
        prefix: KeyChord = KeyChord(key: .character("b"), modifiers: [.ctrl]),
        prefixTable: [KeyChord: BindingCommand] = BindingCommand.defaultPrefixTable,
        copyTable: [KeyChord: BindingCommand] = BindingCommand.defaultCopyTable,
        issues: [String] = [],
        sourceLines: [String] = []
    ) {
        self.prefix = prefix
        self.prefixTable = prefixTable
        self.copyTable = copyTable
        self.issues = issues
        self.sourceLines = sourceLines
    }

    // MARK: - Config-line application

    /// Applies a `prefix = <chord>` value.
    public mutating func applyPrefix(_ value: String) {
        guard let chord = KeyChord.parse(value) else {
            issues.append("prefix: invalid chord \"\(value)\"")
            return
        }
        prefix = chord.normalized
        sourceLines.append("prefix = \(value)")
    }

    /// Applies a `bind = <chord> <command>` or `copy-bind = …` value.
    public mutating func applyBind(_ value: String, toCopyTable: Bool) {
        let key = toCopyTable ? "copy-bind" : "bind"
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            issues.append("\(key): expected \"<chord> <command>\", got \"\(value)\"")
            return
        }
        guard let chord = KeyChord.parse(parts[0]) else {
            issues.append("\(key): invalid chord \"\(parts[0])\"")
            return
        }
        guard let command = BindingCommand(configName: parts[1].trimmingCharacters(in: .whitespaces)) else {
            issues.append("\(key): unknown command \"\(parts[1])\"")
            return
        }
        if toCopyTable {
            copyTable[chord.normalized] = command
        } else {
            prefixTable[chord.normalized] = command
        }
        sourceLines.append("\(key) = \(value)")
    }
}
