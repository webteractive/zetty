import Foundation

/// Builds the URL that opens a file **at a line** in a GUI editor.
///
/// This exists because a plain file open (`NSWorkspace.open`) cannot carry a
/// line number — only each editor's own URL scheme can. Editors without one
/// return nil and the caller falls back to a plain open.
public enum EditorURLScheme {

    /// Editors whose scheme is `<scheme>://file/<path>[:line[:col]]`.
    private static let fileSchemes: [String: String] = [
        "dev.zed.zed": "zed",
        "com.microsoft.vscode": "vscode",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
    ]

    /// Editors that accept a column as a third `:` segment. Zed takes only a line.
    private static let columnCapable: Set<String> = ["vscode", "cursor", "windsurf"]

    public static func url(bundleID: String, file: String, line: Int?, column: Int?) -> URL? {
        let id = bundleID.lowercased()
        let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file

        if let scheme = fileSchemes[id] {
            var spec = encoded
            // A column without a line would render as `::9`; drop it.
            if let line {
                spec += ":\(line)"
                if let column, columnCapable.contains(scheme) { spec += ":\(column)" }
            }
            return URL(string: "\(scheme)://file\(spec)")
        }

        if id == "com.macromates.textmate" {
            // Built through URLComponents, not string interpolation: the path
            // sits in a query VALUE here, and `CharacterSet.urlPathAllowed`
            // permits `&` and `=` — so a real filename like `Q&A.md` would
            // otherwise truncate the url parameter and corrupt `line`.
            var components = URLComponents()
            components.scheme = "txmt"
            components.host = "open"
            var items = [URLQueryItem(name: "url", value: "file://\(file)")]
            if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
            components.queryItems = items
            return components.url
        }

        return nil
    }
}
