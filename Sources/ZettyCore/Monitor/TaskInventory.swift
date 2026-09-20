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
