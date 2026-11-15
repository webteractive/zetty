import type { On, SessionUsage } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const SURFACE = '0A1B2C3D-1111-2222-3333-444455556666'
const USAGE: SessionUsage = {
  startedAt: 0,
  context: { tokens: 50_000, window: 200_000, percent: 25 },
  rateLimits: [{ kind: 'five_hour', percentUsed: 12.5 }],
  cost: { usd: 1.25 },
}

type Written = { path: string; snapshot: Record<string, any> }

// Stands for the engine beneath the mod: answers what it reads, keeps what it writes.
type Hooks = {
  // The clock, when a test moves it; otherwise it stands at 1000.
  now?: () => number
  // Run beneath the mod's turn hooks, to see what it wrote first.
  onTurnStart?: () => void
  onTurnComplete?: () => void
}

function world(on: On, env: Record<string, string>, hooks: Hooks = {}): Written[] {
  const written: Written[] = []
  mock.env(on, env)
  if (hooks.now) {
    const now = hooks.now
    on('clock.now', () => ({ value: now() }))
  } else {
    mock.clock(on, { now: 1000 })
  }
  on('session.id', () => ({ value: 'sess-1' }))
  on('session.cwd', () => ({ value: '/work/app' }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.usage', () => ({ value: USAGE }))
  on('fs.write', (_$, e) => {
    written.push({ path: e.path, snapshot: JSON.parse(e.text) })
    return { value: undefined }
  })
  on('turn.start', (_$, e) => { hooks.onTurnStart?.(); return { turnId: e.turnId } })
  on('turn.complete', (_$, e) => { hooks.onTurnComplete?.(); return { text: e.answer } })
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  return written
}

const IN_PANE = { ZETTY: '1', HOME: '/Users/me', ZETTY_SURFACE: SURFACE }

test('a turn writes running, then idle with why it ended', async ($, on) => {
  const written = world(on, IN_PANE)

  await $.turn.start({ text: 'hi', turnId: 't1' })
  await $.turn.complete({
    answer: 'done', durationMs: 4200, isAborted: false, turnId: 't1', reason: 'answer',
  })

  expect(written.length).toBe(2)
  expect(written[0]?.path).toBe(`/Users/me/.zetty/agent-usage/${SURFACE}.json`)
  expect(written[0]?.snapshot.turn).toEqual({ state: 'running', at: 1000 })
  expect(written[1]?.snapshot.turn).toEqual({ state: 'idle', reason: 'answer', durationMs: 4200, at: 1000 })
  expect(written[1]?.snapshot).toEqual(expect.objectContaining({
    v: 1, agent: 'claude', surface: SURFACE, session: 'sess-1', cwd: '/work/app',
    config: '', model: 'claude-opus-5-5', costUSD: 1.25, updatedAt: 1000,
    context: { tokens: 50_000, window: 200_000, percent: 25 },
    rateLimits: [{ kind: 'five_hour', percentUsed: 12.5 }],
  }))
})

test('a notification is written before the hooks beneath run, and a new turn clears it', async ($, on) => {
  const written = world(on, IN_PANE)
  let writtenWhenBeneathRan = -1
  on('classic.Notification', () => {
    writtenWhenBeneathRan = written.length
    return {}
  })

  await $.classic.Notification({
    message: 'Claude needs your permission to use Bash', notification_type: 'permission_prompt',
  })

  expect(writtenWhenBeneathRan).toBe(1)
  expect(written[0]?.snapshot.attention).toEqual({
    message: 'Claude needs your permission to use Bash', type: 'permission_prompt',
  })

  await $.turn.start({ text: 'ok', turnId: 't1' })
  expect(written[1]?.snapshot.attention).toBe(undefined)
})

test('a subagent finishing leaves the pane running', async ($, on) => {
  const written = world(on, IN_PANE)

  await $.turn.start({ text: 'hi', turnId: 't1' })
  await $.turn.complete({
    answer: 'sub', durationMs: 10, isAborted: false, turnId: 't2', reason: 'answer', agentId: 'a1',
  })

  expect(written.length).toBe(1)
  expect(written[0]?.snapshot.turn.state).toBe('running')
})

test('a measurement writes the figures it carried', async ($, on) => {
  const written = world(on, { ...IN_PANE, CLAUDE_CONFIG_DIR: '/Users/me/.zetty/accounts/work' })

  await $.session.measure({
    context: { tokens: 150_000, window: 200_000, percent: 75 },
    rateLimits: [],
    cost: { usd: 3 },
    changed: ['context', 'cost'],
  })

  expect(written[0]?.snapshot.context.percent).toBe(75)
  expect(written[0]?.snapshot.costUSD).toBe(3)
  expect(written[0]?.snapshot.config).toBe('/Users/me/.zetty/accounts/work')
})

test('an older pane is found by its cwd file', async ($, on) => {
  const written = world(on, {
    ZETTY: '1', HOME: '/Users/me', ZETTY_CWD_FILE: `/Users/me/.zetty/panes/${SURFACE}.cwd`,
  })

  await $.turn.start({ text: '', turnId: 't1' })

  expect(written[0]?.snapshot.surface).toBe(SURFACE)
})

test('outside Zetty nothing is written', async ($, on) => {
  const written = world(on, { HOME: '/Users/me', ZETTY_SURFACE: SURFACE })
  await $.turn.start({ text: '', turnId: 't1' })
  expect(written.length).toBe(0)
})

test('a surface that is no uuid never becomes a path', async ($, on) => {
  const written = world(on, { ZETTY: '1', HOME: '/Users/me', ZETTY_SURFACE: '../../etc/x' })
  await $.turn.start({ text: '', turnId: 't1' })
  expect(written.length).toBe(0)
})

// Classic events reach the hooks beneath as `{}` unless a test listens.
function beneath(on: On, written: Written[], events: string[]): Record<string, number> {
  const seen: Record<string, number> = {}
  for (const name of events) {
    on(name as any, () => {
      seen[name] = written.length
      return {}
    })
  }
  return seen
}

test('a permission request writes waiting before the hooks beneath run', async ($, on) => {
  const written = world(on, IN_PANE)
  const seen = beneath(on, written, ['classic.PermissionRequest'])

  await $.turn.start({ text: 'hi', turnId: 't1' })
  await $.classic.PermissionRequest({
    session_id: 's', transcript_path: '/t', cwd: '/work/app', hook_event_name: 'PermissionRequest',
    tool_name: 'Bash', tool_input: { command: 'rm -rf build' },
  } as any)

  expect(seen['classic.PermissionRequest']).toBe(2)
  expect(written[1]?.snapshot.turn.state).toBe('waiting')
  expect(written[1]?.snapshot.attention?.type).toBe('permission_prompt')
  expect(written[1]?.snapshot.attention?.message).toContain('Bash')
  // Notification Center keeps what it shows; a command can hold a secret.
  expect(written[1]?.snapshot.attention?.message).not.toContain('rm -rf build')
})

test('a tool call after an approval writes running', async ($, on) => {
  const written = world(on, IN_PANE)
  beneath(on, written, ['classic.PermissionRequest', 'classic.PostToolUse'])

  // PreToolUse runs the same code; its envelope can't be fired from a test.
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: {} } as any)
  await $.classic.PostToolUse({ tool_name: 'Bash', tool_input: {}, tool_use_id: 'u1' } as any)

  expect(written.length).toBe(2)
  expect(written[1]?.snapshot.turn.state).toBe('running')
  expect(written[1]?.snapshot.attention).toBe(undefined)
})

