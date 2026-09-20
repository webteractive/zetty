import Foundation

public struct TileProfileFile: Codable, Equatable, Sendable {
    public var profiles: [TileProfile]

    public init(profiles: [TileProfile] = []) {
        self.profiles = profiles
    }
}

/// Load/save for the private tile-profile library, mirroring
/// `ProjectSettingsStore` — same directory, JSON, atomic pretty-printed
/// writes. Global rather than per-project: a tile view spans projects by
/// definition.
///
/// `load()` returns an empty library on ANY failure. A bad profile file must
/// never brick launch.
public struct TileProfileStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("tile-profiles.json")
    }

    public func load() -> TileProfileFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(TileProfileFile.self, from: data)
        else { return TileProfileFile() }
        return file
    }

    public func save(_ file: TileProfileFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }
}
