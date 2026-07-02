import Foundation

public enum SplitDirection: String, Codable, Sendable, Equatable {
    case horizontal
    case vertical
}

public struct Surface: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var workingDir: String
    public var command: String?

    /// Last terminal title the pane reported, persisted so restored tabs keep
    /// their names: a zmx reattach doesn't re-emit the title escape sequence,
    /// so the live title stays empty until the program next sets it.
    public var lastTitle: String?

    public init(id: UUID = UUID(), workingDir: String, command: String? = nil, lastTitle: String? = nil) {
        self.id = id
        self.workingDir = workingDir
        self.command = command
        self.lastTitle = lastTitle
    }
}