test('tool calls in a running turn do not rewrite the file', async ($, on) => {
  const written = world(on, IN_PANE)
  beneath(on, written, ['classic.PostToolUse'])

  await $.turn.start({ text: 'hi', turnId: 't1' })
  await $.classic.PostToolUse({ tool_name: 'Read', tool_input: {}, tool_use_id: 'u1' } as any)
  await $.classic.PostToolUse({ tool_name: 'Read', tool_input: {}, tool_use_id: 'u2' } as any)

  expect(written.length).toBe(1)
})

test('an idle prompt does not change the turn state', async ($, on) => {
  const written = world(on, IN_PANE)
  beneath(on, written, ['classic.Notification'])

  await $.turn.start({ text: 'hi', turnId: 't1' })
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
  await $.classic.Notification({ message: 'Claude is waiting for your input', notification_type: 'idle_prompt' })

  expect(written[written.length - 1]?.snapshot.turn.state).toBe('idle')
})

test('a failed turn is idle with an error', async ($, on) => {
  const written = world(on, IN_PANE)
  beneath(on, written, ['classic.StopFailure'])

  await $.turn.start({ text: 'hi', turnId: 't1' })
  await $.classic.StopFailure({ error: 'server_error' } as any)

  expect(written[1]?.snapshot.turn).toEqual(expect.objectContaining({ state: 'idle', reason: 'error' }))
})

