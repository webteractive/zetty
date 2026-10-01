---
paths:
    - "Sources/ZettyCore/Accounts/**"
    - "App/Sources/App/AccountSeeder.swift"
    - "App/Sources/App/AccountShimInstaller.swift"
    - "App/Sources/App/AddAccountSheet.swift"
    - "App/Sources/App/AgentAuthRunner.swift"
    - "App/Sources/App/HookInstaller.swift"
commands:
    - "zetty run"
    - "zetty accounts"
triggers:
    - "adding or changing agent accounts or logins"
    - "supporting a new agent harness for accounts"
    - "CLAUDE_CONFIG_DIR or CODEX_HOME handling"
---

# Agent accounts (multiple Claude/Codex logins)

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

Named logins for an agent harness — a work Claude account and a personal one —
selectable per project and per pane. Pure model in `ZettyCore/Accounts/`
(`AgentAccount` · `AgentAccountsFile` · `AgentAccountStore` ·
`AgentAccountSupport` · `AgentAccountResolver` · `AccountSeed` ·
`AuthStatusProbe`); private JSON at
`~/Library/Application Support/zetty/agent-accounts.json`. App layer:
`AccountSeeder` (filesystem), `AgentAuthRunner` (process IO), `AddAccountSheet`,
and the Settings → Accounts tab.

**One env var does the whole job**, and which var comes from
`SpawnableAgent.configDirEnvVar` — nil for agents with no VERIFIED isolation
mechanism, which is what stops them hosting accounts. Two are supported:

- **Claude Code** (`CLAUDE_CONFIG_DIR`) relocates the config dir, and Claude
  derives its Keychain service name as
  `Claude Code-credentials-<sha256(configDir)[0:8]>` — so a custom directory
  gets its OWN Keychain item automatically and Zetty never touches the Keychain.
  `.claude.json` (holding `oauthAccount`) and the plaintext
  `.credentials.json` fallback follow the variable.
- **Codex** (`CODEX_HOME`) keeps credentials in a plain `auth.json` INSIDE the
  config dir, so relocating the directory isolates the login outright — no
  Keychain involved. Two differences from Claude, both handled: its status
  output is prose ("Logged in using ChatGPT"), so it reports signed-in state but
  no identity (`AuthStatusFormat.plainText`); and it REFUSES to run at all when
  `CODEX_HOME` names a directory that does not exist, which is why
  `AccountSeeder.prepare` always creates it.

**Never add an agent to this list without verifying its credential store.**
Cursor Agent was investigated and REJECTED: it has a `CURSOR_CONFIG_DIR`, but
its Keychain service names are hardcoded (`cursor-access-token`, account
`cursor-user`) with no config-dir derivation, so every "account" would share one
credential — and its API-key path *overwrites* that shared item, silently
destroying an existing login. opencode isolates only through the generic
`XDG_DATA_HOME` (its own `OPENCODE_CONFIG_DIR` moves config but NOT `auth.json`,
so it would silently share one login), and setting a generic XDG var pane-wide
would relocate every XDG-aware tool in that pane — so it is deferred rather than
shipped. Gemini is deferred too, but only for cost, not safety: it works via
`GEMINI_CLI_HOME` **plus** `GEMINI_FORCE_FILE_STORAGE=true` (without the second,
credentials go to a FIXED keychain name and every account silently shares one
login), its config dir nests at `<dir>/.gemini`, and it has no status command at
all — identity is readable only from `google_accounts.json`. Supporting it means
generalizing `configDirEnvVar` into a per-agent environment MAP, adding a config
subdirectory, and adding a file-based identity reader.

In every one of these three cases the plausible-looking env var is the trap:
`CURSOR_CONFIG_DIR`, `OPENCODE_CONFIG_DIR` and a bare `GEMINI_CLI_HOME` all
exist, all look correct, and none of them isolates credentials on its own.

Gotchas, all deliberate:

