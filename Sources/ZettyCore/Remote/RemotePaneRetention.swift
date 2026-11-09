import Foundation

/// Which of another Mac's projects keep their panes connected after the
/// viewer leaves them, so coming back shows them at once instead of dialling
/// every pane again and replaying its scrollback.
///
/// Every rule frees: a project is kept only while its Mac is online at the
/// address its relays dialled, it is still open there, and it was left less
/// than `keepFor` ago. Panes closed there go on their own. Past
/// `maxSurfaces`, the projects left longest ago go first, whole.
public enum RemotePaneRetention {
    public static let keepFor: TimeInterval = 30 * 60
    /// Each kept pane is a terminal surface here (~37 MB of GPU memory) and a
    /// `zmx attach` on the other Mac.
    public static let maxSurfaces = 32

    public struct Kept: Equatable, Sendable {
        public let machine: String
        public let project: String
        /// The address its relays dialled; they can't follow a new one.
        public let address: String
        public let leftAt: Date
        /// The other Mac's pane id → the surface showing it here.
        public var surfaces: [String: UUID]

        public init(machine: String, project: String, address: String, leftAt: Date, surfaces: [String: UUID]) {
            self.machine = machine
            self.project = project
            self.address = address
            self.leftAt = leftAt
            self.surfaces = surfaces
        }
    }

    /// `kept` with every rule applied, and the surfaces that leaves out.
    public static func prune(_ kept: [Kept], machines: [RemoteMachine], now: Date,
                             keepFor: TimeInterval = keepFor,
                             maxSurfaces: Int = maxSurfaces) -> (kept: [Kept], free: Set<UUID>) {
        var free = Set<UUID>()
        var survivors: [Kept] = []
        for var entry in kept {
            guard let machine = machines.first(where: { $0.stableID == entry.machine }),
                  machine.state == .online, machine.address == entry.address,
                  let project = machine.workspace?.projects.first(where: { ($0.id ?? $0.name) == entry.project }),
                  !project.hibernated, !project.tabs.isEmpty,
                  now.timeIntervalSince(entry.leftAt) < keepFor
            else {
                free.formUnion(entry.surfaces.values)
                continue
            }
            let open = Set(project.tabs.flatMap(\.panes).map(\.id))
            for (pane, surface) in entry.surfaces where !open.contains(pane) {
                free.insert(surface)
                entry.surfaces[pane] = nil
            }
            if !entry.surfaces.isEmpty { survivors.append(entry) }
        }

        var count = 0
        var full = false
        var kept: [Kept] = []
        for entry in survivors.sorted(by: { $0.leftAt > $1.leftAt }) {
            full = full || count + entry.surfaces.count > maxSurfaces
            if full {
                free.formUnion(entry.surfaces.values)
            } else {
                count += entry.surfaces.count
                kept.append(entry)
            }
        }
        return (kept, free)
    }
}
