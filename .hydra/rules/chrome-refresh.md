---
paths:
    - "App/Sources/App/TabBarView.swift"
    - "App/Sources/App/StatusBarView.swift"
    - "App/Sources/App/SidebarView.swift"
    - "App/Sources/App/Tiles/TileGridView.swift"
triggers:
    - "refreshing the tab bar, sidebar or status bar from a title, hook or probe event"
    - "adding a color scheme or changing a widget's applyTheme"
    - "high CPU, memory growth or a sidebar that will not scroll while agents run"
---

# Chrome refresh: coalesce, no-op, never move the scroller

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

Agent CLIs animate a spinner glyph **in their terminal title**, so every frame
is a title escape sequence. Refreshing the chrome synchronously per event once
put 59% of the main thread in Auto Layout and leaked ~550 MB of AppKit KVO
records over two days (1.2 GB footprint, 2.8 GB peak, CPU pinned near 100%).
Three rules keep it flat; breaking any one reintroduces the whole class of bug:

1. **Machine-driven refreshes coalesce.** Terminal titles, the
   foreground-process probe and agent hook events call
   `TerminalViewController.setNeedsChromeRefresh(tabBar:sidebar:)`, which
   refreshes ONCE ~0.1s later. Only user-driven changes call
   `refreshTabBar()`/`refreshSidebar()` directly (same run-loop turn, so input
   still feels immediate). `SurfaceRegistry`'s title subscription also
   `removeDuplicates()` — `combineLatest` re-emits when *either* of title/cwd
   fires, so an unchanged republish used to wake everything.
2. **Every view-layer `update(...)` no-ops on unchanged input.**
   `SidebarProject` is `Equatable` for exactly this (`NSImage`/`NSColor` compare
   via `isEqual:`, and `AgentIcons` caches logos so an unchanged icon is the
   same instance); `TabBarView` caches its last titles/icons/selection and
   re-renders pills **in place** when only content moved, instead of
   destroying and rebuilding every pill's constraints.
   **Corollary — a scheme change must invalidate those caches**, because the
   inputs are equal and only the colors differ: `StatusBarView.applyTheme`
   calls `invalidateRenderCaches()`, `TabBarView.applyTheme` calls
   `item.restyle()` per pill, and `SidebarView.applyTheme` calls
   `rebuildOutline()`. Forget one and that widget freezes in the old palette.
3. **A re-render must never move the sidebar scroller.**
   `rebuildOutline()` calls `scrollRowToVisible` only when the *logical*
   selection (project + tab, not the row index — rows shift when a section
   collapses) actually changed. Unconditional scrolling made the sidebar
   impossible to scroll while any agent was running: it snapped back to the
   active project several times a second.

The layout rules for the chrome (tab strip, window floor, status bar
compaction, command palette, sidebar drawer) are in
`.hydra/rules/chrome-layout.md`; memory, surface and session-lifetime rules
are in `.hydra/rules/surfaces-and-memory.md`.
