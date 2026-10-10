import Foundation

// MARK: - Settings-window editing
//
// The Settings window edits two repeated-line parts of the config as free text:
// the prefix layer's `bind` / `copy-bind` lines and the forwarded ghostty
// directives. Both go through here so the text round-trips through the same
// rules the file parser uses, and so a line that can't be applied is reported
// instead of silently written (or silently dropped).

extension AppConfig {

    /// The result of applying edited text: the new config, plus one message per
    /// line that was not applied. An empty `issues` means every line landed.
    public struct EditResult: Equatable, Sendable {
        public let config: AppConfig
        public let issues: [String]
    }

    /// The `prefix = …` value as written, or `nil` when the default is in use.
    public var prefixSourceValue: String? {
        keybindings.sourceLines.last { $0.hasPrefix("prefix = ") }
            .map { String($0.dropFirst("prefix = ".count)) }
    }

    /// The `bind` / `copy-bind` lines, one per line, for the bindings editor.
    public var bindingLinesText: String {
        keybindings.sourceLines.filter { !$0.hasPrefix("prefix = ") }.joined(separator: "\n")
    }

    /// Rebuilds the key layer from a prefix value (blank → the default) and the
    /// bindings editor's text. `zetty-tmux-passthrough` is kept as it was.
    ///
    /// Blank lines and full-line `#` comments are skipped. Anything other than
    /// `bind = …` / `copy-bind = …` is reported, as is a `prefix` line — the
    /// prefix has its own field, and two sources for one value would make the
    /// editor lie about which one won.
    public func settingKeybindings(prefix: String, lines text: String) -> EditResult {
        var bindings = KeyBindingConfiguration(passPrefixToMultiplexer: keybindings.passPrefixToMultiplexer)
        var issues: [String] = []

        let prefixValue = prefix.trimmingCharacters(in: .whitespaces)
        if !prefixValue.isEmpty { bindings.applyPrefix(prefixValue) }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                issues.append("not a binding: \"\(line)\"")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "bind": bindings.applyBind(value, toCopyTable: false)
            case "copy-bind": bindings.applyBind(value, toCopyTable: true)
            case "prefix": issues.append("set the prefix in its own field, not as a line")
            default: issues.append("not a binding: \"\(line)\"")
            }
        }

        var config = self
        config.keybindings = bindings
        return EditResult(config: config, issues: bindings.issues + issues)
    }

    /// The forwarded ghostty directives, one `key = value` per line.
    public var ghosttyDirectivesText: String {
        ghostty.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
    }

    /// Replaces every forwarded ghostty directive with the editor's text.
    ///
    /// Each line goes through `AppConfig.parse`, so exactly what the file
    /// parser would forward is what gets kept. A line the parser would claim
    /// as one of Zetty's own keys is reported rather than kept: written here it
    /// would land in the ghostty block, and on the next load it would be read
    /// as that Zetty setting — overriding the control that owns it.
    public func settingGhosttyDirectives(_ text: String) -> EditResult {
        var directives: [GhosttyDirective] = []
        var issues: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "="),
                  !line[..<eq].trimmingCharacters(in: .whitespaces).isEmpty else {
                issues.append("expected key = value: \"\(line)\"")
                continue
            }
            guard !line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).isEmpty else {
                issues.append("missing a value: \"\(line)\"")
                continue
            }
            let parsed = AppConfig.parse(line).ghostty
            if parsed.isEmpty {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                issues.append("\(key) is a Zetty setting, not a terminal one")
            } else {
                directives += parsed
            }
        }
        var config = self
        config.ghostty = directives
        return EditResult(config: config, issues: issues)
    }
}
