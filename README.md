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

- **Projects → tabs → splits** — pin a directory as a project; every project
  owns its own tabs, each tab an arbitrarily nested tree of split panes.
- **Full Ghostty terminal** — GPU rendering, ligatures/text shaping, and the
  Kitty keyboard + graphics protocols come from full libghostty. Zetty builds
  the multiplexer shell, not the terminal.
- **tmux-style prefix keys** — `Ctrl+B` then a key drives splits, pane focus,
  tabs, zoom, and paste; fully remappable, no mouse required.
- **Vi-keyed copy mode** — `Ctrl+B [` enters a modal copy mode with vi
  motions, visual selection, and yank-to-clipboard, rendered as a native
  Ghostty selection.
- **Session persistence** — with `preserve-sessions` enabled, panes run inside
  [zmx](https://zmx.sh) sessions that survive app quit/relaunch.
- **AI agent status** — hook-driven status dots per tab and per project:
  green = running, yellow = needs attention, dim = idle — with optional
  sound / Dock badge / Notification Center alerts when an agent needs you.
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
   and download the latest `Zetty-<version>.dmg`. While this repository is
   private, the page requires a GitHub account with access to it — download
   in a logged-in browser (API/`curl` downloads would need an auth token).
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

1. Launch Zetty. The sidebar lists your **projects** — pin any directory to
   add one; each project keeps its own tabs and layout.
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
| `⌥⌘←` `⌥⌘→` `⌥⌘↑` `⌥⌘↓` | Resize the focused pane |
| `⌘W` / `⇧⌘W` | Close pane / close tab |
| `⌘}` / `⌘{` | Next / previous tab |
| `⌘1`–`⌘9` | Jump to tab |
| `⌘K` | Command palette |
| `⌘B` | Toggle sidebar |
| `⌘O` | Add project |
| `⌘,` | Settings |
| `⇧⌘,` | Reload configuration |
| `⇧⌘T` / `⇧⌘A` | Cycle color scheme / appearance |
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
`q`/`Esc` to exit. The status bar shows `PREFIX` / `COPY` / `ZOOM` chips so
you always know what mode you're in.

Remap anything in the config file:

```
prefix = ctrl+b
bind = s split-vertical
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
| `confirm-quit` | `true` | Ask before quitting |
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

- **Quit survives** — relaunching reattaches every pane with its scrollback
  and running programs intact (TUIs get a resize nudge so they repaint).
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

### Control CLI

The `zetty` command drives the running app over `~/.zetty/zetty.sock` —
machine-readable output, errors on stderr, exit codes 0/1/2. Pane targets
resolve by unique id prefix, unique `--cwd`, or default to the focused pane.

```sh
zetty status --json                      # projects → tabs → panes, agent status
zetty send --cwd ~/work/api 'ls' --enter # type into a pane
zetty send --key C-c                     # send a control key
zetty capture --lines 100                # recent pane output (preserved sessions)
zetty new-tab --project api              # prints the new pane id
zetty split --pane 1a2b3c4d --horizontal
zetty focus --cwd ~/work/api
zetty close --pane 1a2b3c4d --tab
zetty reload                             # same as ⇧⌘,
zetty quit --kill-sessions               # full shutdown, ends preserved sessions
```

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

Pre-release (`0.1.0`), under active development and daily use. Interfaces and
config keys may still change. Pre-built (unsigned) apps ship via
[GitHub Releases](https://github.com/webteractive/zetty/releases); Developer
ID signing and notarization are planned.

## Contributing

Zetty is **closed to code contributions** — pull requests are not accepted
and will be closed. Bug reports and feature requests are very welcome via
[GitHub Issues](https://github.com/webteractive/zetty/issues).

## License

Zetty is **source-available, not open source** — see [`LICENSE`](LICENSE).
In short: free to use for any purpose (personal or commercial) and free to
build from source for your own use; the source is published for
transparency, but modification, derivative works, and redistribution are
not permitted. Third-party components (libghostty, icon sets) remain under
their own licenses.

This licensing is expected to be temporary — Zetty will likely be
re-licensed as open source once it matures.

## Acknowledgments

- [Ghostty](https://ghostty.org) / [libghostty-spm](https://github.com/Lakr233/libghostty-spm) — the terminal core
- [zmx](https://zmx.sh) — session persistence
- [simple-icons](https://simpleicons.org) (CC0) and
  [lobe-icons](https://github.com/lobehub/lobe-icons) (MIT) — tool logos
