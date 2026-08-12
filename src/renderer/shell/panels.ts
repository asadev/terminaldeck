/** Single source of truth for the panel rail — icons, labels and shortcuts. */

export type PanelId =
  | 'projects'
  | 'overview'
  | 'board'
  | 'files'
  | 'search'
  | 'git'
  | 'github'
  | 'readiness'
  | 'alerts'
  | 'mcp'
  | 'hooks'

export interface PanelSpec {
  id: PanelId
  label: string
  /** SVG path data, drawn at 24x24. */
  icon: string
  shortcut?: string
}

export const PANELS: PanelSpec[] = [
  { id: 'projects', label: 'Projects', shortcut: '⌘1', icon: 'M3 7h6l2 2h10v9a2 2 0 0 1-2 2H3z M3 7V5a2 2 0 0 1 2-2h4l2 2' },
  // Views of the current project rather than windows, so they belong here
  // and not in the tab strip.
  { id: 'overview', label: 'Overview', icon: 'M4 4h7v7H4zM13 4h7v4h-7zM13 11h7v9h-7zM4 14h7v6H4z' },
  { id: 'board', label: 'Task board', icon: 'M4 5h4v14H4zM10 5h4v9h-4zM16 5h4v11h-4z' },
  { id: 'files', label: 'Files', shortcut: '⌘2', icon: 'M4 4h9l3 3v13H4z M13 4v3h3' },
  { id: 'search', label: 'Search sessions', shortcut: '⌘⇧F', icon: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14z M20 20l-4.2-4.2' },
  { id: 'git', label: 'Source control', shortcut: '⌘3', icon: 'M6 4v9a3 3 0 0 0 3 3h6 M6 20a2 2 0 1 0 0-4 2 2 0 0 0 0 4z M6 8a2 2 0 1 0 0-4 2 2 0 0 0 0 4z M18 18a2 2 0 1 0 0-4 2 2 0 0 0 0 4z' },
  { id: 'github', label: 'GitHub', icon: 'M12 3a9 9 0 0 0-2.8 17.5c.4.1.6-.2.6-.5v-2c-2.5.5-3-1.2-3-1.2-.4-1-1-1.3-1-1.3-.9-.6 0-.6 0-.6 1 .1 1.4 1 1.4 1 .9 1.5 2.4 1 3 .8.1-.6.3-1 .6-1.3-2-.2-4.1-1-4.1-4.4 0-1 .3-1.8.9-2.4-.1-.3-.4-1.2.1-2.4 0 0 .7-.3 2.5 1a8.6 8.6 0 0 1 4.5 0c1.8-1.3 2.5-1 2.5-1 .5 1.2.2 2.1.1 2.4.6.6.9 1.4.9 2.4 0 3.4-2.1 4.2-4.1 4.4.3.3.6.9.6 1.8v2.7c0 .3.2.6.6.5A9 9 0 0 0 12 3z' },
  { id: 'readiness', label: 'AI readiness', icon: 'M12 3l2.6 5.6 6.1.8-4.5 4.2 1.2 6-5.4-3-5.4 3 1.2-6L3.3 9.4l6.1-.8z' },
  { id: 'alerts', label: 'Alerts', icon: 'M12 4a6 6 0 0 0-6 6c0 4-2 5-2 5h16s-2-1-2-5a6 6 0 0 0-6-6z M10.5 20a1.8 1.8 0 0 0 3 0' },
  { id: 'mcp', label: 'MCP servers', icon: 'M5 7h14 M5 12h14 M5 17h14 M8 5v4 M16 10v4 M11 15v4' },
  { id: 'hooks', label: 'Hooks', icon: 'M9 5a3 3 0 1 1 6 0v9a4 4 0 1 1-8 0v-1' },
]
