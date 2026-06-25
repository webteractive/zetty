import Foundation

public struct Session: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    // tabs added in Task 3 once Layout exists.

    public init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
}

public struct Project: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var rootPath: String
    public var isPinned: Bool
    public var sortOrder: Int
    public var preserveSessions: Bool
    public var sessions: [Session]

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        isPinned: Bool = false,
        sortOrder: Int = 0,
        preserveSessions: Bool = false,
        sessions: [Session] = []
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.isPinned = isPinned
        self.sortOrder = sortOrder
        self.preserveSessions = preserveSessions
        self.sessions = sessions
    }
}
