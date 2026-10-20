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
