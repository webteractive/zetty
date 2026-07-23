# "Merge to Source…" Phase 2 (non-git file copy-back) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** For a clone whose source is **not a git repo**, replace the "coming soon" placeholder with a **diff modal**: compute what the clone changed vs the source using `git diff --no-index`, show a file list + per-file line diff, and copy chosen files back into the source with per-file **Replace / Keep Both** conflict handling.

**Architecture:** Pure parsing + path logic in `ZettyCore/Clone/FileCopyBack.swift`; git-diff IO + file copy in `App/Sources/App/FileCopyBackRunner.swift`; the modal in `App/Sources/App/FileCopyBackSheet.swift`; wired into the non-git branch of `TerminalViewController.presentMergeToSourceChooser`.

**Tech Stack:** Swift, AppKit (NSWindow sheet + NSTableView + NSTextView), swift-testing, Tuist + SPM, `/usr/bin/git` (`diff --no-index`, works outside a repo).

## Global Constraints

- `ZettyCore` stays pure — no AppKit import.
- Never hardcode a color — `ZTheme.current.<token>Color`; diff coloring uses semantic `greenColor` (added), `redColor` (removed), `yellowColor`/`accentColor` (hunk header), `fg2Color` (context). Terminal-adjacent/diff text uses `ZTheme.monoFont`.
- New files are ADDED → run `mise exec -- tuist clean` then `tuist generate --no-open` then `xcodebuild … build` (the resources gotcha). Confirm BUILD SUCCEEDED.
- `git diff --no-index` exits **1** when files differ — that is success, not failure; never treat exit 1 as an error here.
- `--name-status -z` layout is `status\0<abs-path>\0` pairs; paths are absolute (the two dir args). Derive rel paths by stripping the matching root prefix. `A`→added (clone path), `M`→modified (source path), `D`→dropped (copy-back never deletes). Skip `.git/`-rooted paths defensively.
- Copy-back writes into the user's REAL source directory: **Keep Both** never destroys the source's file (writes `name 2.ext`); a summary confirm precedes any write.
- Do not push. Work on `main`, no new branch. Commit per task with the given message.
- GUI is TCC-denied here — build is the gate; live modal behavior is the user's check.

---

### Task 1: Pure `FileCopyBack` — parse + path logic (ZettyCore)

**Files:**
- Create: `Sources/ZettyCore/Clone/FileCopyBack.swift`
- Test: `Tests/ZettyCoreTests/FileCopyBackTests.swift`

**Interfaces produced:**
```swift
public enum FileCopyBack {
    enum ChangeKind { case added, modified }
    struct FileChange: Equatable, Sendable { let relPath: String; let kind: ChangeKind }
    enum Action: Equatable, Sendable { case copyNew, replace, keepBoth }
    struct Decision: Equatable, Sendable { let change: FileChange; let action: Action }
    static func nameStatusArgs(sourceRoot:cloneRoot:) -> [String]
    static func parseNameStatusZ(_ raw: String, sourceRoot:cloneRoot:) -> [FileChange]
    static func keepBothName(_ relPath: String) -> String
}
```

- [ ] **Step 1: Write the failing tests** — create `Tests/ZettyCoreTests/FileCopyBackTests.swift`:

