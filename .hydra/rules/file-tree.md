---
paths:
    - "Sources/ZettyCore/FileTree/**"
    - "App/Sources/App/FileTree/**"
triggers:
    - "changing the per-pane file tree"
---

# Per-pane file tree

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

`⇧⌘F`, `Ctrl+B e`, a gutter button, or the pane context menu toggles a file tree
inside a terminal pane.

**`⇧⌘F` is a native menu key equivalent, not a binding.** `KeyBindingEngine` has
only a prefix table and a copy table — in `.normal` mode it tests for the prefix
chord and passes everything else through, so there is nowhere to register a
direct chord. Adding one would mean a third table plus a new config key; until
that exists, native shortcuts live in the View menu. (The chord itself is safe:
`ctrl+shift+b` normalizes to `ctrl+B` — uppercase, shift folded in — which is a
different `KeyChord` from the `ctrl+b` prefix, so it can't arm the prefix.) Hidden by default; `Surface.fileTreeVisible` / `fileTreeWidth`
persist it per pane (both decoded tolerantly, so older `workspace.json` files
load unchanged).

**It is an attachment to a pane, not a pane.** `SurfaceNode` stays
`.leaf(Surface)` — no new case — so `Layout.swift`, the `.surfaces` accessor,
session ownership, `prune`, and the control CLI are all untouched, and prefix
focus / ⌘W / zoom / break-into-tab keep their existing meaning. Deliberate: a
tree-as-pane would force an answer for each of those.

Pure logic in `ZettyCore/FileTree/`: `FileTreeEntry`, `FileTreeSettings`,
`FileTreeFilter` (hidden-file, denylist, and gitignore rules composing, plus
sort order), `GitignoreMatcher`/`GitignoreStack` (globs, `**`, anchoring,
directory-only, negation, deepest-file-wins), `FileTreeSearch` (fuzzy ranking),
`FileTreeExpansionCache` (bounded LRU of expanded dirs per root). App layer:
`DirectoryEnumerator` (the only filesystem reader — every function blocks and
must run off-main), `FileTreeView`, `FileTreeWatcher`, `FileTreeWiring`.

`FileTreeWiring` bundles the five leaf callbacks into one value because
`SurfaceNodeView` → `RatioSplitView` → `SurfaceNodeView` is a recursive builder
already threading seven parameters; add new leaf plumbing there, not as more
positional arguments.

Gotchas, all deliberate:

- **The watcher is filtered to EXPANDED directories.** One FSEvents stream per
  visible tree, debounced 250ms, and events outside open directories are
  dropped. Watching a whole root and refreshing per event is exactly the
  per-second churn that once put 59% of the main thread in Auto Layout — a
  collapsed `node_modules` must absorb an `npm install` silently.
- **`zetty-` is the reserved namespace for NEW keys**, and
  `isReservedButUnsupported` swallows all of it, so a future `zetty-*` key is
  safe the moment it is named — no list to remember. `notify-` is grandfathered.
  A bare `file-tree-*` key is NOT reserved and forwards to ghostty like any
  other directive; a test pins that. Migrating the other 19 unprefixed keys is
  specced in `docs/superpowers/specs/2026-08-09-zetty-config-prefix-migration-design.md`.
- **CRLF `.gitignore` files need normalising before splitting.** Swift treats
  `\r\n` as a SINGLE `Character`, so `split(separator: "\n")` never splits a
  CRLF file — the whole thing collapses into one nonsense pattern that silently
  matches nothing. Regression-tested.
- **Re-rooting on `cd` is debounced 500ms** (driven from `refreshStatusBar`,
  which already runs on cwd-change cadence) and expansion state is keyed by
  absolute path in `FileTreeExpansionCache`, because agents `cd` several times a
  second and a tree that collapses on every hop is worse than no tree.
- **Search needs the whole root enumerated**, so it can't ride the lazy expand
  path: one bounded background walk (100k files) per root, started *after* first
  paint, refreshed on re-root and on the context menu's Refresh — never per
  FSEvent. `FileTreeView.indexLimit` is `nonisolated` because that walk reads it
  off the main actor.
- **The context menu's Open With routes through `onActivateFile`** →
  `presentFileViewer` → `ExternalOpenPolicy`, so a compiled binary is revealed
  rather than launched. Never reimplement that hand-off locally; the security
  decision has one home.
- **Chrome font, not mono** (`ZTheme.chromeFont`) — the tree is chrome, so the
  terminal font must not reflow it. A scheme change runs through
  `rebuildSurfaceNodeView()`, which recreates every tree, so there is no render
  cache to invalidate — that's why `LeafContainerView` has no theme forwarder.
- **Tree updates never call `refreshTabBar()`/`refreshSidebar()`.** They stay
  inside the pane's own view. `rebuildSurfaceNodeView` stops every tree's
  watcher for the same reason it calls `pathHover.reset()`.

Deferred: per-row git status, content search (distinct from S1 scrollback search
and S8 cross-pane grep, which search terminal *output*), per-project
`zetty-file-tree-*` overrides, a `zetty tree` CLI verb (dropped — agents have
`ls`, `find`, and `rg`), and any write path.
