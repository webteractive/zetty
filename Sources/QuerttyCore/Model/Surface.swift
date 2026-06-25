import Foundation

public enum SplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

public struct Surface: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var workingDir: String
    public var command: String?

    public init(id: UUID = UUID(), workingDir: String, command: String? = nil) {
        self.id = id
        self.workingDir = workingDir
        self.command = command
    }
}
