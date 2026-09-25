import Foundation

/// Why a library edit was refused. Messages are user-facing: the CLI prints
/// them verbatim and the manager window shows them in an alert.
public enum TileLibraryError: Error, Equatable, LocalizedError {
    case blankName
    case duplicateName(String)
    case unknownView(String, known: [String])

    public var errorDescription: String? {
        switch self {
        case .blankName:
            return "a tile view needs a name"
        case .duplicateName(let name):
            return "a tile view named '\(name)' already exists"
        case .unknownView(let name, let known):
            return "unknown tile view '\(name)'"
                + (known.isEmpty ? "" : " — known: \(known.joined(separator: ", "))")
        }
    }
}

/// Library-level edits — find, rename, duplicate, delete — shared by the tile
/// manager window and `zetty tiles`, so the two cannot disagree about what a
/// name collision is.
///
/// Names are matched case-insensitively, the rule Space names follow: two
/// views that differ only in case could not be told apart from a CLI argument.
extension TileProfileFile {

    public func profile(named name: String) -> TileProfile? {
        profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// `profile(named:)`, or an error naming every view there is.
    public func requireProfile(named name: String) throws -> TileProfile {
        guard let match = profile(named: name) else {
            throw TileLibraryError.unknownView(name, known: profiles.map(\.name))
        }
        return match
    }

    /// `base`, or `base 2`, `base 3`, … — the first no view already uses.
    public func uniqueName(_ base: String) -> String {
        guard profile(named: base) != nil else { return base }
        var n = 2
        while profile(named: "\(base) \(n)") != nil { n += 1 }
        return "\(base) \(n)"
    }

    /// The name a new view gets when none is asked for: `Tiles N`, counting
    /// from the library's size so the first is `Tiles 1`, skipping taken ones.
    public func nextDefaultName() -> String {
        var n = profiles.count + 1
        while profile(named: "Tiles \(n)") != nil { n += 1 }
        return "Tiles \(n)"
    }

    /// The trimmed name, or why it cannot be used. `excluding` is the view
    /// being renamed, so renaming a view to its own name (or a case change of
    /// it) is not a collision.
    public func validatedName(_ proposed: String, excluding id: UUID? = nil) throws -> String {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TileLibraryError.blankName }
        if let clash = profile(named: name), clash.id != id {
            throw TileLibraryError.duplicateName(clash.name)
        }
        return name
    }

    @discardableResult
    public mutating func rename(id: UUID, to proposed: String) throws -> TileProfile? {
        let name = try validatedName(proposed, excluding: id)
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        profiles[index].name = name
        return profiles[index]
    }

    /// A copy with a fresh id, inserted right after its source. The slots come
    /// with it — a duplicate is for varying an arrangement you already have.
    @discardableResult
    public mutating func duplicate(id: UUID, name proposed: String? = nil) throws -> TileProfile? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let source = profiles[index]
        let name = try proposed.map { try validatedName($0) } ?? uniqueName("\(source.name) copy")
        let copy = TileProfile(name: name, root: source.root, slots: source.slots)
        profiles.insert(copy, at: index + 1)
        return copy
    }

    @discardableResult
    public mutating func delete(id: UUID) -> TileProfile? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        return profiles.remove(at: index)
    }
}
