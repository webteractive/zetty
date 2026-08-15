import Foundation
import ZettyGhostty

/// Everything a pane's leaf needs in order to host a file tree.
///
/// Bundled into one value on purpose: `SurfaceNodeView` → `RatioSplitView` →
/// `SurfaceNodeView` is a recursive builder that already threads seven
/// parameters, and adding five more positional arguments to every level is how
/// plumbing bugs get written. The leaf reads visibility and width straight off
/// its own `Surface`, so those aren't carried here.
@MainActor
struct FileTreeWiring {
    /// Resolved `zetty-file-tree-*` settings, read fresh on each use so a
    /// config reload takes effect without rebuilding the wiring.
    let settings: () -> FileTreeSettings
    /// Show/hide this pane's tree (persists to the surface).
    let onToggle: (UUID) -> Void
    /// Record a dragged width (persists; deliberately does not rebuild).
    let onWidthChange: (UUID, Double) -> Void
    /// Peek a file in the read-only viewer.
    let onPeek: (String) -> Void
    /// Hand a file to the configured editor.
    let onOpenInEditor: (String) -> Void
}
