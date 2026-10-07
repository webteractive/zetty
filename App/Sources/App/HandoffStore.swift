import Foundation
import ZettyCore

/// File side of hibernation handoffs: `~/.zetty/handoffs/<SURFACE-UUID>.json`
/// and `.md`, owner-only.
///
/// A record with no `.md` is a handoff still owed (or one a quit interrupted);
/// a record with one is ready to wake from. Paths and file contents are pure
/// in `ZettyCore` (`HandoffPaths`, `HandoffPrompt`).
enum HandoffStore {
    private static var home: String { NSHomeDirectory() }

    static func handoffPath(for surface: UUID) -> String {
        HandoffPaths.handoff(for: surface, home: home)
    }

    /// Records the pane and clears any handoff an earlier hibernation left,
    /// so a fork that fails this time cannot wake the pane from stale text.
    static func begin(_ record: HandoffRecord) {
        ensureDirectory()
        try? FileManager.default.removeItem(atPath: handoffPath(for: record.surface))
        guard let data = try? JSONEncoder().encode(record) else { return }
        writeOwnerOnly(data, to: HandoffPaths.record(for: record.surface, home: home))
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

    static func isReady(_ surface: UUID) -> Bool {
        FileManager.default.fileExists(atPath: handoffPath(for: surface))
    }

    /// The wake file: wake line plus handoff, because a mention inside a
    /// mentioned file is not expanded.
    static func writeHandoff(_ handoff: String, for surface: UUID) {
        ensureDirectory()
        writeOwnerOnly(Data(HandoffPrompt.wakeFile(handoff: handoff).utf8),
                       to: handoffPath(for: surface))
    }

    static func remove(_ surface: UUID) {
        try? FileManager.default.removeItem(atPath: HandoffPaths.record(for: surface, home: home))
        try? FileManager.default.removeItem(atPath: handoffPath(for: surface))
    }

    /// Drops every file whose pane is gone. `owned` must span hibernated
    /// projects (`sessionOwnerSurfaceIDs`): theirs are the panes with handoffs.
    static func sweep(keeping owned: Set<UUID>) {
        let directory = HandoffPaths.directory(home: home)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            guard let surface = HandoffPaths.surfaceID(fromFileName: name),
                  !owned.contains(surface) else { continue }
            try? FileManager.default.removeItem(atPath: "\(directory)/\(name)")
        }
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            atPath: HandoffPaths.directory(home: home), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// Created owner-only and then moved into place: a handoff describes
    /// somebody's work, so it is never readable by anyone else, and never
    /// seen half-written by a pane that is waking.
    private static func writeOwnerOnly(_ data: Data, to path: String) {
        let temporary = path + ".tmp"
        try? FileManager.default.removeItem(atPath: temporary)
        guard FileManager.default.createFile(atPath: temporary, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { return }
        guard rename(temporary, path) == 0 else {
            try? FileManager.default.removeItem(atPath: temporary)
            return
        }
    }
}
