# Lua scripting (init.lua) — design

Status: approved 2026-11-14 · built on branch `spike/lua` (plan: `2026-11-14-lua-scripting-plan.md`)

## Intent

Make Zetty scriptable from one global Lua file, the way Rex (Superlogical)
does it: custom actions on keys and in ⌘K, handlers that react to what
happens in the app, and logic that runs inside Zetty with no process startup.
Glen wants all three (a, b, c below). There is no single driving use case
yet; this is an exploration that should land as a small, stable surface
people can build on, not a large one that has to be walked back.

- **(a)** Put a custom action on a key or in ⌘K.
- **(b)** React to events (an agent finishing, a pane opening).
- **(c)** Run logic inside the app with no process startup.

The spike (`spike/lua`) proved the mechanics: Lua 5.4.7 compiles clean as a
SwiftPM C target, every verb is a thin wrapper over the control socket's own
request handler (`AppDelegate.handleOnMain`), and actions, a prefix binding,
`agent.status`, the time budget and keep-last-good reload all worked in the
isolated test app.

## Goals

- `~/.config/zetty/init.lua` (or `$XDG_CONFIG_HOME/zetty/init.lua`) is
  loaded at launch and on reload, if present. No file, no change in behavior.
- Lua can define actions, bind them to the prefix layer, list them in ⌘K,
  and run them from the CLI.
- Lua can subscribe to a small, named set of events.
- Lua can call the same operations the `zetty` CLI offers for panes and tabs,
  read the workspace, notify, log, and schedule work for later.
- A broken or runaway script never freezes Zetty, never touches sessions,
  and never fails silently.

## Non-goals

- **Configuring Zetty from Lua.** Themes, fonts, keys and Ghostty lines stay
  in the flat `config`, which Settings reads and writes. Lua cannot set
  config keys in v1.
- **Per-project or in-repo Lua.** Only the one global file. A repo's
  `.zetty/` never runs Lua (cf. the startup-command trust prompt, 224fa46).
- **Shell-side hooks** (`bind = d run:script.sh`, `zetty events --json`).
  Considered and declined (see Approaches).
- **Drawing UI** (panels, status-bar widgets, custom overlays).
- **Non-prefix chords** (`cmd+shift+y`) from Lua. Deferred: they collide with
  the four shortcut surfaces (`keybindings-copy-mode.md`) in ways the prefix
  layer does not.

## Anti-goals (failure even if it "works")

- The main thread hangs because of a script.
- A Lua error drops config, keys, or a pane's session.
- An error is only in the system log, and the user cannot tell why their
  action does nothing.
- Lua code from a cloned repository runs without the user writing it.

## Constraints

- `ZettyCore` stays pure (no AppKit). The Lua runtime lives in its own pure
  target, `ZettyLua` (depends on `CLua`), unit-tested with `swift test`.
- Project rules: new config keys use `zetty-` and ship with a Settings
  control (`configuration.md`); UI follows `DESIGN.md` / `ZTheme`
  (`design-rules.md`); the vendored Lua carries its license
  (`THIRD_PARTY_NOTICES.md`, `licenses/lua-MIT.txt`); CLI verbs follow
  `control-cli.md` (help text, `verbs` list, `--help` never acts); README
  documents usage.
- **No `lua_error`/`luaL_error` longjmp across a Swift frame that holds
  references.** The spike's pattern stays: C entry points return
  `(nil, message)` and a Lua wrapper raises; the time-budget hook holds no
  Swift references.
- Single Lua state, main thread only.

## Approaches

1. **Lua only** — harden the spike and ship it. All of a/b/c, fastest. The
   Lua API is the only scripting contract; a bash/Python script cannot hook
   events or add ⌘K entries. **Chosen by Glen.**
2. **Shared core, Lua first** — an action registry and event bus in
   ZettyCore, with Lua as one front end and a shell front end (`run:`,
   `zetty events`) later. One set of names for both; about a day more up
   front. Declined.
