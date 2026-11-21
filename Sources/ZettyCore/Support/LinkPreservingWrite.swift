import Foundation

/// Writes a user's own config file (Claude's `settings.json`, Codex's
/// `config.toml`, Hermes's config) the way an editor would: through any
/// symlink to the real file, keeping that file's permissions.
///
/// A plain atomic write renames a new file over the path, which turns a
/// link into a regular file with default permissions. A settings file kept
/// in a dotfiles repo and linked in then stops following the repo, silently.
/// Hook repair runs at every launch, so it did this without being asked
/// (release review, 2026-11-20).
public enum LinkPreservingWrite {
    public static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let target = try resolvedTarget(of: url)
        let mode = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int
        try data.write(to: target, options: .atomic)
        if let mode {
            try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
    }

    public static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    /// Copies what `source` points at, not the link itself: a copy of a link
    /// is another link to the same file, and an account's own `settings.json`
    /// must be a file of its own (security review of 70c34a5..cb4df1b).
    public static func copyTarget(of source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: try resolvedTarget(of: source), to: destination)
    }

    /// Follows a chain of links, at most 16 deep; a path that is not a link
    /// is itself. A relative link resolves against its folder's REAL
    /// location, as the kernel does: with `~/.claude` itself a link, a string
    /// `..` named a folder beside the link and the write landed in an
    /// unrelated file there (security review of 70c34a5..cb4df1b). A chain
    /// still a link after 16 hops is a loop, and fails rather than replacing
    /// one of its links with a file.
    static func resolvedTarget(of url: URL) throws -> URL {
        var target = url
        for _ in 0 ..< 16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) else {
                return target
            }
            let folder = target.deletingLastPathComponent().resolvingSymlinksInPath()
            target = URL(fileURLWithPath: destination, relativeTo: folder).standardizedFileURL
        }
        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "\(url.path) is a loop of symbolic links"])
    }
}
