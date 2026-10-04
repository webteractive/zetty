import Foundation

/// What a tile header's end-session button does to the pane it shows.
///
/// Ending a session is closing its pane — lifetime follows model ownership, so
/// there is no "kill the session, keep the pane". What closing means depends
/// on what else the project holds, and the last pane of a project cannot be
/// closed at all, so there the button hibernates the project instead: the
/// session ends and the layout is kept.
public enum TileEndAction: Equatable, Sendable {
    /// Other panes share its tab.
    case closePane
    /// It is its tab's only pane, and the project has other tabs.
    case closeTab
    /// It is the project's only pane.
    case hibernateProject

    /// nil when there is nothing to offer: the project's only pane, in a
    /// project that cannot hibernate (Home, a scratch terminal, or one already
    /// dormant). The button is not built then, rather than built dead.
    public static func resolve(panesInTab: Int, tabsInProject: Int,
                               canHibernate: Bool) -> TileEndAction? {
        if panesInTab > 1 { return .closePane }
        if tabsInProject > 1 { return .closeTab }
        return canHibernate ? .hibernateProject : nil
    }

    public var symbol: String {
        switch self {
        case .closePane, .closeTab: return "stop.circle"
        case .hibernateProject: return "moon"
        }
    }

    public var fallbackGlyph: String {
        switch self {
        case .closePane, .closeTab: return "■"
        case .hibernateProject: return "☾"
        }
    }

    public var tooltip: String {
        switch self {
        case .closePane: return "End this session (closes the pane)"
        case .closeTab: return "End this session (closes its tab)"
        case .hibernateProject:
            return "Hibernate this project (its only pane; the session ends, the layout is kept)"
        }
    }

    /// The noun the busy-pane confirmation names.
    public var confirmationSubject: String {
        switch self {
        case .closePane: return "Pane"
        case .closeTab: return "Tab"
        case .hibernateProject: return "project"
        }
    }
}