```swift
import Testing
import Foundation
@testable import ZettyCore

@Test func fileCopyBackNameStatusArgs() {
    #expect(FileCopyBack.nameStatusArgs(sourceRoot: "/s", cloneRoot: "/c")
            == ["diff", "--no-index", "--name-status", "-z", "/s", "/c"])
}

@Test func fileCopyBackParsesAddedAndModifiedDropsDeleted() {
    // status\0absPath\0 pairs; A uses clone path, M/D use source path.
    let raw = "A\u{0}/c/new.txt\u{0}M\u{0}/s/mod.txt\u{0}D\u{0}/s/gone.txt\u{0}"
    let changes = FileCopyBack.parseNameStatusZ(raw, sourceRoot: "/s", cloneRoot: "/c")
    #expect(changes == [
        FileCopyBack.FileChange(relPath: "new.txt", kind: .added),
        FileCopyBack.FileChange(relPath: "mod.txt", kind: .modified),
    ])   // D dropped
}

@Test func fileCopyBackSkipsGitInternalPaths() {
    let raw = "M\u{0}/s/.git/config\u{0}A\u{0}/c/keep.txt\u{0}"
    let changes = FileCopyBack.parseNameStatusZ(raw, sourceRoot: "/s", cloneRoot: "/c")
    #expect(changes == [FileCopyBack.FileChange(relPath: "keep.txt", kind: .added)])
}

@Test func fileCopyBackParsesNestedRelPaths() {
    let raw = "M\u{0}/s/a/b/c.txt\u{0}"
    #expect(FileCopyBack.parseNameStatusZ(raw, sourceRoot: "/s", cloneRoot: "/c")
            == [FileCopyBack.FileChange(relPath: "a/b/c.txt", kind: .modified)])
}

@Test func fileCopyBackKeepBothName() {
    #expect(FileCopyBack.keepBothName("notes.txt") == "notes 2.txt")
    #expect(FileCopyBack.keepBothName("a/b/notes.txt") == "a/b/notes 2.txt")
    #expect(FileCopyBack.keepBothName("Makefile") == "Makefile 2")          // no extension
    #expect(FileCopyBack.keepBothName("archive.tar.gz") == "archive.tar 2.gz") // last ext only
    #expect(FileCopyBack.keepBothName(".env") == ".env 2")                   // dotfile: no ext split
}
```

- [ ] **Step 2: Run to verify failure** — `mise exec -- swift test --filter fileCopyBack`
Expected: FAIL (no `FileCopyBack`).

- [ ] **Step 3: Implement** — create `Sources/ZettyCore/Clone/FileCopyBack.swift`:

```swift
import Foundation

/// Pure parsing + path logic for bringing a non-git clone's changed files back
/// into its source. Diff computation and file IO live in the app-layer
/// `FileCopyBackRunner`; this stays pure (mirrors the CloneSupport/CloneRunner split).
public enum FileCopyBack {

    public enum ChangeKind: Equatable, Sendable { case added, modified }

    /// A file the clone contributes to the source: new (`added`) or differing
    /// (`modified`). Deletions are never represented — a copy-back adds/updates,
    /// it never removes from the source.
    public struct FileChange: Equatable, Sendable {
        public let relPath: String
        public let kind: ChangeKind
        public init(relPath: String, kind: ChangeKind) {
            self.relPath = relPath
            self.kind = kind
        }
    }

    /// How a chosen change is written into the source.
    public enum Action: Equatable, Sendable {
        case copyNew    // added file — no source counterpart to conflict with
        case replace    // overwrite the source's file
        case keepBoth   // write the clone's version as "name 2.ext", keep the source's
    }

    public struct Decision: Equatable, Sendable {
        public let change: FileChange
        public let action: Action
        public init(change: FileChange, action: Action) {
            self.change = change
            self.action = action
        }
    }

    /// `git diff --no-index --name-status -z <source> <clone>` — the changed-file
    /// list. (Run in the app layer; exit 1 = "differences", which is success.)
    public static func nameStatusArgs(sourceRoot: String, cloneRoot: String) -> [String] {
        ["diff", "--no-index", "--name-status", "-z", sourceRoot, cloneRoot]
    }

    /// Parses `-z` name-status output (`status\0absPath\0` pairs) into the
    /// changes the clone contributes. `A`→added (path under the clone root),
    /// `M`→modified (path under the source root), `D`→dropped. Paths under a
    /// `.git/` directory are skipped defensively.
    public static func parseNameStatusZ(_ raw: String, sourceRoot: String,
                                        cloneRoot: String) -> [FileChange] {
        let tokens = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var out: [FileChange] = []
        var i = 0
        while i + 1 < tokens.count {
            let status = tokens[i]
            let path = tokens[i + 1]
            i += 2
            let root = (status == "A") ? cloneRoot : sourceRoot
            guard let rel = relativePath(path, under: root) else { continue }
            if rel == ".git" || rel.hasPrefix(".git/") { continue }
            switch status {
            case "A": out.append(FileChange(relPath: rel, kind: .added))
            case "M": out.append(FileChange(relPath: rel, kind: .modified))
            default: break   // D and anything else: not a copy-back contribution
            }
        }
        return out
    }

    /// Finder-style Keep-Both target: "name 2.ext" (last extension only; no
    /// extension → "name 2"; a leading-dot-only name like ".env" is treated as
    /// having no extension).
    public static func keepBothName(_ relPath: String) -> String {
        let dir = (relPath as NSString).deletingLastPathComponent
        let file = (relPath as NSString).lastPathComponent
        let base: String
        let suffix: String
        if let dot = file.lastIndex(of: "."), dot != file.startIndex {
            base = String(file[..<dot])
            suffix = String(file[dot...])   // includes the "."
        } else {
            base = file
            suffix = ""
        }
        let renamed = "\(base) 2\(suffix)"
        return dir.isEmpty ? renamed : "\(dir)/\(renamed)"
    }

    /// The path of `abs` relative to `root`, or nil if not under it.
    private static func relativePath(_ abs: String, under root: String) -> String? {
        let r = root.hasSuffix("/") ? root : root + "/"
        guard abs.hasPrefix(r) else { return abs == root ? "" : nil }
        return String(abs.dropFirst(r.count))
    }
}
```

