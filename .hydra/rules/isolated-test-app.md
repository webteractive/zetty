---
commands:
    - "zetty quit"
    - "ditto "
    - "open -a /Applications/zetty.app"
triggers:
    - "verifying a change in the running app before it is committed"
    - "driving the app to check a feature or a fix (/verify, prepare-for-release)"
    - "trying anything that quits, hibernates, closes panes or ends sessions"
---

# Verifying a change in an isolated test app

> This file is authoritative: edit it here, then run `hydra sync`.

**Verify an uncommitted change in a temporary copy of the build that runs
beside Glen's Zetty, never by quitting or replacing `/Applications/zetty.app`**
(Glen, 2026-10-15). His app hosts his sessions, and the agent doing the work
usually lives in one of them; quitting it for a test costs him his view and
risks the reap. On 2026-10-15 one session quit and reinstalled it twice to
verify, and its `/zetty-open` test left his editor in front. Installing to
`/Applications` is still the step AFTER the commit ("Installing after a
change" in `CLAUDE.md`); this rule covers everything before it.

The test app has its own home (`CFFIXED_USER_HOME`: workspace, config,
control socket, mods, handoffs) and its own `zmx` socket directory
(`ZMX_DIR`), so it cannot list, reattach or kill a real session.
`DEVELOPMENT.md` → "An isolated test instance" has the background; this is
the recipe that was run end to end on 2026-10-15.

```sh
# 1. Build, then FREEZE a copy: the next build must not change the binary
#    under a running process. Keep the home short (socket paths cap ~100 chars).
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
mkdir -p /tmp/zti/.config/zetty /tmp/zti/zmx /tmp/zti/.claude
printf 'preserve-sessions = true\n' > /tmp/zti/.config/zetty/config
ln -s "$HOME/.claude/projects" /tmp/zti/.claude/projects   # handoffs need it
ditto <DerivedData>/Build/Products/Debug/zetty.app /tmp/zti/zetty.app

# 2. Both must come back empty-handed before launching:
ZMX_DIR=/tmp/zti/zmx zmx list            # "no sessions found in /tmp/zti/zmx"
CFFIXED_USER_HOME=/tmp/zti zetty status  # "cannot reach zetty at /tmp/zti/.zetty/zetty.sock"

# 3. Launch it as a BACKGROUND TASK of the tool (run_in_background), not
#    with `&` or nohup: a detached job dies when the tool call returns.
env -i HOME="$HOME" USER="$USER" SHELL=/bin/zsh TMPDIR="$TMPDIR" LANG=en_US.UTF-8 \
  PATH="/usr/bin:/bin:/opt/homebrew/bin:$HOME/.local/bin" \
  CFFIXED_USER_HOME=/tmp/zti ZMX_DIR=/tmp/zti/zmx \
  /tmp/zti/zetty.app/Contents/MacOS/zetty </dev/null > /tmp/zti/app.log 2>&1

# 4. Drive it with ITS OWN binary as the CLI:
iz() { CFFIXED_USER_HOME=/tmp/zti ZMX_DIR=/tmp/zti/zmx /tmp/zti/zetty.app/Contents/MacOS/zetty "$@"; }
iz status; P=$(iz add-project /tmp/zti/work --name work --focus)
iz send --pane "$P" --enter 'sleep 900'   # without --enter the text just sits
                                          # at the prompt, and nothing is busy

# 5. Tear down, and prove the real sessions were never touched:
zmx list | grep -c zetty-                     # note the count first
iz quit --kill-sessions --force
zmx list | grep -c zetty-                     # same count
rm -rf /tmp/zti                               # removes the link, not ~/.claude/projects
```

## What is NOT isolated, and how to get around it

- **`zetty` on `PATH` is the INSTALLED CLI** (`~/.local/bin/zetty` links into
  `/Applications`). Driving the test app with it tests the old CLI against
  the new app. `iz` above calls the copy's own binary, and a pane in the
  test app gets `ZETTY_BIN` and `CFFIXED_USER_HOME` from it, so a mod or
  script inside a test pane reaches the test socket on its own.
- **Claude in a test pane loads the REAL installed mod.** The test app
  copies its mod to `/tmp/zti/.zetty/mods` and sets
  `CLAUDE_CODE_PLUGIN_DIRS` to it, but `~/.claude/settings.json`'s `env`
  (real `HOME`) lists `~/.zetty/mods/zetty-bridge` and wins. Proven with a
  marker in the copy's usage text: plain `claude` did not show it. To test
  the mod under change, start Claude in the test pane with
  `claude --settings '{"env":{"CLAUDE_CODE_PLUGIN_DIRS":"/tmp/zti/.zetty/mods/zetty-bridge"}}'`.
  That replaces the whole list, so Glen's other mods (warden, hydra) are
  absent in that pane, and the output label reads `zetty-bridge:` alone.
- **Hooks report to the real home**, so no hook event reaches the test app
  (status dots and needs-attention come from the probe only), and the mod's
  usage snapshot is written under the real `~/.zetty/agent-usage`, where the
  real app sweeps it as a surface it does not own.
- **So a Claude pane's session is GUESSED, and can be guessed stale.**
  Without hooks the session store matches the newest transcript in the
  pane's directory, and it ran before a just-started Claude wrote its own:
  on 2026-10-17 it picked a reply-less chat left in `-private-tmp-zti-work`
  by an earlier test, kept it, and `hibernate` logged "holds no
  conversation, skipped". Give each test a fresh directory, or resume the
  chat by id (`claude --resume <id>`) once its transcript exists. The CLI
  also counts an agent pane as busy, so hibernating one needs `--force`
  (the handoff still runs).
- **Codex's shared daemon is shared**, and the busy-pane teardown freeze was
  never reproduced in isolation (`DEVELOPMENT.md`).
- **The test app is a real window on Glen's screen** with the same bundle id.
  Anything routed by Launch Services (`ssh://` links, `open -a`) may land in
  either copy; see `ssh-url-handover.md`. `open -a` does not activate an
  already-running Zetty; `osascript -e 'tell application id
  "co.webteractive.zetty" to activate'` does, and it may pick either copy.
- **Activating another app is a test condition, not a side effect.** The
  foreground probe only polls while Zetty is the active app, so focus
  changes what `status` reports. A step that opens an editor or Finder
  (`/zetty-open`, `zetty edit`) moves focus; say so, and restore it after.

## What still needs the installed app

Signing and the bundle seal (`codesign --verify --deep`), the Release
build, the self-update swap, and the version the app reports after the
commit (`ZettyBuildCommit` without `*`). Those are the post-commit install
ritual's job, not this one's.
