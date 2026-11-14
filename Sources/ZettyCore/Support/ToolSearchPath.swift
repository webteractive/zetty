import Foundation

/// Where Zetty looks for command-line tools it runs itself. A GUI app
/// inherits a minimal `PATH`, so the search is explicit: the file viewer's
/// highlighter and init.lua's `zetty.exec` both start from this list.
public enum ToolSearchPath {
    public static func directories(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.zetty/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
        ]
    }
}