- [ ] **Step 4: Run to verify pass** — `mise exec -- swift test --filter fileCopyBack`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Clone/FileCopyBack.swift Tests/ZettyCoreTests/FileCopyBackTests.swift
git commit -m "feat(core): FileCopyBack — parse git diff --no-index + Keep-Both naming"
```

---

### Task 2: App IO — `FileCopyBackRunner` (diff + copy)

**Files:**
- Create: `App/Sources/App/FileCopyBackRunner.swift`
- Verify: headless script — Step 3.

**Interfaces produced:**
```swift
enum FileCopyBackRunner {
    static func changes(sourceRoot: String, cloneRoot: String) -> [FileCopyBack.FileChange]
    static func contentDiff(sourceRoot: String, cloneRoot: String, relPath: String, kind: FileCopyBack.ChangeKind) -> String
    struct ApplyResult: Equatable { let applied: Int; let errors: [String] }
    static func apply(sourceRoot: String, cloneRoot: String, decisions: [FileCopyBack.Decision]) -> ApplyResult
}
```

- [ ] **Step 1: Implement** — create `App/Sources/App/FileCopyBackRunner.swift`:

```swift
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
```

- [ ] **Step 2: Regenerate + build** (new file added → clean first)

```
mise exec -- tuist clean
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Headless verification** — save to the scratchpad as `copyback-it.sh`, run with `/bin/sh`. It mirrors the exact git + copy operations:

```bash
#!/bin/sh
set -e
base=$(mktemp -d); s="$base/s"; c="$base/c"; mkdir -p "$s/sub" "$c/sub"
printf 'same\n' > "$s/keep.txt"; printf 'same\n' > "$c/keep.txt"
printf 'old\n'  > "$s/mod.txt";  printf 'new\n'  > "$c/mod.txt"
printf 'x\n'    > "$c/sub/added.txt"
printf 'onlysrc\n' > "$s/removed.txt"
echo "--- name-status (expect A sub/added.txt, M mod.txt, D removed.txt; keep.txt absent) ---"
git diff --no-index --name-status "$s" "$c" || true
echo "--- content diff of mod.txt (expect -old +new) ---"
git diff --no-index "$s/mod.txt" "$c/mod.txt" || true
echo "--- simulate apply: copyNew added.txt, replace mod.txt, keepBoth mod.txt ---"
mkdir -p "$s/sub"; cp "$c/sub/added.txt" "$s/sub/added.txt"; echo "COPY-NEW-OK: $(cat "$s/sub/added.txt")"
cp "$c/mod.txt" "$s/mod.txt"; echo "REPLACE-OK: $(cat "$s/mod.txt")"
printf 'kept\n' > "$s/mod.txt"; cp "$c/mod.txt" "$s/mod 2.txt"   # keepBoth leaves original
echo "KEEP-BOTH-OK orig=$(cat "$s/mod.txt") copy=$(cat "$s/mod 2.txt")"
rm -rf "$base"
```

