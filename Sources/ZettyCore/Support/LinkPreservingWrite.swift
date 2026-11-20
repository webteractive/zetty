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
        let target = resolvedTarget(of: url)
        let mode = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int
        try data.write(to: target, options: .atomic)
        if let mode {
            try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
    }

    public static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    /// Follows a chain of links (relative ones against their own folder), at
    /// most 16 deep so a loop ends; a path that is not a link is itself.
    static func resolvedTarget(of url: URL) -> URL {
        var target = url
        for _ in 0 ..< 16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) else {
                break
            }
            target = URL(fileURLWithPath: destination, relativeTo: target.deletingLastPathComponent())
                .standardizedFileURL
        }
        return target
    }
}
