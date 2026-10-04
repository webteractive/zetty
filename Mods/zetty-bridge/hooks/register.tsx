import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, SessionUsage } from 'claude-code'

import { describePanes, fleetLabel, limitWarning, otherAccounts, projectPanes, UUID } from './panes'

// Zetty bridge: keeps one snapshot per pane at
// ~/.zetty/agent-usage/<surface>.json, rewritten whole on every change.
// Only reports sessions hosted INSIDE Zetty (ZETTY=1 in the pane's
// environment), the same gate zetty-hook.py applies.

const SNAPSHOT_VERSION = 1

type Turn = {
  state: 'running' | 'idle' | 'ended'
  // Why the last turn ended (answer, aborted, refusal, error) or the session did.
  reason?: string
  durationMs?: number
}

type Usage = Pick<SessionUsage, 'context' | 'rateLimits' | 'cost'>

// What a needs-attention is waiting on, in the harness's own words.
type Attention = { message: string; type: string }

let turn: Turn = { state: 'idle' }
let attention: Attention | undefined
// Events can land back to back; one write at a time keeps the file whole.
let writes: Promise<void> = Promise.resolve()

async function write($: EngineInterface, measured?: Usage): Promise<void> {
  if (!(await $.env.get('ZETTY'))) return
  const home = await $.env.get('HOME')
  const surface = await surfaceID($)
  if (!home || surface === undefined) return

  const usage = measured ?? (await $.session.usage())
  const snapshot = {
    v: SNAPSHOT_VERSION,
    agent: 'claude',
    surface,
    session: await $.session.id(),
    cwd: await $.session.cwd(),
    // "" is a real answer: the variable is unset, so the default login.
    config: (await $.env.get('CLAUDE_CONFIG_DIR')) ?? '',
    model: await $.session.model(),
    turn,
    attention,
    context: {
      tokens: usage.context.tokens,
      window: usage.context.window,
      percent: usage.context.percent,
    },
    costUSD: usage.cost?.usd,
    rateLimits: usage.rateLimits,
    updatedAt: await $.clock.now(),
  }
  await $.fs.write(
    `${home}/.zetty/agent-usage/${surface}.json`,
    JSON.stringify(snapshot) + '\n',
  )
}

// A snapshot that cannot be written must never cost the session its turn.
function publish($: EngineInterface, measured?: Usage): Promise<void> {
  writes = writes.then(() => write($, measured)).catch(() => {})
  return writes
}

// MARK: - Talking to Zetty

type ZettyResult = { ok: boolean; out: string }

async function zetty($: EngineInterface, args: readonly string[]): Promise<ZettyResult> {
  const bin = await $.env.get('ZETTY_BIN')
  if (!(await $.env.get('ZETTY')) || !bin) {
    return { ok: false, out: 'This session is not running inside a Zetty pane.' }
  }
  try {
    const ran = await $.process.run([bin, ...args], { timeoutMs: 10_000 })
    const ok = ran.exitCode === 0
    return { ok, out: (ok ? ran.stdout : ran.stderr || ran.stdout).trim() }
  } catch (err) {
    return { ok: false, out: `zetty did not answer: ${String(err)}` }
  }
}

// ZETTY_SURFACE is injected per pane; ZETTY_CWD_FILE (<panes>/<uuid>.cwd)
// predates it and covers preserved sessions created before it existed.
async function surfaceID($: EngineInterface): Promise<string | undefined> {
  const explicit = await $.env.get('ZETTY_SURFACE')
  if (explicit !== undefined && UUID.test(explicit)) return explicit
  const cwdFile = await $.env.get('ZETTY_CWD_FILE')
  const stem = cwdFile?.split('/').pop()?.replace(/\.cwd$/, '')
  return stem !== undefined && UUID.test(stem) ? stem : undefined
}

// The 8-hex id the CLI names a pane by: the surface uuid's first group.
async function paneID($: EngineInterface): Promise<string | undefined> {
  return (await surfaceID($))?.slice(0, 8).toLowerCase()
}

// MARK: - Slash commands

const USAGE = [
  'Usage:',
  '  /zetty panes                 the panes of this project',
  '  /zetty fleet                 a sidebar of this project\'s panes; press one to go to it',
  '  /zetty peek <path>[:line]    open a file in Zetty\'s viewer',
  '  /zetty split [--down] [command…]   open a pane beside this one, optionally running a command',
].join('\n')

