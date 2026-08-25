import Foundation

/// A user-defined sidebar section holding related projects.
///
/// A project belongs to at most one Space (`Project.spaceID`); when it has one
/// it renders under that Space's header instead of Pinned/Projects. Array order
/// in `Workspace.spaces` IS sidebar order — there is deliberately no
/// `sortOrder` field, so there is no second ordering mechanism to disagree with
/// the array.
///
/// Home, Scratch terminals, and clones are never members: Home owns the top
/// row, Scratch is ephemeral, and a clone renders glued beneath its source (so
/// an independent assignment would break that guarantee — it rides into its
/// source's Space instead).
public struct Space: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    /// A `ZTheme.projectPalette` id, or nil for the default header styling.
    public var colorID: String?
    /// An SF Symbol name or emoji overriding the default header glyph
    /// (`HeaderCellView` renders whichever it is), or nil.
    public var glyph: String?
    /// Whether the section is folded to its header row. Persisted, unlike the
    /// Hibernating section's view-local collapse state.
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String, colorID: String? = nil,
                glyph: String? = nil, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.colorID = colorID
        self.glyph = glyph
        self.isCollapsed = isCollapsed
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorID, glyph, isCollapsed
    }

    /// Tolerant decode so a workspace.json written before a field existed still
    /// loads (missing → default), matching `Project.init(from:)`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        colorID = try c.decodeIfPresent(String.self, forKey: .colorID)
        glyph = try c.decodeIfPresent(String.self, forKey: .glyph)
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }
}
