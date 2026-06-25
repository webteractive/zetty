import Foundation

public struct Workspace: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var projects: [Project]

    public init(schemaVersion: Int = 1, projects: [Project] = []) {
        self.schemaVersion = schemaVersion
        self.projects = projects
    }
}
