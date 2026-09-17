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

    /// Which agent account this pane was spawned under — `AgentAccountSupport`'s
    /// `@default` sentinel, an account id, or nil for a pane created before
    /// accounts existed (which resolves as the default).
    ///
    /// STAMPED at creation with a concrete value, and never rewritten. The
    /// environment it names was captured by libghostty when the surface was
    /// created — and by any zmx session when that session was created — so a
    /// value that drifted afterwards would describe a process that no longer
    /// matches. That is what lets the status chip be trusted: changing a
    /// project's default account moves NEW panes only, and an existing pane is
    /// moved by respawning it, not by editing this.
    public var accountID: String?

    /// An account `zetty run` started INSIDE this pane, believed to still be
    /// running. Distinct from `accountID`, which records how the pane was
    /// spawned and is never rewritten.
    ///
    /// Persisted because preserved zmx sessions outlive the app: after a
    /// relaunch the agent is still there, so an in-memory-only override would
    /// start describing the wrong login again on every launch — the same reason
    /// `lastTitle` is persisted. Cleared by the foreground probe when the agent
    /// exits, and at restore for panes that own no preserved session.
    public var runningAccountID: String?

    public init(
        id: UUID = UUID(),
        workingDir: String,
        command: String? = nil,
        lastTitle: String? = nil,
        fileTreeVisible: Bool = false,
        fileTreeWidth: Double? = nil,
        accountID: String? = nil,
        runningAccountID: String? = nil
    ) {
        self.id = id
        self.workingDir = workingDir
        self.command = command
        self.lastTitle = lastTitle
        self.fileTreeVisible = fileTreeVisible
        self.fileTreeWidth = fileTreeWidth
        self.accountID = accountID
        self.runningAccountID = runningAccountID
    }

    private enum CodingKeys: String, CodingKey {
        case id, workingDir, command, lastTitle, fileTreeVisible, fileTreeWidth, accountID
        case runningAccountID
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
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
        runningAccountID = try c.decodeIfPresent(String.self, forKey: .runningAccountID)
    }
}
