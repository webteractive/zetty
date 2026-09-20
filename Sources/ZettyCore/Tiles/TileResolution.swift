import Foundation

/// What one slot currently points at.
public enum ResolvedSlot: Equatable, Sendable {
    /// A hole — renders as the `+ Attach` cell.
    case empty
    /// The slot's project or tab is gone. Carries the label remembered at
    /// attach time, so the grid says WHAT is missing rather than leaving a
    /// silent gap.
    case missing(String)
    case pane(projectIndex: Int, tabIndex: Int, surfaceID: UUID)
}

/// Resolves a profile's slots against the live project list.
///
/// Pure and workspace-shaped rather than model-shaped, so it needs no AppKit
/// and no filesystem: the caller hands in `projects`.
public enum TileResolution {

    public static func resolve(profile: TileProfile,
                               projects: [ProjectRuntime]) -> [ResolvedSlot] {
        // Canonicalised once rather than per slot — a profile can hold dozens,
        // and `canonicalKey` resolves symlinks.
        let byRoot = Dictionary(
            projects.enumerated().map {
                (ProjectSettingsStore.canonicalKey($0.element.rootPath), $0.offset)
            },
            uniquingKeysWith: { first, _ in first })

        return profile.slots.map { slot in
            guard let slot else { return .empty }
            guard let projectIndex = byRoot[ProjectSettingsStore.canonicalKey(slot.projectRoot)],
                  let tabIndex = projects[projectIndex].tabList.trees
                      .firstIndex(where: { $0.id == slot.tabID })
            else { return .missing(slot.label) }

            let tree = projects[projectIndex].tabList.trees[tabIndex]
            // The tab's focused pane, or its first — a tab always has one.
            guard let surfaceID = tree.focusedSurfaceID ?? tree.layout.surfaces.first?.id
            else { return .missing(slot.label) }
            return .pane(projectIndex: projectIndex, tabIndex: tabIndex, surfaceID: surfaceID)
        }
    }
}
