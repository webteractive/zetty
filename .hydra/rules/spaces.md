---
paths:
    - "Sources/ZettyCore/Model/Space.swift"
    - "App/Sources/App/SpaceSheet.swift"
    - "App/Sources/App/SidebarView.swift"
commands:
    - "zetty new-space"
    - "zetty rename-space"
    - "zetty remove-space"
    - "zetty move-to-space"
triggers:
    - "changing sidebar sections, Spaces, or project ordering"
    - "drag-and-drop in the sidebar"
---

# Spaces

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

A **Space** is a named, colorable, collapsible sidebar section holding
related projects, rendered below Projects. Pure model in
`Sources/ZettyCore/Model/Space.swift` (`Space`: id/name/colorID/glyph/
isCollapsed, tolerant-decoded like `isHome`/`cloneSource`) plus
`WorkspaceModel.spaces: [Space]` and `Project.spaceID: UUID?`. **A Space is a
first-class persisted entity, not derived from membership** — `createSpace`
must be able to produce an empty one, and color/glyph/collapsed need a home
regardless of whether anything is filed into it. Array order in `spaces` IS
sidebar order; there is deliberately no second ordering field to disagree
with it.

`regroup()` mirrors the sidebar's sections: Home → spaceless pinned →
spaceless unpinned → each Space in `spaces` order → Scratch terminals last.
**Inside a Space, awake members come before dormant ones**, and members are
never pinned — `assign` clears the pin on the way in and `regroup()`
normalises any that slipped through (self-healing for a `workspace.json`
written before that rule). Scratch is held back explicitly so model order
matches the sidebar;

**The sidebar routes EVERY hibernated project to the Hibernating section**,
Space members included — `spaceID` is kept, so waking returns the project to
its Space (or to Projects when it has none). A hibernated row belonging to a
Space is tagged with that Space's name in `nameLabel`'s attributed text
(a subview would mean conditional constraints in a cell recycled on every
refresh). Because members render nowhere else, a Space's *dormant* count comes
from the filtered `hibernated` list rather than from its rendered rows — both
still derive from `visible`, so a search filter narrows them together. **A
Space with no awake members renders no header at all**; it stays reachable
from `Move to Space ▸`, which lists Spaces from the model, but it cannot be
drag-dropped onto while hidden.
`zetty status` renders model order, so otherwise the two surfaces would
disagree about where a scratch terminal sits.

The existing clone-gluing pass runs **unchanged** after that, which is what
carries a clone into its source's Space without storing anything on the
clone itself — and gluing WINS over the awake/dormant split, so a hibernated
clone of an awake source stays beside its source rather than sinking.

**`assign` re-appends the project to `projects` before regrouping**, so it
lands last among its destination's members. Because the Spaces block now sits
after Projects, leaving it in place would order members by wherever they
happened to sit in the array — which reverses assign order. Members cannot be
drag-sorted, so "the one you just filed appears last" is the only order a user
can predict.

**Hibernating or waking a project must call `WorkspaceModel.reapplyOrdering()`**
(`TerminalViewController.hibernateProject`/`wakeProject` do). The app layer owns
that write, `regroup()` is private, and without the call a member's Space would
not re-sort until some unrelated change happened to trigger a regroup. Note
`wakeProject` re-resolves its project index AFTER that call — the index captured
before it is stale. `moveProject(from:to:)`'s guard — "both endpoints must share
`isPinned`" — extends to **`isPinned` AND `spaceID`**: a drag-reorder may
never cross a Space boundary, or it would relocate a project between Spaces
without going through `assign`'s refusals. Reassignment is the separate
`assign(projectAt:to:)`, which refuses Home, Scratch, and clones — one rule
enforced in the model, mirrored by hiding `Move to Space ▸` for those rows in
the sidebar and by a CLI error — plus an unknown `spaceID`, so a stale id
can't strand a project.

`section(forProjectAt:)` (`SidebarView`) tests `spaceID` **before**
`isHibernated`: a hibernated member stays dimmed in its own Space rather than
dropping to Hibernating, which collects only *spaceless* hibernated
projects. Collapse state (`isCollapsed`) is persisted in the model — unlike
`hibernatedCollapsed`, which is view-local because nothing persists it — and
a collapsed Space still renders its active member, so selecting a project
never leaves an invisible selection.

The header view is `HeaderCellView` (there is no separate
`SectionHeaderView`). Its glyph is a plain color dot by default
(`"circle.fill"` tinted by the Space's color) or a custom SF Symbol *or*
emoji when the Space has one — the same `IconPickerControl` a project's icon
uses, so `HeaderCellView` renders whichever kind it gets, exactly like the
project row's own glyph branch. **Counts are not carried on `SidebarSpace`**
(identity/appearance only, kept `Equatable` for the same coalescing reason as
`SidebarProject`); they live in a `spaceCounts: [UUID: (awake:,
hibernated:)]` dictionary computed in `rebuildOutline` from the **filtered**
member list, so a Space's header respects the search filter like every other
section. Two sources of truth for the count was a real review finding —
don't reintroduce one by reading a count off `SidebarSpace` again.

Dropping a project row onto a Space header (or into a Space's row range) is
**the only cross-section drop Zetty allows**; `validateDrop` refuses every
other one so the pinned-first invariant can't be broken by a drag. Dragging a
Space header reorders the whole Space (`onMoveSpace`) — and, like the
project- and tab-move branches, the drop gap must subtract one when moving
down past the dragged row's own old slot. Omitting that compensation was a
Critical review finding: it landed a Space one slot too far on move-down, and
silently no-op'd on a drop at the very end, because `WorkspaceModel.moveSpace`
bounds-checks `to` against the pre-removal array.

`removeSpace(id:)` clears `spaceID` on every member and removes no project;
`regroup()` also clears any `spaceID` pointing at a Space no longer in
`spaces`, so a hand-edited or partially-restored `workspace.json` can't hide
a project behind a dead id. The CLI's `moveProjectNamed` (backing
`move-to-space`) guards duplicate project names the same way
`hibernateProjectNamed`/`wakeProjectNamed` do — project names are **not**
unique in the model, unlike Space names, which are unique case-insensitively
(the CLI's handle for `space(named:)`).

CLI: `new-space <name> [--color <id>] [--icon <symbol>]` ·
`rename-space <old> <new>` (also `<old> --to <new>` — needed once either name
has spaces and isn't quoted) · `remove-space <name>` ·
`move-to-space <project> (<space> | --none)` · `add-project --space <name>`
(errors on an unknown Space rather than creating one — anti-typo) ·
`hibernate --space <name>` / `wake --space <name>` (`hibernateSpaceNamed`/
`wakeSpaceNamed` mirror the sidebar's Hibernate All / Wake All by iterating the
existing per-project `hibernateProject`/`wakeProject` entry points — no new
session logic, so `reconcileSessions()` is untouched). Every
Space verb is a **fast verb**, plain model mutation through `handleOnMain` —
never the slow-verb path `clone`/`capture`/`quit` use. `StatusSnapshot` gains
`spaces: [Space]` (rendered even when empty, so a Space `new-space` just
created is visible before anything is filed into it) and `Project.space:
String?`, both hand-decoded with `decodeIfPresent` for the same reason
`hibernated`/`live` are — an older standalone `zetty` binary must not throw on
a newer app's payload.
