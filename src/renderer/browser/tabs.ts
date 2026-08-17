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
  /**
   * True while Chromium's own error document is what the native view holds.
   *
   * Not `error !== null`, which is a different question with the same-looking
   * answer: a blocked pop-up sets a message over a page that is still perfectly
   * readable. Only this one may hide the view and put the start page there.
   */
  failed: boolean
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

/**
 * What a page with no name of its own is called, in this renderer.
 *
 * A second copy of `NEW_TAB_LABEL` in `src/main/browser-url.ts`, because the
 * renderer cannot import from `src/main`. The test file pins them equal by
 * reading the other one off disk, which is the only way two copies of a
 * user-visible string stay one string.
 */
export const NEW_TAB_LABEL = 'New tab'

/**
 * The address a tab holds before it has been anywhere.
 *
 * Also spelled out in `src/main/browser-url.ts` as `BLANK_URL`, and for the
 * same reason.
 */
export const BLANK_URL = 'about:blank'

export function newTab(key: string, url = '', isolated = false): WorkspaceTab {
  return {
    key,
    id: null,
    url: '',
    label: NEW_TAB_LABEL,
    title: '',
    loading: false,
    canGoBack: false,
    canGoForward: false,
    inspecting: false,
    error: null,
    failed: false,
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

/**
 * What a browser page is called.
 *
 * The page's own title first, because that is what the user recognises, then
 * the host, and only then a placeholder — a sidebar of rows all reading "New
 * tab" is a sidebar you cannot use.
 *
 * A title of `about:blank` is not a title. `webContents.getTitle()` returns the
 * address when a document has no `<title>`, so the app's own start page arrived
 * here calling itself `about:blank` and this function passed it straight
 * through to the sidebar row, the tab strip, the pane bar and their tooltips.
 * `pageTitle` in `src/main/browser-url.ts` now drops it at the source; this is
 * the backstop, and it is not decorative — `patchFrom` in `BrowserWorkspace`
 * already carries a field that "older main processes did not send", so a
 * renderer talking to a main process older than that fix is a real arrangement
 * in this app rather than a hypothetical one.
 */
export function tabTitle(tab: WorkspaceTab): string {
  const title = tab.title.trim()
  const named = title && title !== BLANK_URL && title !== tab.url.trim() ? title : ''
  return named || tab.label.trim() || NEW_TAB_LABEL
}
