import Foundation
import ZettyCore

/// App-layer IO for the non-git clone→source file copy-back: computes the diff
/// via `git diff --no-index` (works outside any repo) and copies chosen files
/// into the source. Pure parsing/path logic lives in `FileCopyBack` (ZettyCore).
/// All calls block — run off the main thread.
enum FileCopyBackRunner {

    /// The changed-file list (clone's contributions). `git diff --no-index`
    /// exits 1 when there are differences, so we read output regardless of code.
    static func changes(sourceRoot: String, cloneRoot: String) -> [FileCopyBack.FileChange] {
        let raw = runGitStdout(FileCopyBack.nameStatusArgs(sourceRoot: sourceRoot, cloneRoot: cloneRoot))
        return FileCopyBack.parseNameStatusZ(raw, sourceRoot: sourceRoot, cloneRoot: cloneRoot)
    }

    /// The unified line diff for one file (source vs clone). For an added file
    /// there is no source side, so diff against /dev/null.
    static func contentDiff(sourceRoot: String, cloneRoot: String, relPath: String,
                            kind: FileCopyBack.ChangeKind) -> String {
        let cloneFile = (cloneRoot as NSString).appendingPathComponent(relPath)
        let sourceFile = kind == .added ? "/dev/null"
            : (sourceRoot as NSString).appendingPathComponent(relPath)
        return runGitStdout(["diff", "--no-index", sourceFile, cloneFile])
    }

    struct ApplyResult: Equatable { let applied: Int; let errors: [String] }

    /// Writes the chosen changes into the source. `copyNew`/`replace` copy the
    /// clone's file to the same rel path; `keepBoth` copies to the Keep-Both name.
    /// Never deletes. Creates intermediate directories. Collects per-file errors.
    static func apply(sourceRoot: String, cloneRoot: String,
                      decisions: [FileCopyBack.Decision]) -> ApplyResult {
        let fm = FileManager.default
        var applied = 0
        var errors: [String] = []
        for decision in decisions {
            let rel = decision.change.relPath
            let src = (cloneRoot as NSString).appendingPathComponent(rel)
            let destRel = decision.action == .keepBoth ? FileCopyBack.keepBothName(rel) : rel
            let dest = (sourceRoot as NSString).appendingPathComponent(destRel)
            do {
                try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                if decision.action != .keepBoth, fm.fileExists(atPath: dest) {
                    try fm.removeItem(atPath: dest)   // replace/copyNew overwrite
                }
                try fm.copyItem(atPath: src, toPath: dest)
                applied += 1
            } catch {
                errors.append("\(destRel): \(error.localizedDescription)")
            }
        }
        return ApplyResult(applied: applied, errors: errors)
    }

    /// Runs `git <args>`, returning stdout regardless of exit status (git diff
    /// --no-index exits 1 on differences). stderr is discarded.
    private static func runGitStdout(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
