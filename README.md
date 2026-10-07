# Zetty

A native macOS terminal for developers who keep many projects — and the AI
coding agents working in them — open at once.

Zetty puts every project in one window: a sidebar of projects, each with its
own tabs and split panes, terminals that survive quitting the app, and a live
view of which agents are working, waiting on you, or failed. It is built on
[libghostty](https://github.com/ghostty-org/ghostty), so every pane is a full
Ghostty terminal, with a Swift AppKit app around it.

- **Projects, tabs and splits** — pin, reorder, group into Spaces, hibernate
  the ones you're not using, or fork one into a disposable copy-on-write clone.
- **Agent-aware** — status dots for Claude Code, Codex, Hermes and more; launch
  an agent when you open a pane; run several Claude or Codex logins side by
  side; restart an agent without losing its conversation.
- **Tile mode** — a grid of live terminals from any project, so you can answer
  three agents without switching tabs.
- **tmux-style keys** — a `Ctrl+B` prefix layer, vi copy mode, zoom and
  broadcast input, alongside native ⌘ shortcuts.
- **Sessions that survive** — with `preserve-sessions`, panes keep running
  across quits and come back with their scrollback, even after a restart.
- **Scriptable** — a `zetty` CLI to inspect, drive and reshape the workspace,
  usable by the agents running inside it.

**Platforms:** macOS 14+ (Apple Silicon & Intel). Linux later.

## Install

1. Download the latest `Zetty-<version>.dmg` from
   [Releases](https://github.com/webteractive/zetty/releases).
2. Open it and drag **Zetty** into **Applications**.
3. Launch Zetty.

**Install the `zetty` CLI:** **Settings (⌘,) → Command Line → Install** links
`zetty` into `~/.local/bin` — make sure that's on your `PATH`.

**Folder-access prompts.** macOS asks the first time a program running in a
pane touches Desktop, Documents, Downloads, iCloud Drive or an external volume —
every terminal does this. To stop the prompts for good, add
`/Applications/zetty.app` under **System Settings → Privacy & Security → Full
Disk Access**, then relaunch Zetty.

To build from source, see [`DEVELOPMENT.md`](DEVELOPMENT.md).

## Getting started

1. Click **+** in the sidebar (or `⌘O`) to add a project — pick an existing
   folder, or **New Folder** to create one (optionally `git init`).
2. Open tabs with `⌘T` and split with `⌘D` / `⇧⌘D`. The focused pane is the one
   with the accent dot.
3. Press `⌘K` for the command palette — every action is in it.

Your layout, tab titles and sidebar persist across relaunches. **Home** — the
row at the top of the sidebar — is a permanent terminal at your home folder
(or `zetty-home-path`); `⌃⌘N` opens a throwaway **scratch terminal**.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘T` | New tab |
| `⌘D` / `⇧⌘D` | Split vertically / horizontally |
| `⌥⌘T` | Break focused pane into its own tab |
| `⌥⌘←` `⌥⌘→` `⌥⌘↑` `⌥⌘↓` | Resize the focused pane |
| `⌘W` / `⇧⌘W` | Close pane / close tab |
| `⌘}` / `⌘{` | Next / previous tab (tile view, while the grid is up) |
| `⌘1`–`⌘9` | Jump to tab (tile view, while the grid is up) |
| `⌘J` | Toggle Sessions (docked drawer, or its own window) |
| `⇧⌘G` | Toggle tile mode |
| `⇧⌘J` | Toggle the tile manager (saved tile views) |
| `⌘K` | Command palette |
| `⌘B` | Toggle sidebar — pinned → hidden → drawer |
| `⇧⌘F` | Toggle the focused pane's file tree |
| `⌘↓` | Scroll the focused pane back to the live tail |
| `⌘O` (or `⇧⌘N`) | Add project |
| `⌃⌘N` | New scratch terminal |
| `⌘H` | Close Zetty to the menu bar |
| `⌘,` / `⌥⌘,` | Settings / Project Settings |
| `⇧⌘,` | Reload configuration |
| `⇧⌘T` / `⇧⌘A` | Cycle color scheme / appearance |
| `⇧⌘B` | Cycle broadcast scope (Off → Tab → Project → Agents → Workspace) |
| `⌘C` / `⌘V` | Copy / paste |

Closing the window keeps Zetty and its terminals running from the menu-bar icon,
which lists your projects and their agents' status.

### Prefix keys

Press `Ctrl+B`, then:

| Key | Action |
|---|---|
| `%` / `"` | Split vertically / horizontally |
| `h` `j` `k` `l` / arrows | Focus pane in that direction |
| `o` | Cycle pane focus |
| `x` | Close pane |
| `z` | Zoom / unzoom pane |
| `!` | Break pane into a new tab |
| `e` | Toggle the pane's file tree |
| `g` | Toggle tile mode |
| `c` | New tab |
| `n` / `p` | Next / previous tab |
| `1`–`9` | Jump to tab |
| `,` | Rename tab |
| `[` / `]` | Copy mode / paste |
| `Ctrl+B` | Send a literal `Ctrl+B` |
| `Esc` | Cancel |

**Copy mode** is vi-keyed: `h/j/k/l` `w/b/e` `0/$` `g/G` to move,
`Ctrl+U/D/F/B` to page, `v`/`V` to select, `y` or `Enter` to yank, `q`/`Esc` to
exit. The status bar shows `PREFIX`, `COPY`, `ZOOM` and `BROADCAST` while each is
active.

**Running tmux or screen in a pane?** While it's the pane's foreground program,
`Ctrl+B` goes to it (so `Ctrl+B d` detaches) and ⌘ shortcuts keep working. This
needs `preserve-sessions`; turn it off with `zetty-tmux-passthrough = false`.
Over `ssh`, press `Ctrl+B` twice.

Remap anything in the config file:

```
prefix = ctrl+b
bind = s split-vertical
bind = ctrl+a broadcast-cycle
copy-bind = n copy-cursor-down
```

## Using Zetty

### Projects

- **Organize** — drag project rows to reorder them; pin the ones you use most.
  Right-click → **Move to Space ▸** files a project into a named, colored,
  collapsible sidebar section (**New Space…** makes one).
- **Customize** — right-click → **Project Settings…** for a name, color, icon
  (SF Symbol or emoji), theme, environment variables, and per-project overrides
  for session preservation and notifications.
- **Hibernate** — right-click → **Hibernate Project** frees a project's
  processes and keeps its layout; it moves to the **Hibernating** section until
  you wake it. `hibernate-after = 60m` does this automatically for idle
  projects (never Home), measured from when a project was last on screen,
  typed into, or written to by one of its agents. An agent sitting idle at an
  empty prompt no longer keeps its project awake; a working agent, a command
  or subagent an agent left running, a draft in the prompt box or a running
  command still does, and so does a project you woke yourself until you type
  into it. With preserved sessions, each Claude or Codex pane
  leaves a short **handoff** as its project is put away, and waking starts a
  fresh agent from it instead of a bare shell; the old conversation stays on
  disk. Waking again within moments, before the handoff is written, resumes
  the old conversation instead. Hibernating or closing a Codex pane also tells
  it to stop any command it still has running, which would otherwise outlive
  it.
- **Layout templates** — save a project's tabs and splits (each pane's folder
  and an optional startup command) to a committable `.zetty/project.json`; it is
  applied when the project is added, or from Project Settings.

### Panes

Each pane has a thin top strip with its focus dot and buttons to **open its
folder** in an editor or Finder, **split**, **break into a tab** and **close**;
right-click the strip for the same actions plus **Scroll to Bottom**.

- **File tree** — `⇧⌘F`, `Ctrl+B e` or the strip's button. Follows the pane's
  folder, filters fuzzily, peeks a file on click and opens it in your editor on
  double-click. Read-only.
- **Peek a file** — ⌘-click a path in any pane's output (a compiler error, a
  `grep` hit) to open it read-only, highlighted and scrolled to the line; **Open
  in ▾** hands it to your editor at that line. Non-text files open in their
  default app. Needs `preserve-sessions`; `zetty view <path>` works regardless.
  Highlighting uses [`bat`](https://github.com/sharkdp/bat) when installed.
- **Broadcast** — `⇧⌘B` sends your typing to every pane in the tab, the
  project, the workspace, or only panes running an AI agent. Off by default, set
  per project.

### Tile mode

`⇧⌘G` (or `Ctrl+B g`, or `zetty tiles`) shows a grid of **live terminals** from
any awake project — type into the focused tile and it reaches that shell.

- **Fill it** — click an empty slot's **+ Attach** to pick any pane, drag a tab
  from the sidebar onto it, or start a **New session** there.
- **Shape it** — split a slot (`Ctrl+B %` / `"`, or its header button), drag the
  boundaries, drag a tile's header onto another to swap them.
- **Keep it** — each view is a tab in the tab bar and saves itself as a profile;
  reopen, rename or delete views from the tile manager (`⇧⌘J`).
- A tile's `×` only detaches the pane; its stop button ends the session.
  Double-click a header to leave the grid for that pane.

### Sessions

`⌘J` lists every session Zetty runs, grouped by project, with live CPU and
memory. From there: **Reveal Pane**, **Interrupt** (Ctrl-C), **Kill Session…**,
or hibernate a whole project with its moon button.

### Session persistence

Turn on **Settings (⌘,) → Sessions → Preserve sessions** (Zetty offers to
download [zmx](https://zmx.sh) if needed), or set `preserve-sessions = true`.
Every pane then runs in its own zmx session:

- **Quitting keeps them running** — relaunching reattaches every pane with its
  programs and full scrollback intact.
- **Closing a pane ends its session.**
- **Restarts are recovered** — on a macOS restart or shutdown Zetty snapshots
  each pane's screen and, on relaunch, replays it and resumes the Claude Code or
  Codex conversation it was running (`zetty-restart-recovery`). Turn on **Launch
  at login** in the same settings to make that automatic.

### AI agents

**Status dots.** Turn on the harnesses you use under **Settings → Agent Status
Hooks** (Claude Code, Codex, Hermes). Tabs, projects and tiles then show:
green — working · yellow — needs you (optional sound, Dock badge and
notification) · red — Claude's last turn failed · dim — idle.

**Launch agents.** Enable agents under **Project Settings → Agents** (Claude
Code, Codex, Hermes, Gemini, opencode, Pi, Cursor). A new tab or split then asks
which to start — arrow keys or `1`–`9`, `⏎` to launch, **Standard session** for
a plain shell.

**Restart an agent, keeping its conversation.** A pane running Claude or Codex
has a `⟳` button: Zetty quits the agent and resumes the same conversation in
place, scrollback kept. Needs `preserve-sessions`.

**Multiple accounts.** Run a work login in one tab and a personal one in the
next (Claude Code and Codex). **Settings → Accounts → Add Account…** creates
one, optionally sharing your skills, commands and `CLAUDE.md`. Choose an account
per project (Project Settings → Account), per pane (the agent chooser lists each
agent once per account), or from anywhere with `zetty run <account>` or the
generated `claude-<account>` command. A status-bar chip and colored dots show
which account a pane is on, and warn when one nears a rate limit.

**Claude Code integration.** Zetty loads a small Claude Code mod into every
Claude pane. It adds:

- `/zetty panes`, `/zetty fleet`, `/zetty peek <path>[:line]` and
  `/zetty split [command…]` commands;
- tools Claude can call to show you a file, list this project's panes, and open
  and read a pane of its own (`zetty-claude-tools = false` turns those off);
- per-account rate limits on the account chip, a red dot when a turn fails, and
  notifications that say what Claude is asking for.

Turn the mod off with **Settings → Agents → Load Zetty's mod** or
`zetty-claude-mod = false`.

**What Zetty changes in your agent setup.** The Claude mod is on by default;
status hooks and accounts change nothing until you set them up. Turning hooks
or the mod off removes what they added:

- **Status hooks** add entries to `~/.claude/settings.json`, the `notify` line
  of `~/.codex/config.toml` (your original `notify` is backed up and restored)
  and `~/.hermes/config.yaml`, each calling `~/.zetty/hooks/zetty-hook.py`. Agent
  accounts get the same entries in their own config folders. Events are logged
  to `~/.zetty/agent-events.jsonl`, trimmed at launch.
- **The Claude Code mod** is copied to `~/.zetty/mods/zetty-bridge` and reaches
  Claude through `CLAUDE_CODE_PLUGIN_DIRS`, alongside any folders you set there.
  If a `settings.json` sets that variable itself, Zetty adds its folder to the
  list there too.
- **Accounts** live in `~/.zetty/accounts/<name>`, and their `claude-<name>` /
  `codex-<name>` shortcuts in `~/.local/bin` — a file of your own at that name is
  never overwritten. Removing an account leaves its folder and login on disk.
- **Every pane** gets `ZETTY=1` and `ZETTY_SURFACE` in its environment, which is
  how hooks and the CLI know which pane they are in.

### Project clones

Right-click a project → **Clone Project…** (or `zetty clone`) for an instant
copy-on-write copy on its own git branch — untracked files, `.env` and
`node_modules` included — nested under its source in the sidebar. Clones are
disposable: when you're done, right-click → **Merge to Source…** to merge the
work into the source locally or push the branch for a pull request, then
**Remove Clone…**. (A source that isn't a git repo gets a per-file diff to copy
changes back instead.)

### Updates and links

Zetty checks GitHub for new releases; click the **↑ Update** pill to download,
verify and install one in place (`check-updates = false` to opt out). It also
handles `ssh://` links, opening each in a new Home tab.

## Troubleshooting

- **Zetty won't launch, with a "Library not loaded" error naming
  `ZettyGhostty.framework`** — the app bundle is incomplete. Reinstall from the
  [latest DMG](https://github.com/webteractive/zetty/releases); your workspace and
  settings are kept.
- **Reporting a bug** — include your macOS and Zetty versions (About Zetty). A
  blank or wrong file peek has a **Copy diagnostics** button in its footer, and
  everything else is in the system log:
  `/usr/bin/log show --last 15m --predicate 'subsystem == "co.webteractive.zetty"' --style compact`.
  `zetty status --json` helps with CLI and session issues.

## Configuration

Zetty reads `~/.config/zetty/config` (or `$XDG_CONFIG_HOME/zetty/config`), seeded
with a documented starter file on first launch. Lines are `key = value`;
comments are full-line `#`. Reload with **⇧⌘,**.

| Key | Default | Meaning |
|---|---|---|
| `appearance` | `system` | `system` follows macOS; `dark`/`light` pin one |
| `theme-dark` / `theme-light` | `Twilight` / `Daylight` | Scheme per appearance |
| `sidebar-position` | `left` | Side of the window for the sidebar |
| `preserve-sessions` | `false` | Keep panes alive across quit/relaunch (needs zmx) |
| `restore-scrollback` | `true` | Replay preserved panes' scrollback on relaunch |
| `zetty-restart-recovery` | `true` | Recover panes and agent conversations after a macOS restart |
| `hibernate-after` | `off` | Hibernate a project after it has been idle this long (e.g. `60m`, `2h`) |
| `zetty-hibernate-handoffs` | `true` | Hibernating has each Claude or Codex pane leave a handoff, and waking starts a fresh agent from it (needs `preserve-sessions`) |
| `check-updates` | `true` | Notify when a newer release is available |
| `notify-sound` / `notify-badge` / `notify-system` | `true` | Agent needs-attention alerts |
| `zetty-claude-mod` | `true` | Load Zetty's Claude Code mod into new Claude panes |
| `zetty-claude-tools` | `true` | Let that mod give Claude its pane and file tools |
| `editor` | — | App for "Open in Editor" |
| `viewer-highlight-command` | `bat --style=plain --color=always --paging=never` | Highlighter for the file viewer; `off` disables it |
| `viewer-max-bytes` | `2097152` | Largest file the viewer renders |
| `zetty-home-path` | — | Folder the **Home** project opens in (`~` allowed) |
| `zetty-tiles-grid` | `4x4` | Starting shape of a new tile view, up to `8x8` |
| `zetty-tile-manager-view` | `drawer` | Show the tile manager docked (`drawer`) or as a `window` |
| `zetty-file-tree-show-hidden` | `true` | Show dotfiles in the file tree |
| `zetty-file-tree-respect-gitignore` | `false` | Hide what `.gitignore` excludes |
| `zetty-file-tree-ignore` | — | Extra names to hide, comma-separated (e.g. `node_modules, vendor`) |
| `zetty-file-tree-width` | `220` | Width a file tree opens at |
| `prefix` / `bind` / `copy-bind` | tmux defaults | Prefix-layer remapping |
| `zetty-tmux-passthrough` | `true` | Hand `Ctrl+B` to tmux/screen running in the focused pane |

**Any other line is a Ghostty directive**, passed straight to libghostty — paste
your existing Ghostty config in (Zetty doesn't read Ghostty's own file).
`font-family` and `font-size` set the terminal and status-bar font; the rest of
the interface keeps the system font. If Ghostty rejects a directive, Zetty
alerts you once and keeps its own settings working.

**Color schemes** — dark: Midnight, Nocturne, Frost, Twilight, Ember, Velvet,
Eclipse, Rosewood, Neon, Ukiyo · light: Daylight, Paper, Glacier, Dawn, Latte,
Porcelain, Harvest, Citrus, Daybreak, Sakura.

## Control CLI

`zetty` drives the running app over a local socket. Pane targets are a unique
prefix of the pane id, a unique `--cwd`, or the focused pane.

```sh
zetty status --json                      # projects → tabs → panes, agent status
zetty send --cwd ~/work/api 'ls' --enter # type into a pane
zetty send --key C-c                     # send a control key
zetty capture --lines 100                # recent output of a pane
zetty view README.md:20                  # peek a file at line 20
zetty new-tab --project api              # open a tab; prints the new pane id
zetty split --pane 1a2b3c4d --horizontal # split a pane; prints the new pane id
zetty break --pane 1a2b3c4d              # move a pane into its own tab
zetty focus --cwd ~/work/api             # switch to a pane
zetty close --pane 1a2b3c4d --tab        # close a pane, or its whole tab
zetty add-project ~/work/api             # add a folder as a project
zetty new-project ~/work/new --git       # create a folder and add it
zetty remove-project api                 # remove a project
zetty hibernate api                      # put a project away (keeps its layout)
zetty hibernate api --no-handoff         # same, without writing handoffs
zetty wake api                           # bring it back
zetty clone --project api --name fork-1  # copy-on-write clone on its own branch
zetty merge-clone fork-1                 # land a clone's work in its source
zetty push-clone fork-1                  # or push its branch for a pull request
zetty new-space "Client Acme" --color sky
zetty move-to-space api "Client Acme"
zetty scratch                            # throwaway terminal; prints its pane id
zetty tiles                              # toggle the tile grid
zetty tiles --profile morning            # open a saved tile view
zetty accounts                           # list agent accounts
zetty run personal                       # run that account's agent here
zetty reload                             # same as ⇧⌘,
zetty quit --kill-sessions               # quit and end preserved sessions
```

- **Background by default.** `new-tab`, `split`, `break` and `scratch` don't move
  your focus; add `--focus` to switch to the result. New panes start right away,
  so their ids can be used with `send` and `capture` immediately.
- **Hibernated or not-yet-viewed panes still work** — `send` and `focus` wake
  them on demand. `status` marks a hibernated pane `‹handoff: writing›` while
  its handoff is being written and `‹handoff: ready›` once waking will start
  from it.
- **Destructive commands never wait on a dialog.** `close`, `remove-project`,
  `hibernate`, `scratch-clear` and `quit --kill-sessions` refuse busy panes with an error naming them; pass
  `--force` to go ahead.
- **`zetty <command> --help`** shows usage and does nothing else. Run
  `zetty --help` for every command.

## Contributing

Zetty is pre-release (`0.1.x`): interfaces and config keys may still change.
Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md), and
[`DEVELOPMENT.md`](DEVELOPMENT.md) for building, testing and releasing.

## License

Zetty is released under the [MIT License](LICENSE). It includes third-party
software under its own licenses — Ghostty and libghostty-spm (MIT), FreeType,
Oniguruma, libpng, zlib and others, plus GNU libintl (LGPL-2.1) inside the
terminal core and Ghostty's bash and zsh shell-integration scripts (GPLv3). See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the full list; the notices
and license texts also ship inside the app.

## Acknowledgments

- [Ghostty](https://ghostty.org) and [libghostty-spm](https://github.com/Lakr233/libghostty-spm) — the terminal core
- [zmx](https://zmx.sh) — session persistence
- [JetBrains Mono](https://www.jetbrains.com/lp/mono/) — the bundled font
- [simple-icons](https://simpleicons.org) and [lobe-icons](https://github.com/lobehub/lobe-icons) — tool logos
