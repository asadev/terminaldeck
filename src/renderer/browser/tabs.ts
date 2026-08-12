/**
 * The tab strip's model: which tabs exist, which one is showing, and what
 * happens to the selection when one goes away.
 *
 * Pure, because the interesting behaviour is not "a tab was added" — it is what
 * a browser does *around* the change, and every one of those rules is a
 * one-liner that is wrong in a way nobody notices until they are three tabs
 * deep. Closing the active tab should land on its right-hand neighbour, not on
 * the first tab and not on nothing. Reordering must not change which tab is
 * showing. A tab that has not been created in the main process yet still has to
 * hold a place in the strip, or the strip jumps as each one resolves.
 */

export interface WorkspaceTab {
  /**
   * Identity in the renderer, from the moment the tab appears in the strip.
   *
   * Separate from {@link id} because the main process's id arrives one IPC round
   * trip later, and a tab keyed on something that starts null cannot be
   * rendered, selected or closed in the meantime.
   */
  key: string
  /** The main-process tab id, or null until `browser:create` has resolved. */
  id: string | null
  url: string
  /** Host and path, as the main process shortens it for the strip. */
  label: string
  title: string
  loading: boolean
  canGoBack: boolean
  canGoForward: boolean
  inspecting: boolean
  error: string | null
  /** 0 to 1, from the main process's load milestones. */
  progress: number
  recording: boolean
  /** What is in this tab's URL bar while the user is editing it. */
  draft: string
  editing: boolean
  /**
   * On a partition of its own: no imported cookies, no other tab's logins.
   *
   * Kept here rather than read back from the main process because it is decided
   * *before* the view exists — the partition is fixed when the WebContents is
   * constructed and cannot be changed afterwards, which is also why switching it
   * replaces the tab rather than editing it.
   */
  isolated: boolean
  /** The partition key the main process minted, or null for a shared tab. */
  isolationKey: string | null
}

export function newTab(key: string, url = '', isolated = false): WorkspaceTab {
  return {
    key,
    id: null,
    url: '',
    label: 'New tab',
    title: '',
    loading: false,
    canGoBack: false,
    canGoForward: false,
    inspecting: false,
    error: null,
    progress: 0,
    recording: false,
    draft: url,
    editing: false,
    isolated,
    isolationKey: null,
  }
}

export function indexOfKey(tabs: WorkspaceTab[], key: string): number {
  return tabs.findIndex((tab) => tab.key === key)
}

export function tabForId(tabs: WorkspaceTab[], id: string): WorkspaceTab | null {
  return tabs.find((tab) => tab.id === id) ?? null
}

/** Patch one tab. Returns the same array when the key is unknown. */
export function withTab(
  tabs: WorkspaceTab[],
  key: string,
  patch: Partial<WorkspaceTab>,
): WorkspaceTab[] {
  const index = indexOfKey(tabs, key)
  if (index < 0) return tabs
  const next = [...tabs]
  next[index] = { ...next[index], ...patch }
  return next
}

/** Same, addressed by the main process's id — which is what events carry. */
export function withTabId(
  tabs: WorkspaceTab[],
  id: string,
  patch: Partial<WorkspaceTab>,
): WorkspaceTab[] {
  const tab = tabForId(tabs, id)
  return tab ? withTab(tabs, tab.key, patch) : tabs
}

/** Insert after the active tab, the way a browser opens one. */
export function openTab(
  tabs: WorkspaceTab[],
  tab: WorkspaceTab,
  afterKey: string | null,
): WorkspaceTab[] {
  const at = afterKey === null ? -1 : indexOfKey(tabs, afterKey)
  if (at < 0) return [...tabs, tab]
  return [...tabs.slice(0, at + 1), tab, ...tabs.slice(at + 1)]
}

/**
 * Remove a tab and say which one should be showing afterwards.
 *
 * The neighbour to the right, falling back to the left. Landing on the first
 * tab instead — which is what a naive `tabs[0]` does — throws the user across
 * the strip every time they close something.
 */
export function closeTab(
  tabs: WorkspaceTab[],
  key: string,
  activeKey: string,
): { tabs: WorkspaceTab[]; activeKey: string } {
  const index = indexOfKey(tabs, key)
  if (index < 0) return { tabs, activeKey }

  const next = tabs.filter((tab) => tab.key !== key)
  if (key !== activeKey) return { tabs: next, activeKey }
  if (next.length === 0) return { tabs: next, activeKey: '' }

  const neighbour = next[Math.min(index, next.length - 1)]
  return { tabs: next, activeKey: neighbour.key }
}

/** Move a tab to a position. Out-of-range targets clamp rather than throw. */
export function moveTab(tabs: WorkspaceTab[], key: string, toIndex: number): WorkspaceTab[] {
  const from = indexOfKey(tabs, key)
  if (from < 0) return tabs
  const to = Math.min(Math.max(0, Math.trunc(toIndex)), tabs.length - 1)
  if (to === from) return tabs

  const next = [...tabs]
  const [moved] = next.splice(from, 1)
  next.splice(to, 0, moved)
  return next
}

/** The next tab along, wrapping. Returns the current key when there is nowhere to go. */
export function cycle(tabs: WorkspaceTab[], activeKey: string, delta: number): string {
  if (tabs.length === 0) return ''
  const index = indexOfKey(tabs, activeKey)
  if (index < 0) return tabs[0].key
  const size = tabs.length
  return tabs[(((index + delta) % size) + size) % size].key
}

/**
 * What the strip writes on a tab.
 *
 * The page's own title first, because that is what the user recognises, then
 * the host, and only then a placeholder — a strip of tabs all reading "New tab"
 * is a strip you cannot use.
 */
export function tabTitle(tab: WorkspaceTab): string {
  return tab.title.trim() || tab.label.trim() || 'New tab'
}
