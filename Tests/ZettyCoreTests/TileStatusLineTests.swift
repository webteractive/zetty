import Foundation
import Testing
@testable import ZettyCore

private let dirty = GitStatus(branch: "feature/narrow", ahead: 2, behind: 1, changes: 3, isRepo: true)
private let account = AccountResolution(accountID: "work", displayName: "Work",
                                        colorID: "blue", isDefault: false, env: [:])
private let full = TileStatusLine(cwd: "~/AI/zetty", git: dirty, account: account)
private let widths = TileStatusLine.Widths(accountIcon: 14, accountLabel: 40,
                                           branch: 90, aheadBehind: 30, changes: 20)

/// Each shown part costs `width + spacing`; the account label costs `width`
/// only (it sits inside the chip). Base = padding*2 + cwdMin = 16 + 48 = 64.
/// Chip 14+6+40 = 60 · branch 96 · ↑↓ 36 · ●n 26 → everything = 282.
private let roomy = 282.0

@Test func equalLinesCompareEqualSoAnUnchangedRefreshIsANoOp() {
    #expect(full == TileStatusLine(cwd: "~/AI/zetty", git: dirty, account: account))
}

@Test func anyChangedFieldBreaksEquality() {
    var moved = full; moved.cwd = "~/AI"
    var committed = full; committed.git.changes = 0
    var signedOut = full; signedOut.account = nil
    #expect(full != moved)
    #expect(full != committed)
    #expect(full != signedOut)
}

@Test func availablePartsFollowContent() {
    let bare = TileStatusLine(cwd: "/tmp", git: .none, account: nil)
    #expect(bare.availableParts == .init(account: false, accountLabel: false,
                                         branch: false, aheadBehind: false, changes: false))
    let clean = TileStatusLine(cwd: "~", git: GitStatus(branch: "main", ahead: 0, behind: 0,
                                                        changes: 0, isRepo: true), account: nil)
    #expect(clean.availableParts == .init(account: false, accountLabel: false,
                                          branch: true, aheadBehind: false, changes: false))
    #expect(full.availableParts == .init(account: true, accountLabel: true,
                                         branch: true, aheadBehind: true, changes: true))
}

@Test func everythingShowsWhenItFits() {
    #expect(full.visibleParts(width: roomy, widths: widths) == full.availableParts)
}

@Test func partsDropWholeInLadderOrder() {
    // Required width after each drop: 282 → 246 (↑↓) → 206 (label) → 180 (●n)
    // → 160 (account icon) → 64 (branch). One point under each boundary forces
    // exactly the next drop.
    let steps: [(Double, TileStatusLine.Parts)] = [
        (281, .init(account: true,  accountLabel: true,  branch: true,  aheadBehind: false, changes: true)),
        (245, .init(account: true,  accountLabel: false, branch: true,  aheadBehind: false, changes: true)),
        (205, .init(account: true,  accountLabel: false, branch: true,  aheadBehind: false, changes: false)),
        (179, .init(account: false, accountLabel: false, branch: true,  aheadBehind: false, changes: false)),
        (159, .init(account: false, accountLabel: false, branch: false, aheadBehind: false, changes: false)),
    ]
    for (width, expected) in steps {
        #expect(full.visibleParts(width: width, widths: widths) == expected, "width \(width)")
    }
}

@Test func theNarrowestTileShowsTheCwdAlone() {
    let none = TileStatusLine.Parts(account: false, accountLabel: false,
                                    branch: false, aheadBehind: false, changes: false)
    #expect(full.visibleParts(width: 10, widths: widths) == none)
}

@Test func absentContentIsNeverShownHoweverWide() {
    let bare = TileStatusLine(cwd: "/tmp", git: .none, account: nil)
    #expect(bare.visibleParts(width: 10_000, widths: widths) == bare.availableParts)
}

// MARK: - Branch width cap

@Test func aLongBranchIsCappedSoItTruncatesInsteadOfPushingPartsOut() {
    #expect(TileStatusLine.branchWidth(labelWidth: 300) == 14 + TileStatusLine.branchLabelMaxWidth)
    #expect(TileStatusLine.branchWidth(labelWidth: 50) == 64)
}

@Test func aCappedLongBranchKeepsTheAccountAndChangeCount() {
    let git = GitStatus(branch: String(repeating: "x", count: 80), ahead: 0, behind: 0,
                        changes: 3, isRepo: true)
    let account = AccountResolution(accountID: "w", displayName: "W", colorID: nil,
                                    isDefault: false, env: [:])
    let line = TileStatusLine(cwd: "~/a", git: git, account: account)
    let widths = TileStatusLine.Widths(accountIcon: 14, accountLabel: 40,
                                       branch: TileStatusLine.branchWidth(labelWidth: 300),
                                       aheadBehind: 0, changes: 20)
    // 64 base + 60 chip + (134 + 6) branch + 26 changes = 290.
    let parts = line.visibleParts(width: 290, widths: widths)
    #expect(parts.account && parts.accountLabel && parts.changes && parts.branch)
}

// MARK: - Footer fit

@Test func aFooterShowsOnlyWhenTheTileLeavesRoomForTheTerminal() {
    // header 24 + footer 18 + body 24 + borders 2 = 68.
    #expect(TileStatusLine.fitsFooter(tileHeight: 68, headerHeight: 24, border: 1))
    #expect(!TileStatusLine.fitsFooter(tileHeight: 67, headerHeight: 24, border: 1))
}
