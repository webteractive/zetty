import Foundation

/// Resolved file-tree preferences, sourced from the `file-tree-*` config keys.
///
/// Defaults deliberately show the raw filesystem — dotfiles included — so an
/// untouched config never hides anything. Filtering is opt-in.
public struct FileTreeSettings: Sendable, Equatable {
    /// Show entries whose name begins with `.`.
    public var showHidden: Bool
    /// Consult the repo's `.gitignore` files when deciding visibility.
    public var respectGitignore: Bool
    /// Extra names to hide regardless of gitignore, matched case-insensitively
    /// against an entry's name (not its path).
    public var extraIgnores: [String]
    /// Width a tree opens at when its pane has no stored width.
    public var width: Double

    public static let defaultWidth: Double = 220

    public init(
        showHidden: Bool = true,
        respectGitignore: Bool = false,
        extraIgnores: [String] = [],
        width: Double = FileTreeSettings.defaultWidth
    ) {
        self.showHidden = showHidden
        self.respectGitignore = respectGitignore
        self.extraIgnores = extraIgnores
        self.width = width
    }
}
