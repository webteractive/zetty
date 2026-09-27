import Foundation

/// One tile's status line: the status bar's account · cwd · git cluster, for
/// the pane that tile shows. Pure data plus the width ladder deciding which
/// parts fit, so the view never tunes truncation by eye.
///
/// `Equatable` is load-bearing: the view no-ops on an equal line, which is
/// what keeps a busy grid from re-rendering sixteen footers per title tick.
public struct TileStatusLine: Equatable, Sendable {
    public var cwd: String
    public var git: GitStatus
    public var account: AccountResolution?

    public init(cwd: String, git: GitStatus, account: AccountResolution?) {
        self.cwd = cwd
        self.git = git
        self.account = account
    }

    public struct Parts: Equatable, Sendable {
        public var account: Bool
        public var accountLabel: Bool
        public var branch: Bool
        public var aheadBehind: Bool
        public var changes: Bool

        public init(account: Bool, accountLabel: Bool, branch: Bool,
                    aheadBehind: Bool, changes: Bool) {
            self.account = account
            self.accountLabel = accountLabel
            self.branch = branch
            self.aheadBehind = aheadBehind
            self.changes = changes
        }
    }

    /// Measured natural widths, in points, of each droppable part.
    public struct Widths: Equatable, Sendable {
        public var accountIcon: Double
        public var accountLabel: Double
        public var branch: Double
        public var aheadBehind: Double
        public var changes: Double

        public init(accountIcon: Double, accountLabel: Double, branch: Double,
                    aheadBehind: Double, changes: Double) {
            self.accountIcon = accountIcon
            self.accountLabel = accountLabel
            self.branch = branch
            self.aheadBehind = aheadBehind
            self.changes = changes
        }
    }

    public static let padding: Double = 8
    public static let spacing: Double = 6
    /// The cwd always shows; below this it would be a stub, so parts drop first.
    public static let cwdMinWidth: Double = 48
    /// A branch label wider than this truncates instead of pushing the account
    /// and the change count out — a long feature-branch name is the common case.
    public static let branchLabelMaxWidth: Double = 120
    /// The footer strip's height.
    public static let footerHeight: Double = 18
    /// The least terminal worth keeping under a header and above a footer.
    public static let minimumBodyHeight: Double = 24

    /// The branch part's width: icon (11) + gap (3) + the label, capped.
    public static func branchWidth(labelWidth: Double) -> Double {
        14 + min(labelWidth, branchLabelMaxWidth)
    }

    /// Whether a tile this tall has room for a footer and still a usable
    /// terminal. A shorter tile drops the footer rather than over-constrain.
    public static func fitsFooter(tileHeight: Double, headerHeight: Double, border: Double) -> Bool {
        tileHeight >= headerHeight + footerHeight + minimumBodyHeight + border * 2
    }

    /// What there is content for — a part with nothing to say never shows.
    public var availableParts: Parts {
        let repo = git.isRepo && !git.branch.isEmpty
        return Parts(account: account != nil,
                     accountLabel: account != nil,
                     branch: repo,
                     aheadBehind: repo && (git.ahead > 0 || git.behind > 0),
                     changes: repo && git.changes > 0)
    }

    /// Which parts fit in `width`. Parts drop WHOLE, in this order: ↑↓, the
    /// account's label (its icon stays), ●n, the account icon, the branch.
    /// The cwd always shows and takes what is left.
    public func visibleParts(width: Double, widths: Widths) -> Parts {
        var parts = availableParts
        func required(_ p: Parts) -> Double {
            var total = Self.padding * 2 + Self.cwdMinWidth
            if p.account { total += widths.accountIcon + Self.spacing }
            if p.account && p.accountLabel { total += widths.accountLabel }
            if p.branch { total += widths.branch + Self.spacing }
            if p.aheadBehind { total += widths.aheadBehind + Self.spacing }
            if p.changes { total += widths.changes + Self.spacing }
            return total
        }
        let ladder: [WritableKeyPath<Parts, Bool>] = [
            \.aheadBehind, \.accountLabel, \.changes, \.account, \.branch,
        ]
        for step in ladder where required(parts) > width {
            parts[keyPath: step] = false
            if step == \Parts.account { parts.accountLabel = false }
        }
        return parts
    }
}
