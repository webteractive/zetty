---
paths:
    - "THIRD_PARTY_NOTICES.md"
    - "licenses/**"
    - "App/Resources/**"
    - "Package.swift"
triggers:
    - "adding a package, bundled file, font, logo set or script to the app"
    - "bumping libghostty"
---

# Third-party licenses that ship in the app

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

**Anything new that ships in the app needs its license in
`THIRD_PARTY_NOTICES.md` and `licenses/`** (both are bundled into the app —
MIT, BSD and FTL require the notice to travel with the binary). That covers a
new package, a bundled file (font, logo set, script), and **every libghostty
bump**: list the static library's members (`ar -t libghostty.a` on a thin
slice) and compare against the notices, since a Ghostty update can compile in
a new C library (and can drop one: GNU libintl, LGPL, left with
`2.2.2026101502`). One entry needs care: Ghostty's bash/zsh
shell-integration scripts under `App/Resources/ghostty` are GPLv3 (derived
from Kitty). libghostty-spm ships
an MIT rewrite of those scripts, but it has no `ssh` wrapper (TERM fallback,
terminfo install), which Zetty's `ssh-env,ssh-terminfo` default relies on.
The package also points `GHOSTTY_RESOURCES_DIR` at its own bundle right
before `ghostty_init`, so from v0.1.50 panes silently ran the rewrite and
`ssh` sent `TERM=xterm-ghostty` to hosts without it ("terminal is not
supported"). The build now copies Ghostty's scripts over the package's
inside the app (`Project.swift`, "Use Ghostty's shell integration"), and
fails if the package moves them. A libghostty bump must keep that step
green; check a new pane with `whence -w ssh` (a function, not a command).

**Never re-sync those scripts from upstream wholesale.** Ghostty after v1.4.0
(by `042b16b6146a`, bundled in libghostty-spm `2.2.2026110702`) moved the
`ssh` wrapper into its CLI: the scripts now call `"$GHOSTTY_BIN_DIR/ghostty"
+ssh`, and Zetty ships no `ghostty` binary, so a straight copy would break
`ssh` in every pane. Port upstream fixes into Zetty's copies one at a time
instead, keeping Zetty's own patches (zsh's `_ghostty_report_pwd` sends a
`file://` OSC 7 and writes `$ZETTY_CWD_FILE`). Ported so far: `ebd449995d`
(directory names can't inject escape sequences: zsh `print -r` with `$'...'`
framing, control bytes stripped in zsh and bash), on 2026-11-11.
