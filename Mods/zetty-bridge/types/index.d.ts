// The values the mod keeps in `$.state` for its drawing. The engine holds them
// for the session; a hot reload of the mod keeps them where module variables
// start over.

export type Limit = { kind: string; percentUsed: number; resetsAt?: string }

export type FleetPane = {
  id: string
  title: string
  cwd: string
  tool?: string
  agentStatus?: string
  tab: string
  isMe: boolean
}

export type Fleet = { project: string; panes: FleetPane[] }

declare module 'claude-code' {
  interface PluginState {
    'zetty-bridge': {
      /** The rate-limit windows last measured. */
      limits: Limit[]
      /** Window kinds whose warning the person dismissed, until they clear. */
      dismissed: string[]
      /** Other Claude accounts Zetty knows, by name: where a new pane can go. */
      accounts: string[]
      /** This project's panes as last listed, for the fleet sidebar. */
      fleet: Fleet | null
    }
  }
}