3. **Shell only** — `run:` bindings and `zetty events`. Smallest, but drops
   (c). Declined.

## Design

### File and lifecycle

- Path: the directory of `ConfigStore().fileURL`, file `init.lua`.
  `require` resolves from that directory (`?.lua`, `?/init.lua`).
- Not seeded on first launch. Settings → Scripting offers **Create
  init.lua**, which writes a commented starter (one action, one binding, one
  handler) and opens it in the editor. *(my call)*
- Loaded at launch after the config, and again on ⇧⌘, / `zetty reload`, and
  automatically when `init.lua` changes on disk, through the same watcher
  pattern as `config` (`ConfigFileWatcher`). Files pulled in by `require` are
  not watched. *(my call: matches how `config` already behaves; Rex reloads
  by hand only)*
- The `config` file's own auto-reload (and Settings saves) re-apply the flat
  config **without** re-running init.lua; they only re-merge its existing
  bindings. Otherwise every Settings toggle would restart scripts, cancel
  timers and re-run top-level code. *(my call, from review)*
- A reload builds a fresh state. If the file does not compile, the previous
  state stays and the error is recorded. If it compiles but raises while
  running, the new state is kept with whatever ran before the error.
  Replacing the state cancels the old state's timers and handlers.
- **`zetty-scripting = true|false`** (default `true`), with a switch in
  Settings → Scripting. `false` skips loading `init.lua` entirely: the
  escape hatch if a script misbehaves at launch. *(my call)*

### Runtime limits

- Every call from Swift into Lua (load, an action, an event handler, a timer,
  `zetty lua`) runs under a **2-second budget**, enforced by a count hook. A
  call past it is stopped with "script ran past its time budget and was
  stopped"; the state stays usable. Nested calls share the outer deadline.
- The full Lua standard library is available, `os` and `io` included. The
  file is the user's own, with the trust level of a shell rc file.
- **A script never freezes Zetty waiting on a command** (Glen chose this).
  `os.execute` and `io.popen` wait for the command and run outside the
  budget, so the prelude replaces both with functions that raise
  "os.execute blocks Zetty; use zetty.exec(cmd, callback)". Shell commands
  go through `zetty.exec` (below), which runs them off the main thread.
  Opening these up later is additive; taking them away once scripts rely on
  them is not.
- `os.exit` raises too, since it would quit Zetty with every pane in it.
  *(my call)*
- Only plain `.lua` modules load: the C module loader is switched off
  (`package.cpath = ""`, no `LUA_USE_DLOPEN` path), since luarocks `.so`
  files would need the `disable-library-validation` entitlement on every
  build. `package.path` holds the config directory only, not `./?.lua`.
  *(my call; additive to change later)*
- A 64 MB memory cap on the state. A counting allocator tracks the bytes and
  the budget hook raises "script used more than its memory limit" once they
  pass the cap; the allocator itself never fails, because a failed
  allocation longjmps from whichever frame allocated, Swift frames that push
  values included. A call stopped this way runs a full collection after.
  *(my call; planning found the longjmp issue)*
- Swift keeps its own references to the internal functions (`_run`, `_emit`,
  `_manifest`, `_render`) in the registry at load, so a script that
  reassigns or nils `zetty` cannot crash the app. *(fix from review)*

### API (v1) — the `zetty` global

Actions and bindings:

| Call | Does |
|---|---|
| `zetty.action{ name, title?, run }` | Defines an action. `run(ctx)` gets `ctx = { pane, cwd, project, source }`, `source` one of `"key"`, `"palette"`, `"cli"`, `"lua"`. Redefining a name replaces it. |
| `zetty.bind(chord, name)` | Binds a prefix-layer key: `"prefix>d"` or `"d"`. A chord that does not parse is an error at load. Lua bindings override the flat config's for the same chord. |
| `zetty.run(name, ctx?)` | Runs another action from Lua. |

The flat config can also bind one: `bind = d lua:dev`.

