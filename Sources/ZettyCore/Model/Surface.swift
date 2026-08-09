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

    /// Whether this pane shows its file tree. Hidden by default; persisted so a
    /// pane keeps the tree across relaunch.
    public var fileTreeVisible: Bool

    /// Width the pane's file tree was last dragged to, in points. `nil` means
    /// "never resized" — the tree opens at the width from `file-tree-width`.
    public var fileTreeWidth: Double?

    public init(
        id: UUID = UUID(),
        workingDir: String,
        command: String? = nil,
        lastTitle: String? = nil,
        fileTreeVisible: Bool = false,
        fileTreeWidth: Double? = nil
    ) {
        self.id = id
        self.workingDir = workingDir
        self.command = command
        self.lastTitle = lastTitle
        self.fileTreeVisible = fileTreeVisible
        self.fileTreeWidth = fileTreeWidth
    }

    private enum CodingKeys: String, CodingKey {
        case id, workingDir, command, lastTitle, fileTreeVisible, fileTreeWidth
    }

    /// Hand-written so a `workspace.json` written by an older build — one with
    /// no file-tree keys — still decodes. `encode(to:)` stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        workingDir = try c.decode(String.self, forKey: .workingDir)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        lastTitle = try c.decodeIfPresent(String.self, forKey: .lastTitle)
        fileTreeVisible = try c.decodeIfPresent(Bool.self, forKey: .fileTreeVisible) ?? false
        fileTreeWidth = try c.decodeIfPresent(Double.self, forKey: .fileTreeWidth)
    }
}
