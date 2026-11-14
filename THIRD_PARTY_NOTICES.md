# Third-party notices

Zetty's own code is released under the [MIT License](LICENSE). The app also
contains the third-party software listed below, each under its own license. The
full text of every license is in [`licenses/`](licenses/), and both this file
and that folder ship inside the app (`Zetty.app/Contents/Resources`).

## Linked into the app

Zetty embeds the Ghostty terminal core through
[libghostty-spm](https://github.com/Lakr233/libghostty-spm), a prebuilt static
library. The libraries compiled into it ship as part of Zetty's binary.

| Component | License | Text |
|---|---|---|
| [Ghostty](https://github.com/ghostty-org/ghostty) (libghostty) — © Mitchell Hashimoto, Ghostty contributors | MIT | [`ghostty-MIT.txt`](licenses/ghostty-MIT.txt) |
| [libghostty-spm](https://github.com/Lakr233/libghostty-spm) — © @Lakr233 | MIT | [`libghostty-spm-MIT.txt`](licenses/libghostty-spm-MIT.txt) |
| [DisplayLink](https://github.com/Lakr233/DisplayLink) — © Lakr Aream | MIT | [`DisplayLink-MIT.txt`](licenses/DisplayLink-MIT.txt) |
| [FreeType](https://freetype.org) | FreeType License (FTL) | [`freetype-FTL.txt`](licenses/freetype-FTL.txt) |
| [Oniguruma](https://github.com/kkos/oniguruma) — © K.Kosako | BSD-2-Clause | [`oniguruma-BSD-2-Clause.txt`](licenses/oniguruma-BSD-2-Clause.txt) |
| [libpng](http://www.libpng.org/pub/png/libpng.html) | PNG Reference Library License v2 | [`libpng.txt`](licenses/libpng.txt) |
| [zlib](https://zlib.net) — © Jean-loup Gailly and Mark Adler | zlib | [`zlib.txt`](licenses/zlib.txt) |
| [simdutf](https://github.com/simdutf/simdutf) — © The simdutf authors | MIT (dual MIT / Apache-2.0) | [`simdutf-MIT.txt`](licenses/simdutf-MIT.txt) |
| [Highway](https://github.com/google/highway) — © The Highway Project Authors | Apache-2.0 or BSD-3-Clause | [`highway.txt`](licenses/highway.txt) |
| [Wuffs](https://github.com/google/wuffs) — © The Wuffs Authors | Apache-2.0 | [`wuffs-Apache-2.0.txt`](licenses/wuffs-Apache-2.0.txt) |
| [stb](https://github.com/nothings/stb) — © Sean Barrett | MIT or public domain | [`stb.txt`](licenses/stb.txt) |

Portions of this software are copyright © The FreeType Project
(www.freetype.org). All rights reserved.

The Zig and LLVM runtime support compiled into libghostty (compiler-rt and a
libc++ shim) are under the MIT License and Apache-2.0 with the LLVM exception,
which require no notice in binary form.

## Linked into the app: Tailscale

Zetty joins your tailnet as its own device through Tailscale's embeddable
node ([tsnet](https://tailscale.com/kb/1244/tsnet)), compiled from Go into a
static library (`Bridge/tailnet`). The Go standard library and these modules
ship as part of Zetty's binary. Every license text, with copyright lines, is in
[`tailscale-go-modules.txt`](licenses/tailscale-go-modules.txt).

| Module | License |
|---|---|
| The Go standard library and runtime — © The Go Authors | BSD-3-Clause |
| `filippo.io/edwards25519` v1.2.0 | BSD-3-Clause |
| `github.com/coder/websocket` v1.8.15 | ISC |
| `github.com/creachadair/msync` v0.10.1 | BSD-2-Clause |
| `github.com/fxamacker/cbor/v2` v2.9.3 | MIT |
| `github.com/gaissmai/bart` v0.29.0 | MIT |
| `github.com/go-json-experiment/json` v0.0.0-… | BSD-3-Clause |
| `github.com/golang/groupcache` v0.0.0-… | Apache-2.0 |
| `github.com/google/btree` v1.1.3 | Apache-2.0 |
| `github.com/hdevalence/ed25519consensus` v0.2.0 | BSD-3-Clause |
| `github.com/huin/goupnp` v1.3.0 | BSD-2-Clause |
| `github.com/klauspost/compress` v1.20.0 | Apache-2.0 |
| `github.com/mitchellh/go-ps` v1.0.0 | MIT |
| `github.com/pires/go-proxyproto` v0.15.0 | Apache-2.0 |
| `github.com/tailscale/certstore` v0.1.1-… | MIT |
| `github.com/tailscale/hujson` v0.0.0-… | BSD-3-Clause |
| `github.com/tailscale/peercred` v0.0.0-… | BSD-3-Clause |
| `github.com/tailscale/web-client-prebuilt` v0.0.0-… | BSD-3-Clause |
| `github.com/tailscale/wireguard-go` v0.0.0-… | MIT |
| `github.com/x448/float16` v0.8.4 | MIT |
| `go4.org/mem` v0.0.0-… | Apache-2.0 |
| `go4.org/netipx` v0.0.0-… | BSD-3-Clause |
| `golang.org/x/crypto` v0.58.0 | BSD-3-Clause |
| `golang.org/x/exp` v0.0.0-… | BSD-3-Clause |
| `golang.org/x/net` v0.60.0 | BSD-3-Clause |
| `golang.org/x/oauth2` v0.37.0 | BSD-3-Clause |
| `golang.org/x/sync` v0.24.0 | BSD-3-Clause |
| `golang.org/x/sys` v0.49.0 | BSD-3-Clause |
| `golang.org/x/term` v0.47.0 | BSD-3-Clause |
| `golang.org/x/text` v0.43.0 | BSD-3-Clause |
| `golang.org/x/time` v0.16.0 | BSD-3-Clause |
| `gvisor.dev/gvisor` v0.0.0-… | Apache-2.0 |
| `tailscale.com` v1.104.7 | BSD-3-Clause |

Tailscale's code is © Tailscale Inc & contributors. "Tailscale" is a trademark
of Tailscale Inc.; Zetty is not affiliated with or endorsed by Tailscale.

## Bundled executable: zmx

Session preservation runs [zmx](https://github.com/neurosnap/zmx), shipped
unmodified as a separate program at `Contents/Helpers/zmx`: upstream's release
binaries for arm64 and x86_64, checksummed against [`scripts/zmx.pin`](scripts/zmx.pin)
and combined into one file. It is not linked into Zetty.

| Component | License | Text |
|---|---|---|
| [zmx](https://github.com/neurosnap/zmx) — © Eric Bower | MIT | [`zmx-MIT.txt`](licenses/zmx-MIT.txt) |

zmx compiles in Ghostty's terminal library (ghostty-vt) and with it simdutf
and Highway, covered by the [`ghostty-MIT.txt`](licenses/ghostty-MIT.txt),
[`simdutf-MIT.txt`](licenses/simdutf-MIT.txt) and [`highway.txt`](licenses/highway.txt)
texts above, plus the Zig standard library and compiler-rt (MIT), which
require no notice in binary form.

## Bundled files

| Component | Where in the app | License | Text |
|---|---|---|---|
| Ghostty shell integration for **bash** and **zsh** (`ghostty.bash`, `zsh/.zshenv`, `zsh/ghostty-integration`) — derived from [Kitty](https://github.com/kovidgoyal/kitty)'s | `Resources/ghostty/shell-integration`, copied over libghostty-spm's in `Resources/GhosttyKit_GhosttyTerminal.bundle/Contents/Resources/Ghostty/shell-integration` | **GPL-3.0-or-later** | [`GPL-3.0.txt`](licenses/GPL-3.0.txt) |
| Ghostty shell integration for fish, elvish and nushell; the `xterm-ghostty` terminfo | `Resources/ghostty` | MIT (Ghostty) | [`ghostty-MIT.txt`](licenses/ghostty-MIT.txt) |
| [bash-preexec](https://github.com/rcaloras/bash-preexec) — © Ryan Caloras | `Resources/ghostty/shell-integration/bash` | MIT | [`bash-preexec-MIT.txt`](licenses/bash-preexec-MIT.txt) |
| [JetBrains Mono](https://www.jetbrains.com/lp/mono/) font | `Resources` | SIL Open Font License 1.1 | [`JetBrainsMono-OFL-1.1.txt`](licenses/JetBrainsMono-OFL-1.1.txt) |
| Tool logos from [lobe-icons](https://github.com/lobehub/lobe-icons) — © LobeHub | `Resources` (`agent-*.svg`) | MIT | [`lobe-icons-MIT.txt`](licenses/lobe-icons-MIT.txt) |
| Tool logos from [simple-icons](https://simpleicons.org) | `Resources` (`agent-*.svg`) | CC0 1.0 (no conditions) | — |

**The bash and zsh shell-integration scripts are GPLv3**, as their headers state,
because they derive from Kitty's. They are separate scripts that your shell runs
inside a pane; they are not linked into Zetty, and Zetty's own code stays under
the MIT License. Their source is the files themselves — in the app bundle and in
this repository under [`App/Resources/ghostty/shell-integration`](App/Resources/ghostty/shell-integration).
Logo marks remain trademarks of their respective owners.

## Used but not shipped

Zetty runs these if you have them, but does not distribute them:
[bat](https://github.com/sharkdp/bat) (file viewer highlighting) and the agent
CLIs themselves.
