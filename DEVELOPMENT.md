# Developing Zetty

Building, testing and releasing Zetty from source. For how to contribute (pull
requests, bug reports) see [`CONTRIBUTING.md`](CONTRIBUTING.md); for the full
contributor guide — repo layout, design rules, subsystem internals and gotchas —
see [`AGENTS.md`](AGENTS.md). [`DESIGN.md`](DESIGN.md) is the visual spec.

## Agent instructions: `AGENTS.md` and `CLAUDE.md`

Zetty is developed largely with AI coding agents, and the repo carries their
instructions:

- **[`AGENTS.md`](AGENTS.md)** and **[`CLAUDE.md`](CLAUDE.md)** are the same
  file under the two names agents look for — Claude Code reads `CLAUDE.md`,
  Codex and most others read `AGENTS.md`. They hold the rules every change
  follows: design rules, how to build and install, how to release, and the
  conventions behind them. **Keep them byte-identical**: edit one and copy the
  change to the other in the same commit.
- **`.hydra/rules/`** holds the feature deep-dives — session preservation,
  tile mode, the Claude mod, the chrome layout and so on. They are indexed
  from `CLAUDE.md` / `AGENTS.md` and read when a change touches that feature,
  which keeps the always-loaded files short. They are managed with
  [hydra](https://github.com/webteractive/hydra): add or edit a rule there,
  then run `hydra sync` to refresh the index in both files — never hand-edit
  the generated block between hydra's markers.

They are written for agents but are the most complete account of how Zetty
works, so read them before a substantial change whether or not you use one.

## Prerequisites

- macOS 14.0 or later
- Xcode 16+ (Swift 6 toolchain) with command-line tools
- [Tuist](https://tuist.dev) — `brew install tuist`, or through
  [mise](https://mise.jdx.dev): `mise install` in the repo
- Optional: [zmx](https://zmx.sh) for session persistence —
  `brew install neurosnap/tap/zmx` (Settings can also download it)

The libghostty terminal core comes as a prebuilt Swift package
([libghostty-spm](https://github.com/Lakr233/libghostty-spm)) — no Zig
toolchain or submodule build.

## Build and install

```sh
git clone https://github.com/webteractive/zetty.git
cd zetty

# Generate the Xcode project (Tuist)
tuist generate --no-open        # or: mise exec -- tuist generate --no-open

# Build the app
xcodebuild -project zetty.xcodeproj -scheme zetty \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build build

# Install
ditto build/Build/Products/Release/zetty.app /Applications/zetty.app
open /Applications/zetty.app
```

The generated project lists source files explicitly, so **run `tuist generate`
again after adding or removing a file**. A build you compile yourself is ad-hoc
signed, so macOS asks for folder access again after each build.

## Tests

```sh
swift test                 # the pure ZettyCore suite — fast
swift test --filter <name> # a single test
tuist test                 # all unit tests (ZettyCore + ZettyGhostty)
```

`tuist test` rewrites the Xcode project without its build-stamp phase; run
`tuist generate` again before the next build.

## Layout

- `Sources/ZettyCore/**` — the pure, unit-tested model layer (no AppKit): pane
  tree, workspace persistence, config parsing, keybinding engine, agent state
  machine, CLI protocol.
- `App/Sources/App/**` — the AppKit application.
- `App/Sources/ZettyGhostty/**` — the libghostty bridge.
- `Mods/zetty-bridge/` — the Claude Code mod Zetty loads into Claude panes.

## Releasing

```sh
scripts/release.sh --notes notes.md patch   # or minor | major | X.Y.Z; --dry-run first
scripts/package.sh                          # just build dist/Zetty-<version>.dmg + .sha256
```

Releases go through `scripts/release.sh`: it runs the tests, bumps the version in
`Project.swift`, packages a Developer ID signed and notarized DMG, tags, and
uploads both the DMG and the `.sha256` sidecar the in-app updater verifies
against. Release notes are a required, human-written input. Don't assemble a
release by hand or with a generic release tool — see the **Releasing** section of
[`AGENTS.md`](AGENTS.md) for why.

## Diagnostic logs

Zetty logs to the macOS unified log under the subsystem `co.webteractive.zetty`,
so logs can be collected after the fact on any build:

```sh
/usr/bin/log show --last 15m --predicate 'subsystem == "co.webteractive.zetty"' --style compact
```

The file viewer narrates each peek (file read, highlighter output, rendering) —
its **Copy diagnostics** button puts the recent lines, plus the build and macOS
version, on the clipboard for a bug report. File contents are never recorded.

Product plans live in [`docs/plans/`](docs/plans/).