// Splits this pane and, with a command, types it into the new one. Shared with
// the model's `open_pane` tool so the two cannot drift apart.
async function openPane(
  $: EngineInterface,
  options: { down: boolean; command?: string },
): Promise<{ ok: boolean; pane?: string; text: string }> {
  const me = await paneID($)
  if (me === undefined) return { ok: false, text: 'This session is not running inside a Zetty pane.' }
  const split = await zetty($, ['split', '--pane', me, ...(options.down ? ['--horizontal'] : [])])
  if (!split.ok) return { ok: false, text: split.out }
  const pane = split.out.split('\n').pop()?.trim() ?? ''
  if (options.command !== undefined && options.command.trim() !== '') {
    const sent = await zetty($, ['send', '--pane', pane, '--enter', options.command])
    if (!sent.ok) return { ok: false, pane, text: `Opened pane ${pane}, but could not run the command: ${sent.out}` }
    return { ok: true, pane, text: `Opened pane ${pane} running: ${options.command}` }
  }
  return { ok: true, pane, text: `Opened pane ${pane}.` }
}

async function listPanes($: EngineInterface): Promise<{ ok: boolean; text: string }> {
  const status = await zetty($, ['status', '--json'])
  if (!status.ok) return { ok: false, text: status.out }
  const found = projectPanes(status.out, await paneID($))
  return found === undefined
    ? { ok: false, text: 'Could not find this pane in the Zetty workspace.' }
    : { ok: true, text: describePanes(found) }
}

// Called from the module's one `session.start` hook: the engine allows a
// single unmatched hook per event, so the pieces cannot each register theirs.
async function startCommands($: EngineInterface): Promise<void> {
  // Only where there is a Zetty to talk to.
  if (!(await $.env.get('ZETTY'))) return
  await $.command.register({
    name: 'zetty',
    description: 'Zetty: list this project\'s panes, peek a file, or open a pane',
    argumentHint: 'panes | fleet | peek <path> | split [command]',
  })
}

// MARK: - Tools for the model

// Tools the model can call. Deliberately narrow: it can show a file, see this
// project's panes, open a pane, and read back a pane IT opened. Nothing closes
// a pane, types into one it did not open, or reaches another project.

// The matchers below spell each tool's full name (`mcp__<plugin>__<name>`) as a
// literal: the engine reads a matcher off the source, and a computed one
// matches nothing it can name.

// Panes this session opened, which is what `read_pane` is limited to. A module
// variable: a reload of the mod forgets them, and reading then asks to reopen.
const opened = new Set<string>()

const text = (value: unknown): string => (typeof value === 'string' ? value : '')

async function isEnabled($: EngineInterface): Promise<boolean> {
  // Zetty sets this from `zetty-claude-tools`; anything but "0" is on.
  return Boolean(await $.env.get('ZETTY')) && (await $.env.get('ZETTY_CLAUDE_TOOLS')) !== '0'
}

// Called from the module's one `session.start` hook, and awaited there so the
// tools are listed by the first turn.
async function startTools($: EngineInterface): Promise<void> {
  if (!(await isEnabled($))) return
  {
      await $.tool.register({
        name: 'show_file',
        description:
          'Open a file in the user\'s Zetty file viewer, at a line if given. Use it to SHOW the user a file you are talking about; it does not return the file\'s contents.',
        inputSchema: {
          type: 'object',
          properties: {
            path: { type: 'string', description: 'Absolute path, or relative to the session directory' },
            line: { type: 'integer', minimum: 1 },
          },
          required: ['path'],
        },
      })
      await $.tool.register({
        name: 'list_panes',
        description:
          'List the terminal panes of the Zetty project this session runs in: id, what runs in each, agent status and title.',
        inputSchema: { type: 'object', properties: {} },
      })
      await $.tool.register({
        name: 'open_pane',
        description:
          'Open a new terminal pane beside this one in Zetty, visible to the user, optionally running a command in it (a dev server, a test watcher, a log tail). Returns the new pane\'s id. Prefer this over a hidden background shell when the user would want to watch it.',
        inputSchema: {
          type: 'object',
          properties: {
            command: { type: 'string', description: 'Shell command to run in the new pane' },
            direction: { type: 'string', enum: ['right', 'down'] },
          },
        },
      })
      await $.tool.register({
        name: 'read_pane',
        description:
          'Read the recent output of a pane you opened with open_pane. Only panes this session opened can be read.',
        inputSchema: {
          type: 'object',
          properties: {
            pane: { type: 'string', description: 'The id open_pane returned' },
            lines: { type: 'integer', minimum: 1, maximum: 400 },
          },
          required: ['pane'],
        },
      })
  }
}

