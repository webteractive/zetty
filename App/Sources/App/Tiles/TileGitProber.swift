import Foundation
import ZettyCore

/// Git state for the directories the tile footers show — ONE probe per
/// directory, however many tiles sit in it.
///
/// Probes run on the controller's existing serial `gitQueue`, so sixteen
/// repos cost sixteen `git` runs one after another rather than forked at
/// once, and sixteen tiles in one repo cost one.
@MainActor
final class TileGitProber {
    private let queue: DispatchQueue
    private var statuses: [String: GitStatus] = [:]
    private var inFlight: Set<String> = []
    /// Directories some tile shows right now. A result for anything else is
    /// dropped — the grid may have closed, or the pane may have `cd`'d away.
    private var wanted: Set<String> = []

    /// Called on main when a directory's status actually changed.
    var onUpdate: (() -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    /// `.none` until the first probe lands — the footer shows the cwd alone.
    func status(for directory: String) -> GitStatus { statuses[directory] ?? .none }

    /// Declares what the tiles show now; probes any directory not yet known.
    func track(_ directories: Set<String>) {
        wanted = directories
        statuses = statuses.filter { directories.contains($0.key) }
        for directory in directories where statuses[directory] == nil {
            probe(directory)
        }
    }

    /// The 15s re-probe: branch and dirtiness move without the cwd changing.
    func refreshAll() {
        for directory in wanted { probe(directory) }
    }

    /// The grid closed: forget everything, and let in-flight results fall on
    /// the floor via `wanted`.
    func reset() {
        wanted = []
        statuses = [:]
    }

    private func probe(_ directory: String) {
        guard !inFlight.contains(directory) else { return }
        inFlight.insert(directory)
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let status = GitStatusProbe.probe(directory: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(directory)
                guard self.wanted.contains(directory),
                      self.statuses[directory] != status else { return }
                self.statuses[directory] = status
                self.onUpdate?()
            }
        }
    }
}
