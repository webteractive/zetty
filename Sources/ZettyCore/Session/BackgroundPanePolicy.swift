import Foundation

/// Decides which panes may have their GPU surfaces released while they are out
/// of view — "hibernate the pixels, not the session".
///
/// A libghostty surface costs ~37 MB of `IOSurface`/`IOAccelerator` (measured
/// across 5→37 live panes), so a workspace with many awake projects pays for
/// render targets nobody is looking at. Releasing a surface and re-creating it
/// on return is already a solved path — it is exactly what a quit/relaunch
/// does, and `restore-scrollback` replays the terminal state on re-attach.
///
/// The whole point of this type is the *safety* rules, which are all
/// disqualifiers. Getting one wrong destroys a running shell, so the default
/// answer is always "keep attached".
public enum BackgroundPanePolicy {

    /// One pane's candidacy. `isSessionBacked` is the load-bearing field.
    public struct Pane: Equatable, Sendable {
        public let id: UUID
        /// True only when re-creating this surface would re-attach to a live
        /// preserved session. False for plain shells and scratch terminals,
        /// where freeing the surface would KILL the process and lose its
        /// output — those must never be released.
        public let isSessionBacked: Bool

        public init(id: UUID, isSessionBacked: Bool) {
            self.id = id
            self.isSessionBacked = isSessionBacked
        }
    }

    /// One awake project's panes plus how long it has been out of view.
    public struct Project: Equatable, Sendable {
        public let isActive: Bool
        /// Seconds since this project was last the visible one.
        public let idleFor: TimeInterval
        public let panes: [Pane]

        public init(isActive: Bool, idleFor: TimeInterval, panes: [Pane]) {
            self.isActive = isActive
            self.idleFor = idleFor
            self.panes = panes
        }
    }

    /// Surfaces that should remain attached, given `freeAfter` seconds of being
    /// out of view (0 or negative disables the feature entirely).
    ///
    /// Note the asymmetry: this returns what to KEEP, not what to free, so any
    /// pane the caller forgot to describe is kept by construction.
    public static func surfacesToKeepAttached(
        projects: [Project],
        freeAfter: TimeInterval
    ) -> Set<UUID> {
        var keep = Set<UUID>()
        for project in projects {
            let releasable = freeAfter > 0
                && !project.isActive
                && project.idleFor >= freeAfter
            for pane in project.panes {
                // Keep unless every condition for release is met. A pane with no
                // preserved session is kept no matter how long it has been idle.
                if !releasable || !pane.isSessionBacked {
                    keep.insert(pane.id)
                }
            }
        }
        return keep
    }

    /// Surfaces eligible for release — the complement of
    /// `surfacesToKeepAttached`, provided for logging/diagnostics. Never use
    /// this to drive `prune`; prune takes a keep-set so that an unknown pane
    /// fails safe.
    public static func releasableSurfaces(
        projects: [Project],
        freeAfter: TimeInterval
    ) -> Set<UUID> {
        let keep = surfacesToKeepAttached(projects: projects, freeAfter: freeAfter)
        let all = Set(projects.flatMap { $0.panes.map(\.id) })
        return all.subtracting(keep)
    }
}
