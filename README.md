# Zetty

A native macOS GUI **terminal multiplexer** for developers, built on
[libghostty](https://github.com/ghostty-org/ghostty) (Ghostty's embeddable
terminal core) with a Swift AppKit application layer.

Zetty organizes work around **pinnable projects**, each holding terminal
**tabs and nested split panes** — and it natively understands **AI coding
agents** (Claude Code, Codex, Gemini, opencode, Hermes, …) running inside
those panes, surfacing their status in the sidebar and identifying each tab
by the tool it's running.

**Platforms:** macOS 14+ (Apple Silicon & Intel). Linux later.

## Features

- **Home** — a permanent terminal that's always there in its own top sidebar
  section. It's seeded on first launch (rooted at your home directory), can't be
  removed, but *can* be hibernated/woken like any project, and carries its own
  project settings (color, icon, theme, env, preserve-sessions, notifications).
- **Projects → tabs → splits** — add a project from one picker (**New Folder**
  to create one, optionally `git init`, or pick an existing directory); every
  project owns its own tabs, each tab an arbitrarily nested tree of split
  panes. Break any pane out into its own tab. **Drag project rows** to reorder
  them within their section (Pinned / Projects).
- **Scratch terminals** — spin up a throwaway, project-less terminal rooted at
  home (`⌃⌘N`, the command palette, or `zetty scratch`). They live in their own
  **Scratch** sidebar section, are never saved to the workspace, and every tab
  is closable — closing the last returns you to your first pinned project.
  Clear them all at once with **Close All Scratch Terminals** (`zetty
  scratch-clear`).
- **Live status bar** — the bottom strip tracks the **focused pane**: its
  working directory (updates as you `cd`), git branch/ahead-behind/changes,
  and the shell, alongside the color scheme and libghostty version.
- **Full Ghostty terminal** — GPU rendering, ligatures/text shaping, and the
  Kitty keyboard + graphics protocols come from full libghostty. Zetty builds
  the multiplexer shell, not the terminal.
- **tmux-style prefix keys** — `Ctrl+B` then a key drives splits, pane focus,
  tabs, zoom, and paste; fully remappable, no mouse required.
- **Vi-keyed copy mode** — `Ctrl+B [` enters a modal copy mode with vi
  motions, visual selection, and yank-to-clipboard, rendered as a native
  Ghostty selection.
- **Broadcast input** — type once, send the same keystrokes to a set of panes:
  the current **tab**'s splits, the whole **project** (every tab), the whole
  **workspace**, or **only the panes running an AI agent** — steer a whole
  swarm with one prompt. A yellow `BROADCAST` chip keeps the mode obvious.
- **Session persistence** — with `preserve-sessions` enabled, panes run inside
  [zmx](https://zmx.sh) sessions that survive app quit/relaunch, and
  reattached panes replay their full scrollback history (colors intact) so
  scrolling up works as if the app never quit.
- **Per-project settings** — right-click a project → **Rename…** or **Project
  Settings…**: custom name, identity color, and an SF Symbol or emoji icon
  for the sidebar; a
  per-project **theme** (the whole app re-themes when you switch projects);
  per-project overrides (Follow global / On / Off) of session preservation
  and agent notifications; and per-project **environment variables**
  (private, never written into the repo).
- **Layout templates** — save a project's tab/split arrangement (each pane's
  cwd + optional startup command) into a git-committable
  `.zetty/project.json`; it re-applies automatically when the project is
  added, or on demand from Project Settings. A hand-editable global default
  lives in Application Support.
- **AI agent status** — hook-driven status dots per tab and per project:
  green = running, yellow = needs attention, dim = idle — with optional
  sound / Dock badge / Notification Center alerts when an agent needs you.
- **Launch agents per project** — enable coding agents (Claude Code, Codex,
  Hermes, Gemini, opencode, Pi, Cursor) in a project's **Agents** settings;
  opening a new tab/split then offers a keyboard-driven chooser to launch one
  or a plain shell.
- **Update notifications** — Zetty checks GitHub for newer releases and shows
  an "Update available" pill in the status bar (plus **Check for Updates…**);
  opt out with `check-updates = false`.
- **Tab identity** — a foreground-process probe names each tab after what it's
  actually running, with bundled logos for 40+ CLI tools.
