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
| [GNU libintl](https://www.gnu.org/software/gettext/) (gettext) — © Free Software Foundation | LGPL-2.1-or-later | [`LGPL-2.1.txt`](licenses/LGPL-2.1.txt) |

Portions of this software are copyright © The FreeType Project
(www.freetype.org). All rights reserved.

**GNU libintl is LGPL-licensed and statically linked** inside libghostty. Its
source is available from the [GNU gettext project](https://www.gnu.org/software/gettext/).
To run Zetty with a modified libintl, rebuild libghostty from
[libghostty-spm's source](https://github.com/Lakr233/libghostty-spm) (which
builds Ghostty and its dependencies from source) and build Zetty against it
from [Zetty's source](https://github.com/webteractive/zetty) — see
[`DEVELOPMENT.md`](DEVELOPMENT.md).

The Zig and LLVM runtime support compiled into libghostty (compiler-rt and a
libc++ shim) are under the MIT License and Apache-2.0 with the LLVM exception,
which require no notice in binary form.

## Bundled files

| Component | Where in the app | License | Text |
|---|---|---|---|
| Ghostty shell integration for **bash** and **zsh** (`ghostty.bash`, `zsh/.zshenv`, `zsh/ghostty-integration`) — derived from [Kitty](https://github.com/kovidgoyal/kitty)'s | `Resources/ghostty/shell-integration` | **GPL-3.0-or-later** | [`GPL-3.0.txt`](licenses/GPL-3.0.txt) |
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
[zmx](https://zmx.sh) (session persistence — Settings can download the
official binary for you), [bat](https://github.com/sharkdp/bat) (file viewer
highlighting), and the agent CLIs themselves.