Expected: name-status shows `A …/added.txt`, `M …/mod.txt`, `D …/removed.txt` (no `keep.txt`); the content diff shows `-old`/`+new`; markers `COPY-NEW-OK`, `REPLACE-OK`, `KEEP-BOTH-OK` with the Keep-Both original preserved. Paste output into the report.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/App/FileCopyBackRunner.swift
git commit -m "feat(app): FileCopyBackRunner — git diff --no-index + guarded copy-back"
```

---

### Task 3: The diff modal + wire into the non-git branch

**Files:**
- Create: `App/Sources/App/FileCopyBackSheet.swift`
- Modify: `App/Sources/App/TerminalViewController.swift` (non-git branch of `presentMergeToSourceChooser`)

**Interfaces:**
- `FileCopyBackSheet.present(cloneName:sourceRoot:cloneRoot:changes:on:onApply:)` — modal sheet (follows `ProjectSettingsSheet`'s `NSObject` + static `active` + `NSWindow`/`beginSheet` idiom); calls `onApply([FileCopyBack.Decision])` when the user confirms, nothing on cancel.
- In `TerminalViewController`, the `!options.canMergeUpdates` branch computes `changes` off-main and presents the sheet instead of the "coming soon" alert.

- [ ] **Step 1: Create the sheet** — `App/Sources/App/FileCopyBackSheet.swift`:

```swift
import AppKit
import ZettyCore

