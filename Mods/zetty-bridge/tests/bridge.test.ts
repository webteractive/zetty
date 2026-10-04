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
function world(on: On, env: Record<string, string>): Written[] {
  const written: Written[] = []
  mock.env(on, env)
  mock.clock(on, { now: 1000 })
  on('session.id', () => ({ value: 'sess-1' }))
  on('session.cwd', () => ({ value: '/work/app' }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.usage', () => ({ value: USAGE }))
  on('fs.write', (_$, e) => {
    written.push({ path: e.path, snapshot: JSON.parse(e.text) })
    return { value: undefined }
  })
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
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
  expect(written[0]?.snapshot.turn).toEqual({ state: 'running' })
  expect(written[1]?.snapshot.turn).toEqual({ state: 'idle', reason: 'answer', durationMs: 4200 })
  expect(written[1]?.snapshot).toEqual(expect.objectContaining({
    v: 1, agent: 'claude', surface: SURFACE, session: 'sess-1', cwd: '/work/app',
    config: '', model: 'claude-opus-5-5', costUSD: 1.25, updatedAt: 1000,
    context: { tokens: 50_000, window: 200_000, percent: 25 },
    rateLimits: [{ kind: 'five_hour', percentUsed: 12.5 }],
  }))
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
