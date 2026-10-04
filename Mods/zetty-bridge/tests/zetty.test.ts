import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

import { describePanes, projectPanes } from '../hooks/panes'

const SURFACE = '0A1B2C3D-1111-2222-3333-444455556666'
const BIN = '/Applications/zetty.app/Contents/MacOS/zetty'
const IN_PANE = { ZETTY: '1', HOME: '/Users/me', ZETTY_SURFACE: SURFACE, ZETTY_BIN: BIN }

const STATUS = JSON.stringify({
  projects: [
    { name: 'other', tabs: [{ title: 't', panes: [{ id: 'ffffffff', title: 'secret', cwd: '/x' }] }] },
    {
      name: 'app',
      tabs: [
        { title: 'main', panes: [{ id: '0a1b2c3d', title: 'claude', cwd: '/work/app', tool: 'claude', agentStatus: 'running' }] },
        { title: 'srv', panes: [{ id: '99999999', title: 'npm run dev', cwd: '/work/app' }] },
      ],
    },
  ],
})

type Run = { argv: readonly string[] }

// Stands for the engine beneath the mod: answers the reads, and stands in for
// the zetty CLI, keeping every command line it was asked to run.
function world(on: On, env: Record<string, string>, answer: (argv: readonly string[]) => string = () => '') {
  const runs: Run[] = []
  const registered: { commands: string[]; tools: string[] } = { commands: [], tools: [] }
  mock.env(on, env)
  mock.clock(on, { now: 1000 })
  on('session.id', () => ({ value: 'sess-1' }))
  on('session.cwd', () => ({ value: '/work/app' }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 200_000 }, rateLimits: [] } }))
  on('fs.write', () => ({ value: undefined }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('command.register', (_$, e) => {
    registered.commands.push(e.name)
    return { value: { command: e.name } }
  })
  on('tool.register', (_$, e) => {
    registered.tools.push(e.name)
    return { value: { tool: `mcp__zetty-bridge__${e.name}` } }
  })
  on('process.run', (_$, e) => {
    runs.push({ argv: e.argv })
    return { value: { exitCode: 0, stdout: answer(e.argv), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  return { runs, registered }
}

const START = { cwd: '/work/app', surface: 'terminal' as const, isInteractive: true }
const cli = (run: Run | undefined) => run?.argv.slice(1).join(' ')

test('only the project this pane is in is listed', () => {
  const found = projectPanes(STATUS, '0a1b2c3d')
  expect(found?.project).toBe('app')
  expect(found?.panes.map(pane => pane.id)).toEqual(['0a1b2c3d', '99999999'])
  expect(describePanes(found!)).toBe(
    'Project app: 2 pane(s)\n0a1b2c3d  claude (running)  claude  <- this pane\n99999999  shell  npm run dev',
  )
  expect(projectPanes(STATUS, 'nope')).toBe(undefined)
  expect(projectPanes('not json', '0a1b2c3d')).toBe(undefined)
})

test('inside Zetty the command and the tools are registered', async ($, on) => {
  const { registered } = world(on, IN_PANE)
  await $.session.start(START)
  expect(registered.commands).toEqual(['zetty'])
  expect(registered.tools).toEqual(['show_file', 'list_panes', 'open_pane', 'read_pane'])
})

test('outside Zetty nothing is registered, and the tools can be switched off', async ($, on) => {
  const { registered } = world(on, { HOME: '/Users/me' })
  await $.session.start(START)
  expect(registered.commands).toEqual([])
  expect(registered.tools).toEqual([])
})

test('zetty-claude-tools = false keeps the command and drops the tools', async ($, on) => {
  const { registered } = world(on, { ...IN_PANE, ZETTY_CLAUDE_TOOLS: '0' })
  await $.session.start(START)
  expect(registered.commands).toEqual(['zetty'])
  expect(registered.tools).toEqual([])
})

const RUN = { origin: { kind: 'composer' as const }, presentation: { isFullscreen: true, columns: 120 } }

test('/zetty peek opens the file in the viewer', async ($, on) => {
  const { runs } = world(on, IN_PANE)
  const ran = await $.command.run({ command: 'zetty', args: 'peek src/main.swift:42', ...RUN })
  expect(runs[0]?.argv[0]).toBe(BIN)
  expect(cli(runs[0])).toBe('view src/main.swift:42')
  expect(ran.text).toBe('Opened src/main.swift:42 in the viewer.')
})

test('/zetty split opens a pane beside this one and runs the command in it', async ($, on) => {
  const { runs } = world(on, IN_PANE, argv => (argv[1] === 'split' ? 'abcd1234\n' : ''))
  const ran = await $.command.run({ command: 'zetty', args: 'split --down npm run dev', ...RUN })
  expect(cli(runs[0])).toBe('split --pane 0a1b2c3d --horizontal')
  expect(cli(runs[1])).toBe('send --pane abcd1234 --enter npm run dev')
  expect(ran.text).toBe('Opened pane abcd1234 running: npm run dev')
})

test('/zetty with nothing it knows prints the usage', async ($, on) => {
  const { runs } = world(on, IN_PANE)
  const ran = await $.command.run({ command: 'zetty', args: '', ...RUN })
  expect(ran.text).toContain('Usage:')
  expect(runs.length).toBe(0)
})

test('the model can read a pane it opened, and no other', async ($, on) => {
  const { runs } = world(on, IN_PANE, argv =>
    argv[1] === 'split' ? 'abcd1234' : argv[1] === 'capture' ? 'ready on :3000' : '')

  const refused = await $.tool.call({ tool: 'mcp__zetty-bridge__read_pane', pane: '99999999' })
  expect(String(refused.deny ?? refused.text)).toContain('only reads panes this session opened')
  expect(runs.length).toBe(0)

  const opened = await $.tool.call({ tool: 'mcp__zetty-bridge__open_pane', command: 'npm run dev' })
  expect(opened.result).toBe('Opened pane abcd1234 running: npm run dev')

  const read = await $.tool.call({ tool: 'mcp__zetty-bridge__read_pane', pane: 'abcd1234', lines: 20 })
  expect(read.result).toBe('ready on :3000')
  expect(cli(runs.at(-1))).toBe('capture --pane abcd1234 --lines 20')
})

test('show_file adds the line, and list_panes answers for this project only', async ($, on) => {
  const { runs } = world(on, IN_PANE, argv => (argv[1] === 'status' ? STATUS : ''))
  const shown = await $.tool.call({ tool: 'mcp__zetty-bridge__show_file', path: 'README.md', line: 12 })
  expect(cli(runs[0])).toBe('view README.md:12')
  expect(shown.result).toBe('Opened README.md:12 in the Zetty viewer.')

  const listed = await $.tool.call({ tool: 'mcp__zetty-bridge__list_panes' })
  expect(String(listed.result)).toContain('Project app: 2 pane(s)')
  expect(String(listed.result)).not.toContain('secret')
})