/// Non-git clone → source file copy-back modal. Left: the changed-file list
/// (include checkbox · status · name · Replace/Keep-Both for modified files).
/// Right: the selected file's line diff, colored with ZTheme semantic tokens.
/// Confirming hands the chosen `FileCopyBack.Decision`s to `onApply`.
/// Follows ProjectSettingsSheet's programmatic-AppKit idiom.
@MainActor
final class FileCopyBackSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private static var active: FileCopyBackSheet?

    private final class Row {
        let change: FileCopyBack.FileChange
        var include: Bool = true
        var action: FileCopyBack.Action
        init(_ change: FileCopyBack.FileChange) {
            self.change = change
            self.action = change.kind == .added ? .copyNew : .replace
        }
    }

    private let panel: NSWindow
    private let hostWindow: NSWindow
    private let sourceRoot: String
    private let cloneRoot: String
    private let rows: [Row]
    private let onApply: ([FileCopyBack.Decision]) -> Void

    private let table = NSTableView()
    private let diffView = NSTextView()

    static func present(cloneName: String, sourceRoot: String, cloneRoot: String,
                        changes: [FileCopyBack.FileChange], on window: NSWindow,
                        onApply: @escaping ([FileCopyBack.Decision]) -> Void) {
        let sheet = FileCopyBackSheet(cloneName: cloneName, sourceRoot: sourceRoot,
                                      cloneRoot: cloneRoot, changes: changes,
                                      window: window, onApply: onApply)
        active = sheet
        window.beginSheet(sheet.panel)
    }

    private init(cloneName: String, sourceRoot: String, cloneRoot: String,
                 changes: [FileCopyBack.FileChange], window: NSWindow,
                 onApply: @escaping ([FileCopyBack.Decision]) -> Void) {
        self.hostWindow = window
        self.sourceRoot = sourceRoot
        self.cloneRoot = cloneRoot
        self.rows = changes.map(Row.init)
        self.onApply = onApply

        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                         styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Merge to Source — \(cloneName)"
        panel.appearance = ZTheme.current.appearance
        panel.backgroundColor = ZTheme.current.bg1Color
        super.init()
        buildLayout()
    }

    private func buildLayout() {
        let content = NSView()

        // Left: file table.
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = ZTheme.current.bg1Color
        table.headerView = nil
        table.rowHeight = 22
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        // Right: diff text.
        diffView.isEditable = false
        diffView.drawsBackground = true
        diffView.backgroundColor = ZTheme.current.bg1Color
        diffView.textContainerInset = NSSize(width: 8, height: 8)
        let diffScroll = NSScrollView()
        diffScroll.documentView = diffView
        diffScroll.hasVerticalScroller = true
        diffScroll.translatesAutoresizingMaskIntoConstraints = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(diffScroll)

        let intro = NSTextField(wrappingLabelWithString:
            "This clone's source isn't a git repository. Choose which changed files to bring "
            + "back. “Replace” overwrites the source's file; “Keep Both” saves the clone's copy "
            + "as “name 2.ext”. Nothing is deleted.")
        intro.font = NSFont.systemFont(ofSize: 12)
        intro.textColor = ZTheme.current.fg2Color
        intro.translatesAutoresizingMaskIntoConstraints = false

        let apply = NSButton(title: "Bring to Source", target: self, action: #selector(applyClicked))
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, apply])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        [intro, split, buttons].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            split.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            tableScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        panel.contentView = content
        if let first = rows.indices.first {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            renderDiff(for: rows[first])
        } else {
            renderPlain("No differences — the clone matches its source.")
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let model = rows[row]
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6

        let include = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleInclude(_:)))
        include.state = model.include ? .on : .off
        include.tag = row

        let status = NSTextField(labelWithString: model.change.kind == .added ? "A" : "M")
        status.font = ZTheme.monoFont(size: 11)
        status.textColor = model.change.kind == .added ? ZTheme.current.greenColor : ZTheme.current.yellowColor
        status.setContentHuggingPriority(.required, for: .horizontal)

        let name = NSTextField(labelWithString: model.change.relPath)
        name.font = ZTheme.monoFont(size: 11)
        name.textColor = ZTheme.current.fgColor
        name.lineBreakMode = .byTruncatingMiddle

        stack.addArrangedSubview(include)
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(name)

        // Modified files get a Replace/Keep-Both selector; added files don't conflict.
        if model.change.kind == .modified {
            let selector = NSSegmentedControl(labels: ["Replace", "Keep Both"],
                                              trackingMode: .selectOne,
                                              target: self, action: #selector(changeAction(_:)))
            selector.selectedSegment = model.action == .keepBoth ? 1 : 0
            selector.tag = row
            selector.segmentDistribution = .fit
            stack.addArrangedSubview(selector)
        }
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0 else { return }
        renderDiff(for: rows[table.selectedRow])
    }

    @objc private func toggleInclude(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].include = sender.state == .on
    }

    @objc private func changeAction(_ sender: NSSegmentedControl) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].action = sender.selectedSegment == 1 ? .keepBoth : .replace
    }

    // MARK: - Diff rendering

    private func renderDiff(for row: Row) {
        let text = FileCopyBackRunner.contentDiff(sourceRoot: sourceRoot, cloneRoot: cloneRoot,
                                                  relPath: row.change.relPath, kind: row.change.kind)
        let result = NSMutableAttributedString()
        let mono = ZTheme.monoFont(size: 11)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let color: NSColor
            if s.hasPrefix("+") { color = ZTheme.current.greenColor }
            else if s.hasPrefix("-") { color = ZTheme.current.redColor }
            else if s.hasPrefix("@@") { color = ZTheme.current.accentColor }
            else if s.hasPrefix("diff ") || s.hasPrefix("index ") { color = ZTheme.current.fg3Color }
            else { color = ZTheme.current.fg2Color }
            result.append(NSAttributedString(string: s + "\n",
                attributes: [.font: mono, .foregroundColor: color]))
        }
        diffView.textStorage?.setAttributedString(result)
    }

    private func renderPlain(_ message: String) {
        diffView.textStorage?.setAttributedString(NSAttributedString(
            string: message,
            attributes: [.font: ZTheme.monoFont(size: 11),
                         .foregroundColor: ZTheme.current.fg2Color]))
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        hostWindow.endSheet(panel)
        Self.active = nil
    }

    @objc private func applyClicked() {
        let decisions = rows.filter(\.include).map {
            FileCopyBack.Decision(change: $0.change, action: $0.action)
        }
        hostWindow.endSheet(panel)
        Self.active = nil
        onApply(decisions)
    }
}
```

- [ ] **Step 2: Wire into the non-git branch** — in `App/Sources/App/TerminalViewController.swift`, in `presentMergeToSourceChooser`, replace the `guard options.canMergeUpdates else { … "coming soon" alert … }` block's body with a launch of the copy-back flow:

```swift
        guard options.canMergeUpdates else {
            // Non-git source → the file copy-back diff modal.
            guard let window = view.window else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let changes = FileCopyBackRunner.changes(sourceRoot: sourceRoot, cloneRoot: cloneRoot)
                DispatchQueue.main.async {
                    guard !changes.isEmpty else {
                        let alert = NSAlert()
                        alert.alertStyle = .informational
                        alert.messageText = "Nothing to bring back"
                        alert.informativeText = "“\(cloneName)” has no changes its source doesn't already have."
                        alert.addButton(withTitle: "OK")
                        alert.beginSheetModal(for: window, completionHandler: nil)
                        return
                    }
                    FileCopyBackSheet.present(cloneName: cloneName, sourceRoot: sourceRoot,
                                              cloneRoot: cloneRoot, changes: changes, on: window) { decisions in
                        guard !decisions.isEmpty else { return }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let result = FileCopyBackRunner.apply(sourceRoot: sourceRoot,
                                                                  cloneRoot: cloneRoot, decisions: decisions)
                            DispatchQueue.main.async {
                                self.presentCopyBackResult(result, cloneName: cloneName)
                            }
                        }
                    }
                }
            }
            return
        }