Operations (each mirrors a CLI verb; a failure raises a Lua error naming
the verb):

| Call | Returns |
|---|---|
| `zetty.split{ pane?, cwd?, direction = "right"\|"down", focus?, account? }` | new pane id |
| `zetty.send{ pane?, cwd?, text?, keys?, enter? }` or `zetty.send("text")` | `true` |
| `zetty.new_tab{ project?, focus?, account? }` | new pane id |
| `zetty.focus{ pane? \| cwd? }` or `zetty.focus("id")` | `true` |
| `zetty.close{ pane? \| cwd?, tab?, force? }` | `true` |
| `zetty.status()` | the `zetty status --json` tree as a table |
| `zetty.notify{ title?, text }` or `zetty.notify("text")` | `true`; a macOS banner, shown even while Zetty is in front |

`pane` is a short pane id (unique prefix); omitted means the focused pane,
as in the CLI. Adding more verbs later (hibernate, wake, view) is additive.

**Scripts never raise a dialog, and never close a busy pane without being
told to.** *(my call, from review)*

- Every Lua verb runs with `isServingControlRequest` set, the way socket
  requests do, so no confirmation sheet can open mid-script.
- `zetty.close` refuses a pane unless `force = true` when the pane is busy
  (`BusyPaneGate`) **or its foreground state is not freshly known**: the
  probe (`foregroundBySurface`) stops while Zetty is in the background, so a
  stale or missing reading counts as busy. This holds for every `source`,
  key presses included. The error names the pane, so a script can retry
  with `force` deliberately.

Events and time:

| Call | Does |
|---|---|
| `zetty.on(event, fn)` | Subscribes. Handlers run in order; one handler's error is logged and does not stop the others. |
| `zetty.after(seconds, fn)` | Runs `fn` once later on main. Returns a handle with `:cancel()`. |
| `zetty.every(seconds, fn)` | Repeats (minimum 1 s). Same handle. |

Shell commands:

| Call | Does |
|---|---|
| `zetty.exec(cmd, fn)` or `zetty.exec(cmd, opts, fn)` | Runs `cmd` off the main thread and returns at once with a handle (`:cancel()`). When it finishes, `fn(result)` runs on main under the usual budget, with `result = { code, stdout, stderr, timed_out }`. |

`zetty.exec` details *(my calls)*:

- `cmd` is a string run with `/bin/sh -c`, or an array run as argv with no
  shell (`{"git", "-C", dir, "status"}`), so paths with spaces need no
  quoting.
- `opts`: `cwd` (default: the config directory), `timeout` in seconds
  (default 30; on expiry the process gets SIGTERM, then SIGKILL after 2 s,
  and `timed_out = true`), `env` (a table merged over the base
  environment).
- The base environment is Zetty's own, with `PATH` led by the directories
  the file viewer already searches (`~/.zetty/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin`, `~/.local/bin`, `/usr/bin`, `/bin`), so Homebrew tools
  and `gh` are found; a GUI app's own `PATH` does not have them. (Zetty
  never resolves a login shell's environment; panes get theirs by running
  the shell. A command needing more sets `env` or runs
  `{"/bin/zsh", "-lc", cmd}`.)
- stdout and stderr are each capped at 1 MB; past that the rest is dropped
  and the string ends with a "[truncated]" line.
- At most 8 commands run at once; more wait in a queue. Reloading
  `init.lua`, turning scripting off, or quitting terminates the running
  ones and drops their callbacks.
- A callback's error is logged like an event handler's.

Utilities: `zetty.log(...)` and `print` (to the log and the Scripting page's
recent output), `zetty.inspect(v)`, `zetty.config_dir`.

### Events (v1) — names and payloads are the contract

| Event | Payload | Fired when |
|---|---|---|
| `agent.status` | `pane, project, agent, status, previous` | an agent's status changes (`running`, `idle`, `needsAttention`, `none`) |
| `pane.opened` | `pane, project, cwd` | a **new shell** starts in a pane: a split, new tab, new project or clone, scratch pane, or a wake (which starts fresh shells) |
| `pane.closed` | `pane, project` | a pane is closed, or its project hibernated or removed |
| `project.focused` | `project, previous` | the active project changes |