- **`Surface.accountID` is STAMPED at creation with a concrete value**, never
  "nil means inherit". Env is captured once — by libghostty in `pair(for:)`, and
  by zmx when the session is created — so a value that could drift afterwards
  would describe a process that no longer matches, and the status chip would
  name the wrong login. `resolvedAccountID(explicit:project:)` +
  `makeSurface`/`stampAccounts` are the only ways to set it, and **every stamp
  must land BEFORE the rebuild that spawns the pane**. `performNewTab` is the
  trap: `newTab()` mints the surface inside the model, so the stamp goes between
  it and `rebuildSurfaceNodeView()`. The other four minting paths (CLI
  `openNewTab`/`splitPane`, layout templates, clone registration, scratch) stamp
  from the project default.
- **`@default` is a reserved sentinel, never stored.** It resolves to an EMPTY
  environment, so `pair(for:)` emits no `env` directive at all and the pane
  inherits the process environment exactly as before accounts existed. It is
  collision-proof because `slug` cannot emit `@` (same trick as
  `ProjectSettingsStore.homeKey`).
- **An unresolvable account id falls THROUGH** — pane → project → `@default` —
  so removing an account can never strand a pane. `WorkspaceModel
  .healAccountIDs(known:)` additionally clears dangling stamps on launch and
  after a delete, mirroring how `regroup()` drops dead `spaceID`s.
- **Account env is merged LAST and wins**, so a hand-typed `CLAUDE_CONFIG_DIR`
  in Project Settings → Environment can't point the pane somewhere the chip
  doesn't claim. `surfaceEnvironmentProvider` takes the whole `Surface` (not a
  UUID) so the pane's own account is readable without a workspace-wide scan, and
  it guards `isScratch` — a scratch project is rooted at home and would
  otherwise adopt that path's project settings.
- **The account directory is validated, not trusted.** It is rendered into a
  one-line `env = KEY=VALUE` directive, and libghostty validates all-or-nothing
  — a rejected directive frees the WHOLE config including the per-surface
  `command`, stranding preserved sessions. `AgentAccountSupport.make` therefore
  restricts the path to `[A-Za-z0-9._-/~]`, refuses the agent's own home
  (`~/.claude` IS the default account, and pointing at it would hash to a
  DIFFERENT Keychain item while looking identical), and refuses `~` or an
  ancestor. v1 only ever generates `~/.zetty/accounts/<slug>`; importing an
  existing config dir is deferred behind that validator.
- **`pair(for:)` is a three-rung ladder**: full config → Zetty-only →
  **command-only**. The old two-rung version re-applied Zetty's own env on
  retry, so a bad value we generated failed BOTH attempts. Rung 3 is what makes
  "a preserved pane always reattaches" true regardless of env.
  `EnvDirective.sanitized` is the matching boundary guard (no control chars, no
  `=` in a key, no empty key/value).
- **`HookInstaller` is account-aware, and it has to be.** Claude reads
  `settings.json` from `CLAUDE_CONFIG_DIR`, so hooks written only into
  `~/.claude` are invisible to an account — its panes would show NO agent status
  dots, no needs-attention notification, no Dock badge.
  `AppDelegate.installHooksForAccounts()` mirrors the default directory's state
  into every account on creation and whenever the Settings toggle flips. The
  same is true of Codex, whose hook is the `notify` key in `config.toml` —
  hence `installCodexHooks(inConfigDirectory:)` beside the Claude one.
- **Seed lists are PER AGENT** (`AccountSeed.shareable(forAgent:)` /
  `identity(forAgent:)`), because the two harnesses share entirely different
  files: Claude shares `skills`/`commands`/`agents`/`CLAUDE.md` and copies
  `settings.json`; Codex shares `AGENTS.md`/`skills`/`rules` and copies
  `config.toml`. Preference seeding is Claude-only — Codex keeps no equivalent
  JSON, so `preferenceFileName(forAgent:)` returns nil for it.