// MARK: - Rate-limit warning band

// A row above the prompt once a rate-limit window is nearly spent. Claude Code
// says so too; what this adds is the way out that only Zetty has, a new pane
// on another account.
const LIMIT_WARN_PERCENT = 90
const MAX_ACCOUNT_BUTTONS = 3

const limits = atom({ plugin: 'zetty-bridge', key: 'limits' } as const, [])
const dismissed = atom({ plugin: 'zetty-bridge', key: 'dismissed' } as const, [])
const accounts = atom({ plugin: 'zetty-bridge', key: 'accounts' } as const, [])

async function startBand($: EngineInterface): Promise<void> {
  if (!(await $.env.get('ZETTY'))) return
  const listed = await zetty($, ['accounts', '--json'])
  if (!listed.ok) return
  const names = otherAccounts(
    listed.out, (await $.env.get('CLAUDE_CONFIG_DIR')) ?? '~/.claude', (await $.env.get('HOME')) ?? '')
  await update($, accounts, () => names)
}

// Stored only when a window moved a whole point: every write redraws the band.
async function recordLimits($: EngineInterface, measured: Usage): Promise<void> {
  const next = measured.rateLimits.map(limit => ({
    kind: limit.kind, percentUsed: Math.round(limit.percentUsed), resetsAt: limit.resetsAt,
  }))
  if (JSON.stringify(next) === JSON.stringify(await read($, limits))) return
  await update($, limits, () => next)
  // A dismissal lasts while its window stays near the limit; once it clears,
  // crossing again is news.
  const stillNear = new Set(next.filter(l => l.percentUsed >= LIMIT_WARN_PERCENT).map(l => l.kind))
  await update($, dismissed, kinds => kinds.filter(kind => stillNear.has(kind)))
}

async function openOnAccount($: EngineInterface, account: string): Promise<void> {
  const me = await paneID($)
  if (me === undefined) return
  const split = await zetty($, ['split', '--pane', me, '--account', account, '--focus'])
  $.ui.toast(split.ok ? `Opened a pane on ${account}` : split.out)
}

// MARK: - Fleet sidebar

// A docked list of this project's panes, opened only by `/zetty fleet`. Claude
// Code shows one session; what Zetty knows is the others beside it.
const FLEET = 'zetty-fleet'
const fleet = atom({ plugin: 'zetty-bridge', key: 'fleet' } as const, null)

async function refreshFleet($: EngineInterface): Promise<boolean> {
  const status = await zetty($, ['status', '--json'])
  const found = status.ok ? projectPanes(status.out, await paneID($)) : undefined
  await update($, fleet, () => found ?? null)
  return found !== undefined
}

