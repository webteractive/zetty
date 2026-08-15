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

- **Home** — a permanent terminal that's always there as a single row at the top
  of the sidebar (its own house icon, no pin, and — though it supports tabs —
  they aren't listed in the sidebar). Seeded on first launch (rooted at your home
  directory), it can't be removed but *can* be hibernated/woken like any project,
  and carries its own project settings (color, icon, theme, env,
  preserve-sessions, notifications).
- **Projects → tabs → splits** — add a project from one picker (**New Folder**
  to create one, optionally `git init`, or pick an existing directory); every
  project owns its own tabs, each tab an arbitrarily nested tree of split
  panes. Break any pane out into its own tab. **Drag project rows** to reorder
  them within their section (Pinned / Projects). Tabs spread across the bar,
  shrink as more open, and once they hit their minimum width the strip scrolls
  instead — so a project with many tabs never forces the window wider than you
  want it, and the active tab is always scrolled into view.
- **Pane gutter buttons** — every pane carries a thin top strip with a focus
  dot and click targets for **scroll to bottom**, **split vertically**, and
  **split horizontally**; panes in a multi-pane tab additionally get **break
  into tab** and **close**. Right-clicking the strip opens the same actions as
  a menu.
- **Project clones** — right-click a project → **Clone Project…** (or the
  command palette / `zetty clone`) to fork it into an instant APFS
  copy-on-write copy under `~/.zetty/clones/<project>-<name>` — every
  untracked file, `.env`, and `node_modules` included — checked out on its
  own git branch (named `<name>`); it nests under its source in the sidebar
  behind a fork glyph, and a caution strip below the tab bar reminds you the
  copy is disposable (commit + push, or merge back — uncommitted changes are
  lost on removal). The copy runs in the background (the app never freezes); a
  "Cloning…" spinner row appears under the source while it works and is
  replaced by the real clone row when it lands. When the project has agents set
  (Project Settings →
  Agents), the clone sheet offers **Open with** — pick an agent (the default)
  and it launches in the clone's first pane, or choose Standard session.
  **Remove Clone…** offers **Fetch & Delete** (lands the
  branch back in the original repo first — merge it with your normal tools)
  or a plain delete, warning before discarding uncommitted or unfetched work.
  Clones inherit the source project's settings (env, theme, agents) and have
  no Project Settings of their own. No clones of clones; Home, Scratch, and
  projects rooted at your home directory can't be cloned; non-APFS volumes
  fall back to a full copy.
- **Scratch terminals** — spin up a throwaway, project-less terminal rooted at
  home (`⌃⌘N`, the command palette, or `zetty scratch`). They live in their own
  **Scratch** sidebar section, are never saved to the workspace, and every tab
  is closable — closing the last returns you to your first pinned project.
  Clear them all at once with **Close All Scratch Terminals** (`zetty
  scratch-clear`).
