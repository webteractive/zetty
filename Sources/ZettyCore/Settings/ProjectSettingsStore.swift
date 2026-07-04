import Foundation

/// Load/save for the private per-user project-settings file, mirroring
/// `WorkspaceStore` (same directory, JSON, atomic pretty-printed writes).
/// Unlike the workspace, settings are non-critical: `load()` returns an
/// empty file on ANY failure — a bad settings file must never brick launch.
public struct ProjectSettingsStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("project-settings.json")
    }

    /// Normalizes a project rootPath into the dictionary key: tilde expanded,
    /// `.`/`..` and symlink-free standardized form, no trailing slash.
    public static func canonicalKey(_ rootPath: String) -> String {
        var path = (rootPath as NSString).expandingTildeInPath
        path = (path as NSString).standardizingPath
        path = URL(fileURLWithPath: path).standardizedFileURL
            .resolvingSymlinksInPath().path
        return path
    }

    public func load() -> ProjectSettingsFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(ProjectSettingsFile.self, from: data)
        else { return ProjectSettingsFile() }
        return file
    }

    public func save(_ file: ProjectSettingsFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }
}
