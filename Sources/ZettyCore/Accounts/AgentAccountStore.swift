import Foundation

/// Load/save for the private agent-accounts file, mirroring
/// `ProjectSettingsStore` (same directory, JSON, atomic pretty-printed writes).
/// `load()` returns an empty file on ANY failure — a corrupt accounts file must
/// never brick launch, it just means no accounts are configured.
public struct AgentAccountStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("agent-accounts.json")
    }

    public func load() -> AgentAccountsFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(AgentAccountsFile.self, from: data)
        else { return AgentAccountsFile() }
        return file
    }

    public func save(_ file: AgentAccountsFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }
}
