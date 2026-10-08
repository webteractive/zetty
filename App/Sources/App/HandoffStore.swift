import Foundation
import ZettyCore

/// File side of hibernation handoffs: `~/.zetty/handoffs/<SURFACE-UUID>.json`,
/// owner-only. One per pane that comes back by resuming a conversation its
/// agent compacted before the project was put away.
///
/// Written at the moment a project is put away (`save`): while its agents
/// are compacting nothing is on disk, so a quit or a cancel leaves nothing to
/// clean up. Paths are pure in `ZettyCore` (`HandoffPaths`).
enum HandoffStore {
    private static var home: String { NSHomeDirectory() }

    /// False when it could not be written, with nothing left behind.
    @discardableResult
    static func save(_ record: HandoffRecord) -> Bool {
        ensureDirectory()
        guard let data = try? JSONEncoder().encode(record),
              writeOwnerOnly(data, to: HandoffPaths.record(for: record.surface, home: home))
        else {
            remove(record.surface)
            return false
        }
        return true
    }

    static func record(for surface: UUID) -> HandoffRecord? {
        guard let data = FileManager.default.contents(
            atPath: HandoffPaths.record(for: surface, home: home)) else { return nil }
        return try? JSONDecoder().decode(HandoffRecord.self, from: data)
    }

    static func allRecords() -> [HandoffRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: HandoffPaths.directory(home: home))) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .compactMap(HandoffPaths.surfaceID(fromFileName:))
            .compactMap(record(for:))
    }

    static func remove(_ surface: UUID) {
        try? FileManager.default.removeItem(atPath: HandoffPaths.record(for: surface, home: home))
    }

    /// Drops every record nobody owns any more. A record that names its
    /// project (by `settingsKey`) is that project's, whatever became of the
    /// pane it came from:
    /// a project wakes as one pane and its other handoffs wait. An older one
    /// is its pane's, and `panes` must then span hibernated projects
    /// (`sessionOwnerSurfaceIDs`).
    static func sweep(keeping panes: Set<UUID>, projects: Set<String>) {
        let directory = HandoffPaths.directory(home: home)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            guard let surface = HandoffPaths.surfaceID(fromFileName: name) else { continue }
            let owned = record(for: surface)?.project.map(projects.contains) ?? panes.contains(surface)
            if !owned { try? FileManager.default.removeItem(atPath: "\(directory)/\(name)") }
        }
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            atPath: HandoffPaths.directory(home: home), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// Created owner-only and then moved into place: it names somebody's
    /// conversation and login, and is never seen half-written by a pane
    /// that is waking.
    private static func writeOwnerOnly(_ data: Data, to path: String) -> Bool {
        let temporary = path + ".tmp"
        try? FileManager.default.removeItem(atPath: temporary)
        guard FileManager.default.createFile(atPath: temporary, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(temporary, path) == 0 else {
            try? FileManager.default.removeItem(atPath: temporary)
            return false
        }
        return true
    }
}
