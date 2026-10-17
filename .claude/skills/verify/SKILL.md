---
name: verify
description: Verify a Zetty change in the running app, in an isolated test copy beside the installed one. Use for /verify, or to drive hibernate, handoffs, panes or the CLI before or after a commit.
---

# Verifying Zetty

The recipe is `.hydra/rules/isolated-test-app.md`: build, freeze a copy in
`/tmp/zti`, launch it as a background task with `CFFIXED_USER_HOME` and
`ZMX_DIR`, drive it with its own binary (`iz`), tear down with
`iz quit --kill-sessions --force`, and check the real `zmx list` count is
unchanged. Never quit or replace `/Applications/zetty.app` to verify.

## Reading what happened

- Pane screen: `ZMX_DIR=/tmp/zti/zmx env -u ZMX_SESSION zmx history zetty-<id>`;
  add `--vt` for styling (SGR 2 is faint, which is what Claude's
  placeholders are drawn in).
- App log: `/usr/bin/log show --last 2m --predicate 'subsystem == "co.webteractive.zetty"' --style compact`
  (not zsh's `log`). Hibernation logs `hibernate:` and `handoff:` lines.
- `iz status` shows `‹handoff: writing|ready|failed›`.

## Hibernate and handoffs

- Each Claude test goes in a FRESH directory: without hooks the pane's
  session is guessed from the newest transcript there.
- A new directory first shows Claude's trust question: `iz send --pane <id> --key Down --key Enter`.
- `iz hibernate <project> --force` (an agent pane counts as busy).
- Claude's predicted-prompt placeholder needs
  `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=1` on the `claude` command line; a
  pane woken from a handoff resumes without it.
- The queued-message hint shows while a long reply runs ("Count from 1 to
  300…") and a second message is sent behind it.
- Without hooks a working Claude is not known to be working, so a hibernate
  mid-turn types `/compact` over the turn. That path needs the installed app.
- Delete the throwaway chats afterwards: `~/.claude/projects/-private-tmp-zti-*`
  folders the test made.
