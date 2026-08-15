/* ============================================================================
   Panes ⇄ sessions — the rules that keep a split layout and the sidebar
   telling the same story.

   `pane-tree.ts` is the geometry and knows nothing about sessions; the shell
   knows about sessions and should not know about trees. This is the seam, and
   it exists because the pane tree spent its entire life rendered nowhere,
   partly on the argument that a hand-arranged layout would inevitably drift out
   of step with a sidebar that lists one row per session.

   That argument is answerable, and the answer is one sentence:

       the sidebar names the session in the FOCUSED pane.

   With a single pane — which is every session until somebody splits one — that
   is byte-for-byte what the sidebar has always done: click a row, see that
   session. Split the pane and the row means exactly the same thing; it just
   fills the half you are looking at instead of the whole window. Nothing in the
   sidebar has to learn what a pane is, and no pane can show a session the
   sidebar does not list, because every function here takes the session list as
   its authority and prunes against it.

   Everything is pure and returns the same reference on a no-op, matching
   `pane-tree.ts`, so a render of the shell never costs a remount of a terminal.
   ============================================================================ */

import {
  closePane,
  createLayout,
  emptyLayout,
  listPanes,
  setPaneSession,
  splitPane,
  type PaneLayout,
} from './pane-tree'

/** The minimum a session has to expose for the layout to reason about it. */
export interface PaneSession {
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
 * The layout entering split mode starts from: the session you are looking at,
 * beside the next one you have open.
 *
 * Two panes rather than one, because a "split view" that opens as a single
 * undivided pane has not done the thing its own name promises — the user
 * presses it and nothing appears to happen. The second pane takes the next open
 * session where there is one, and is left empty where there is not; an empty
 * pane is not a placeholder, it is an instruction, and the shell renders it as
 * one ("pick a session on the left").
 *
 * `active` is allowed to be null (nothing focused yet), in which case the first
 * two sessions are used, so the caller never has to special-case a cold start.
 */
export function seedSplit(
  sessions: readonly PaneSession[],
  active: string | null,
): PaneLayout {
  const first = sessions.find((session) => session.id === active) ?? sessions[0] ?? null
  const second = sessions.find((session) => session.id !== first?.id) ?? null

  const layout = createLayout(first?.id ?? null)
  if (!layout.focusedPaneId) return layout

  // `keepFocus`, so the session you were already working in keeps the keyboard.
  // Without it, pressing Split moves focus into the pane that just appeared —
  // which on a two-session window means your next keystroke goes to the other
  // agent.
  return splitPane(layout, layout.focusedPaneId, 'horizontal', {
    sessionId: second?.id ?? null,
    keepFocus: true,
  })
}

/**
 * Put a session into the focused pane.
 *
 * This is what a sidebar click means while a layout is on screen. It is
 * deliberately *not* "open it in a new pane": the sidebar is a list of what you
 * have open, not a layout editor, and a click that silently multiplied your
 * panes would be the sidebar fighting the layout rather than driving it.
 */
export function showInFocusedPane(layout: PaneLayout, sessionId: string): PaneLayout {
  if (!layout.focusedPaneId) return layout
  return setPaneSession(layout, layout.focusedPaneId, sessionId)
}

/**
 * Drop panes whose session no longer exists.
 *
 * Called whenever the session list changes, because a session can leave without
 * the layout being told: ⌘W on the tab, the process exiting, a whole project
 * being closed. A pane still naming a dead session renders an empty pane whose
 * emptiness has no explanation, and — worse — `focusedSessionId` keeps
 * answering with an id the store has already forgotten, so the toolbar and the
 * composer act on a session that is gone.
 *
 * Panes with no session at all are kept: those are the deliberate "pick a
 * session" holes `seedSplit` leaves, and the user put them there.
 *
 * Collapses through `closePaneOrCollapse` for the same reason a manual close
 * does — closing the last of your two agents should put the window back the way
 * it was, not leave you in a split view with one pane in it.
 */
export function pruneClosedSessions(
  layout: PaneLayout,
  sessions: readonly PaneSession[],
): PaneLayout {
  const open = new Set(sessions.map((session) => session.id))
  let next = layout
  for (const pane of listPanes(layout)) {
    if (pane.sessionId === null || open.has(pane.sessionId)) continue
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
 * Add a pane beside the focused one, showing the same session.
 *
 * The same session and not a blank pane, deliberately: splitting a terminal in
 * two so you can look at two ends of the same scrollback is the ordinary reason
 * to split, and a blank pane makes the common case cost a second click. The
 * user retargets either half from the sidebar.
 */
export function splitFocused(layout: PaneLayout): PaneLayout {
  if (!layout.focusedPaneId) return layout
  const focused = listPanes(layout).find((pane) => pane.id === layout.focusedPaneId)
  return splitPane(layout, layout.focusedPaneId, 'horizontal', {
    sessionId: focused?.sessionId ?? null,
  })
}
