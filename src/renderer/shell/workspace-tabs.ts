import type { SessionStatus } from '@shared/types'

/**
 * A tab in the top header.
 *
 * Sessions and browsers live in ONE strip rather than a tab bar plus a
 * separate view switcher: a browser window is a window you opened, exactly
 * like a session is, and splitting them into two controls meant the switcher
 * read as a caption and the browser was effectively unreachable.
 *
 * Overview and Board are singletons — opening one twice focuses the existing
 * tab instead of stacking duplicates that show identical content.
 */
/**
 * Only the things that are a *window you opened*.
 *
 * Overview and Board are views of the current project, not windows, so they
 * live on the side rail. Mixing them into the tab strip meant the strip stopped
 * answering "what do I have open".
 */
export type TabKind = 'session' | 'browser'

export interface WorkspaceTab {
  id: string
  kind: TabKind
  label: string
  /** Sessions only; drives the coloured dot. */
  status?: SessionStatus
  /** Sessions only — the project the session runs in. */
  projectPath?: string
  /** True for tabs the user can close. */
  closable: boolean
}

export const SINGLETON_KINDS: readonly TabKind[] = []

export function isSingleton(kind: TabKind): boolean {
  return SINGLETON_KINDS.includes(kind)
}

/** Stable ids for the singletons so they can be found without a lookup table. */
export function singletonId(kind: TabKind): string {
  return `view:${kind}`
}

export const KIND_LABEL: Record<TabKind, string> = {
  session: 'Session',
  browser: 'Browser',
}

/** 15x15 icon path per kind, matching the rail's visual weight. */
export const KIND_ICON: Record<TabKind, string> = {
  session: 'M4 17l6-6-6-6M12 19h8',
  browser: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.6 2.5 15.4 0 18M12 3c-2.5 2.6-2.5 15.4 0 18',
}

/**
 * What to call a session on screen.
 *
 * A session starts out titled after the folder it runs in, and it is listed
 * *under* that folder in the sidebar and beside its siblings in the swarm — so
 * the untitled case printed the project's name three times down one column and
 * again across every cell of the grid. Once the agent has named the session,
 * that name is what is worth reading.
 *
 * `folderName` is optional because the swarm and the orphan list have no
 * project heading above them to be redundant with.
 */
export function sessionLabel(title: string, index: number, folderName?: string): string {
  return title && title !== folderName ? title : `Session ${index + 1}`
}

/**
 * Which tab should take focus after `closingId` goes away.
 *
 * Falls to the right neighbour, then the left, then nothing — the same rule
 * every tabbed editor uses, so closing a run of tabs walks predictably instead
 * of jumping back to the first one each time.
 */
export function nextActiveId(tabs: WorkspaceTab[], closingId: string): string | null {
  const index = tabs.findIndex((t) => t.id === closingId)
  if (index === -1) return tabs[0]?.id ?? null
  const remaining = tabs.filter((t) => t.id !== closingId)
  if (remaining.length === 0) return null
  return remaining[index]?.id ?? remaining[index - 1]?.id ?? remaining[0].id
}