`pane.opened` is fired from the workspace change, not from surface creation.
It does **not** fire for preserved panes reattached at launch (their shells
already ran), for a surface view rebuilt for an existing pane, or for
another Mac's panes. *(my call, from review: otherwise a "send `nvm use`"
handler types into every pane on every launch)*

`pane.opened` and `pane.closed` do **not** fire for panes a script itself
opens or closes (a change made while a Lua call is running): a
`pane.opened` handler that splits would otherwise split forever. *(my call,
from planning)*

- Delivered asynchronously on main after the change that caused them, never
  from inside the code path that is mutating the workspace.
- `agent.status` fires for every pane whose status Zetty changed, the same
  set the status dots update: an event matched by working directory instead
  of an exact pane id reaches every pane in that directory.
- Events from the startup replay of old hook events are not delivered.

### CLI

- `zetty do <action>` runs an action (`ctx.source = "cli"`).
- `zetty lua <code>` evaluates in the live state and prints the result
  (strings raw, tables rendered); a statement prints nothing. Same-user 0600
  socket only.
- Both follow `control-cli.md`: entries in `verbs`, help text, `--help`
  never acts.

### Surfacing state and errors

- **Settings → Scripting** (new page): the `zetty-scripting` switch; the file
  path with **Open in Editor**, **Reload**, and **Create init.lua** when it
  does not exist; a status line (loaded at HH:MM, N actions, N bindings, or
  "not loaded"); the current errors, each with file and line; the actions
  with their bindings; the last 50 lines of script output.
- **When the last load or a handler errored**, the status bar shows a small
  warning chip ("init.lua") that opens Settings → Scripting. It clears on the
  next clean load. No modal alerts: saving a half-edited file would raise one
  every time. *(my call)*
- Every error is also logged under the `config` category.
- ⌘K lists every action by its title, with its prefix binding as the hint.

## Docs

- README: a short "Scripting" section (file location, a three-line example,
  the API and event tables in brief, `zetty do` / `zetty lua`), labelled
  **experimental** for its first releases, so names can still change if
  something is wrong. *(my call)*
- New `.hydra/rules/lua-scripting.md`: runtime internals, the longjmp rule,
  the budget, the event choke points, how to add a verb or an event.
- `THIRD_PARTY_NOTICES.md` + `licenses/lua-MIT.txt` (already in the spike).
- `configuration.md`: `zetty-scripting`.

## Testing

- `ZettyLua` unit tests: actions, bindings, verbs reaching the host, errors
  raised at the caller, keep-last-good on syntax errors, budget stop, timers
  cancelled on reload, event handler isolation, eval rendering;
  `os.execute` / `io.popen` / `os.exit` raise; `zetty.exec` returns
  immediately, delivers code and output, honours `cwd`, times out, caps
  output, and drops callbacks on reload.
- `ZettyCore` tests: `lua:` binding names; `do` / `lua` request round-trip;
  help coverage (existing `--help never acts` test picks the verbs up).
- Isolated test app: each event fires once per change with the documented
  payload; a prefix binding and a ⌘K entry run their action; Settings shows
  errors and the chip clears on fix; `zetty-scripting = false` loads nothing.

## Left to the builder

- Where exactly each event is fired (one choke point per event in
  `TerminalViewController`), and how `pane.closed` relates to hibernation.
- The Scripting page layout, the ⌘K glyph and the status-bar chip styling,
  within `DESIGN.md`.
- The starter file's contents.
- How the 50-line output ring is stored.
- How `zetty.exec` runs processes (`Process` with pipes is fine) and where
  it gets the pane-shell environment from.
- Whether to keep the spike's code as-is or restructure it; the spike is not
  production code (no Settings, no timers, three events missing).
