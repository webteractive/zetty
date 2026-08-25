import Foundation

public struct Workspace: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var projects: [Project]
    /// User-defined sidebar sections, in sidebar order. Missing in
    /// pre-Spaces files → empty (grouping simply isn't there).
    public var spaces: [Space]
    /// Index of the project that was active when the workspace was saved,
    /// restored on launch. Missing in pre-existing files → 0.
    public var activeProjectIndex: Int
    /// Whether the sidebar was collapsed (⌘B) when the workspace was saved.
    /// Missing in pre-existing files → false.
    public var sidebarCollapsed: Bool
    /// The sidebar's user-dragged width in points, clamped to
    /// `SidebarMetrics` bounds on restore. Missing in pre-existing files →
    /// the default width.
    public var sidebarWidth: Double

    public init(
        schemaVersion: Int = 1,
        projects: [Project] = [],
        spaces: [Space] = [],
        activeProjectIndex: Int = 0,
        sidebarCollapsed: Bool = false,
        sidebarWidth: Double = SidebarMetrics.defaultWidth
    ) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.spaces = spaces
        self.activeProjectIndex = activeProjectIndex
        self.sidebarCollapsed = sidebarCollapsed
        self.sidebarWidth = sidebarWidth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        projects = try container.decode([Project].self, forKey: .projects)
        spaces = try container.decodeIfPresent([Space].self, forKey: .spaces) ?? []
        activeProjectIndex = try container.decodeIfPresent(Int.self, forKey: .activeProjectIndex) ?? 0
        sidebarCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false
        sidebarWidth = SidebarMetrics.clampWidth(
            try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? SidebarMetrics.defaultWidth
        )
    }
}
