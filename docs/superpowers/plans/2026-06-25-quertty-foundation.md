# quertty Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the quertty SPM workspace, a fully-tested pure-Swift `QuerttyCore` (layout tree + model + persistence), and a de-risked single libghostty terminal surface rendering in a SwiftUI window.

**Architecture:** Three SPM targets — `QuerttyCore` (pure Swift, no UI/C imports; the portable brain), `GhosttyKit` (the only module that touches libghostty's C API), and `quertty` (the macOS SwiftUI/AppKit app). This plan delivers all of `QuerttyCore`'s foundation plus the Phase 0 spike proving the GhosttyKit↔libghostty seam. Phase 1 UI, AI-detection, and CLI subsystems are deliberately deferred to follow-up plans written against the C API this plan pins.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing (`import Testing`), SwiftUI + AppKit (macOS 14+), full libghostty (vendored & pinned), Metal.

## Global Constraints

- **Platform:** macOS first (macOS 14.0 minimum deployment target). No Windows. Linux is a future port — `QuerttyCore` and `GhosttyKit` must import no AppKit/SwiftUI.
- **Layer rule:** `QuerttyCore` imports no UI frameworks and no C library. `GhosttyKit` is the only module that imports libghostty. The app target is the only one importing SwiftUI/AppKit.
- **Ghostty layer:** Full **libghostty** (renderer included), NOT `libghostty-vt`. We render nothing ourselves.
- **libghostty pinning:** Vendored at a single known Ghostty commit, recorded verbatim in `vendor/GHOSTTY_COMMIT`. Never float the dependency.
- **Testing:** Use Swift Testing (`import Testing`, `@Test`, `#expect`). `QuerttyCore` carries the test weight; all its logic is unit-tested. GhosttyKit/app are smoke/manually verified.
- **Commits:** Frequent, one per task minimum. Do not push without the owner's say-so.

---

### Task 1: SPM workspace + three-target skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/QuerttyCore/QuerttyCore.swift`
- Create: `Tests/QuerttyCoreTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a `QuerttyCore` library target named `QuerttyCore`, importable by tests and later the app; a working `swift test` cycle.

- [ ] **Step 1: Write the Package manifest**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "quertty",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuerttyCore", targets: ["QuerttyCore"]),
    ],
    targets: [
        .target(name: "QuerttyCore"),
        .testTarget(name: "QuerttyCoreTests", dependencies: ["QuerttyCore"]),
    ]
)
```

- [ ] **Step 2: Write a placeholder source so the target compiles**

```swift
// Sources/QuerttyCore/QuerttyCore.swift
/// Marker for the QuerttyCore module. Real types live in their own files.
public enum QuerttyCore {
    public static let version = "0.0.1"
}
```

- [ ] **Step 3: Write the smoke test**

```swift
// Tests/QuerttyCoreTests/SmokeTests.swift
import Testing
@testable import QuerttyCore

@Test func moduleHasVersion() {
    #expect(QuerttyCore.version == "0.0.1")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS, 1 test passing.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "chore: SPM workspace with QuerttyCore target and smoke test"
```

---

### Task 2: Core model types

**Files:**
- Create: `Sources/QuerttyCore/Model/Surface.swift`
- Create: `Sources/QuerttyCore/Model/Project.swift`
- Create: `Tests/QuerttyCoreTests/ModelTests.swift`

**Interfaces:**
- Consumes: nothing from prior tasks.
- Produces:
  - `struct Surface: Codable, Sendable, Equatable, Identifiable` — `id: UUID`, `workingDir: String`, `command: String?`. Init: `init(id: UUID = UUID(), workingDir: String, command: String? = nil)`.
  - `enum SplitDirection: String, Codable, Sendable { case horizontal, vertical }`
  - `struct Tab: Codable, Sendable, Equatable, Identifiable` — `id: UUID`, `title: String`, `layout: Layout` (defined in Task 3; for now declare the property after Task 3 — see ordering note).
  - `struct Session`, `struct Project` (below).

> **Ordering note:** `Tab` references `Layout` from Task 3. Implement `Surface`, `SplitDirection`, `Session`, and `Project`-without-`Tab` here; add `Tab` and wire it into `Session` at the end of Task 3 where `Layout` exists. The steps below build only the parts whose types already exist.

- [ ] **Step 1: Write the failing test for Surface + Project**

```swift
// Tests/QuerttyCoreTests/ModelTests.swift
import Testing
import Foundation
@testable import QuerttyCore

@Test func surfaceCarriesWorkingDirAndCommand() {
    let s = Surface(workingDir: "/tmp/proj", command: "claude")
    #expect(s.workingDir == "/tmp/proj")
    #expect(s.command == "claude")
}

@Test func projectStartsUnpinnedWithNoSessions() {
    let p = Project(name: "demo", rootPath: "/tmp/proj")
    #expect(p.name == "demo")
    #expect(p.isPinned == false)
    #expect(p.sessions.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ModelTests`
Expected: FAIL — `Surface`/`Project` not found.

- [ ] **Step 3: Implement Surface and SplitDirection**

```swift
// Sources/QuerttyCore/Model/Surface.swift
import Foundation

public enum SplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

public struct Surface: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var workingDir: String
    public var command: String?

    public init(id: UUID = UUID(), workingDir: String, command: String? = nil) {
        self.id = id
        self.workingDir = workingDir
        self.command = command
    }
}
```

- [ ] **Step 4: Implement Project and Session**

```swift
// Sources/QuerttyCore/Model/Project.swift
import Foundation

public struct Session: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    // tabs added in Task 3 once Layout exists.

    public init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
}

public struct Project: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var rootPath: String
    public var isPinned: Bool
    public var sortOrder: Int
    public var preserveSessions: Bool
    public var sessions: [Session]

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        isPinned: Bool = false,
        sortOrder: Int = 0,
        preserveSessions: Bool = false,
        sessions: [Session] = []
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.isPinned = isPinned
        self.sortOrder = sortOrder
        self.preserveSessions = preserveSessions
        self.sessions = sessions
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ModelTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuerttyCore/Model Tests/QuerttyCoreTests/ModelTests.swift
git commit -m "feat(core): Surface, SplitDirection, Session, Project model types"
```

---

### Task 3: Layout tree (split / close / resize)

**Files:**
- Create: `Sources/QuerttyCore/Model/SurfaceNode.swift`
- Create: `Sources/QuerttyCore/Model/Layout.swift`
- Modify: `Sources/QuerttyCore/Model/Project.swift` (add `Tab`, wire into `Session`)
- Create: `Tests/QuerttyCoreTests/LayoutTests.swift`

**Interfaces:**
- Consumes: `Surface`, `SplitDirection` (Task 2).
- Produces:
  - `indirect enum SurfaceNode: Codable, Sendable, Equatable` — cases `.leaf(Surface)` and `.split(direction: SplitDirection, ratio: Double, first: SurfaceNode, second: SurfaceNode)`. Computed `var surfaces: [Surface]`.
  - `struct Layout: Codable, Sendable, Equatable` — `var root: SurfaceNode`; `var surfaces: [Surface]`; `mutating func split(surfaceID:direction:newSurface:ratio:) -> Bool`; `mutating func close(surfaceID:) -> Bool`; `mutating func setRatio(parentOf:to:) -> Bool`.
  - `struct Tab: Codable, Sendable, Equatable, Identifiable` — `id: UUID`, `title: String`, `layout: Layout`; and `Session.tabs: [Tab]`.

> **Design refinement of the PRD:** the PRD sketched `.split(... children: [SurfaceNode])`; we use an explicit **binary** `first`/`second` because ratio resizing and parent-collapse-on-close are unambiguous with two children.

- [ ] **Step 1: Write failing tests for the layout tree**

```swift
// Tests/QuerttyCoreTests/LayoutTests.swift
import Testing
import Foundation
@testable import QuerttyCore

private func surface(_ n: Int) -> Surface {
    Surface(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!,
            workingDir: "/tmp")
}

@Test func singleLeafHasOneSurface() {
    let layout = Layout(root: .leaf(surface(1)))
    #expect(layout.surfaces.map(\.id) == [surface(1).id])
}

@Test func splitReplacesLeafWithBinarySplit() {
    var layout = Layout(root: .leaf(surface(1)))
    let ok = layout.split(surfaceID: surface(1).id, direction: .vertical, newSurface: surface(2))
    #expect(ok)
    #expect(layout.surfaces.map(\.id) == [surface(1).id, surface(2).id])
    guard case let .split(direction, ratio, first, second) = layout.root else {
        Issue.record("root should be a split"); return
    }
    #expect(direction == .vertical)
    #expect(ratio == 0.5)
    #expect(first == .leaf(surface(1)))
    #expect(second == .leaf(surface(2)))
}

@Test func splitUnknownSurfaceReturnsFalse() {
    var layout = Layout(root: .leaf(surface(1)))
    #expect(layout.split(surfaceID: surface(9).id, direction: .horizontal, newSurface: surface(2)) == false)
}

@Test func closeCollapsesParentToSibling() {
    var layout = Layout(root: .leaf(surface(1)))
    _ = layout.split(surfaceID: surface(1).id, direction: .horizontal, newSurface: surface(2))
    let ok = layout.close(surfaceID: surface(1).id)
    #expect(ok)
    #expect(layout.root == .leaf(surface(2)))
}

@Test func closingTheOnlySurfaceFails() {
    var layout = Layout(root: .leaf(surface(1)))
    #expect(layout.close(surfaceID: surface(1).id) == false)
    #expect(layout.root == .leaf(surface(1)))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LayoutTests`
Expected: FAIL — `SurfaceNode`/`Layout` not found.

- [ ] **Step 3: Implement SurfaceNode**

```swift
// Sources/QuerttyCore/Model/SurfaceNode.swift
import Foundation

public indirect enum SurfaceNode: Codable, Sendable, Equatable {
    case leaf(Surface)
    case split(direction: SplitDirection, ratio: Double, first: SurfaceNode, second: SurfaceNode)

    /// All leaf surfaces, left-to-right / first-to-second order.
    public var surfaces: [Surface] {
        switch self {
        case .leaf(let s):
            return [s]
        case .split(_, _, let first, let second):
            return first.surfaces + second.surfaces
        }
    }
}
```

- [ ] **Step 4: Implement Layout operations**

```swift
// Sources/QuerttyCore/Model/Layout.swift
import Foundation

public struct Layout: Codable, Sendable, Equatable {
    public var root: SurfaceNode

    public init(root: SurfaceNode) {
        self.root = root
    }

    public var surfaces: [Surface] { root.surfaces }

    /// Replace the leaf with `surfaceID` by a binary split of the existing
    /// surface (first) and `newSurface` (second). Returns false if not found.
    @discardableResult
    public mutating func split(
        surfaceID: UUID,
        direction: SplitDirection,
        newSurface: Surface,
        ratio: Double = 0.5
    ) -> Bool {
        var changed = false
        root = Self.transform(root) { node in
            guard case let .leaf(existing) = node, existing.id == surfaceID else { return nil }
            changed = true
            return .split(direction: direction, ratio: ratio,
                          first: .leaf(existing), second: .leaf(newSurface))
        }
        return changed
    }

    /// Remove the leaf with `surfaceID`, collapsing its parent split to the
    /// sibling. Returns false if it's the only surface or not found.
    @discardableResult
    public mutating func close(surfaceID: UUID) -> Bool {
        // The root being the target leaf means it's the only surface.
        if case let .leaf(s) = root, s.id == surfaceID { return false }
        var changed = false
        root = Self.collapse(root, removing: surfaceID, changed: &changed)
        return changed
    }

    /// Set the ratio of the split that directly contains the leaf `surfaceID`.
    @discardableResult
    public mutating func setRatio(parentOf surfaceID: UUID, to ratio: Double) -> Bool {
        let clamped = min(max(ratio, 0.05), 0.95)
        var changed = false
        root = Self.transform(root) { node in
            guard case let .split(direction, _, first, second) = node else { return nil }
            let directlyContains =
                (first.isLeaf(surfaceID) || second.isLeaf(surfaceID))
            guard directlyContains else { return nil }
            changed = true
            return .split(direction: direction, ratio: clamped, first: first, second: second)
        }
        return changed
    }

    // MARK: - Recursion helpers

    /// Bottom-up rewrite: apply `rewrite` to each node; if it returns a
    /// replacement, use it, else recurse into children.
    private static func transform(
        _ node: SurfaceNode,
        _ rewrite: (SurfaceNode) -> SurfaceNode?
    ) -> SurfaceNode {
        if let replacement = rewrite(node) { return replacement }
        switch node {
        case .leaf:
            return node
        case let .split(direction, ratio, first, second):
            return .split(direction: direction, ratio: ratio,
                          first: transform(first, rewrite),
                          second: transform(second, rewrite))
        }
    }

    /// Remove `surfaceID`; a split whose child is the removed leaf collapses to
    /// its sibling.
    private static func collapse(
        _ node: SurfaceNode,
        removing surfaceID: UUID,
        changed: inout Bool
    ) -> SurfaceNode {
        switch node {
        case .leaf:
            return node
        case let .split(direction, ratio, first, second):
            if first.isLeaf(surfaceID) { changed = true; return collapse(second, removing: surfaceID, changed: &changed) }
            if second.isLeaf(surfaceID) { changed = true; return collapse(first, removing: surfaceID, changed: &changed) }
            return .split(direction: direction, ratio: ratio,
                          first: collapse(first, removing: surfaceID, changed: &changed),
                          second: collapse(second, removing: surfaceID, changed: &changed))
        }
    }
}

extension SurfaceNode {
    /// True if this node is a leaf holding `id`.
    func isLeaf(_ id: UUID) -> Bool {
        if case let .leaf(s) = self { return s.id == id }
        return false
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LayoutTests`
Expected: PASS, all 5 layout tests.

- [ ] **Step 6: Add `Tab` and wire it into `Session`**

```swift
// Append to Sources/QuerttyCore/Model/Project.swift

public struct Tab: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var layout: Layout

    public init(id: UUID = UUID(), title: String, layout: Layout) {
        self.id = id
        self.title = title
        self.layout = layout
    }
}
```

Then add `public var tabs: [Tab]` to `Session` (default `[]`) and include it in `Session.init`:

```swift
// Replace Session in Project.swift with:
public struct Session: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var tabs: [Tab]

    public init(id: UUID = UUID(), title: String, tabs: [Tab] = []) {
        self.id = id
        self.title = title
        self.tabs = tabs
    }
}
```

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS (model + layout tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/QuerttyCore/Model Tests/QuerttyCoreTests/LayoutTests.swift
git commit -m "feat(core): binary SurfaceNode layout tree with split/close/resize + Tab wiring"
```

---

### Task 4: Workspace persistence (JSON round-trip)

**Files:**
- Create: `Sources/QuerttyCore/Persistence/Workspace.swift`
- Create: `Sources/QuerttyCore/Persistence/WorkspaceStore.swift`
- Create: `Tests/QuerttyCoreTests/PersistenceTests.swift`

**Interfaces:**
- Consumes: `Project` (Task 2/3) and its nested `Session`/`Tab`/`Layout`.
- Produces:
  - `struct Workspace: Codable, Sendable, Equatable` — `var projects: [Project]`; `var schemaVersion: Int` (current `1`).
  - `struct WorkspaceStore` — `init(directory: URL)`; `func load() throws -> Workspace` (returns empty workspace if file absent); `func save(_ workspace: Workspace) throws`. File is `workspace.json` in `directory`, pretty-printed, atomic write.

- [ ] **Step 1: Write failing round-trip + missing-file tests**

```swift
// Tests/QuerttyCoreTests/PersistenceTests.swift
import Testing
import Foundation
@testable import QuerttyCore

private func tempDir() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("quertty-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func loadingMissingWorkspaceReturnsEmpty() throws {
    let store = WorkspaceStore(directory: tempDir())
    let ws = try store.load()
    #expect(ws.projects.isEmpty)
    #expect(ws.schemaVersion == 1)
}

@Test func saveThenLoadRoundTrips() throws {
    let dir = tempDir()
    let store = WorkspaceStore(directory: dir)

    let surface = Surface(workingDir: "/tmp/proj", command: "claude")
    let tab = Tab(title: "main", layout: Layout(root: .leaf(surface)))
    let session = Session(title: "work", tabs: [tab])
    let project = Project(name: "demo", rootPath: "/tmp/proj",
                          isPinned: true, sessions: [session])
    let original = Workspace(schemaVersion: 1, projects: [project])

    try store.save(original)
    let restored = try store.load()

    #expect(restored == original)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PersistenceTests`
Expected: FAIL — `Workspace`/`WorkspaceStore` not found.

- [ ] **Step 3: Implement Workspace**

```swift
// Sources/QuerttyCore/Persistence/Workspace.swift
import Foundation

public struct Workspace: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var projects: [Project]

    public init(schemaVersion: Int = 1, projects: [Project] = []) {
        self.schemaVersion = schemaVersion
        self.projects = projects
    }
}
```

- [ ] **Step 4: Implement WorkspaceStore**

```swift
// Sources/QuerttyCore/Persistence/WorkspaceStore.swift
import Foundation

public struct WorkspaceStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("workspace.json")
    }

    public func load() throws -> Workspace {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Workspace()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Workspace.self, from: data)
    }

    public func save(_ workspace: Workspace) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workspace)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter PersistenceTests`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS (all core tests green).

- [ ] **Step 7: Commit**

```bash
git add Sources/QuerttyCore/Persistence Tests/QuerttyCoreTests/PersistenceTests.swift
git commit -m "feat(core): Workspace JSON persistence with round-trip + missing-file handling"
```

---

### Task 5: Vendor & pin libghostty; discover the surface C API

> **This is a discovery/spike task.** Its deliverable is the *pinned, recorded C API surface* that later GhosttyKit interop code is written against. We do NOT fabricate `ghostty_*` signatures from memory — we read them from the vendored header and record them verbatim.

**Files:**
- Create: `vendor/GHOSTTY_COMMIT` (the pinned commit hash + date)
- Create: `vendor/README.md` (how libghostty is obtained/built and where the header lives)
- Create: `docs/ghostty-embedding-api.md` (the recorded API reference — created in Step 4)
- Modify: `.gitignore` (already ignores `vendor/**/zig-out/` etc.)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `docs/ghostty-embedding-api.md` containing the **verbatim** signatures of the libghostty embedding entry points that Task 6 will bind. At minimum it must record the real names/signatures for: runtime/app init, surface creation (and what drawing target it takes — Metal layer vs callback), size/focus/key/mouse input entry points, the draw/tick entry point, and the embedder **callback table** (title, bell, clipboard, child-exit, OSC notification).

- [ ] **Step 1: Obtain and pin libghostty**

Clone Ghostty, check out a specific recent commit, and record it. Run:

```bash
mkdir -p vendor
git clone https://github.com/ghostty-org/ghostty vendor/ghostty
cd vendor/ghostty && git rev-parse HEAD | tee ../GHOSTTY_COMMIT && git log -1 --format=%cd >> ../GHOSTTY_COMMIT
```

Expected: `vendor/GHOSTTY_COMMIT` contains a 40-char hash and a date.

- [ ] **Step 2: Locate the embedding header and library build**

Find the public C header and the macOS framework/static-lib build target. Run:

```bash
find vendor/ghostty -name "*.h" -path "*include*" -o -name "ghostty.h" | head
grep -rn "GHOSTTY_EXPORT\|export fn ghostty_" vendor/ghostty/src | head -40
```

Expected: the path to the embedding header (e.g. an `include/ghostty.h`) and the list of exported `ghostty_*` functions. Note: Ghostty builds libghostty via `zig build`; record the exact build invocation that produces the macOS artifact GhosttyKit will link (it is what Ghostty's own `macos/` Xcode project consumes).

- [ ] **Step 3: Build the macOS libghostty artifact once**

Run the build command discovered in Step 2 (Ghostty documents this for its macOS app — typically a `zig build` producing `GhosttyKit.xcframework` or a static lib). Capture the exact command and output path.

Expected: a buildable libghostty artifact + the precise path, both recorded in `vendor/README.md`.

- [ ] **Step 4: Record the API reference**

Read the header and write `docs/ghostty-embedding-api.md` with the **verbatim** C signatures for the entry points listed in the Interfaces block, plus a one-line note on threading expectations and how a surface is given its render target. This document is the contract Task 6 implements against.

- [ ] **Step 5: Commit**

```bash
git add vendor/GHOSTTY_COMMIT vendor/README.md docs/ghostty-embedding-api.md .gitignore
git commit -m "chore(ghostty): vendor + pin libghostty; record embedding C API reference"
```

> Do **not** commit the cloned `vendor/ghostty` working tree or build outputs. If keeping the source vendored is desired, add it as a git submodule pinned to `GHOSTTY_COMMIT` in a follow-up step; otherwise add `vendor/ghostty/` to `.gitignore`.

---

### Task 6: GhosttyKit C-interop target (compiles + links + smoke call)

**Files:**
- Create: `Sources/CGhostty/module.modulemap`
- Create: `Sources/CGhostty/shim.h`
- Create: `Sources/GhosttyKit/Ghostty.swift`
- Create: `Tests/GhosttyKitTests/LinkSmokeTests.swift`
- Modify: `Package.swift` (add `CGhostty` system/target, `GhosttyKit` target, test target, linker settings)

**Interfaces:**
- Consumes: the signatures recorded in `docs/ghostty-embedding-api.md` (Task 5).
- Produces:
  - A `CGhostty` target exposing libghostty's header to Swift via a module map.
  - `enum Ghostty` (in `GhosttyKit`) with `static func initializeRuntime() throws` wrapping the real init entry point recorded in Task 5, and a `static var isInitialized: Bool`.
  - Linkage so `import GhosttyKit` resolves libghostty symbols.

> The exact `ghostty_*` call inside `initializeRuntime()` MUST be the one recorded in Task 5 — substitute the real name/signature there. The structure below is fixed; the single C call is filled from the pinned API.

- [ ] **Step 1: Add the C module map and shim**

```c
/* Sources/CGhostty/shim.h */
#include "ghostty.h"   /* path resolved via header search path set in Package.swift */
```

```modulemap
// Sources/CGhostty/module.modulemap
module CGhostty {
    header "shim.h"
    export *
}
```

- [ ] **Step 2: Wire targets + linker settings into Package.swift**

Add to `targets:` (adjust `unsafeFlags` paths to the artifact path recorded in Task 5):

```swift
.target(
    name: "CGhostty",
    cSettings: [
        .unsafeFlags(["-I", "vendor/ghostty/include"])  // header dir from Task 5
    ]
),
.target(
    name: "GhosttyKit",
    dependencies: ["CGhostty"],
    linkerSettings: [
        .unsafeFlags(["-L", "vendor/ghostty/zig-out/lib", "-lghostty"])  // artifact from Task 5
    ]
),
.testTarget(name: "GhosttyKitTests", dependencies: ["GhosttyKit"]),
```

And add `GhosttyKit` to `products` if it should be importable by the app.

- [ ] **Step 3: Write the failing link-smoke test**

```swift
// Tests/GhosttyKitTests/LinkSmokeTests.swift
import Testing
@testable import GhosttyKit

@Test func runtimeInitializesWithoutThrowing() throws {
    try Ghostty.initializeRuntime()
    #expect(Ghostty.isInitialized)
}
```

- [ ] **Step 4: Run test to verify it fails (does not compile / does not link)**

Run: `swift test --filter GhosttyKitTests`
Expected: FAIL — `Ghostty` undefined (and/or link error proving symbols aren't wired yet).

- [ ] **Step 5: Implement the Ghostty runtime wrapper**

```swift
// Sources/GhosttyKit/Ghostty.swift
import CGhostty

public enum Ghostty {
    public private(set) static var isInitialized = false

    /// Initializes the libghostty global runtime exactly once.
    /// NOTE: the call below MUST be the real entry point recorded in
    /// docs/ghostty-embedding-api.md (Task 5). Replace `ghostty_init` and its
    /// arguments with the verbatim signature if they differ.
    public static func initializeRuntime() throws {
        guard !isInitialized else { return }
        let rc = ghostty_init(0, nil)   // ← substitute real signature from Task 5
        guard rc == 0 else { throw GhosttyError.initFailed(code: Int(rc)) }
        isInitialized = true
    }
}

public enum GhosttyError: Error, Equatable {
    case initFailed(code: Int)
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter GhosttyKitTests`
Expected: PASS — proving the header is visible, symbols link, and a real libghostty call succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/CGhostty Sources/GhosttyKit Tests/GhosttyKitTests Package.swift
git commit -m "feat(ghostty): CGhostty module map + GhosttyKit runtime init linking libghostty"
```

---

### Task 7: Phase 0 spike — one libghostty surface in a SwiftUI window

> **Spike task with a manual acceptance check** (rendering and input can't be unit-asserted headlessly). The deliverable is a runnable app showing a working terminal in one pane. This proves the riskiest seam (SwiftUI↔AppKit↔libghostty surface, focus, key routing, Metal) before any Phase 1 UI is built.

**Files:**
- Create: `Sources/quertty/querttyApp.swift`
- Create: `Sources/quertty/GhosttySurfaceView.swift` (AppKit `NSView` hosting a libghostty surface)
- Create: `Sources/quertty/SurfaceViewRepresentable.swift` (`NSViewRepresentable` bridge)
- Create: `Sources/quertty/ContentView.swift`
- Modify: `Package.swift` (add the `quertty` executable target)
- Create: `docs/phase0-acceptance.md` (the manual checklist + result)

**Interfaces:**
- Consumes: `Ghostty.initializeRuntime()` (Task 6) and the surface-creation / input / draw entry points + callback table recorded in Task 5.
- Produces: a runnable `quertty` executable; `GhosttySurfaceView: NSView` owning a `CAMetalLayer` and one libghostty surface; documented Phase 0 acceptance result.

- [ ] **Step 1: Add the executable target to Package.swift**

```swift
.executableTarget(
    name: "quertty",
    dependencies: ["QuerttyCore", "GhosttyKit"]
),
```

- [ ] **Step 2: Implement the AppKit surface view**

Create `GhosttySurfaceView: NSView` that: sets `wantsLayer = true` and backs itself with a `CAMetalLayer`; on `init`/`viewDidMoveToWindow` calls the libghostty surface-creation entry point (from Task 5) passing the Metal layer; forwards `keyDown`/`keyUp`/`flagsChanged`, `mouseDown`/`mouseUp`/`mouseMoved`/`scrollWheel`, and `setFrameSize`/`viewDidChangeBackingProperties` into the corresponding `ghostty_surface_*` calls; overrides `acceptsFirstResponder = true` and becomes first responder on click. Use the verbatim signatures from `docs/ghostty-embedding-api.md`. Spawn the user's `$SHELL` as the surface command.

> Reference Ghostty's own `macos/Sources/Ghostty/SurfaceView*.swift` for the working pattern at the pinned commit — mirror it, don't reinvent it.

- [ ] **Step 3: Implement the SwiftUI bridge and app shell**

```swift
// Sources/quertty/SurfaceViewRepresentable.swift
import SwiftUI

struct SurfaceViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> GhosttySurfaceView { GhosttySurfaceView() }
    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {}
}
```

```swift
// Sources/quertty/ContentView.swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        SurfaceViewRepresentable()
            .frame(minWidth: 640, minHeight: 400)
    }
}
```

```swift
// Sources/quertty/querttyApp.swift
import SwiftUI
import GhosttyKit

@main
struct QuerttyApp: App {
    init() {
        do { try Ghostty.initializeRuntime() }
        catch { fatalError("libghostty init failed: \(error)") }
    }
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

- [ ] **Step 4: Build and run**

Run: `swift build && swift run quertty`
(If a SwiftUI `@main` executable needs an app bundle to render, build/run via an Xcode app target generated from the package instead — document whichever works in `vendor/README.md`.)
Expected: a window opens showing a live terminal.

- [ ] **Step 5: Manual acceptance check — record results**

Create `docs/phase0-acceptance.md` and tick each:
- [ ] Window shows a shell prompt rendered by libghostty.
- [ ] Typing appears in the terminal; `ls`, `vim`, exit all work.
- [ ] Resizing the window reflows the terminal (PTY size updates).
- [ ] Clicking the pane gives it keyboard focus.
- [ ] A Kitty-graphics image (e.g. `kitten icat` or any inline-image tool) renders — confirming full libghostty rendering, not just text.

Record PASS/FAIL per line with notes. Any FAIL blocks Phase 1 and feeds back into the API binding.

- [ ] **Step 6: Commit**

```bash
git add Sources/quertty Package.swift docs/phase0-acceptance.md
git commit -m "feat(app): Phase 0 spike — single libghostty surface in a SwiftUI window"
```

---

## Self-Review

**Spec coverage (against PRD §3–§9 foundation portions):**
- 3-layer architecture (QuerttyCore / GhosttyKit / app) → Tasks 1, 6, 7. ✓
- Layer rule (Core no UI/C; GhosttyKit only C) → enforced by target boundaries in Tasks 1/6. ✓
- Data model (Project→Session→Tab→SurfaceNode) → Tasks 2, 3. ✓
- Binary split tree + split/close/resize → Task 3. ✓
- JSON persistence + restore + missing-file → Task 4. ✓
- Full libghostty (not vt) pinned → Tasks 5, 6. ✓
- Phase 0 surface spike incl. Kitty graphics check → Task 7. ✓
- **Deliberately deferred to follow-up plans:** sidebar/panel UI, AI presence + hook-status engine, `quertty` CLI + socket, `DetachedPTY`/zmx, tmux keybindings. These depend on the API pinned in Task 5 and are noted as separate plans (per scope check).

**Placeholder scan:** The only non-literal code is the single `ghostty_init(0, nil)` call (Task 6 Step 5) and the surface-view C calls (Task 7 Step 2), explicitly flagged to be substituted from the Task 5 API reference rather than guessed — this is correct given libghostty's API must be read from the pinned header, not fabricated. All pure-Swift tasks (1–4) contain complete, runnable code.

**Type consistency:** `Surface`, `SplitDirection`, `SurfaceNode` (`.leaf`/`.split(direction:ratio:first:second:)`), `Layout` (`split`/`close`/`setRatio`/`surfaces`), `Tab`, `Session.tabs`, `Project`, `Workspace`, `WorkspaceStore` (`load`/`save`), `Ghostty.initializeRuntime`/`isInitialized`, `GhosttyError.initFailed` — names and signatures match across all tasks and tests. ✓