test('every transition carries its time', async ($, on) => {
  let now = 1000
  const written = world(on, IN_PANE, { now: () => now })

  await $.turn.start({ text: 'hi', turnId: 't1' })
  expect(written[0]?.snapshot.turn.at).toBe(1000)

  now = 5000
  await $.session.measure({
    context: { tokens: 1, window: 200_000, percent: 0 }, rateLimits: [], cost: { usd: 0 }, changed: ['cost'],
  })
  expect(written[1]?.snapshot.turn.at).toBe(1000)

  now = 9000
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
  expect(written[2]?.snapshot.turn.at).toBe(9000)
})

test('the turn state is written before the hooks beneath run', async ($, on) => {
  let atStart = -1
  let atComplete = -1
  const written: Written[] = world(on, IN_PANE, {
    onTurnStart: () => { atStart = written.length },
    onTurnComplete: () => { atComplete = written.length },
  })

  await $.turn.start({ text: 'hi', turnId: 't1' })
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })

  expect(atStart).toBe(1)
  expect(atComplete).toBe(2)
})

test('a parallel subagent\'s tool call leaves another loop\'s prompt waiting', async ($, on) => {
  const written = world(on, IN_PANE)
  beneath(on, written, ['classic.PermissionRequest', 'classic.PostToolUse'])

  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: {}, agent_id: 'agent-a' } as any)
  expect(written[written.length - 1]?.snapshot.turn).toEqual(expect.objectContaining({ state: 'waiting', loop: 'agent-a' }))

  await $.classic.PostToolUse({ tool_name: 'Read', tool_input: {}, tool_use_id: 'u1', agent_id: 'agent-b' } as any)
  expect(written[written.length - 1]?.snapshot.turn.state).toBe('waiting')

  await $.classic.PostToolUse({ tool_name: 'Bash', tool_input: {}, tool_use_id: 'u2', agent_id: 'agent-a' } as any)
  expect(written[written.length - 1]?.snapshot.turn.state).toBe('running')
})

test('a session start stamps its time', async ($, on) => {
  const written = world(on, IN_PANE)
  on('session.start', (_$, e) => ({ cwd: (e as any).cwd }))
  await $.session.start({ source: 'startup', cwd: '/work/app' } as any)
  expect(written[0]?.snapshot.turn).toEqual({ state: 'idle', at: 1000 })
})

test('a session end clears what it was asking', async ($, on) => {
  const written = world(on, IN_PANE)
  beneath(on, written, ['classic.PermissionRequest'])
  on('session.end', () => ({ sessionId: 'sess-1' }))

  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: {} } as any)
  await $.session.end({ reason: 'prompt_input_exit' } as any)

  expect(written[written.length - 1]?.snapshot.attention).toBe(undefined)
})
