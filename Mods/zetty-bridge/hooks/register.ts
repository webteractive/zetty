import type { EngineInterface, Register, SessionUsage } from 'claude-code'

// Zetty bridge: keeps one snapshot per pane at
// ~/.zetty/agent-usage/<surface>.json, rewritten whole on every change.
// Only reports sessions hosted INSIDE Zetty (ZETTY=1 in the pane's
// environment), the same gate zetty-hook.py applies.

const SNAPSHOT_VERSION = 1
const UUID = /^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$/

type Turn = {
  state: 'running' | 'idle' | 'ended'
  // Why the last turn ended (answer, aborted, refusal, error) or the session did.
  reason?: string
  durationMs?: number
}

type Usage = Pick<SessionUsage, 'context' | 'rateLimits' | 'cost'>

let turn: Turn = { state: 'idle' }
// Events can land back to back; one write at a time keeps the file whole.
let writes: Promise<void> = Promise.resolve()

// ZETTY_SURFACE is injected per pane; ZETTY_CWD_FILE (<panes>/<uuid>.cwd)
// predates it and covers preserved sessions created before it existed.
async function surfaceID($: EngineInterface): Promise<string | undefined> {
  const explicit = await $.env.get('ZETTY_SURFACE')
  if (explicit !== undefined && UUID.test(explicit)) return explicit
  const cwdFile = await $.env.get('ZETTY_CWD_FILE')
  const stem = cwdFile?.split('/').pop()?.replace(/\.cwd$/, '')
  return stem !== undefined && UUID.test(stem) ? stem : undefined
}

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

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    turn = { state: 'idle' }
    await publish($)
    return started
  })

  on('turn.start', async ($, e, next) => {
    const started = await next(e)
    turn = { state: 'running' }
    await publish($)
    return started
  })

  on('turn.complete', async ($, e, next) => {
    const completed = await next(e)
    // A subagent's run is a turn too; only the main loop decides the pane's state.
    if (e.agentId === undefined) {
      turn = { state: 'idle', reason: e.reason, durationMs: e.durationMs }
      await publish($)
    }
    return completed
  })

  on('session.measure', async ($, e, next) => {
    const measured = await next(e)
    await publish($, e)
    return measured
  })

  on('session.end', async ($, e, next) => {
    const ended = await next(e)
    // After a /clear the process goes on under a new session id.
    turn = e.reason === 'clear' ? { state: 'idle' } : { state: 'ended', reason: e.reason }
    await publish($)
    return ended
  })
}
