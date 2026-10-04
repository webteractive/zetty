import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

import { limitWarning, otherAccounts, waitText } from '../hooks/panes'

const SURFACE = '0A1B2C3D-1111-2222-3333-444455556666'
const BIN = '/Applications/zetty.app/Contents/MacOS/zetty'
const ACCOUNTS = JSON.stringify({
  accounts: [
    { agent: 'claude', directory: '~/.zetty/accounts/work', name: 'Work' },
    { agent: 'claude', directory: '~/.zetty/accounts/home', name: 'Home' },
    { agent: 'codex', directory: '~/.zetty/accounts/cx', name: 'Codex one' },
  ],
})

test('a wait reads at the precision a glance needs', () => {
  expect(waitText(30_000)).toBe('1m')
  expect(waitText(45 * 60_000)).toBe('45m')
  expect(waitText(80 * 60_000)).toBe('1h 20m')
  expect(waitText(120 * 60_000)).toBe('2h')
  expect(waitText(50 * 3_600_000)).toBe('2d 2h')
})

test('only a window at the threshold warns, the fullest first, and not once dismissed', () => {
  const now = Date.parse('2026-10-04T05:00:00.000Z')
  const limits = [
    { kind: 'five_hour', percentUsed: 92, resetsAt: '2026-10-04T06:20:00.000Z' },
    { kind: 'seven_day', percentUsed: 96 },
  ]
  expect(limitWarning([{ kind: 'five_hour', percentUsed: 89 }], [], 90, now)).toBe(undefined)
  expect(limitWarning(limits, [], 90, now)).toEqual({ kind: 'seven_day', text: '7-day limit 96% used' })
  expect(limitWarning(limits, ['seven_day'], 90, now)).toEqual({
    kind: 'five_hour', text: '5-hour limit 92% used · resets in 1h 20m',
  })
  expect(limitWarning(limits, ['seven_day', 'five_hour'], 90, now)).toBe(undefined)
})

test('other accounts are the Claude ones this session is not running under', () => {
  expect(otherAccounts(ACCOUNTS, '/Users/me/.zetty/accounts/work', '/Users/me')).toEqual(['Home'])
  expect(otherAccounts(ACCOUNTS, '~/.claude', '/Users/me')).toEqual(['Work', 'Home'])
  expect(otherAccounts('nope', '~/.claude', '/Users/me')).toEqual([])
})

function world(on: On, runs: string[], status = '', toasts: string[] = []) {
  mock.env(on, {
    ZETTY: '1', HOME: '/Users/me', ZETTY_SURFACE: SURFACE, ZETTY_BIN: BIN,
    CLAUDE_CONFIG_DIR: '/Users/me/.zetty/accounts/work',
  })
  mock.clock(on, { now: Date.parse('2026-10-04T05:00:00.000Z') })
  on('session.id', () => ({ value: 'sess-1' }))
  on('session.cwd', () => ({ value: '/work/app' }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 200_000 }, rateLimits: [] } }))
  on('fs.write', () => ({ value: undefined }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('tool.register', (_$, e) => ({ value: { tool: `mcp__zetty-bridge__${e.name}` } }))
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  // What the engine draws when the mod has nothing to show: an empty band.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box />
  })
  on('process.run', (_$, e) => {
    runs.push(e.argv.slice(1).join(' '))
    const stdout = e.argv[1] === 'accounts' ? ACCOUNTS
      : e.argv[1] === 'split' ? 'abcd1234' : e.argv[1] === 'status' ? status : ''
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
}

const BAND = {
  plugin: 'zetty-bridge',
  component: 'AbovePrompt' as const,
  props: {
    hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 6, totalRows: 1 },
  },
}

