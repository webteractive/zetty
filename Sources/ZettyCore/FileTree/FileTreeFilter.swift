import Foundation

/// Decides which of a directory's entries a pane's file tree shows, and in what
/// order.
///
/// Three rules compose independently: hidden-file suppression, the user
/// denylist, and gitignore matching. Sorting lives here too so ordering is
/// covered by the same tests rather than left to the view.
public enum FileTreeFilter {

    /// - Parameters:
    ///   - entries: one directory's children, in any order.
    ///   - settings: resolved preferences.
    ///   - isIgnored: gitignore verdict for an entry. Consulted **only** when
    ///     `settings.respectGitignore` is true, so the caller can pass it
    ///     unconditionally.
    /// - Returns: visible entries, directories first, then case-insensitive by name.
    public static func visible(
        _ entries: [FileTreeEntry],
        settings: FileTreeSettings,
        isIgnored: ((FileTreeEntry) -> Bool)? = nil
    ) -> [FileTreeEntry] {
        let denied = Set(
            settings.extraIgnores
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )

        let kept = entries.filter { entry in
            if !settings.showHidden, entry.name.hasPrefix(".") { return false }
            if denied.contains(entry.name.lowercased()) { return false }
            if settings.respectGitignore, isIgnored?(entry) == true { return false }
            return true
        }

        return kept.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order == .orderedSame ? a.path < b.path : order == .orderedAscending
        }
    }
}
