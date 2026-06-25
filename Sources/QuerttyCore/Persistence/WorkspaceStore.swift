import Foundation

public struct WorkspaceStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("workspace.json")
    }

    public func load() throws -> Workspace {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Workspace()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Workspace.self, from: data)
    }

    public func save(_ workspace: Workspace) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workspace)
        try data.write(to: fileURL, options: .atomic)
    }
}