const measure = (percent: number) => ({
  context: { window: 200_000 },
  rateLimits: [{ kind: 'five_hour', percentUsed: percent, resetsAt: '2026-10-04T06:20:00.000Z' }],
  changed: ['rateLimits' as const],
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`${surface}: the band appears near a limit, opens a pane on another account, and dismisses`, async ($, on) => {
    const runs: string[] = []
    world(on, runs)
    await $.session.start({ cwd: '/work/app', surface, isInteractive: true })

    await $.session.measure(measure(40))
    const quiet = await $.ui.mount({ ...BAND, surface })
    expect(await quiet.find({ type: 'Button' })).toBe(undefined)
    await quiet.unmount()

    await $.session.measure(measure(92))
    const ui = await $.ui.mount({ ...BAND, surface })
    expect(await ui.find({ type: 'Text', text: /5-hour limit 92% used · resets in 1h 20m/ })).toBeDefined()
    // Home only: Work is the account this session is on, and Codex is not Claude.
    expect((await ui.find({ key: 'account-0' }))?.text).toBe('New pane on Home')
    expect(await ui.find({ key: 'account-1' })).toBe(undefined)

    await ui.press({ key: 'account-0' })
    expect(runs.at(-1)).toBe('split --pane 0a1b2c3d --account Home --focus')

    await ui.press({ key: 'dismiss' })
    expect(await ui.find({ key: 'dismiss' })).toBe(undefined)
    await ui.unmount()
  })
}

const STATUS = JSON.stringify({
  projects: [{
    name: 'app',
    tabs: [
      { title: 'main', panes: [{ id: '0a1b2c3d', title: 'claude', cwd: '/work/app', tool: 'claude', agentStatus: 'running' }] },
      { title: 'srv', panes: [{ id: '99999999', title: 'review', cwd: '/work/app', tool: 'claude', agentStatus: 'needsAttention' }] },
    ],
  }],
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`${surface}: /zetty fleet lists this project's panes and a press goes to one`, async ($, on) => {
    const runs: string[] = []
    world(on, runs, STATUS)
    on('ui.open', () => ({ value: { isPlaced: true } }))

    const ran = await $.command.run({
      command: 'zetty', args: 'fleet',
      origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 },
    })
    expect(ran.text).toBe('Opened the Zetty panes sidebar.')

    const ui = await $.ui.mount({
      plugin: 'zetty-bridge', surface, component: 'Pane', requestId: 'zetty-fleet',
      props: {
        title: 'Zetty panes', isFocused: true, bodyColumns: 40, placement: 'dock',
        scroll: { offset: 0, bodyRows: 20, totalRows: 5 }, view: {},
      },
    })
    expect((await ui.find({ key: 'pane-0' }))?.text).toBe('* claude: claude (this pane)')
    expect((await ui.find({ key: 'pane-1' }))?.text).toBe('! claude: review')

    await ui.press({ key: 'pane-0' })   // this pane: nowhere to go
    expect(runs.some(run => run.startsWith('focus'))).toBe(false)
    await ui.press({ key: 'pane-1' })
    expect(runs.at(-1)).toBe('focus --pane 99999999')
    await ui.unmount()
  })
}

const CLONE_STATUS = JSON.stringify({
  projects: [{
    name: 'app/fix-1', cloneOf: '/work/app',
    tabs: [{ title: 'main', panes: [{ id: '0a1b2c3d', title: 'claude', cwd: '/c', tool: 'claude' }] }],
  }],
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`${surface}: in a clone the band offers merge and push, each behind a second press`, async ($, on) => {
    const runs: string[] = []
    const toasts: string[] = []
    world(on, runs, CLONE_STATUS, toasts)
    await $.session.start({ cwd: '/c', surface, isInteractive: true })

    const ui = await $.ui.mount({ ...BAND, surface })
    expect(await ui.find({ type: 'Text', text: /Clone of app/ })).toBeDefined()

    await ui.press({ key: 'clone-push' })
    expect(await ui.find({ type: 'Text', text: /Push app\/fix-1's branch to origin\?/ })).toBeDefined()
    expect(runs.some(run => run.startsWith('push-clone'))).toBe(false)   // not yet
    await ui.press({ key: 'clone-cancel' })
    expect(runs.some(run => run.startsWith('push-clone'))).toBe(false)

    await ui.press({ key: 'clone-merge' })
    await ui.press({ key: 'clone-confirm' })
    expect(runs.at(-1)).toBe('merge-clone app/fix-1')
    expect(toasts.at(-1)).toBe('Merged into the source.')   // the CLI printed nothing

    await ui.press({ key: 'clone-hide' })
    expect(await ui.find({ key: 'clone-merge' })).toBe(undefined)
    await ui.unmount()
  })
}

test('an ordinary project shows no clone band', async ($, on) => {
  const runs: string[] = []
  world(on, runs, STATUS)
  await $.session.start({ cwd: '/work/app', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await ui.find({ key: 'clone-merge' })).toBe(undefined)
  await ui.unmount()
})