// MARK: - Hooks

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    turn = { state: 'idle' }
    await publish($)
    // Never let one piece failing to start cost the others, or the session.
    await startCommands($).catch(() => {})
    await startTools($).catch(() => {})
    await startBand($).catch(() => {})
    return started
  })

  on('turn.start', async ($, e, next) => {
    const started = await next(e)
    turn = { state: 'running' }
    attention = undefined
    await publish($)
    return started
  })

  on('turn.complete', async ($, e, next) => {
    const completed = await next(e)
    // A subagent's run is a turn too; only the main loop decides the pane's state.
    if (e.agentId === undefined) {
      turn = { state: 'idle', reason: e.reason, durationMs: e.durationMs }
      attention = undefined
      await publish($)
    }
    return completed
  })

  // Written BEFORE `next`: the settings hook beneath is what raises
  // needs-attention in Zetty, which reads this file the moment it does.
  on('classic.Notification', async ($, e, next) => {
    attention = { message: e.message, type: e.notification_type }
    await publish($)
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    const measured = await next(e)
    await publish($, e)
    await recordLimits($, e).catch(() => {})
    return measured
  })

  on('session.end', async ($, e, next) => {
    const ended = await next(e)
    // After a /clear the process goes on under a new session id.
    turn = e.reason === 'clear' ? { state: 'idle' } : { state: 'ended', reason: e.reason }
    await publish($)
    return ended
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const warning = limitWarning(
      await read($, limits), await read($, dismissed), LIMIT_WARN_PERCENT, await $.clock.now())
    if (warning === undefined) return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    const others = (await read($, accounts)).slice(0, MAX_ACCOUNT_BUTTONS)

    return (
      <Box>
        <Text color="yellow">{warning.text} </Text>
        {others.map((account, index) => (
          <Button
            key={`account-${index}`}
            label={`New pane on ${account}`}
            onPress={() => openOnAccount($, account)}
          />
        ))}
        <Button
          key="dismiss"
          label="Dismiss"
          onPress={() => update($, dismissed, kinds => [...kinds, warning.kind])}
        />
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: FLEET }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const listed = await read($, fleet)

    return (
      <Box flexDirection="column">
        {listed === null && <Text dimColor>Not in a Zetty project.</Text>}
        {listed !== null && <Text dimColor>{listed.project}</Text>}
        {(listed?.panes ?? []).map((pane, index) => (
          <Button
            key={`pane-${index}`}
            plain
            label={fleetLabel(pane)}
            onPress={async () => {
              if (!pane.isMe) await zetty($, ['focus', '--pane', pane.id])
            }}
          />
        ))}
        <Button key="refresh" label="Refresh" onPress={async () => { await refreshFleet($) }} />
        <Button key="close" label="Close" role="dismiss" onPress={() => $.ui.close({ id: FLEET })} />
      </Box>
    )
  })

  on('command.run', { command: 'zetty' }, async ($, e) => {
    const [verb = '', ...rest] = e.args.trim().split(/\s+/)
    switch (verb) {
      case 'panes':
        return { text: (await listPanes($)).text }
      case 'fleet': {
        if (!(await refreshFleet($))) return { text: 'Could not find this pane in the Zetty workspace.' }
        await $.ui.open({ id: FLEET, title: 'Zetty panes' })
        return { text: 'Opened the Zetty panes sidebar.' }
      }
      case 'peek': {
        const path = rest.join(' ')
        if (path === '') return { text: USAGE }
        const viewed = await zetty($, ['view', path])
        return { text: viewed.ok ? `Opened ${path} in the viewer.` : viewed.out }
      }
      case 'split': {
        const down = rest[0] === '--down'
        const command = (down ? rest.slice(1) : rest).join(' ')
        return { text: (await openPane($, { down, command })).text }
      }
      default:
        return { text: USAGE }
    }
  })

  on('tool.call', { tool: 'mcp__zetty-bridge__show_file' }, async ($, e) => {
    const input = e as unknown as { path?: unknown; line?: unknown }
    const path = text(input.path)
    if (path === '') return { deny: 'show_file needs a path.' }
    const target = typeof input.line === 'number' ? `${path}:${Math.floor(input.line)}` : path
    const viewed = await zetty($, ['view', target])
    return viewed.ok ? { result: `Opened ${target} in the Zetty viewer.` } : { deny: viewed.out }
  })

  on('tool.call', { tool: 'mcp__zetty-bridge__list_panes' }, async $ => {
    const listed = await listPanes($)
    return listed.ok ? { result: listed.text } : { deny: listed.text }
  })

  on('tool.call', { tool: 'mcp__zetty-bridge__open_pane' }, async ($, e) => {
    const input = e as unknown as { command?: unknown; direction?: unknown }
    const done = await openPane($, { down: input.direction === 'down', command: text(input.command) })
    if (done.pane !== undefined) opened.add(done.pane)
    return done.ok ? { result: done.text } : { deny: done.text }
  })

  on('tool.call', { tool: 'mcp__zetty-bridge__read_pane' }, async ($, e) => {
    const input = e as unknown as { pane?: unknown; lines?: unknown }
    const pane = text(input.pane)
    if (!opened.has(pane)) {
      return { deny: `read_pane only reads panes this session opened with open_pane; ${pane || 'that'} is not one.` }
    }
    const lines = typeof input.lines === 'number' ? Math.min(400, Math.max(1, Math.floor(input.lines))) : 80
    const captured = await zetty($, ['capture', '--pane', pane, '--lines', String(lines)])
    return captured.ok ? { result: captured.out } : { deny: captured.out }
  })
}
