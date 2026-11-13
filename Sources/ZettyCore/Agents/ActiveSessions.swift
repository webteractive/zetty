import Foundation

/// One agent session as the sidebar's Active section sees it, on this Mac or
/// another one. Fed to `ActiveSessions` whatever its status: only working and
/// needs-attention sessions become rows.
public struct ActiveSession: Equatable, Sendable {
    /// Where a click on the row goes.
    public enum Target: Equatable, Sendable {
        case local(projectID: UUID, tabIndex: Int, surfaceID: UUID)
        /// `projectID` is the id that Mac's snapshot gives the project (its
        /// name when it sent none); `paneID` the snapshot's short pane id.
        case remote(machineID: String, projectID: String, tabIndex: Int, paneID: String)
    }

    /// Stable across refreshes: the surface UUID here, "<machine>/<pane>" there.
    public let id: String
    public let status: AgentStatus
    /// The other Mac's name, or nil for this Mac.
    public let machine: String?
    public let project: String
    public let tool: AgentKind?
    public let tabTitle: String
    public let target: Target

    public init(id: String, status: AgentStatus, machine: String?, project: String,
                tool: AgentKind?, tabTitle: String, target: Target) {
        self.id = id
        self.status = status
        self.machine = machine
        self.project = project
        self.tool = tool
        self.tabTitle = tabTitle
        self.target = target
    }

    var isBusy: Bool { status == .running || status == .needsAttention }
}

/// A row of the Active section, in display order.
public struct ActiveRow: Equatable, Sendable {
    public let id: String
    /// "zetty · Claude", "zetty · Claude · tab 2" (and "· pane 1" when the tab
    /// holds several) when the project has several busy sessions,
    /// "WebteractiveGlen · devops · Claude" for another Mac.
    public let label: String
    /// Working or needs attention.
    public let status: AgentStatus
    public let tool: AgentKind?
    public let target: ActiveSession.Target
}

/// Picks and orders the Active section's rows. Pure: fed sessions and a
/// clock, so the sidebar only renders what it returns.
///
/// - A session is a row exactly while it is busy: it appears as soon as it
///   is, and leaves as soon as it stops (gone, idle, errored). Glen asked for
///   no linger (2026-11-12): a row that stays after its agent stopped reads
///   as stuck.
/// - Needs-attention rows come first, then working rows; within each group,
///   the order they entered, oldest first. A session that flips between the
///   two keeps its entry time, so new arrivals never jump ahead of old ones.
///   One that stops and later becomes busy again enters anew, at the bottom.
public final class ActiveSessions {

    private struct Entry {
        var session: ActiveSession
        let entered: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// The rows for `sessions` at `now`.
    public func update(_ sessions: [ActiveSession], now: Date) -> [ActiveRow] {
        // Each busy session's pane number within its tab, in layout order
        // (the order `sessions` arrives in), for telling two agents in one
        // tab apart.
        var paneNumber: [String: Int] = [:]
        var perTab: [String: Int] = [:]
        for session in sessions where session.isBusy {
            let key = Self.tabKey(session)
            perTab[key, default: 0] += 1
            paneNumber[session.id] = perTab[key]
        }
        var next: [String: Entry] = [:]
        for session in sessions where session.isBusy {
            next[session.id] = Entry(session: session, entered: entries[session.id]?.entered ?? now)
        }
        entries = next

        let ordered = entries.values.sorted { a, b in
            let aAsks = a.session.status == .needsAttention, bAsks = b.session.status == .needsAttention
            if aAsks != bAsks { return aAsks }
            if a.entered != b.entered { return a.entered < b.entered }
            return a.session.id < b.session.id
        }.map(\.session)

        // A project with several busy sessions names each row's place: its
        // tab, and its pane when the tab holds more than one. Never the tab's
        // title: that carries the agent's own terminal title, spinner and
        // all, and a label that changes every frame rebuilt the whole sidebar
        // on every frame (bug hunt, 2026-11-13).
        var perProject: [String: Int] = [:]
        for session in ordered { perProject[Self.projectKey(session), default: 0] += 1 }
        return ordered.map { session in
            var parts = [session.machine, session.project, session.tool?.displayName].compactMap { $0 }
            if perProject[Self.projectKey(session), default: 0] > 1 {
                parts.append("tab \(Self.tabIndex(session) + 1)")
                if perTab[Self.tabKey(session), default: 0] > 1, let pane = paneNumber[session.id] {
                    parts.append("pane \(pane)")
                }
            }
            return ActiveRow(id: session.id, label: parts.joined(separator: " · "),
                             status: session.status, tool: session.tool, target: session.target)
        }
    }

    private static func projectKey(_ session: ActiveSession) -> String {
        "\(session.machine ?? "")\u{0}\(session.project)"
    }

    private static func tabIndex(_ session: ActiveSession) -> Int {
        switch session.target {
        case .local(_, let tabIndex, _), .remote(_, _, let tabIndex, _): return tabIndex
        }
    }

    private static func tabKey(_ session: ActiveSession) -> String {
        "\(projectKey(session))\u{0}\(tabIndex(session))"
    }

    /// Another Mac's agent sessions, from the snapshot it sent. Hibernated
    /// projects have no live sessions; the caller passes online Macs only, since
    /// an offline Mac's snapshot is stale.
    public static func remoteSessions(machineID: String, machineName: String,
                                      snapshot: StatusSnapshot) -> [ActiveSession] {
        snapshot.projects.filter { !$0.hibernated }.flatMap { project in
            project.tabs.enumerated().flatMap { tabIndex, tab in
                tab.panes.compactMap { pane -> ActiveSession? in
                    guard let status = pane.agentStatus.flatMap(AgentStatus.init(rawValue:)) else { return nil }
                    return ActiveSession(
                        id: "\(machineID)/\(pane.id)", status: status, machine: machineName,
                        project: project.name,
                        tool: pane.tool.flatMap { AgentRegistry.match(command: $0)?.kind },
                        tabTitle: tab.title,
                        target: .remote(machineID: machineID, projectID: project.id ?? project.name,
                                        tabIndex: tabIndex, paneID: pane.id))
                }
            }
        }
    }
}
