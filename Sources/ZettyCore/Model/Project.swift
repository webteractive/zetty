import Foundation

public struct Tab: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var layout: Layout

    public init(id: UUID = UUID(), title: String, layout: Layout) {
        self.id = id
        self.title = title
        self.layout = layout
    }
}

public struct Session: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var tabs: [Tab]

    public init(id: UUID = UUID(), title: String, tabs: [Tab] = []) {
        self.id = id
        self.title = title
        self.tabs = tabs
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
