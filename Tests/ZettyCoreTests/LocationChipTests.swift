import XCTest
@testable import ZettyCore

final class LocationChipTests: XCTestCase {

    private let dirty = GitStatus(branch: "feature/narrow-window", ahead: 2, behind: 5,
                                  changes: 3, isRepo: true)
    private let clean = GitStatus(branch: "main", ahead: 0, behind: 0, changes: 0, isRepo: true)

    // MARK: - Basename

    func testBasenameIsTheIdentifyingComponent() {
        XCTAssertEqual(LocationChip.basename(of: "~/AI/zetty"), "zetty")
        XCTAssertEqual(LocationChip.basename(of: "/Users/x/Code/app"), "app")
    }

    func testBasenameToleratesATrailingSlash() {
        XCTAssertEqual(LocationChip.basename(of: "~/AI/zetty/"), "zetty")
    }

    func testRootKeepsItsSlashRatherThanVanishing() {
        XCTAssertEqual(LocationChip.basename(of: "/"), "/")
    }

    func testABareNameIsItsOwnBasename() {
        XCTAssertEqual(LocationChip.basename(of: "~"), "~")
    }

    // MARK: - Chip

    func testChipNamesThePlaceAndTheBranch() {
        XCTAssertEqual(LocationChip.label(cwd: "~/AI/zetty", git: clean), "zetty ⎇ main")
    }

    func testChipMarksADirtyTreeButNotACleanOne() {
        // The count itself lives in the dropup; the chip only has to answer
        // "is there anything uncommitted" at a glance.
        XCTAssertEqual(LocationChip.label(cwd: "~/AI/zetty", git: dirty),
                       "zetty ⎇ feature/narrow-window ●")
        XCTAssertFalse(LocationChip.label(cwd: "~/AI/zetty", git: clean).contains("●"))
    }

    func testOutsideARepoTheChipIsJustThePlace() {
        XCTAssertEqual(LocationChip.label(cwd: "~/Downloads", git: .none), "Downloads")
    }

    func testARepoWithNoBranchYetIsAlsoJustThePlace() {
        let unborn = GitStatus(branch: "", ahead: 0, behind: 0, changes: 0, isRepo: true)
        XCTAssertEqual(LocationChip.label(cwd: "~/new", git: unborn), "new")
    }

    // MARK: - Dropup

    func testDropupLeadsWithTheFullPathThenTheNonZeroCounts() {
        XCTAssertEqual(LocationChip.detailLines(cwd: "~/AI/zetty", git: dirty),
                       ["~/AI/zetty", "⎇ feature/narrow-window",
                        "↑2 ahead", "↓5 behind", "●3 changed"])
    }

    func testACleanBranchIsJustPathAndBranch() {
        XCTAssertEqual(LocationChip.detailLines(cwd: "~/AI/zetty", git: clean),
                       ["~/AI/zetty", "⎇ main"])
    }

    func testOutsideARepoTheDropupIsJustThePath() {
        XCTAssertEqual(LocationChip.detailLines(cwd: "~/Downloads", git: .none), ["~/Downloads"])
    }

    func testOneChangeIsNotPluralised() {
        let one = GitStatus(branch: "main", ahead: 1, behind: 0, changes: 1, isRepo: true)
        XCTAssertEqual(LocationChip.detailLines(cwd: "~/x", git: one),
                       ["~/x", "⎇ main", "↑1 ahead", "●1 changed"])
    }

    func testNothingKnownYieldsNoLines() {
        XCTAssertTrue(LocationChip.detailLines(cwd: "", git: .none).isEmpty)
    }

    // MARK: - When it collapses

    func testStaysExpandedWhileThereIsRoom() {
        XCTAssertFalse(LocationChip.shouldCollapse(spaceIfExpanded: 200, wasCollapsed: false))
    }

    func testCollapsesWhenTheDirectoryWouldBeSqueezedTooFar() {
        XCTAssertTrue(LocationChip.shouldCollapse(spaceIfExpanded: LocationChip.cwdFloor - 1,
                                                  wasCollapsed: false))
    }

    func testStaysCollapsedInsideTheHysteresisBand() {
        let justOver = LocationChip.cwdFloor + StatusBarCompaction.hysteresis - 1
        XCTAssertTrue(LocationChip.shouldCollapse(spaceIfExpanded: justOver, wasCollapsed: true))
    }

    func testExpandsOnceClearOfTheBand() {
        let clear = LocationChip.cwdFloor + StatusBarCompaction.hysteresis
        XCTAssertFalse(LocationChip.shouldCollapse(spaceIfExpanded: clear, wasCollapsed: true))
    }

    func testNegativeSpaceCollapses() {
        XCTAssertTrue(LocationChip.shouldCollapse(spaceIfExpanded: -40, wasCollapsed: false))
    }
}
