import Foundation
import ZettyCore

/// Reads the per-pane snapshots Zetty's Claude Code mod rewrites under
/// `~/.zetty/agent-usage/`.
///
/// A poll on the main run loop, like `AgentEventWatcher`, so the callbacks
/// fire on main. Each tick lists one small directory and re-reads only the
/// files whose modification date moved — an idle workspace costs a `readdir`.
final class AgentUsageWatcher {

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zetty", isDirectory: true)
            .appendingPathComponent("agent-usage", isDirectory: true)
    }

    private let directory: URL
    /// The panes Zetty has. A snapshot for any other is a leftover — its pane
    /// closed, or it predates this launch — and is deleted.
    private let knownSurfaces: () -> Set<UUID>
    private let onUsage: ([AgentUsage]) -> Void
    private let onRemoved: ([UUID]) -> Void
    private var timer: Timer?
    private var modified: [UUID: Date] = [:]

    init(directory: URL = AgentUsageWatcher.directory,
         knownSurfaces: @escaping () -> Set<UUID>,
         onUsage: @escaping ([AgentUsage]) -> Void,
         onRemoved: @escaping ([UUID]) -> Void) {
        self.directory = directory
        self.knownSurfaces = knownSurfaces
        self.onUsage = onUsage
        self.onRemoved = onRemoved
    }

    func start() {
        stop()
        poll()   // agents inside preserved sessions wrote theirs before this launch
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let known = knownSurfaces()

        var seen: Set<UUID> = []
        var changed: [AgentUsage] = []
        for url in entries {
            guard let surface = AgentUsage.surface(fromFileName: url.lastPathComponent) else { continue }
            // An empty set means the workspace is not restored yet, not that
            // every pane is gone.
            if !known.isEmpty, !known.contains(surface) {
                try? fileManager.removeItem(at: url)
                continue
            }
            seen.insert(surface)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let date, modified[surface] != date else { continue }
            // A file caught mid-write fails to parse; its date is not recorded,
            // so the next tick reads it again.
            guard let data = try? Data(contentsOf: url),
                  let usage = AgentUsage.parse(data: data), usage.surface == surface else { continue }
            modified[surface] = date
            changed.append(usage)
        }

        let removed = modified.keys.filter { !seen.contains($0) }
        for surface in removed { modified.removeValue(forKey: surface) }
        if !removed.isEmpty { onRemoved(removed) }
        if !changed.isEmpty { onUsage(changed) }
    }
}
