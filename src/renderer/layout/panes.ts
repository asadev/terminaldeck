/* ============================================================================
   Panes ⇄ open windows — the rules that keep a split layout and the sidebar
   telling the same story.

   `pane-tree.ts` is the geometry and knows nothing about what a pane shows; the
   shell knows about sessions and pages and should not know about trees. This is
   the seam, and it exists because the pane tree spent its entire life rendered
   nowhere, partly on the argument that a hand-arranged layout would inevitably
   drift out of step with a sidebar that lists one row per session.

   That argument is answerable, and the answer is one sentence:

       the sidebar names whatever is in the FOCUSED pane.

   With a single pane — which is every session until somebody splits one — that
   is byte-for-byte what the sidebar has always done: click a row, see that
   session. Split the pane and the row means exactly the same thing; it just
   fills the half you are looking at instead of the whole window. Nothing in the
   sidebar has to learn what a pane is, and no pane can show something the
   sidebar does not list, because every function here takes the open-window list
   as its authority and prunes against it.

   ## "Open window" and not "session"

   The list this prunes against used to be the *session* list, and that one word
   was the whole of a real defect: a browser page put into a pane was a pane
   holding an id no session had, so the very next render pruned it and the
   user's split collapsed under them. Every route to a page in a pane therefore
   had to refuse, which is why `selectTab` used to return early for anything
   that was not a session.

   The authority is the shell's tab list — sessions *and* pages — because that
   is the honest answer to the question this file is actually asking, which is
   "is the thing this pane names still open". A terminal on one side and a
   localhost page on the other is not an edge case; it is the arrangement
   somebody splits the window in order to get.

   Everything is pure and returns the same reference on a no-op, matching
   `pane-tree.ts`, so a render of the shell never costs a remount of a terminal.
   ============================================================================ */

import {
  closePane,
  createLayout,
  emptyLayout,
  listPanes,
  setPaneTab,
  splitPane,
  type PaneLayout,
} from './pane-tree'

/**
 * The minimum an open window has to expose for the layout to reason about it.
 *
 * An id, and nothing else. Deliberately not `WorkspaceTab`: this file must not
 * be able to tell a session from a page, because the moment it can, something
 * here will start treating one of them as the real kind.
 */
export interface PaneTab {
  readonly id: string
}

/**
 * True when the window is showing a pane layout rather than a single session.
 *
 * Derived rather than stored. A separate `splitOn` boolean is a second source
 * of truth for the same fact, and the two disagree the moment the last pane is
 * closed from inside the split — which is exactly the state where the app would
 * be drawing a "Split" mode with nothing in it.
 */
export function isSplit(layout: PaneLayout): boolean {
  return layout.root !== null
}

/**
 * The layout entering split mode starts from: what you are looking at, beside
 * the next thing you have open.
 *
 * Two panes rather than one, because a "split view" that opens as a single
 * undivided pane has not done the thing its own name promises — the user
 * presses it and nothing appears to happen. The second pane takes the next open
 * window where there is one, and is left empty where there is not; an empty
 * pane is not a placeholder, it is an instruction, and the shell renders it as
 * one ("pick a session on the left").
 *
 * `open` is the shell's whole tab list rather than its sessions, so pressing
 * Split while a browser page is in front keeps that page and puts the next
 * thing beside it. Handed the session list instead — which is what this took
 * until 2026-08-17 — the page you were reading vanished the moment you split,
 * because it was not in the list the first pane was chosen from.
 *
 * `active` is allowed to be null (nothing focused yet), in which case the first
 * two are used, so the caller never has to special-case a cold start.
 */
export function seedSplit(
  open: readonly PaneTab[],
  active: string | null,
): PaneLayout {
  const first = open.find((tab) => tab.id === active) ?? open[0] ?? null
  const second = open.find((tab) => tab.id !== first?.id) ?? null

  const layout = createLayout(first?.id ?? null)
  if (!layout.focusedPaneId) return layout

  // `keepFocus`, so the session you were already working in keeps the keyboard.
  // Without it, pressing Split moves focus into the pane that just appeared —
  // which on a two-session window means your next keystroke goes to the other
  // agent.
  return splitPane(layout, layout.focusedPaneId, 'horizontal', {
    tabId: second?.id ?? null,
    keepFocus: true,
  })
}

/**
 * Put an open window into the focused pane.
 *
 * This is what a sidebar click means while a layout is on screen. It is
 * deliberately *not* "open it in a new pane": the sidebar is a list of what you
 * have open, not a layout editor, and a click that silently multiplied your
 * panes would be the sidebar fighting the layout rather than driving it.
 *
 * A page is as welcome here as a session. It was not — this is the line
 * `newBrowserTab` was forbidden to call, because the prune below would have
 * torn the layout down on the next render. What made it safe is that the prune
 * is now told about pages too, not anything that changed in here.
 */
