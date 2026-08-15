import Foundation
import ZettyGhostty

/// Filesystem reads for the per-pane file tree.
///
/// This is the only place in the feature that touches the disk — `ZettyCore`'s
/// file-tree types are pure by design. **Every function here blocks on I/O and
/// must be called off the main thread**, with the single documented exception of
/// `children(of:)` during an outline-view expand (see `FileTreeView`).
enum DirectoryEnumerator {

    struct Children {
        let entries: [FileTreeEntry]
        /// True when the directory exists but could not be read (permissions,
        /// TCC). The tree says so rather than showing an indistinguishable
        /// "empty" — an alert here would nag on every stray click.
        let isUnreadable: Bool
    }

    /// One directory's immediate children, unfiltered and unsorted — filtering
    /// and ordering belong to `FileTreeFilter`.
    static func children(of path: String) -> Children {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: []          // deliberately NOT skipsHiddenFiles: the filter decides
        ) else {
            return Children(entries: [], isUnreadable: true)
        }

        let entries = contents.map { child -> FileTreeEntry in
            let values = try? child.resourceValues(forKeys: Set(keys))
            return FileTreeEntry(
                name: values?.name ?? child.lastPathComponent,
                path: child.path,
                isDirectory: values?.isDirectory ?? false
            )
        }
        return Children(entries: entries, isUnreadable: false)
    }

    /// Collects the `.gitignore` files at and beneath `root` into a stack.
    ///
    /// Bounded on purpose: only the root's own `.gitignore` plus those in its
    /// immediate children are read. A deep scan for gitignore files would cost
    /// exactly what the whole lazy design avoids, and nested ignores below the
    /// first level are rare enough to skip.
    static func gitignoreStack(root: String) -> GitignoreStack {
        var matchers: [GitignoreMatcher] = []
        func load(_ directory: String) {
            let path = (directory as NSString).appendingPathComponent(".gitignore")
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            matchers.append(GitignoreMatcher(base: directory, contents: contents))
        }
        load(root)
        for entry in children(of: root).entries where entry.isDirectory {
            load(entry.path)
        }
        return GitignoreStack(matchers: matchers)
    }

    /// Breadth-first walk collecting file paths for the search index.
    ///
    /// Applies the same filter as the tree, so a hidden or ignored directory is
    /// never descended and its contents never appear in search — which is also
    /// how gitignore's "everything under an ignored directory is ignored" rule
    /// gets satisfied without implementing ancestor propagation.
    ///
    /// - Returns: the paths found, and whether `limit` cut the walk short.
    static func walk(
        root: String,
        settings: FileTreeSettings,
        gitignore: GitignoreStack,
        limit: Int,
        isCancelled: () -> Bool
    ) -> (paths: [String], truncated: Bool) {
        var paths: [String] = []
        var queue = [root]
        var visited = Set<String>()

        while !queue.isEmpty {
            if isCancelled() { return (paths, false) }
            let directory = queue.removeFirst()
            // Resolving symlinks per directory is what stops a link loop from
            // walking forever.
            let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
            guard visited.insert(resolved).inserted else { continue }

            let visible = FileTreeFilter.visible(
                children(of: directory).entries,
                settings: settings,
                isIgnored: { gitignore.isIgnored(path: $0.path, isDirectory: $0.isDirectory) }
            )
            for entry in visible {
                if entry.isDirectory {
                    queue.append(entry.path)
                } else {
                    guard paths.count < limit else { return (paths, true) }
                    paths.append(entry.path)
                }
            }
        }
        return (paths, false)
    }
}
