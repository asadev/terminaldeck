import type { ProviderId, SessionStatus } from '@shared/types'
import { folderName } from '../session-title'

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
  /**
   * Sessions only — the account the session is signed in as.
   *
   * Absent when no account applies, which is a plain shell or an agent whose
   * config directory this app cannot redirect. Absent is not "the default": it
   * means there is nothing true to say, and a row that says nothing is better
   * than one that names an account the session is not actually isolated to.
   *
   * `provider` is the agent the session was launched as, carried here so the
   * account chip can draw that agent's mark beside the name without reading the
   * account list — which it only does when its menu is opened, because reading
   * it spawns a process per account.
   */
  account?: { id: string; name: string; provider: ProviderId }
  /** True for tabs the user can close. */
  closable: boolean
}

/**
 * Whether a list of tabs needs to say which account each session belongs to.
 *
 * Only when they do not all agree. On the ordinary install there is one
 * account, every row would carry the same word, and a label that is on every
 * row carries no information — the same reason the Accounts screen hides its
 * "Default" badge when there is only one account to be the default of. The
 * moment a second account is in play the rows have to be tellable apart,
 * because two sessions in the same folder under two logins are otherwise
 * identical on screen.
 *
 * Sessions with no account are not counted. A plain shell tab appearing beside
 * an agent tab is not a disagreement about accounts, and letting it flip every
 * row into carrying a name would make the label mean "you opened a shell".
 */