- **Seeding is three tiers, not two.** `skills/`, `commands/`, `agents/`,
  `CLAUDE.md` are **symlinked** (read-mostly). `settings.json` is **copied** —
  Claude rewrites it, so a shared link is last-writer-wins between two live
  processes, and each account needs a real file for its hooks. `plugins/` is
  **never shared in any form**: it is mutable state (marketplace JSON, a catalog
  cache, git clones), and it sits on `AccountSeed.identity` alongside the
  credential-bearing paths. That denylist is deliberately a SEPARATE list from
  `shareable` so adding an item there can't leak credentials by omission.
  `AccountSeeder` links to the source path **without resolving** it
  (`~/.claude/agents` is already a symlink into a dotfiles repo; linking to the
  repo would break if it moves), never overwrites a destination, and refuses a
  source that resolves inside the account directory.
- **Creating an account and authenticating it are separate.** `AddAccountSheet`
  offers **Create** alongside **Create & Sign In** (`onCreate`'s `signIn` flag →
  `addAgentAccount(_:seeding:signIn:)`), so an account can exist unauthenticated
  — its panes still get the config directory, the agent there is just logged
  out. `signInToAccount` is the shared path, reused by the Accounts list's
  **Sign In** button.
- **A signed-in account still looks signed-OUT without `hasCompletedOnboarding`.**
  `claude auth login` writes credentials and `oauthAccount` but does NOT mark
  onboarding complete (only the in-app login does; logout sets it back to
  false). A fresh config dir has no onboarding state, so interactive `claude`
  runs its first-run flow — which OPENS WITH the login-method selector — even
  though `claude auth status` reports `loggedIn: true` and the Keychain item
  exists. It reads as "the account didn't work", and the credentials are fine.
  `AccountSeed.preferenceKeys` + `AccountSeeder.seedPreferences` carry
  `hasCompletedOnboarding` (plus theme and a few machine-level answers) from the
  default `.claude.json` into the account's. It is an ALLOWLIST, so identity and
  history cannot ride along, and it fills only MISSING keys — which makes it
  idempotent and safe to re-run, and is why `signInToAccount` calls it on every
  sign-in: an account created before this existed repairs itself there. The
  per-folder trust prompt is NOT this bug; every account answers that once per
  directory.
- **Identity is captured, never polled.** `claude auth status` is a heavyweight
  CLI, once PER ACCOUNT, that a GUI app's `PATH` can't even find without an
  explicit candidate list — putting it on any cadence is the `git`-pill mistake
  with a multiplier. It runs only on sign-in, on Settings → **Check**, and on
  `zetty accounts --probe`; the chip reads the cached value only.
- **Moving an open pane means a NEW `Surface`.** `pair(for:)` returns the
  existing pair for a known id, so reusing it would apply nothing; and the zmx
  session name derives from the id, so it would reattach with the OLD env.
  `Layout.replace(surfaceID:with:)` / `PaneTree.replaceSurface` swap the leaf,
  keeping slot, siblings and ratios — and **must rewrite `focusedSurfaceID` and
  `zoomedSurfaceID`**, since a zoom pointing at a dead leaf makes the pane
  vanish. No session race: `reconcileSessions()` re-samples ownership on main
  before killing, and the replacement's uuid (hence session name) differs.
- **Removing an account never deletes its directory** — it holds a live login.
  The confirmation says so, or people believe they signed out.
- **`--account` is the one place tolerance is wrong.** An unknown name is an
  ERROR, never a fallback to the default login: landing an agent's pane on the
  wrong account is the mistake accounts exist to prevent, and a stale
  `/Applications` copy makes version skew real. `AccountsSnapshot` and
  `StatusSnapshot.Pane.account` still decode with `decodeIfPresent` so an older
  standalone `zetty` doesn't throw.