- **Control CLI** — a `zetty` command scripts the app over a local socket:
  inspect layout, send keys, capture output, open tabs/splits, focus panes.
- **Themes** — 20 built-in color schemes (10 dark, 10 light), independent
  dark/light selection, live macOS appearance following, and verbatim
  passthrough of your existing Ghostty config.

## Installation

### Download (recommended)

1. Open the [Releases](https://github.com/webteractive/zetty/releases) page
   and download the latest `Zetty-<version>.dmg`.
2. Open the DMG and drag **Zetty** into **Applications**.
3. Clear the Gatekeeper quarantine flag (see below), then launch Zetty from
   Applications or Spotlight:

   ```sh
   xattr -d com.apple.quarantine /Applications/zetty.app
   ```

> **Why step 3?** Builds are not yet signed or notarized by Apple, so macOS
> quarantines the downloaded app and shows *"Zetty is damaged and can't be
> opened. You should move it to the Trash."* It isn't damaged — that's
> Gatekeeper's message for any unsigned download. The command above clears
> the flag for good on that copy; you won't see the dialog again until you
> install an **update**, where the freshly downloaded DMG repeats step 3.
>
> Don't bother hunting for "Open Anyway" in System Settings → Privacy &
> Security — macOS often doesn't offer it for unsigned apps; the command is
> the reliable path. Developer ID signing + notarization is planned, which
> removes this step entirely.

### "Zetty would like to access files in…" prompts

macOS shows a folder-access (TCC) prompt the first time a process **you run
inside a pane** touches a protected folder — Desktop, Documents, Downloads,
iCloud Drive, or removable/network volumes. The access is attributed to Zetty
because Zetty spawned that process. This is normal — every terminal emulator
(Terminal, iTerm2, Ghostty, WezTerm) behaves the same way. It is **not** a bug,
and Zetty stores nothing about your folders.

**Make it stop for good — grant Full Disk Access (one time):**

1. **System Settings → Privacy & Security → Full Disk Access**
2. Click **`+`**, add **`/Applications/zetty.app`**, and turn it on
   (shortcut: `open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"`)
3. **Quit and relaunch Zetty.**

After that, the per-folder prompts stop.

> **Why does it keep coming back?** Two reasons:
>
> - **It re-triggers on re-access.** Any tool that re-scans its working
>   directory pops the prompt again until access is granted app-wide — for
>   example, clearing and restarting an AI agent session (Claude Code's
>   `/clear`, etc.) makes it re-read the project directory, so the prompt
>   reappears. Full Disk Access covers all of these at once.
> - **Unsigned builds change identity.** macOS ties the grant to the app's
>   code signature, and current builds are ad-hoc signed (the signature
>   changes every build), so an **update** can reset the grant and re-prompt.
>   Developer ID signing + notarization (planned) gives Zetty a stable
>   identity so the grant sticks across updates.
>
> You do **not** need to "trust" each project — that's an App Sandbox concept,
> and Zetty is not sandboxed. Granting folder access once is all it takes.

### Build from source

#### Prerequisites

- macOS 14.0 or later
- Xcode 16+ (Swift 6 toolchain) with command-line tools
- [Tuist](https://tuist.dev) — `brew install tuist` (or via
  [mise](https://mise.jdx.dev): `mise use -g tuist`)
- Optional: [zmx](https://zmx.sh) for session persistence —
  `brew install neurosnap/tap/zmx` (Settings can also download it for you)

The libghostty terminal core is consumed as a prebuilt Swift package
([libghostty-spm](https://github.com/Lakr233/libghostty-spm)) — no Zig
toolchain or submodule build required.

#### Build and install

```sh
git clone https://github.com/webteractive/zetty.git
cd zetty

# Generate the Xcode project (Tuist; sources are listed explicitly)
tuist generate --no-open        # or: mise exec -- tuist generate --no-open

# Build the app
xcodebuild -project zetty.xcodeproj -scheme zetty \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build build

# Install
ditto build/Build/Products/Release/zetty.app /Applications/zetty.app
open /Applications/zetty.app
```

### Install the `zetty` CLI

The app binary doubles as the control CLI. In Zetty, open **Settings (⌘,) →
Command Line** and click install — this symlinks `zetty` into
`~/.local/bin`. Make sure `~/.local/bin` is on your `PATH`.

## Usage

### Getting started

1. Launch Zetty. The sidebar lists your **projects**. Click the **+** to open
   the **Add Project** picker — use **New Folder** to create one (with an
   optional *Initialize git repository*) or pick an existing directory. Each
   project keeps its own tabs and layout. Drag project rows to reorder them.
   Need a quick throwaway shell? `⌃⌘N` opens a **scratch terminal** (see below).
2. Open tabs and split panes with the prefix keys below (or the menus).
   Layout, tab titles, and sidebar state persist across relaunches
   (`~/Library/Application Support/zetty/workspace.json`).
3. Focus is shown by the accent status dot on the active pane — panes are
   intentionally borderless.

### Keyboard shortcuts (native)

| Shortcut | Action |
|---|---|
| `⌘T` | New tab |
| `⌘D` / `⇧⌘D` | Split vertically / horizontally |
| `⌥⌘T` | Break focused pane into its own tab |
| `⌥⌘←` `⌥⌘→` `⌥⌘↑` `⌥⌘↓` | Resize the focused pane |
| `⌘W` / `⇧⌘W` | Close pane / close tab |
| `⌘}` / `⌘{` | Next / previous tab |
| `⌘1`–`⌘9` | Jump to tab |
| `⌘K` | Command palette |
| `⌘B` | Toggle sidebar |
| `⌘O` (or `⇧⌘N`) | Add project (create or pick a folder) |
| `⌃⌘N` | New scratch terminal |
| `⌘,` | Settings |
| `⌥⌘,` | Project Settings (active project) |
| `⇧⌘,` | Reload configuration |
| `⇧⌘T` / `⇧⌘A` | Cycle color scheme / appearance |
| `⇧⌘B` | Cycle broadcast scope (Off → Tab → Project → Agents → Workspace) |
| `⌘C` / `⌘V` | Copy / paste (Ghostty defaults inside the terminal) |

Everything above is also reachable from the menu bar and the command
palette (`⌘K`).

### Keybindings (prefix layer)

Press `Ctrl+B` (the prefix, configurable), then:

| Key | Action |
|---|---|
| `%` | Split vertically |
| `"` | Split horizontally |
| `h` `j` `k` `l` / arrows | Focus pane in that direction |
| `o` | Cycle pane focus |
| `x` | Close pane |
| `z` | Zoom / unzoom pane |
| `!` | Break focused pane into a new tab |
| `c` | New tab |
| `n` / `p` | Next / previous tab |
| `1`–`9` | Jump to tab |
| `,` | Rename tab (inline) |
| `[` | Enter copy mode |
| `]` | Paste |
| `Ctrl+B` (again) | Send a literal `Ctrl+B` to the terminal |
| `Esc` | Cancel the prefix |

**Copy mode** is vi-keyed: `h/j/k/l` `w/b/e` `0/$` `g/G` to move,
`Ctrl+U/D/F/B` to page, `v`/`V` to select, `y` or `Enter` to yank,
`q`/`Esc` to exit. The status bar shows `PREFIX` / `COPY` / `ZOOM` /
`BROADCAST` chips so you always know what mode you're in.

**Broadcast input is per-project and Off by default.** Each project remembers
its own scope; pick it in **Project Settings → Broadcast Input**, from **View →
Broadcast Input** (Off / Tab / Project / Agents / Workspace), the command
palette, or **⇧⌘B** to cycle scopes (Off → Tab → Project → Agents → Workspace →
Off). You can also bind it on the prefix layer: `broadcast-cycle`, plus
`broadcast-toggle` / `broadcast-agents-toggle` to flip the Tab / Agents scopes
directly. Whichever you use edits the active project's scope.

Remap anything in the config file:

```
prefix = ctrl+b
bind = s split-vertical
bind = ctrl+a broadcast-cycle
copy-bind = n copy-cursor-down
```

### Configuration

Zetty reads `~/.config/zetty/config` (or `$XDG_CONFIG_HOME/zetty/config`) and
seeds a documented starter file on first launch. Format is plain
`key = value` lines; comments are full-line only (`#` at line start).

| Key | Default | Meaning |
|---|---|---|
| `appearance` | `system` | `system` follows macOS live; `dark`/`light` pin one axis |
| `theme-dark` / `theme-light` | `Twilight` / `Daylight` | Scheme per appearance axis |
| `sidebar-position` | `left` | Window side for the project sidebar |
| `preserve-sessions` | `false` | Keep panes alive across quit/relaunch (requires zmx) |
| `restore-scrollback` | `true` | Replay preserved panes' scrollback history on relaunch (with `preserve-sessions`) |
| `confirm-quit` | `true` | Ask before quitting |
| `check-updates` | `true` | Notify when a newer Zetty release is available |
| `notify-sound` / `notify-badge` / `notify-system` | `true` | Agent needs-attention alerts |
| `editor` | — | App used by Settings → "Open in Editor" |
| `prefix` / `bind` / `copy-bind` | tmux-canonical | Prefix-key layer remapping |

**Any other `key = value` is a Ghostty directive**, forwarded verbatim to
libghostty — paste your existing `~/.config/ghostty/config` straight in
(Zetty does not read Ghostty's own config file). Terminal colors from pasted
directives override the scheme; the app chrome stays scheme-driven. Font is
uniform: the `font-family` / `font-size` directives drive both the terminal
and the app chrome, and are also editable in Settings → Appearance.

Built-in schemes — dark: Midnight, Nocturne, Frost, Twilight, Ember, Velvet,
Eclipse, Rosewood, Neon, Ukiyo · light: Daylight, Paper, Glacier, Dawn,
Latte, Porcelain, Harvest, Citrus, Daybreak, Sakura.

Reload config anytime with **⇧⌘,** (also in the App menu and command
palette) — theme and terminal overrides re-apply to every live pane, and
runtime scheme/appearance switches persist back to the file.

### Session persistence

To enable, either:

- open **Settings (⌘,) → Sessions** and turn on **Preserve sessions** — if
  zmx isn't installed, Zetty offers to download it for you; or
- set `preserve-sessions = true` in `~/.config/zetty/config` and reload with
  **⇧⌘,** (this path needs zmx already installed — e.g.
  `brew install neurosnap/tap/zmx` — otherwise panes fall back to plain
  shells with a one-time alert).

Once enabled, every pane runs inside its own zmx session:

- **Quit survives** — relaunching reattaches every pane with its running
  programs intact (TUIs get a resize nudge so they repaint), and replays the
  pane's full scrollback history, colors included, so scrolling up works as
  if the app never quit (`restore-scrollback = false` disables the replay).
- **Close kills** — explicitly closing a pane ends its session.
- Crash leftovers are reaped once at startup; Settings offers a manual
  kill-all too.

The Settings-offered download installs zmx into `~/.zetty/bin`; existing
Homebrew or manual installs are detected automatically.

### AI agent status

Open **Settings (⌘,) → Agent Status Hooks** and toggle the harnesses you use
(Claude Code, Codex, Hermes). Zetty installs a small hook helper
(`~/.zetty/hooks/zetty-hook.py`) into each harness's own config; on lifecycle
events the harness pings Zetty, which lights the sidebar dots:

- 🟢 **green** — agent is working
- 🟡 **yellow** — agent needs your attention (optional sound, Dock badge, and
  macOS notification that focuses the pane when clicked)
- **dim** — agent is idle

Restart the agent after installing a hook. Events correlate to panes by
working directory, so two panes in the same directory light up together.
Toggling off uninstalls the hook cleanly.

### Launching agents in a project

Status hooks (above) *detect* agents you start yourself. To have Zetty *launch*
them, open **Project Settings → Agents** and enable the ones you use — Claude
Code, Codex, Hermes, Gemini, opencode, Pi, or Cursor. Each row has an editable
launch command (defaults to the tool's CLI, e.g. `cursor-agent` for Cursor).

With at least one agent enabled, opening a **new tab or split** in that project
shows a chooser before the pane spawns:

- **↑/↓** to select, **⏎** to launch, **1–9** to jump straight to an agent,
  **Esc** to cancel.
- **Standard session** opens a plain shell instead.
- **Manage agents…** jumps to the Agents settings.

The master **"Ask which agent to launch…"** toggle silences the chooser without
unchecking your agents. This is per-project and stays on your machine (it is not
written into the repo). The CLI (`zetty new-tab` / `split`) never prompts.

### Updates

Zetty checks [GitHub Releases](https://github.com/webteractive/zetty/releases)
for a newer version on launch and periodically. When one exists, an **"↑ Update
&lt;version&gt;"** pill appears in the status bar. Click it (or use **App menu →
Check for Updates…**) and confirm **Install & Restart** — Zetty downloads the
release DMG, verifies its SHA-256, swaps itself in place, and relaunches (no
manual download or quarantine step needed for in-app updates). You can still
choose **View Release Notes** to open the page instead. Set `check-updates =
false` to disable the automatic checks (the menu item still works).

### Control CLI

The `zetty` command drives the running app over `~/.zetty/zetty.sock` —
machine-readable output, errors on stderr, exit codes 0/1/2. Pane targets
resolve by unique id prefix, unique `--cwd`, or default to the focused pane.

```sh
zetty status --json                      # projects → tabs → panes, agent status
zetty send --cwd ~/work/api 'ls' --enter # type into a pane
zetty send --key C-c                     # send a control key
zetty capture --lines 100                # recent pane output (preserved sessions)
zetty new-tab --project api              # background tab; prints the new pane id
zetty split --pane 1a2b3c4d --horizontal # background split; prints the new pane id
zetty split --pane 1a2b3c4d --focus      # ...or bring the new pane to front
zetty break --pane 1a2b3c4d              # move a pane into its own (background) tab
zetty add-project ~/work/api             # add an existing directory as a project
zetty new-project ~/work/new --git       # create a folder + add it (optional git init)
zetty remove-project api                 # close a project's tabs (no confirmation)
zetty hibernate api                      # free a project's sessions/processes (keeps layout)
zetty wake api                           # wake a hibernated project (fresh shells)
zetty scratch                            # background scratch terminal; prints its pane id
zetty scratch-clear                      # close and clear all scratch terminals
zetty focus --cwd ~/work/api
zetty close --pane 1a2b3c4d --tab
zetty reload                             # same as ⇧⌘,
zetty quit --kill-sessions               # full shutdown, ends preserved sessions
```

The **Home** project is targetable by name (`zetty new-tab --project Home`,
`zetty hibernate Home`), but `zetty remove-project Home` is rejected — Home
can't be removed.

`new-tab`, `split`, `break`, and `scratch` never change the active project or
keyboard focus by default — an agent can reshape your workspace while you keep
typing. Pass `--focus` to switch to the result. A background pane's shell spawns
when you first view it, so `zetty send` to a brand-new background pane fails
until it is viewed or created with `--focus`.

Run `zetty --help` for the full grammar. This makes Zetty scriptable by
anything — including the AI agents running inside it.

## Development

```sh
tuist generate --no-open   # regenerate after adding/removing files
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
tuist test                 # unit tests (ZettyCore + ZettyGhostty)
```

- `Sources/ZettyCore/**` — pure, unit-tested model layer (no AppKit):
  pane tree, workspace persistence, config parsing, keybinding engine,
  agent state machine, CLI protocol.
- `App/Sources/App/**` — the AppKit application.
- `App/Sources/ZettyGhostty/**` — the libghostty bridge.

See [`AGENTS.md`](AGENTS.md) for the full contributor guide (layout, design
rules, subsystem internals, gotchas) and [`DESIGN.md`](DESIGN.md) for the
visual spec. Product plans live in [`docs/plans/`](docs/plans/).

## Status

Pre-release (`0.1.x`), under active development and daily use. Interfaces and
config keys may still change. Pre-built (unsigned) apps ship via
[GitHub Releases](https://github.com/webteractive/zetty/releases); Developer
ID signing and notarization are planned.

## Contributing

Contributions are welcome — bug reports, feature requests, and pull
requests alike. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to get a
build running and what a good PR looks like, and
[`AGENTS.md`](AGENTS.md) for the full contributor guide.

## License

Zetty is open source under the [MIT License](LICENSE). Third-party
components (libghostty, icon sets, bundled fonts) remain under their own
licenses.

## Acknowledgments

- [Ghostty](https://ghostty.org) / [libghostty-spm](https://github.com/Lakr233/libghostty-spm) — the terminal core
- [zmx](https://zmx.sh) — session persistence
- [simple-icons](https://simpleicons.org) (CC0) and
  [lobe-icons](https://github.com/lobehub/lobe-icons) (MIT) — tool logos
