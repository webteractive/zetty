import Foundation

/// Every action the key layer can dispatch — prefix-table commands (pane, tab,
/// mode entry) and copy-mode commands. Config names are the kebab-case strings
/// accepted by `bind = <chord> <command>` / `copy-bind = <chord> <command>`.
public enum BindingCommand: Hashable, Sendable {
    // Prefix table — panes
    case splitVertical
    case splitHorizontal
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case cyclePanes
    case closePane
    case zoomPane
    case breakPane
    // Prefix table — tabs
    case newTab
    case nextTab
    case previousTab
    case selectTab(Int)
    case renameTab
    // Prefix table — modes & misc
    case enterCopyMode
    case paste
    case sendPrefixLiteral
    case cancelPrefix
    // Broadcast / synchronized input (toggles; App fans out — not a KeyMode)
    case broadcastToggle
    case broadcastAgentsToggle
    // Copy mode — cursor motions
    case copyCursorLeft
    case copyCursorRight
    case copyCursorUp
    case copyCursorDown
    case copyWordForward
    case copyWordBackward
    case copyWordEnd
    case copyLineStart
    case copyLineEnd
    // Copy mode — scrolling
    case copyScrollTop
    case copyScrollBottom
    case copyHalfPageUp
    case copyHalfPageDown
    case copyPageUp
    case copyPageDown
    // Copy mode — selection & exit
    case copyBeginSelection
    case copyBeginLineSelection
    case copyYank
    case copyExit

    // MARK: - Config names

    private static let namesByCommand: [BindingCommand: String] = [
        .splitVertical: "split-vertical",
        .splitHorizontal: "split-horizontal",
        .focusLeft: "focus-left",
        .focusRight: "focus-right",
        .focusUp: "focus-up",
        .focusDown: "focus-down",
        .cyclePanes: "cycle-panes",
        .closePane: "close-pane",
        .zoomPane: "zoom-pane",
        .breakPane: "break-pane",
        .newTab: "new-tab",
        .nextTab: "next-tab",
        .previousTab: "previous-tab",
        .renameTab: "rename-tab",
        .enterCopyMode: "copy-mode",
        .paste: "paste",
        .sendPrefixLiteral: "send-prefix",
        .cancelPrefix: "cancel",
        .broadcastToggle: "broadcast-toggle",
        .broadcastAgentsToggle: "broadcast-agents-toggle",
        .copyCursorLeft: "copy-cursor-left",
        .copyCursorRight: "copy-cursor-right",
        .copyCursorUp: "copy-cursor-up",
        .copyCursorDown: "copy-cursor-down",
        .copyWordForward: "copy-word-forward",
        .copyWordBackward: "copy-word-backward",
        .copyWordEnd: "copy-word-end",
        .copyLineStart: "copy-line-start",
        .copyLineEnd: "copy-line-end",
        .copyScrollTop: "copy-scroll-top",
        .copyScrollBottom: "copy-scroll-bottom",
        .copyHalfPageUp: "copy-half-page-up",
        .copyHalfPageDown: "copy-half-page-down",
        .copyPageUp: "copy-page-up",
        .copyPageDown: "copy-page-down",
        .copyBeginSelection: "copy-begin-selection",
        .copyBeginLineSelection: "copy-begin-line-selection",
        .copyYank: "copy-yank",
        .copyExit: "copy-exit",
    ]

    private static let commandsByName: [String: BindingCommand] =
        Dictionary(uniqueKeysWithValues: namesByCommand.map { ($0.value, $0.key) })

    /// The kebab-case name used in config files.
    public var configName: String {
        if case .selectTab(let n) = self { return "select-tab-\(n)" }
        // Every non-parameterized case is in the table by construction.
        return Self.namesByCommand[self]!
    }

    /// Parses a config command name; `select-tab-N` accepts N in 1...9.
    public init?(configName: String) {
        if let command = Self.commandsByName[configName] {
            self = command
            return
        }
        if configName.hasPrefix("select-tab-"),
           let n = Int(configName.dropFirst("select-tab-".count)),
           (1...9).contains(n) {
            self = .selectTab(n)
            return
        }
        return nil
    }

    // MARK: - Default tables (tmux canon, design doc)

    /// The built-in prefix table. Keys are `KeyChord.normalized` positions.
    public static let defaultPrefixTable: [KeyChord: BindingCommand] = {
        var table: [KeyChord: BindingCommand] = [:]
        func bind(_ chord: String, _ command: BindingCommand) {
            table[KeyChord.parse(chord)!.normalized] = command
        }
        bind("%", .splitVertical)
        bind("\"", .splitHorizontal)
        bind("h", .focusLeft)
        bind("j", .focusDown)
        bind("k", .focusUp)
        bind("l", .focusRight)
        bind("left", .focusLeft)
        bind("down", .focusDown)
        bind("up", .focusUp)
        bind("right", .focusRight)
        bind("o", .cyclePanes)
        bind("x", .closePane)
        bind("z", .zoomPane)
        bind("!", .breakPane)
        bind("c", .newTab)
        bind("n", .nextTab)
        bind("p", .previousTab)
        for n in 1...9 { bind("\(n)", .selectTab(n)) }
        bind(",", .renameTab)
        bind("[", .enterCopyMode)
        bind("]", .paste)
        return table
    }()

    /// The built-in copy-mode table (vi keys). Keys are normalized positions.
    public static let defaultCopyTable: [KeyChord: BindingCommand] = {
        var table: [KeyChord: BindingCommand] = [:]
        func bind(_ chord: String, _ command: BindingCommand) {
            table[KeyChord.parse(chord)!.normalized] = command
        }
        bind("h", .copyCursorLeft)
        bind("j", .copyCursorDown)
        bind("k", .copyCursorUp)
        bind("l", .copyCursorRight)
        bind("left", .copyCursorLeft)
        bind("down", .copyCursorDown)
        bind("up", .copyCursorUp)
        bind("right", .copyCursorRight)
        bind("w", .copyWordForward)
        bind("b", .copyWordBackward)
        bind("e", .copyWordEnd)
        bind("0", .copyLineStart)
        bind("$", .copyLineEnd)
        bind("g", .copyScrollTop)
        bind("G", .copyScrollBottom)
        bind("ctrl+u", .copyHalfPageUp)
        bind("ctrl+d", .copyHalfPageDown)
        bind("ctrl+b", .copyPageUp)
        bind("ctrl+f", .copyPageDown)
        bind("v", .copyBeginSelection)
        bind("V", .copyBeginLineSelection)
        bind("y", .copyYank)
        bind("enter", .copyYank)
        bind("escape", .copyExit)
        bind("q", .copyExit)
        return table
    }()
}
