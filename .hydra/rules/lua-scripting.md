---
paths:
    - "Sources/ZettyLua/**"
    - "Sources/CLua/**"
    - "App/Sources/App/LuaScripting.swift"
    - "Sources/ZettyCore/Scripting/**"
commands:
    - "zetty do"
    - "zetty lua"
triggers:
    - "changing init.lua scripting, its API, events or runtime limits"
    - "adding a zetty.<verb> or an init.lua event"
---

# Lua scripting (init.lua)

`~/.config/zetty/init.lua` (beside `config`) runs in one Lua 5.4.7 state on
the main thread. Usage is in the README's "Scripting (experimental)"
section; the design is `docs/plans/2026-11-14-lua-scripting-design.md`.

## Layout

- `Sources/CLua/` — vendored Lua 5.4.7 (`lua.c`/`luac.c` excluded),
  `LUA_USE_MACOSX`. License in `THIRD_PARTY_NOTICES.md` /
  `licenses/lua-MIT.txt`.
- `Sources/ZettyLua/` — pure, unit-tested (`swift test --filter "lua|runner"`):
  `LuaRuntime` (state, load, calls in, budget/memory hook, timers and exec
  bookkeeping), `LuaPrelude` (the Lua that builds `zetty`, and
  `starterFile`), `LuaStack` (value conversion), `LuaScheduler`,
  `LuaCommandRunner` (`ProcessCommandRunner`).
- `Sources/ZettyCore/Scripting/PaneEventTracker.swift` — pure diff of pane
  snapshots into `pane.opened` / `pane.closed` / `project.focused`.
- `App/Sources/App/LuaScripting.swift` — the `LuaHost`: verbs, the busy gate
  on `close`, state for Settings → Scripting and the status-bar chip, the
  init.lua file watcher.

## Rules that keep it from crashing the app

- **Nothing longjmps across a Swift frame.** C entry points (`rawEntry`,
  `logEntry`) return `(nil, message)` and the Lua wrapper raises. The count
  hook (`budgetHook`) holds no Swift references, so its `lua_error` is safe.
