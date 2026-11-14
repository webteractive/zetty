import Foundation

/// One awake pane, as init.lua's events describe it.
public struct PaneRecord: Equatable, Sendable {
    /// The pane's 8-hex short id, as `zetty status` shows it.
    public var pane: String
    public var project: String
    public var cwd: String?

    public init(pane: String, project: String, cwd: String?) {
        self.pane = pane
        self.project = project
        self.cwd = cwd
    }
}

/// init.lua's `zetty.bind` chords: the prefix layer only, written
/// `"prefix>d"` or plain `"d"`.
public enum ScriptBinding {
    /// The normalized prefix-table key for `text`, or nil when it does not
    /// parse (a typo such as `"prefx>d"` must be an error, not a dead key).
    public static func chord(_ text: String) -> KeyChord? {
        var key = text
        if key.hasPrefix("prefix>") { key.removeFirst("prefix>".count) }
        guard key == ">" || !key.contains(">") else { return nil }
        return KeyChord.parse(key)?.normalized
    }
}

/// A workspace change init.lua can subscribe to.
public enum WorkspaceEvent: Equatable, Sendable {
    case paneOpened(PaneRecord)
    case paneClosed(pane: String, project: String)
    case projectFocused(project: String, previous: String?)
}

/// Turns successive snapshots of the awake panes into events.
///
/// Fed from the workspace's own change hooks rather than surface creation, so
/// a view rebuilt for an existing pane is not a new pane. The first snapshot
/// is only a baseline: panes reattached at launch already ran their shells.
public final class PaneEventTracker {
    private var panes: [PaneRecord]?
    private var activeProject: String?

    public init() {}

    /// Moves the baseline to this snapshot and returns what changed: closed
    /// panes (previous order), opened panes (new order), then a project
    /// switch. `emitPaneChanges: false` absorbs pane changes silently, for
    /// panes a script opened or closed itself (a `pane.opened` handler that
    /// splits would otherwise loop); a project switch is reported either way.
    public func update(panes current: [PaneRecord], activeProject currentProject: String?,
                       emitPaneChanges: Bool) -> [WorkspaceEvent] {
        defer {
            panes = current
            activeProject = currentProject
        }
        guard let previous = panes else { return [] }
        var events: [WorkspaceEvent] = []
        if emitPaneChanges {
            let previousIDs = Set(previous.map(\.pane))
            let currentIDs = Set(current.map(\.pane))
            events += previous
                .filter { !currentIDs.contains($0.pane) }
                .map { .paneClosed(pane: $0.pane, project: $0.project) }
            events += current.filter { !previousIDs.contains($0.pane) }.map(WorkspaceEvent.paneOpened)
        }
        if let currentProject, currentProject != activeProject {
            events.append(.projectFocused(project: currentProject, previous: activeProject))
        }
        return events
    }
}
