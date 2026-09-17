import Foundation

/// Where Zetty keeps its private stores. Shared so the app and the CLI cannot
/// disagree about the location of `agent-accounts.json` — the CLI reads it
/// directly, without the app running.
public enum ZettyPaths {
    public static func applicationSupportDirectory(home: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent("zetty")
    }
}