- **Hibernating projects** — right-click a project → **Hibernate Project** (or
  `zetty hibernate`) to free its sessions/processes while keeping its layout.
  Hibernated projects collect at the bottom of the sidebar in a **Hibernating**
  section that is **collapsible** (click the header to tuck the dormant rows
  away) and **sorted by name**. Dormancy never blocks the CLI: `zetty status`
  reports it (`hibernated` per project, `live` per pane) and `send`/`new-tab`/
  `split`/`break`/`focus` wake a project on demand, so scripts and agents don't
  have to call `zetty wake` themselves.
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
- **Peek a file without leaving the terminal** — ⌘-click a file path in any
  pane's output (a compiler error, a `grep` hit, a stack frame) and Zetty does
  the obvious thing with it. **Text** opens in a transient **read-only** overlay,
  syntax-highlighted and scrolled to the referenced line; ⌘-hover underlines a
  path that resolves to a real file, and Esc, the ✕, or a click outside closes
  it. **Anything else** — a PDF, an image — skips the overlay and opens in its
  default app, so a ⌘-click is useful whatever you point it at. Editing is
  delegated: the overlay's **Open in ▾** button hands the file, *at the right
  line*, to Zed, VS Code, Cursor, Windsurf, TextMate, or any editor Zetty finds.
  Highlighting comes from [`bat`](https://github.com/sharkdp/bat) when it's
  installed and falls back to plain text when it isn't; it follows your active
  scheme's light/dark axis, and any colour the highlighter emits that would be
  unreadable against the current background is replaced with the scheme's own
  foreground. A peek is never blank: when there is genuinely nothing to draw —
  an empty file, or one whose bytes couldn't be read — it says so in the panel
  instead of showing an empty one. Because paths come from
  untrusted output, files macOS would *install or execute* (installers, disk
  images, compiled binaries) are only revealed in Finder, never launched.
  ⌘-click detection reads the pane's preserved zmx session, so it needs
  `preserve-sessions = true`; `zetty view` works either way.
- **Per-pane file tree** — toggle a file tree on any pane with `⇧⌘F`, from its
  gutter button, its right-click menu, or `Ctrl+B` `e`. Hidden by default. It roots at
  the pane's current directory and follows `cd`, remembers which folders you had
  open so hopping around doesn't collapse it, and has a fuzzy filename filter
  (`tvc` finds `TerminalViewController.swift`). Click a file to peek it in the
  read-only viewer, double-click or ⌘Enter to open it in your editor; right-click
  for Reveal in Finder, Copy Path, and Copy Relative Path. It is **read-only** —
  no rename, delete, or move — and it shows the raw filesystem by default, so
  set `zetty-file-tree-respect-gitignore = true` on a project where
  `node_modules` would drown it.
- **`ssh://` links** — Zetty registers as a macOS handler for `ssh://` URLs, so
  a handover from another app (Terminal, a browser link, `open ssh://host`)
  opens the session in a new Home tab.
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

### Collecting a diagnostic log

The **file viewer** narrates every step of a peek — the file it read, the
highlighter it ran and what that returned, how many styled runs it rendered,
which colours it resolved them to, and the geometry the text landed in. If a
peek ever comes up blank, that's the difference between "the modal is empty"
and knowing which step emptied it.

**Copy diagnostics** in the peek's footer puts the recent lines, plus your build
and macOS version, on the clipboard — paste it straight into the issue. Nothing
is sent anywhere, and the file's own contents are never recorded, only counts.

The same lines also go to the macOS unified log, so they can be collected after
the fact on any build — no debug build, no need to be watching when it happens:

```sh
log show --last 15m --predicate 'subsystem == "co.webteractive.zetty"' --style compact
```

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
  -configuration Release -destination 'generic/platform=macOS' \
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
| `⇧⌘F` | Toggle the focused pane's file tree |
| `⌘↓` | Scroll the focused pane back to the live tail |
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

Closing the main window keeps Zetty and its terminals running behind a **Z**
in the macOS menu bar and hides its Dock icon until the window is restored. The
status menu lists every awake project, with nested tab choices for projects that
have multiple tabs. Agent status dots mirror the sidebar: green means running,
yellow needs attention, and dim gray is idle. **Quit Zetty** and **Shut Down
Zetty…** remain available from the regular Zetty application menu.

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
| `e` | Toggle the focused pane's file tree |
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
| `check-updates` | `true` | Notify when a newer Zetty release is available |
| `notify-sound` / `notify-badge` / `notify-system` | `true` | Agent needs-attention alerts |
| `editor` | — | App used by Settings → "Open in Editor" |
| `viewer-highlight-command` | `bat --style=plain --color=always --paging=never` | Command the file viewer pipes a file through for syntax highlighting; `off` disables it. Zetty sets `BAT_THEME` to match the active scheme's light/dark axis — pass your own `--theme` here to override |
| `viewer-max-bytes` | `2097152` | Largest file the viewer will render; bigger files open in their default app instead |
| `zetty-file-tree-show-hidden` | `true` | Show dotfiles in the per-pane file tree |
| `zetty-file-tree-respect-gitignore` | `false` | Hide anything the repo's `.gitignore` excludes |
| `zetty-file-tree-ignore` | — | Extra names to hide, comma-separated (e.g. `node_modules, vendor`) |
| `zetty-file-tree-width` | `220` | Width a file tree opens at, in points |
| `prefix` / `bind` / `copy-bind` | tmux-canonical | Prefix-key layer remapping |

The file tree shows the raw filesystem by default, dotfiles included. On a JS
project `node_modules` will dominate both the tree and its filter until you turn
on `zetty-file-tree-respect-gitignore` or list names in `zetty-file-tree-ignore`.
Dragging a tree's divider stores that pane's own width, which then wins over
`zetty-file-tree-width` for that pane.

New Zetty keys take a **`zetty-` prefix**, which is what keeps them out of the
Ghostty passthrough (see below). Older Zetty keys predate the convention and stay
unprefixed.

**Any other `key = value` is a Ghostty directive**, forwarded verbatim to
libghostty — paste your existing `~/.config/ghostty/config` straight in
(Zetty does not read Ghostty's own config file). Terminal colors from pasted
directives override the scheme; the app chrome stays scheme-driven. The
`font-family` / `font-size` directives drive the **terminal and status bar**
(also editable in Settings → Appearance); the rest of the chrome — tab bar,
sidebar, file tree, palette, dialogs — uses the system font at a fixed size, so
changing your terminal font never reflows the app around it.

Ghostty validates its config **all-or-nothing**: one directive it doesn't
recognize (a typo, or a Zetty key from a newer build) makes it discard *every*
custom setting. Zetty guards both ends — Zetty's own keys, including ones this
build predates, are never forwarded to Ghostty, and if a passthrough directive
is still rejected, panes fall back to Zetty's own directives so
`preserve-sessions` keeps working, with a one-time alert naming the problem.

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

### `ssh://` links

Zetty registers as a macOS handler for `ssh://` URLs. When another app opens
`ssh://[user@]host[:port]` — Terminal, a browser link, or `open ssh://host`
from a shell — Zetty comes to the front and opens a new **Home** tab running
`ssh host` (with `-p <port>` when the URL carries one). URLs are validated
strictly, so a crafted link can't inject shell commands; anything that isn't a
clean `ssh://` target is ignored.

To make Zetty the default `ssh://` handler, set it in the app that opens the
links (or via a URL-handler utility) — macOS picks the default, not Zetty.

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

The hook event log (`~/.zetty/agent-events.jsonl`) is trimmed to its most
recent entries at launch, so it can't grow without bound on a long-lived
workspace.

Agent CLIs animate a spinner in their terminal title, so tab names and status
dots update on a short coalescing interval (~0.1s) rather than on every escape
sequence — many panes running agents at once cost the same as one. Scrolling
the sidebar is unaffected by those updates: it only scrolls to reveal a project
when the active project or tab actually changes.

### Memory: background pane pruning temporarily disabled

Each live pane costs roughly **37 MB of GPU memory** (the terminal's render
target and glyph atlas), so a workspace with many awake projects pays for
surfaces nobody is looking at — about 300 MB at 5 live panes, 1.5 GB at 37.

`free-background-panes-after = <duration>` remains accepted and preserved in
the config, but currently has no runtime effect. Releasing a live preserved
surface can block inside libghostty's synchronous subprocess teardown and freeze
Zetty's main thread, so live terminal surfaces belonging to awake projects stay
attached until a safe non-blocking teardown path is available. Use
`hibernate-after` when you want idle projects' processes and surfaces stopped.

Zetty also continuously reconciles preserved sessions against the workspace, so
closing a pane always ends its session — even one whose tab you never opened —
and no orphaned `zmx` shells accumulate.

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

### Project clones

#### Bringing clone work back

A clone's `.git` is a full copy of the source, so it carries the source's
`main` and the same `origin`. Your clone's work lives on its own branch
`<name>` — **don't push the clone's `main`** (that just creates two divergent
`main`s). Right-click the clone → **Merge to Source…** for an adaptive
chooser. It always starts by updating the clone from the source (resolving
any conflicts *in the clone* — if it stops there, resolve + commit, then
re-run "Merge to Source…"), then offers:

- **Merge updates** — merges the clone's work into the source **locally**
  (fetches the clone into the source repo and merges there); no remote
  needed. Refuses if the source has uncommitted changes, and if the merge
  into the source conflicts it aborts cleanly, leaving the source untouched.
- **Push to branch** — pushes the clone's branch to `origin` so you can open
  a pull request against the source's default branch. Only offered when the
  clone has a remote.

If the clone's source isn't a git repository, "Merge to Source…" instead opens
a **diff modal** (built on `git diff --no-index`) listing the clone's
changed and new files, each with a per-file line-diff preview. Bring files
back individually with **Replace** (overwrite the source's file) or
**Keep Both** (save the clone's copy alongside it as `name 2.ext`) — nothing
is ever deleted, and overwriting the source is atomic (the original survives
a failed copy).

`zetty update-clone <name>` still runs just that first sync step — merging
the source's latest into the clone and leaving conflicts in place to
resolve — the same step "Merge to Source…" runs before either strategy; it
doesn't merge or push on its own.

The clone banner's **"How do I merge this back?"** button shows the update /
PR / no-origin-local-merge steps with your clone's real branch and paths
filled in (git clones only), with a pointer to **Merge to Source…** for the
one-click version.

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
zetty view README.md:20                  # peek text read-only at line 20 (else: default app)
zetty new-tab --project api              # background tab; prints the new pane id
zetty split --pane 1a2b3c4d --horizontal # background split; prints the new pane id
zetty split --pane 1a2b3c4d --focus      # ...or bring the new pane to front
zetty break --pane 1a2b3c4d              # move a pane into its own (background) tab
zetty add-project ~/work/api             # add an existing directory as a project
zetty new-project ~/work/new --git       # create a folder + add it (optional git init)
zetty clone --project api --name fork-1  # instant CoW clone, own branch zetty/fork-1
zetty update-clone fork-1                # merge the source's latest into the clone, leaving conflicts in place
zetty remove-project api                 # close a project's tabs (no confirmation)
zetty remove-project api/fork-1 --fetch  # clone: land its branch in the source repo, then delete
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
typing. Pass `--focus` to switch to the result.

**Dormant panes never dead-end a script.** A pane has no terminal behind it
until it is viewed (shells spawn lazily), and a hibernated project has none at
all — `zetty status` shows this as `live: false` on the pane plus `hibernated:
true` on the project, so a caller can tell the two apart. Either way you don't
have to act on it: `send` spawns the pane on demand, waking its project if
needed, and puts your view back where it was, so the pane ids `new-tab`, `split`
and `break` print are always usable. A pane that had to be spawned needs a
moment before its shell reads input, so `send` queues the payload and returns 0
— success means "delivered or queued", not "already executed". `focus` also
wakes, and stays switched, since switching is the point. `capture` is the one
exception: hibernating frees a project's zmx sessions, so there is no output
left to read and it errors instead of waking a shell for nothing.

`view` takes no pane target — the peek belongs to the window and appears over
whichever project is active. Relative paths resolve against the **cwd of the
shell you ran it in** (as `add-project` does), so running it inside a pane
naturally resolves against that pane's directory. It needs no preserved session,
which makes it the reliable way for an agent to put a file in front of you.

Run `zetty --help` for the full grammar. This makes Zetty scriptable by
anything — including the AI agents running inside it.

## Development

```sh
tuist generate --no-open   # regenerate after adding/removing files
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'generic/platform=macOS' build
tuist test                 # unit tests (ZettyCore + ZettyGhostty)
swift test                 # faster: the pure ZettyCore suite only

scripts/package.sh                             # build dist/Zetty-<version>.dmg + .sha256
scripts/release.sh --notes notes.md patch      # cut a release (add --dry-run first)
```

Releases go through `scripts/release.sh` — it bumps the version, packages, tags,
and uploads both the DMG and the `.sha256` sidecar the in-app updater verifies
against. Don't assemble a release by hand or with a generic release tool; see the
**Releasing** section of [`AGENTS.md`](AGENTS.md) for why.

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
