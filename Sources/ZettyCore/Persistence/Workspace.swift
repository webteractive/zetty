import Foundation

public struct Workspace: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var projects: [Project]
    /// Index of the project that was active when the workspace was saved,
    /// restored on launch. Missing in pre-existing files → 0.
    public var activeProjectIndex: Int

    public init(schemaVersion: Int = 1, projects: [Project] = [], activeProjectIndex: Int = 0) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.activeProjectIndex = activeProjectIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        projects = try container.decode([Project].self, forKey: .projects)
        activeProjectIndex = try container.decodeIfPresent(Int.self, forKey: .activeProjectIndex) ?? 0
    }
}
