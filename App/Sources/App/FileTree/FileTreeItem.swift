import Foundation
import ZettyGhostty

/// Identity-stable box for an outline-view row.
///
/// `NSOutlineView` tracks expansion by object identity (pointer / `isEqual:`),
/// so handing it a fresh box per reload would silently collapse the tree. Boxes
/// are therefore cached by path for the lifetime of a root.
final class FileTreeItem {
    let entry: FileTreeEntry
    /// Children once loaded; nil means "not enumerated yet".
    var children: [FileTreeItem]?
    /// True when the directory exists but couldn't be read.
    var isUnreadable = false

    init(entry: FileTreeEntry) {
        self.entry = entry
    }

    var path: String { entry.path }
    var isDirectory: Bool { entry.isDirectory }
}

extension FileTreeItem: Equatable, Hashable {
    static func == (lhs: FileTreeItem, rhs: FileTreeItem) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}
