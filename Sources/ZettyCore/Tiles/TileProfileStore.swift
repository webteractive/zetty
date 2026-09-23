import Foundation

public struct TileProfileFile: Codable, Equatable, Sendable {
    public var profiles: [TileProfile]
    /// Named shapes a new view can start from. Absent in libraries written
    /// before layouts existed → empty, and seeded on load.
    public var layouts: [TileLayout]
    /// Built-in names already offered once. Seeding by name against THIS rather
    /// than "is the list empty" means a new built-in reaches an existing
    /// library — while one the user deleted stays deleted.
    public var seededLayoutNames: [String]

    public init(profiles: [TileProfile] = [], layouts: [TileLayout] = [],
                seededLayoutNames: [String] = []) {
        self.profiles = profiles
        self.layouts = layouts
        self.seededLayoutNames = seededLayoutNames
    }

    private enum CodingKeys: String, CodingKey { case profiles, layouts, seededLayoutNames }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decodeIfPresent([TileProfile].self, forKey: .profiles) ?? []
        layouts = try container.decodeIfPresent([TileLayout].self, forKey: .layouts) ?? []
        seededLayoutNames = try container.decodeIfPresent([String].self,
                                                          forKey: .seededLayoutNames)
            // A library from before this existed has already been offered
            // whatever it holds, so treat its current names as seeded.
            ?? layouts.map(\.name)
    }

    /// A built-in that shipped once and was withdrawn. Kept as a constant
    /// rather than inlined so it reads as retired rather than arbitrary.
    private static let retiredLayoutName = "Focus"

    /// Adds built-ins this library has never been offered. Returns whether
    /// anything changed, so the caller knows to save.
    public mutating func seedMissingLayouts() -> Bool {
        var changed = false
        // Clears the retired "Focus" built-in from libraries that were already
        // seeded with it.
        //
        // BY NAME, deliberately — this used to remove every layout with one
        // leaf, and Freeform has one leaf. Left as it was, the built-in seeded
        // three lines below would be deleted again on the very next load, with
        // nothing to show for it: the seed name is recorded, so it would never
        // come back either. A rename spares a layout the user made their own,
        // which is the right answer too.
        let before = layouts.count
        layouts.removeAll { $0.name == Self.retiredLayoutName }
        if layouts.count != before { changed = true }

        let offered = Set(seededLayoutNames)
        let missing = TileLayout.builtIns.filter { !offered.contains($0.name) }
        if !missing.isEmpty {
            layouts.append(contentsOf: missing)
            seededLayoutNames.append(contentsOf: missing.map(\.name))
            changed = true
        }
        return changed
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