- **The allocator never fails.** A failed allocation raises from whichever
  frame allocated, including Swift frames pushing values. The 64 MB cap is
  enforced by the count hook instead (`used > limit` → "script used more
  than its memory limit"), and a call stopped that way runs a full
  collection (`internals.gc` is `collectgarbage` itself, a C function, so no
  Lua instruction runs and the hook can't fire inside it). The collection
  runs whenever `used > limit` after a call, not only on that error message:
  handlers, timers and exec callbacks run under their own Lua `pcall`, which
  swallows it.
- **The deadline and the counter share one struct, the allocator's `ud`**
  (`LuaMemory`), reached from any thread with `lua_getallocf`. Not
  `LUA_EXTRASPACE`: `lua_newthread` copies that once, so a coroutine resumed
  in a later call saw the deadline of the call that created it and died.
- **Once tripped, the hook fires on every instruction** of that thread
  (`lua_sethook(..., 1)`), and drops back to 10,000 when within limits
  again. At 10,000 a `pcall` retry loop never ends: the hook's error is
  caught, the loop runs a few instructions and calls back in, and every
  10,000th instruction lands inside the protected call again.
- **Known limit:** `__gc` finalizers run with hooks off (`lgc.c`), so an
  infinite loop inside one hangs main, including at reload (`lua_close` runs
  pending finalizers). Nothing in the budget can stop it.
- **Swift never reads the `zetty` global.** The prelude returns an internals
  table (`run`, `emit`, `manifest`, `render`, `fire`, `exec_done`, `gc`) that
  Swift keeps by registry ref, and every prelude function closes over the
  local `Z`. A script may reassign or nil `zetty` freely.
- Budget: 2 s per call from Swift, nested calls share the outer deadline.
  Infinite recursion hits the memory cap before Lua's 1M-slot stack limit.
- `os.execute`, `io.popen`, `os.exit`, `package.loadlib` raise; `cpath` is
  empty; `package.path` is the config dir only.

## Timers and commands

- Swift owns the clock and the processes; Lua owns the callbacks, by id.
  Runtime-internal verbs start with `_` (`_after`, `_cancel`, `_exec`,
  `_cancel_exec`) and never reach the host.
- Callbacks capture the runtime weakly and the state pointer they were
  made for; a callback for a replaced state does nothing. Replacing the
  state (reload) or `shutdown()` cancels every timer and command.
- `ProcessCommandRunner` spawns with `posix_spawn` into its own process
  group (`POSIX_SPAWN_SETPGROUP`, `CLOEXEC_DEFAULT`), so a timeout signals
  the whole group (SIGTERM, SIGKILL after 2 s). A cancel (reload, quit,
  `:cancel()`) signals the group from `cancel()` itself, not the worker's
  next poll, because at quit the app can exit first. A relative program with
  a slash (`{"./build.sh"}`) resolves against the command's `cwd`, as a
  shell would. **A command is done when
  the spawned process exits**: output is drained for 0.25 s more, then
  dropped, so `sleep 60 &` holding the pipe can't hold the callback. Output
  is capped at 1 MB per stream. At most 8 run at once.
- `PATH` for commands is `ToolSearchPath.directories()` + Zetty's own, not a
  login shell's (Zetty never resolves one).

## Events

- `agent.status` — `TerminalViewController.onAgentStatusChanged`, from
  `handleAgentEvents` when `notify` is set (so the startup replay is
  silent).
- `pane.opened` / `pane.closed` / `project.focused` — `AppDelegate.trackPaneEvents`
  on `onWorkspaceDidChange` and `onActiveProjectChanged`. It snapshots
  `TerminalViewController.paneRecords()` (awake projects only) synchronously
  and delivers `main.async`. Launch takes the baseline after the restore, so
  reattached panes fire nothing; hibernate reads as closed, wake as opened.
- **Panes a script's own verbs open or close don't emit**
  (`LuaScripting.isRunningLua` is set around each verb, and the tracker's
  `emitPaneChanges: false` absorbs them): a `pane.opened` handler that splits
  would otherwise loop. A project switch still fires `project.focused`, as
  the spec's carve-out is pane events only. A new structural change path
  must call `onWorkspaceDidChange`, or it fires no event.
- `zetty.bind` chords are parsed by `ScriptBinding.chord` (ZettyCore); one
  that doesn't parse is recorded as a load error (Scripting page and chip),
  never a silently dead key.

## Reloading

- init.lua has its own `ConfigFileWatcher`; saving it reloads. Explicit
  reloads (⇧⌘,, palette, `zetty reload`) re-run it too. The flat config's
  watcher and Settings saves do not (`applyConfigFromDisk(rerunScripts:
  false)`), or every Settings toggle would restart timers.
- A file that doesn't compile keeps the previous state; a runtime error
  keeps the new state with what ran before it. A missing file leaves an
  empty state.

## The busy gate on `zetty.close`

Every verb runs with `isServingControlRequest` set, so nothing can open a
dialog. An unforced `close` with no socket reading (key, palette, timer,
event, `zetty lua`) takes its own fresh reading on main, each call bounded
to 0.5 s (`scriptForegroundReadTimeout`). That's up to about 1.5 s when zmx
lists unreachable sessions and needs a second `ps`. The cached probe polls
every 3 s and stops in the background, so it let a pane that had just
started `sleep 100` close. `zetty do` uses the reading the socket took. A
`zmx list` or `ps` that fails or times out reads as unreadable
(`BusyPaneGate.reading`), which refuses the close.

## Adding things

- **A verb:** a case in `LuaScripting.luaCall` that builds a
  `ControlRequest` and goes through `perform`; the name in the prelude's verb
  list and `LuaRuntime.verbs`; the README table.
- **An event:** a call site (or a `PaneEventTracker` case) that emits after
  the change, `main.async`; the README table.
- **Swift ↔ Lua macros** Swift can't import: `LUA_REGISTRYINDEX` =
  `-1_001_000`; first upvalue = `-1_001_001`; `lua_pcall` →
  `lua_pcallk(L,n,r,0,0,nil)`; `lua_pop(L,n)` → `lua_settop(L,-n-1)`;
  `lua_newtable` → `lua_createtable(L,0,0)`; `lua_gc` is variadic, so run
  `collectgarbage` from Lua.

## Verifying

Isolated test app only (`isolated-test-app.md`). The app's log isn't
readable from an agent's sandbox (`log show` returns nothing), so check
results through globals: `zetty lua 'SOME_GLOBAL'`. The test copy takes
focus when it launches and blocks `/Applications/zetty.app` from
relaunching while it runs (`LSMultipleInstancesProhibited`), so keep it up
only while verifying.
