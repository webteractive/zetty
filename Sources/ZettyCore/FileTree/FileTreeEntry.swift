import Foundation

/// One filesystem entry in a pane's file tree.
///
/// Deliberately inert: no `URL`, no attributes, no `FileManager`. The app layer
/// enumerates directories and hands these in, which keeps every decision about
/// what is *visible* pure and testable.
public struct FileTreeEntry: Sendable, Equatable, Identifiable {
    /// Absolute paths are unique within a tree, so they double as identity.
    public var id: String { path }

    public let name: String
    public let path: String
    public let isDirectory: Bool

    public init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}
