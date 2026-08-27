import XCTest
@testable import ZettyCore

final class SelfUpdateScriptTests: XCTestCase {
    private func render(
        pid: Int32 = 4242,
        target: String = "/Applications/zetty.app",
        staged: String = "/tmp/z work/zetty.app",
        workDir: String = "/tmp/z work"
    ) -> String {
        SelfUpdateScript.render(
            pid: pid, targetAppPath: target, stagedAppPath: staged, workDir: workDir)
    }

    func testRendersQuotedPathsAndPID() {
        let script = render()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("kill -0 4242"))
        XCTAssertTrue(script.contains("TARGET='/Applications/zetty.app'"))
        XCTAssertTrue(script.contains("STAGED='/tmp/z work/zetty.app'"))
        XCTAssertTrue(script.contains("WORKDIR='/tmp/z work'"))
        XCTAssertTrue(script.contains(#"ditto "$STAGED" "$TARGET""#))
        XCTAssertTrue(script.contains(#"xattr -dr com.apple.quarantine "$TARGET""#))
        XCTAssertTrue(script.contains(#"open "$TARGET""#))
        XCTAssertTrue(script.contains(#"rm -- "$0""#))
    }

    func testEscapesSingleQuotesInPaths() {
        let script = render(pid: 1, target: "/x/it's.app", staged: "/s/a.app", workDir: "/s")
        XCTAssertTrue(script.contains(#"'/x/it'\''s.app'"#))
    }

    /// The field failure this hardening exists for: an interrupted swap left a
    /// live bundle whose framework was missing, which dyld refuses to launch.
    /// The old bundle must be moved aside, never deleted outright.
    func testMovesOldBundleAsideInsteadOfDeletingIt() {
        let script = render()
        XCTAssertTrue(script.contains(#"mv "$TARGET" "$BACKUP""#))
        XCTAssertFalse(script.contains(#"rm -rf "$TARGET""# + "\nditto"))
        // The only unconditional pre-copy removal is of a stale backup.
        XCTAssertTrue(script.contains(#"rm -rf "$BACKUP""#))
    }

    func testGuardsOnBundleCompletenessBeforeAndAfterTheCopy() {
        let script = render()
        for path in SelfUpdateScript.requiredBundlePaths {
            XCTAssertTrue(script.contains(path), "completeness check must cover \(path)")
        }
        XCTAssertTrue(script.contains(#"if ! complete "$STAGED""#))
        XCTAssertTrue(script.contains(#"complete "$TARGET""#))
    }

    func testRestoresTheOldBundleWhenTheCopyFails() {
        let script = render()
        XCTAssertTrue(script.contains(#"mv "$BACKUP" "$TARGET""#))
        XCTAssertTrue(script.contains(#"elif [ -d "$BACKUP" ]"#))
    }

    func testRequiredPathsCoverTheExecutableAndTheGhosttyFramework() {
        XCTAssertEqual(SelfUpdateScript.requiredBundlePaths, [
            "Contents/MacOS/zetty",
            "Contents/Frameworks/ZettyGhostty.framework/Versions/A/ZettyGhostty",
        ])
    }
}