export function accountsWorthShowing(tabs: readonly WorkspaceTab[]): boolean {
  const seen = new Set<string>()
  for (const tab of tabs) {
    if (tab.kind !== 'session' || !tab.account) continue
    seen.add(tab.account.id)
    if (seen.size > 1) return true
  }
  return false
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
 * The same name, for a tab that is being drawn away from the sidebar's tree.
 *
 * The strip drew `tab.label` raw, and the sidebar draws it through
 * {@link sessionLabel}, so one window was "terminaldeck" along the top and
 * "Session 1" down the side until the agent got round to naming it — seen on
 * screen, not reasoned about. Promoting a tab is a *placement*; it is not a
 * rename, and nothing about the top of the window should make it look like one.
 *
 * The index is recovered from the tab list rather than passed in, because the
 * strip's own order is the promoted order and the number in "Session 3" counts
 * siblings in a folder. Both ends filter the same array the same way, so the
 * numbering cannot drift.
 */
export function tabLabel(tab: WorkspaceTab, tabs: readonly WorkspaceTab[]): string {
  if (tab.kind !== 'session') return tab.label
  const siblings = tabs.filter(
    (other) => other.kind === 'session' && other.projectPath === tab.projectPath,
  )
  const index = siblings.findIndex((other) => other.id === tab.id)
  return sessionLabel(
    tab.label,
    index === -1 ? 0 : index,
    tab.projectPath ? folderName(tab.projectPath) : undefined,
  )
}

/**
 * A tab's name, cut to fit, with the *middle* taken out rather than the end.
 *
 * Verified against this machine rather than imagined: the window this was
 * written in had three sessions open in one folder, and every one of them was
 * an agent-written title beginning "Update Claude Code terminal to …". Cut at
 * the end — which is all `text-overflow: ellipsis` can do — the strip read
 * "Update Claude Code ter…" three times and the tabs were genuinely
 * indistinguishable. The half that tells them apart is the tail, and the only
 * way to keep both halves is to lose the middle.
 *
 * A character budget rather than a measured width, because the alternative is
 * measuring text in a layout effect and re-measuring on every resize, and
 * because a budget is a pure function that a test can hold. CSS keeps its own
 * `text-overflow` as the backstop for a run of unusually wide glyphs, so the
 * failure mode of a budget that is slightly too generous is the old behaviour,
 * not an overflowing tab.
 *
 * Budgets under four are returned untouched: there is nothing left to show on
 * either side of an ellipsis, and a lone "…" is worse than a clipped word.
 */
export function middleEllipsis(label: string, budget: number): string {
  if (!Number.isFinite(budget) || budget < 4 || label.length <= budget) return label
  const keep = Math.trunc(budget) - 1
  const head = Math.ceil(keep / 2)
  // Trimmed on the inside edges only. Without it a cut that lands on a space
  // prints "Update Claude …o new API", where the gap reads as part of the name.
  return `${label.slice(0, head).trimEnd()}…${label.slice(label.length - (keep - head)).trimStart()}`
}

/**
 * How many characters of a title a tab in the top strip can hold.
 *
 * Measured off the real thing rather than guessed: a strip tab is capped at
 * 220px, and its icon, status dot, two trailing controls and padding take
 * about 80 of them, leaving 138px of 11px UI text. Twenty-four characters
 * rendered 146px into that box and the CSS backstop clipped the last one, so
 * the tab read "…to ne…" — this is the number that lets the middle cut be the
 * only cut, which is the point of making one.
 */
export const STRIP_LABEL_BUDGET = 22

/**
 * What a strip tab's tooltip should say: the whole title, and the folder under
 * it when there is one.
 *
 * Two lines rather than one joined by a dash, because the title can itself be a
 * sentence with dashes in it. A browser page has no folder and gets one line —
 * an empty second line would read as a missing value.
 */
export function tabTooltip(tab: WorkspaceTab, label: string): string {
  return tab.projectPath ? `${label}\n${tab.projectPath}` : label
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

/* ------------------------------------------------------------ dragging -- */

/**
 * The one thing a dragged tab carries, and the only format it is offered in.
 *
 * A private MIME type rather than `text/plain`, which matters more here than it
 * usually would. This window is full of drop targets that are not ours: a
 * terminal accepts dropped text and types it, the address bar accepts a dragged
 * URL, and a chat composer accepts anything at all. A tab offered as plain text
 * would be droppable into every one of them, and dropping a session onto a
 * terminal would type its opaque id into whatever agent is running there.
 * Offering only this format means every surface that did not ask for a tab
 * simply refuses the drop, which is the correct behaviour and needs no code.
 *
 * The value is the tab's `id`, which is all a receiver needs — the tab itself is
 * already in the list both ends are rendering from, and serialising a copy of it
 * would let the two drift apart mid-drag.
 */
export const TAB_DRAG_MIME = 'application/x-terminaldeck-tab'

/**
 * The slice of `DataTransfer` the helpers below touch.
 *
 * Structural rather than the DOM type, because this project's tests run in Node
 * with no DOM at all. A real `DataTransfer` satisfies it.
 */
export interface TabTransfer {
  readonly types: ReadonlyArray<string>
  setData(format: string, data: string): void
  getData(format: string): string
  effectAllowed: string
}

/** Begin dragging a tab. Call from the drag source's `onDragStart`. */
export function startTabDrag(transfer: TabTransfer, tabId: string): void {
  transfer.setData(TAB_DRAG_MIME, tabId)
  // `move`, not `copy`: promoting a tab to the strip and folding it back into
  // the rail are both moves, and the cursor is the only thing telling the user
  // which of the two they are about to do.
  transfer.effectAllowed = 'move'
}

/**
 * Is the thing being dragged one of our tabs?
 *
 * The test a `dragover` handler has to use. During a drag the browser puts the
 * data in *protected mode* — `types` is readable, `getData` returns the empty
 * string — so a target that decided whether to accept a drop by reading the
 * payload would refuse every drop it was written to accept. Verified behaviour,
 * not a precaution: it is in the HTML drag-and-drop spec and every engine
 * implements it.
 */
export function isTabDrag(transfer: TabTransfer | null | undefined): boolean {
  return transfer ? Array.from(transfer.types).includes(TAB_DRAG_MIME) : false
}

/** The tab id being dropped, or null when the drop was something else. */
export function readTabDrag(transfer: TabTransfer | null | undefined): string | null {
  if (!isTabDrag(transfer)) return null
  const id = transfer?.getData(TAB_DRAG_MIME) ?? ''
  return id === '' ? null : id
}
