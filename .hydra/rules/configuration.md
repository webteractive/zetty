---
paths:
    - "Sources/ZettyCore/Config/**"
    - "App/Sources/App/SettingsWindowController.swift"
commands:
    - "zetty reload"
triggers:
    - "adding, retiring or changing a config key"
    - "changing how the config file is parsed, applied or reloaded"
    - "custom ghostty directives or the per-surface command are silently dropped"
---

# Configuration (~/.config/zetty/config)

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

Zetty reads `~/.config/zetty/config` (or `$XDG_CONFIG_HOME/zetty/config`),
seeded with a documented default on first launch. Parsing is pure + unit-tested
in `ZettyCore` (`AppConfig` / `ConfigStore`); `AppDelegate` resolves + applies it.

- **`appearance = system | dark | light`** — `system` (default) follows macOS
  live (KVO on `NSApp.effectiveAppearance`); `dark`/`light` pin one axis.
- **`theme-dark` / `theme-light`** — the `ZColorScheme` for each axis (case-insensitive).
- **Every other `key = value` is a ghostty directive**, forwarded verbatim to
  libghostty via `TerminalConfiguration.withCustom` — so a user can paste an
  existing ghostty config straight in (no prefix; we do NOT read the external
  `~/.config/ghostty/config`). Ghostty defines none of the reserved keys, so no
  collision. Comments are **full-line only** (`#` at line start) so `#`-prefixed
  color values survive.
- **Ghostty validates all-or-nothing** — `TerminalController.prepareConfig`
  frees the WHOLE config if any key yields a diagnostic, so a single stray
  directive silently drops every custom setting *including the per-surface
  `command`*, which strands preserved sessions (panes launch plain shells).
  Two guards, both regression-tested: `AppConfig.isReservedButUnsupported`
  swallows Zetty's own keys this build lacks (the `zetty-` namespace — which
  **all new keys must use** — plus the grandfathered `notify-` one and
  `retiredReservedKeys`; add a retired key there, don't just delete its
  `case`, since deleting it makes old configs *forward* the key rather than
  ignore it. They're recorded in `unsupportedKeys` and dropped by `rendered()`),
  and `SurfaceRegistry.pair(for:)` retries with a Zetty-only config when
  `setTerminalConfiguration` returns false, reporting via
  `onConfigurationRejected` → one-time alert. Real cause of a
  4-relaunch session-loss incident (`notify-poke` from a feature branch).
- **Precedence:** scheme theme → pasted ghostty directives (last wins). Pasted
  directives may override terminal colors; the app chrome stays scheme-driven.
- **Reload:** ⇧⌘, (also App menu + command palette) re-reads config and
  re-applies theme + terminal overrides to every live pane. Runtime scheme /
  appearance switches persist back to the file (`AppConfig.rendered()`).
- **Every config key has a control in Settings (⌘,)** — a new key ships with
  one in `SettingsWindowController`, or with the reason it has none written in
  that file's doc comment (today only `free-background-panes-after`, whose
  feature is disabled). Settings writes through `updateConfig`, which calls
  `onConfigSaved` so `AppDelegate` reloads at once: its in-memory `appConfig`
  is otherwise stale until the 1s file poll, and an `AppDelegate` save in that
  window would overwrite the Settings write.
- **`preserve-sessions = true|false`** (default false) — panes run inside
  [zmx](https://zmx.sh) sessions so they survive quit/relaunch. The reattach,
  scrollback-restore, scratch-pane deadlock, title persistence and restart-
  recovery rules are in `.hydra/rules/session-preservation.md` — read it before
  touching anything session-related.