```

Then add the result presenter alongside the other present* methods:

```swift
    private func presentCopyBackResult(_ result: FileCopyBackRunner.ApplyResult, cloneName: String) {
        let alert = NSAlert()
        if result.errors.isEmpty {
            alert.alertStyle = .informational
            alert.messageText = "Brought \(result.applied) file\(result.applied == 1 ? "" : "s") to the source"
            alert.informativeText = "Copied from “\(cloneName)” into its source directory."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Brought \(result.applied) file\(result.applied == 1 ? "" : "s"); \(result.errors.count) failed"
            alert.informativeText = result.errors.joined(separator: "\n")
        }
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }
```

Note: the `sourceRoot`/`cloneRoot`/`cloneName` used here are the ones already captured in `presentMergeToSourceChooser`'s signature (Phase 1). `self` is used inside the closures — capture `[weak self]` on the outer async and guard, consistent with the sibling methods; adjust the closures to `self?`/`guard let self`.

- [ ] **Step 3: Regenerate + build** (new file added → clean first)

```
mise exec -- tuist clean
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/App/FileCopyBackSheet.swift App/Sources/App/TerminalViewController.swift
git commit -m "feat(app): non-git clone file copy-back diff modal"
```

---

### Task 4: Docs

**Files:** `README.md`, `CLAUDE.md`, `AGENTS.md`

- [ ] **Step 1: README** — in the clone "Bringing clone work back" section, replace the "non-git sources coming soon" note with the real behavior: for a non-git source, **Merge to Source…** opens a diff modal (built on `git diff --no-index`) listing the clone's changed/new files with a line-diff preview; each file can be brought back with **Replace** or **Keep Both** (`name 2.ext`); nothing is deleted.

- [ ] **Step 2: CLAUDE.md + AGENTS.md** — update the clone paragraph to note the non-git path: pure `FileCopyBack` (parse `git diff --no-index --name-status -z`, Keep-Both naming) + app-layer `FileCopyBackRunner` (diff + guarded copy) + `FileCopyBackSheet` (the diff modal), launched from the non-git branch of `presentMergeToSourceChooser`. Same edit in both files, byte-identical.

- [ ] **Step 3: Verify parity** — `diff CLAUDE.md AGENTS.md` → no output.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md AGENTS.md
git commit -m "docs: non-git clone file copy-back (diff modal)"
```

---

## Self-Review

- **Spec coverage:** diff via `git diff --no-index` (Tasks 1-2), modal showing what changed with a line-diff preview (Task 3), per-file Replace/Keep-Both + include (Tasks 1/3), copy-back that never deletes and Keep-Both preserves the source (Tasks 1-2), wired into the non-git branch replacing the placeholder (Task 3), docs (Task 4). ✅
- **Placeholders:** none — full code in every code step; scripts have expected markers. ✅
- **Type consistency:** `FileChange`/`ChangeKind`/`Action`/`Decision` identical Tasks 1/2/3; `FileCopyBackRunner.changes`/`contentDiff`/`apply`/`ApplyResult` identical Tasks 2/3; `FileCopyBackSheet.present(cloneName:sourceRoot:cloneRoot:changes:on:onApply:)` identical Tasks 3. ✅
- **Risk:** the modal is the largest surface and is GUI (TCC-denied) — non-UI parts (parse/diff/copy) are unit-tested + script-verified; the sheet is build-gated and the user does the visual/interaction check. `git diff --no-index` exit-1-is-success is handled by reading stdout regardless of code.
- **TDD note:** Task 1 pure is red→green. Tasks 2-3 are IO + AppKit — headless script (Task 2) + build gate; live modal verified by the user.