export function showInFocusedPane(layout: PaneLayout, tabId: string): PaneLayout {
  if (!layout.focusedPaneId) return layout
  return setPaneTab(layout, layout.focusedPaneId, tabId)
}

/**
 * One window has become another, and every pane showing the first must show the
 * second — in the same place, at the same size.
 *
 * Written for exactly one caller and it is worth naming, because the situation
 * looks impossible from in here: switching the account a running session is on.
 * A CLI is authenticated at spawn, so changing account means stopping the
 * process and starting another, which means a *new session id* for what is, to
 * the person, the same tab they were already looking at. Everything they can see
 * is meant to survive that — including a pane arrangement they built by hand.
 *
 * Without this the switch would be a prune and an insert: `pruneClosedPanes`
 * would find the old id gone and collapse its pane, and the replacement would
 * arrive with nowhere to be. Somebody who split their window and switched the
 * left half's account would watch the split fall apart, which is the layout
 * rearranging itself in response to something that was not a drag — the thing
 * `keepInStrip` refuses to do one file over.
 *
 * Every pane, not just the focused one: the same session can legitimately be in
 * two panes (`splitFocused` puts it there deliberately, so you can watch two
 * ends of one scrollback), and leaving the second on a dead id is the stale-pane
 * failure `pruneClosedPanes` exists for.
 *
 * Returns the same reference when nothing shows the old id, matching every other
 * function here, so a render that changes nothing costs no remount.
 */
export function replaceTabInPanes(
  layout: PaneLayout,
  oldId: string,
  newId: string,
): PaneLayout {
  let next = layout
  for (const pane of listPanes(layout)) {
    if (pane.tabId !== oldId) continue
    next = setPaneTab(next, pane.id, newId)
  }
  return next
}

/**
 * Drop panes whose window no longer exists.
 *
 * Called whenever the open list changes, because a session or a page can leave
 * without the layout being told: ⌘W on the tab, the process exiting, a whole
 * project being closed. A pane still naming a dead one renders an empty pane
 * whose emptiness has no explanation, and — worse — `focusedTabId` keeps
 * answering with an id the store has already forgotten, so the chrome and the
 * composer act on something that is gone.
 *
 * **`open` is every kind of window, not only the sessions.** Given the session
 * list alone this function is what destroyed a split the moment a browser page
 * was put in a pane: the page was open, on the tab strip, on screen — and not
 * in the list, so this pruned its pane and collapsed the layout on the render
 * after the click. The bug reads as "split view is broken"; the cause is one
 * argument being narrower than the thing it is the authority for.
 *
 * Panes with nothing in them at all are kept: those are the deliberate "pick a
 * session" holes `seedSplit` leaves, and the user put them there.
 *
 * Collapses through `closePaneOrCollapse` for the same reason a manual close
 * does — closing the last of your two agents should put the window back the way
 * it was, not leave you in a split view with one pane in it.
 */
export function pruneClosedPanes(
  layout: PaneLayout,
  open: readonly PaneTab[],
): PaneLayout {
  const alive = new Set(open.map((tab) => tab.id))
  let next = layout
  for (const pane of listPanes(layout)) {
    if (pane.tabId === null || alive.has(pane.tabId)) continue
    next = closePaneOrCollapse(next, pane.id)
  }
  return next
}

/**
 * The layout after a pane is closed, collapsed back to nothing when only one
 * pane is left.
 *
 * A "split view" holding a single pane is just the ordinary session view with a
 * divider's worth of extra chrome and a mode switch claiming you are in split
 * mode. Closing the second pane is the user saying they are done splitting, so
 * this returns an empty layout and the shell falls back to the single-session
 * view — the same state the mode switch calls Terminal.
 */
export function closePaneOrCollapse(layout: PaneLayout, paneId: string): PaneLayout {
  const next = closePane(layout, paneId)
  return listPanes(next).length < 2 ? emptyLayout() : next
}

/**
 * Add a pane beside the focused one, showing the same thing.
 *
 * The same thing and not a blank pane, deliberately: splitting a terminal in
 * two so you can look at two ends of the same scrollback is the ordinary reason
 * to split, and a blank pane makes the common case cost a second click. The
 * user retargets either half from the sidebar.
 */
export function splitFocused(layout: PaneLayout): PaneLayout {
  if (!layout.focusedPaneId) return layout
  const focused = listPanes(layout).find((pane) => pane.id === layout.focusedPaneId)
  return splitPane(layout, layout.focusedPaneId, 'horizontal', {
    tabId: focused?.tabId ?? null,
  })
}
