import Foundation

/// One session as the task manager renders it.
public struct TaskRow: Equatable, Sendable {
    public let session: String
    /// nil when no surface claims this session — an orphan.
    public let surfaceID: UUID?
    public let paneLabel: String?
    public let running: String
    public let load: SessionLoad

    public var isOrphan: Bool { surfaceID == nil }
}

/// Matches live zmx sessions against the workspace that owns them.
public enum TaskInventory {

    /// Shown when the foreground probe has nothing for a session: it is idle
    /// at a prompt, which `ForegroundProcess` reports as nil.
    public static let idleLabel = "shell"

    /// - Parameter owned: MUST be `WorkspaceModel.sessionOwnerSurfaceIDs`,
    ///   which spans hibernated projects. `allSurfaceIDs` excludes them, and
    ///   using it here reports every dormant project's session as an orphan.
    public static func rows(sessions: [String: Int32],
                            owned: [UUID],
                            paneLabels: [UUID: String],
                            running: [String: String],
                            loads: [String: SessionLoad]) -> [TaskRow] {
        var bySession: [String: UUID] = [:]
        for id in owned { bySession[SessionPersistence.sessionName(for: id)] = id }

        let rows = sessions.keys.map { name -> TaskRow in
            let surface = bySession[name]
            return TaskRow(
                session: name,
                surfaceID: surface,
                paneLabel: surface.flatMap { paneLabels[$0] },
                // "" is the probe's value for "looked, found a shell" — a
                // meaning, not a missing entry, so it maps to idle too.
                running: running[name].flatMap { $0.isEmpty ? nil : $0 } ?? idleLabel,
                load: loads[name] ?? .none
            )
        }

        // Highest CPU first; unmeasured last; session name breaks ties so the
        // order cannot change between refreshes.
        return rows.sorted { a, b in
            switch (a.load.cpuPercent, b.load.cpuPercent) {
            case let (l?, r?) where l != r: return l > r
            case (nil, .some): return false
            case (.some, nil): return true
            default: return a.session < b.session
            }
        }
    }
}

/// What the task manager needs to know about one project to group its rows.
public struct TaskProjectRef: Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// Every pane the project owns, hibernated ones included.
    public let surfaceIDs: Set<UUID>
    /// False for Home and scratch, which have no hibernate verb anywhere.
    public let canHibernate: Bool
    public let isHibernated: Bool

    public init(id: UUID, name: String, surfaceIDs: Set<UUID>,
                canHibernate: Bool, isHibernated: Bool) {
        self.id = id
        self.name = name
        self.surfaceIDs = surfaceIDs
        self.canHibernate = canHibernate
        self.isHibernated = isHibernated
    }
}

/// One project's sessions, as the task manager renders them under a header.
public struct TaskGroup: Equatable, Sendable {
    public enum Owner: Hashable, Sendable {
        case project(UUID)
        /// Sessions nothing in the workspace claims.
        case orphaned
    }

    public let owner: Owner
    public let title: String
    /// Whether the header offers Hibernate.
    public let canHibernate: Bool
    /// Hibernated, but its sessions have not ended yet — the teardown's grace
    /// period, while idle shells are given the chance to exit.
    public let isHibernating: Bool
    public let rows: [TaskRow]

    /// Sum of the measured rows; nil when none is measured yet, for the same
    /// reason a row shows "—" rather than 0 on the first tick.
    public var cpuPercent: Double? {
        let measured = rows.compactMap(\.load.cpuPercent)
        return measured.isEmpty ? nil : measured.reduce(0, +)
    }

    public var rssBytes: Int64 { rows.reduce(0) { $0 + $1.load.rssBytes } }
}

extension TaskInventory {

    /// Groups `rows` under their projects, in `projects` order (sidebar
    /// order) — NOT by load: a group's Hibernate button must not slide away
    /// while the pointer is on its way to it. Rows keep their incoming order
    /// inside a group, so the busiest still leads. Projects without sessions
    /// get no group; orphans (and any row no project claims) trail.
    public static func groups(rows: [TaskRow], projects: [TaskProjectRef]) -> [TaskGroup] {
        var owner: [UUID: Int] = [:]
        for (index, project) in projects.enumerated() {
            for id in project.surfaceIDs { owner[id] = index }
        }
        var byProject = [[TaskRow]](repeating: [], count: projects.count)
        var unclaimed: [TaskRow] = []
        for row in rows {
            if let id = row.surfaceID, let index = owner[id] {
                byProject[index].append(row)
            } else {
                unclaimed.append(row)
            }
        }

        var groups: [TaskGroup] = projects.indices.compactMap { index in
            let project = projects[index]
            guard !byProject[index].isEmpty else { return nil }
            return TaskGroup(owner: .project(project.id),
                             title: project.name,
                             canHibernate: project.canHibernate && !project.isHibernated,
                             isHibernating: project.isHibernated,
                             rows: byProject[index])
        }
        if !unclaimed.isEmpty {
            groups.append(TaskGroup(owner: .orphaned, title: "Orphaned", canHibernate: false,
                                    isHibernating: false, rows: unclaimed))
        }
        return groups
    }
}
