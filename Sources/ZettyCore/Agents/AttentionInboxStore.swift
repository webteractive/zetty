import Foundation

/// Reads and writes the attention inbox at `<directory>/attention-inbox.json`.
public struct AttentionInboxStore {
    public static let fileName = "attention-inbox.json"

    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    /// nil when there is no file yet or it can't be read.
    public func load() -> AttentionInboxSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AttentionInboxSnapshot.self, from: data)
    }

    public func save(_ snapshot: AttentionInboxSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
