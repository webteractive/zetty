# Home panel — design

**Date:** 2026-07-09
**Status:** Approved (design)

## Problem

There's no guaranteed, always-present terminal home base. Today first launch
seeds an ordinary `Homedir` project rooted at `~`, and `remove-project` refuses
to remove the *last* project — an accidental "there's always something" rule.
Scratch terminals are ephemeral (no settings, not persisted). Users want a
permanent, settings-capable home base that can't be removed but can be
hibernated/woken, in its own sidebar section.

## Goal

A first-class **Home** construct: seeded by default (never added), non-removable,
hibernatable/wakeable, in its own sidebar section, with full project settings.
Home is a *new* construct modeled on today's default `Homedir` project — not a
rename of it.

## Behavior

**Model**
- New `ProjectRuntime.isHome` flag (sibling to `isScratch`). Home is a
  `ProjectRuntime` rooted at `~`, persisted, with tabs/panes like any project.
  Exactly one Home always exists.
- `WorkspaceModel.init()` seeds **Home** (`isHome: true`) instead of today's
  ordinary `Homedir` project. On restore, if the decoded workspace has no
  `isHome` project, inject a fresh Home at the top.
- **Existing users:** their current `Homedir` remains an ordinary (now-removable)
  project; a fresh Home appears above it. No auto-migration.
- Drop the "can't remove the last project" guard. Home is the guaranteed floor,
  so all real/scratch projects become freely removable. `removeProject` instead
  refuses when the target `isHome`.
- Scratch unchanged (ephemeral, its own section). Home is persistent.

**Sidebar**
- New `SidebarSection.home`, ordered first: **Home · Pinned · Projects ·
  Scratch**. Single fixed row — can't be pinned, reordered out of its section, or
  removed. Row context menu: Project Settings… / Hibernate / Wake (when dormant)
  — no "Remove".

**Hibernation**
- Home hibernates/wakes exactly like a project. Relax the `count > 1` guard so
  the *last awake* project can hibernate; when nothing is awake the main area
  shows the existing dormant placeholder (name + Wake button). The
  "switch-away-from-active-first" step picks any other awake project; if none,
  the active project simply becomes the dormant placeholder (no switch).
- Auto-hibernate (idle timeout) applies to Home, subject to its per-project
  opt-out setting.

**Project settings**
- Full `ProjectSettings` set (name, curated color, icon, appearance/theme
  overrides, env, preserve-sessions, notifications).
- Keyed by a reserved **`isHome` sentinel** (e.g. `"@home"`), NOT its `~`
  rootPath — so it never collides with a user-added `~` project.
- Renamable via settings (default display name "Home"); renaming doesn't change
  that it is Home.

**CLI / agents**
- Targetable by name: `zetty new-tab --project Home`, `zetty hibernate Home` /
  `wake Home`.
- `zetty remove-project Home` is rejected with a clear message.
- `add-project ~` still creates a separate ordinary project.

**Persistence**
- `isHome` serialized in `workspace.json`; preserve-sessions + startup reap
  behave as for any owned surface.

## Testing

- Pure `ZettyCore`: Home seeded on `init()`; restore injects Home when absent;
  `removeProject` rejects `isHome` and now allows removing the last non-home
  project; hibernate allowed on the last awake project; section classification →
  `.home`; settings resolve via the sentinel key.
- App-layer/manual (GUI, TCC-blocked for the agent → user verifies): sidebar
  Home-section placement, dormant placeholder when everything is hibernated,
  settings sheet opens on Home, CLI targeting works, `remove-project Home`
  rejected.

## Non-goals

- No auto-migration of existing `Homedir` projects.
- No change to Scratch semantics.
- Multiple Home panels (exactly one).
