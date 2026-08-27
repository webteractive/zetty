import Foundation

/// Renders the detached POSIX-sh helper that performs the in-place bundle swap
/// after the app quits. Pure text generation; the App layer writes and launches
/// it. A running app can't overwrite itself, so this waits for the PID first.
///
/// **The swap may never leave a half-copied bundle at the target.** An earlier
/// version did `rm -rf <target>` then `ditto`, so anything that cut the helper
/// short — a restart, a full disk, a killed process — destroyed the working
/// install and left whatever `ditto` had managed to write. That failure mode
/// was reported from the field as a launch crash: `/Applications/zetty.app`
/// with its `MacOS/zetty` present but `Frameworks/ZettyGhostty.framework`
/// simply absent, which dyld rejects before `main` runs. Nothing inside the app
/// can recover from it, so the helper is the only place it can be prevented.
///
/// Hence: the staged bundle is checked for completeness *before* the target is
/// touched, the old bundle is moved aside rather than deleted, the copy is
/// verified, and a failed copy puts the old bundle back.
public enum SelfUpdateScript {
    /// Paths, relative to a `zetty.app` bundle, whose presence means the copy
    /// is at least structurally complete. The framework is the one that
    /// actually went missing in the field. Public so the App layer can run the
    /// same check on the bundle it stages out of the DMG, while the app is
    /// still alive and a failure can still be reported to the user.
    public static let requiredBundlePaths = [
        "Contents/MacOS/zetty",
        "Contents/Frameworks/ZettyGhostty.framework/Versions/A/ZettyGhostty",
    ]

    public static func render(
        pid: Int32, targetAppPath: String, stagedAppPath: String, workDir: String
    ) -> String {
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return """
        #!/bin/sh
        # Zetty self-update helper (generated). Waits for the app to quit, swaps
        # the bundle in place, strips quarantine, relaunches, and self-deletes.
        # The swap is staged through a backup so an interrupted or failed copy
        # can never leave a partial bundle at the target — see SelfUpdateScript.
        TARGET=\(q(targetAppPath))
        STAGED=\(q(stagedAppPath))
        WORKDIR=\(q(workDir))
        BACKUP="$TARGET.zetty-previous"

        complete() {
            [ -x "$1/\(requiredBundlePaths[0])" ] && [ -f "$1/\(requiredBundlePaths[1])" ]
        }

        finish() {
            xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
            rm -rf "$WORKDIR"
            open "$TARGET"
            rm -- "$0"
        }

        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done

        # Never touch the target for a staged bundle that isn't whole.
        if ! complete "$STAGED"; then
            finish
            exit 1
        fi

        rm -rf "$BACKUP"
        mv "$TARGET" "$BACKUP" 2>/dev/null
        if ditto "$STAGED" "$TARGET" && complete "$TARGET"; then
            rm -rf "$BACKUP"
        elif [ -d "$BACKUP" ]; then
            # Copy failed: put the working bundle back rather than leaving a
            # corpse that can't launch.
            rm -rf "$TARGET"
            mv "$BACKUP" "$TARGET"
        fi
        finish
        """
    }
}
