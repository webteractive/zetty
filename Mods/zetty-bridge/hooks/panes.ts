// Pure helpers: no engine access, so they can live outside the hooks module.
// (The engine follows `$` only inside ONE file, so everything that touches it
// is in register.ts.)

export const UUID = /^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$/

export type Pane = {
  id: string
  title: string
  cwd: string
  tool?: string
  agentStatus?: string
  tab: string
  isMe: boolean
}

// The panes of the project this pane belongs to, from `zetty status --json`.
// Only that project: the rest of the workspace is not this session's business.
export function projectPanes(statusJSON: string, me: string | undefined): {
  project: string
  /** The directory this project was cloned from, when it is a clone. */
  cloneOf?: string
  panes: Pane[]
} | undefined {
  let status: unknown
  try {
    status = JSON.parse(statusJSON)
  } catch {
    return undefined
  }
  const projects = (status as { projects?: unknown }).projects
  if (!Array.isArray(projects) || me === undefined) return undefined
  for (const project of projects) {
    const tabs: unknown[] = Array.isArray(project?.tabs) ? project.tabs : []
    const panes: Pane[] = []
    for (const tab of tabs as { title?: string; panes?: unknown[] }[]) {
      for (const pane of (Array.isArray(tab.panes) ? tab.panes : []) as Record<string, unknown>[]) {
        if (typeof pane.id !== 'string') continue
        panes.push({
          id: pane.id,
          title: typeof pane.title === 'string' ? pane.title : '',
          cwd: typeof pane.cwd === 'string' ? pane.cwd : '',
          tool: typeof pane.tool === 'string' ? pane.tool : undefined,
          agentStatus: typeof pane.agentStatus === 'string' ? pane.agentStatus : undefined,
          tab: typeof tab.title === 'string' ? tab.title : '',
          isMe: pane.id === me,
        })
      }
    }
    if (panes.some(pane => pane.isMe)) {
      return {
        project: typeof project.name === 'string' ? project.name : '',
        cloneOf: typeof project.cloneOf === 'string' ? project.cloneOf : undefined,
        panes,
      }
    }
  }
  return undefined
}

// One row of the fleet sidebar: a glyph for what the pane is doing, then what
// it is. The glyphs are text because the sidebar is drawn in a terminal.
export function fleetLabel(pane: Pane): string {
  const glyph =
    pane.agentStatus === 'needsAttention' ? '!'
      : pane.agentStatus === 'errored' ? 'x'
        : pane.agentStatus === 'running' ? '*'
          : pane.tool !== undefined ? '-' : ' '
  const what = pane.tool ?? 'shell'
  const name = pane.title !== '' ? pane.title : pane.cwd
  return `${glyph} ${what}: ${name}${pane.isMe ? ' (this pane)' : ''}`
}

export function describePanes(found: { project: string; panes: Pane[] }): string {
  const lines = found.panes.map(pane => {
    const what = pane.tool ?? 'shell'
    const status = pane.agentStatus !== undefined ? ` (${pane.agentStatus})` : ''
    const me = pane.isMe ? '  <- this pane' : ''
    return `${pane.id}  ${what}${status}  ${pane.title || pane.cwd}${me}`
  })
  return [`Project ${found.project}: ${found.panes.length} pane(s)`, ...lines].join('\n')
}

// The last path component, which is how a clone's source is named in a row.
export function baseName(path: string): string {
  return path.replace(/\/+$/, '').split('/').pop() ?? path
}

// MARK: - Rate-limit warning

export type LimitLike = { kind: string; percentUsed: number; resetsAt?: string }

const WINDOW_NAMES: Record<string, string> = {
  five_hour: '5-hour limit',
  seven_day: '7-day limit',
  spend_limit: 'Spend limit',
}

// "1h 20m", "45m", "3d 2h" — a wait, at the precision a glance needs.
export function waitText(ms: number): string {
  const minutes = Math.max(1, Math.round(ms / 60_000))
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return minutes % 60 === 0 ? `${hours}h` : `${hours}h ${minutes % 60}m`
  return hours % 24 === 0 ? `${Math.floor(hours / 24)}d` : `${Math.floor(hours / 24)}d ${hours % 24}h`
}

// The window worth warning about: the fullest one at or past `threshold` that
// has not been dismissed. undefined when none is, which is nearly always.
export function limitWarning(
  limits: readonly LimitLike[],
  dismissed: readonly string[],
  threshold: number,
  now: number,
): { kind: string; text: string } | undefined {
  const near = limits
    .filter(limit => limit.percentUsed >= threshold && !dismissed.includes(limit.kind))
    .sort((a, b) => b.percentUsed - a.percentUsed)[0]
  if (near === undefined) return undefined
  const name = WINDOW_NAMES[near.kind] ?? near.kind
  const resets = near.resetsAt !== undefined ? Date.parse(near.resetsAt) : NaN
  const wait = Number.isFinite(resets) && resets > now ? ` · resets in ${waitText(resets - now)}` : ''
  return { kind: near.kind, text: `${name} ${Math.round(near.percentUsed)}% used${wait}` }
}

// Other Claude accounts from `zetty accounts --json`: every one whose config
// directory is not the one this session runs under.
export function otherAccounts(accountsJSON: string, currentDirectory: string, home: string): string[] {
  let parsed: unknown
  try {
    parsed = JSON.parse(accountsJSON)
  } catch {
    return []
  }
  const expand = (path: string) => (path.startsWith('~') ? home + path.slice(1) : path).replace(/\/$/, '')
  const list = (parsed as { accounts?: unknown }).accounts
  if (!Array.isArray(list)) return []
  return (list as Record<string, unknown>[])
    .filter(account => account.agent === 'claude' && typeof account.name === 'string'
      && typeof account.directory === 'string'
      && expand(account.directory) !== expand(currentDirectory))
    .map(account => account.name as string)
}
