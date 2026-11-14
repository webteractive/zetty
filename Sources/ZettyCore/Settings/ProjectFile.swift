import Foundation

/// The optional, git-committable `.zetty/project.json` at a project root.
/// Carries ONLY shareable keys — a layout template, a default startup
/// command, and declared env variable NAMES (like `.env.example`). There is
/// deliberately no field for env VALUES: the writer cannot leak secrets by
/// construction, and a hand-edited values map is dropped on read.
public struct ProjectFile: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var layoutTemplate: LayoutTemplate?
    public var startupCommand: String?
    public var envNames: [String]?

    public init(
        schemaVersion: Int = 1,
        layoutTemplate: LayoutTemplate? = nil,
        startupCommand: String? = nil,
        envNames: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.layoutTemplate = layoutTemplate
        self.startupCommand = startupCommand
        self.envNames = envNames
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        layoutTemplate = try c.decodeIfPresent(LayoutTemplate.self, forKey: .layoutTemplate)
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand)
        envNames = try c.decodeIfPresent([String].self, forKey: .envNames)
    }
}

public enum ProjectFileIO {

    public static func url(forProjectRoot rootPath: String) -> URL {
        URL(fileURLWithPath: rootPath)
            .appendingPathComponent(".zetty/project.json")
    }

    /// The largest file read. A real one is a few kilobytes.
    public static let maxBytes = 1 << 20

    /// Missing or malformed file → nil, never throws — a bad repo file must
    /// never brick project open. It is someone else's file, so only a regular
    /// file (a link to one is fine) of at most `maxBytes` is read: a link to
    /// `/dev/zero` would otherwise be read forever, on the main thread.
    public static func load(projectRoot: String) -> ProjectFile? {
        let fileURL = url(forProjectRoot: projectRoot).resolvingSymlinksInPath()
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= maxBytes,
              let handle = try? FileHandle(forReadingFrom: fileURL)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes,
              let file = try? JSONDecoder().decode(ProjectFile.self, from: data)
        else { return nil }
        return file
    }

    /// Writes the file (creating `.zetty/`), pretty-printed for hand-editing.
    public static func save(_ file: ProjectFile, projectRoot: String) throws {
        let fileURL = url(forProjectRoot: projectRoot)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }
}

/// Global default layout template (`layout-template.json` in the app's
/// Application Support directory) — used when a project has no repo file
/// template. Hand-editable; mirrors `WorkspaceStore`'s conventions.
public struct LayoutTemplateStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("layout-template.json")
    }

    public func load() -> LayoutTemplate? {
        guard let data = try? Data(contentsOf: fileURL),
              let template = try? JSONDecoder().decode(LayoutTemplate.self, from: data)
        else { return nil }
        return template
    }

    public func save(_ template: LayoutTemplate) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(template).write(to: fileURL, options: .atomic)
    }
}