- **Chrome:** a status-bar chip (cached-token renderer, `renderedAccountToken`
  in `invalidateRenderCaches()` — the palette flips its dark/light variant while
  the id is unchanged), a tab-pill dot (colour **IDs** in `TabBarView.update`'s
  cache key so equality is by value; `restyle()` re-resolves the hue), and
  sidebar dots (`SidebarProject.accountColor` / `tabAccountColors`, trailing —
  the leading dot is agent status). Every dot view is created unconditionally
  with a 0↔6 width toggle so `canRepresent` stays valid and no structural flip
  forces a pill rebuild.

- **An account is reachable by name, not only by picker.** `zetty run <account>`
  (and the generated `<harness>-<account>` shim, e.g. `claude-work`) execs the harness in the CURRENT
  terminal with the account's config-dir variable set, reading
  `agent-accounts.json` directly — **no control socket in that path**, so it
  works with the app closed, in Terminal.app, or over SSH. That is what makes a
  project's enabled-agents setting stop gating access to an account. An unknown
  name is an ERROR listing the known accounts, the same rule `--account` follows.
  The advisory chip report uses `notify` (fire-and-forget, 250ms budget), NOT
  `roundTrip` — the latter waits up to 30s, which would stall a launch whenever
  the app is wedged.
- **The shims are SCRIPTS that exec `~/.local/bin/zetty`, not symlinks to the app
  binary.** All of them therefore inherit the freshness guarantee `CLILink`
  already provides for that one symlink — an app update repairs one link and
  every shim follows, instead of N stale links to detect. `AccountShim.marker`
  (`# zetty-account-shim`) is load-bearing: a file without it is never written or
  removed, so a user's own `claude-<name>` survives. Shims are named after the
  account's harness (`AccountShim.name`); they were `z-<account>` until that
  read too little like the agent it starts. The installer scans only
  `AccountShim.candidatePrefixes` (the legacy `z-` plus each account-capable
  harness id) — never every file in `~/.local/bin`, which holds large
  binaries — so upgrading removes the old `z-*` shims rather than leaving both.
- **The GUI clears inherited account and pane variables at launch**
  (`LaunchEnvironment.clearInherited`, on main.swift's GUI path only — the CLI
  runs inside panes and needs them). A Default-login pane sets no
  `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, so it inherits the app's, and `open -a`
  from a terminal hands the app that shell's env: relaunching Zetty from a
  pane on an account put every Default pane on that account. A new
  account-capable harness's `configDirEnvVar` joins the list automatically.
- **`Surface.runningAccountID` is the account RUNNING in a pane; `accountID` is
  the one it was SPAWNED with.** Both are persisted, and the difference matters:
  the spawn stamp can never be rewritten (the env was captured once, at
  creation), but `zetty run` genuinely changes which login is running, so chrome
  resolves `runningAccountID ?? accountID` through the single
  `effectiveAccountID(for:)` accessor — never by reading either field directly.
  The override is persisted because preserved zmx sessions outlive the app; it is
  cleared by the foreground probe when the pane's foreground process stops being
  that agent, and at restore for any pane owning no preserved session. The
  probe skips a pane with a restart or a recovery resume in flight
  (`agentRestartTimers`, `runningAccountHolds`), whose agent is gone on
  purpose and coming back under the same login. **With
  `preserve-sessions` off there is no probe**, so an override there clears only
  at the next launch.
- **Deriving the running account from the process environment was tried and
  rejected.** `ps -E` on the foreground pid would be self-clearing and need no
  stored field, but on macOS it returns a full environment only for user-owned,
  non-hardened binaries — verified working for a user-installed `node`, and
  returning nothing at all for `/bin/sleep` and `/bin/sh`. A chip that updates on
  some installs and not others is worse than one with a documented rule.

CLI: `accounts [--probe] [--json]` (a **slow verb** — probing starts a process
per account) · `run <account> [args…]` (a **fast verb** that never reaches the
socket — it execs the harness in place) · `--account <name>` on `new-tab` /
`split` · the account name in `zetty status`.
