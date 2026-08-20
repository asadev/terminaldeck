import { readMachineTabId, readServerTabId, type WorkspaceTab } from './workspace-tabs'

/**
 * What the window is showing — including the answer "nothing, on purpose".
 *
 * ## The bug this exists for
 *
 * Asad, 2026-08-17: *"If there are three or two windows open and I close all of
 * them, the last one I will not be able to close from the top bar — I can just
 * close a few ones."*
 *
 * He is describing a control that does not work. Press the ✕ on the last tab in
 * the strip and the tab is gone for one frame and back in the next, drawn in
 * italic as a transient tab; press it again and the same thing happens. Nothing
 * was broken — every piece was doing exactly what it was written to do:
 *
 *  - `removeFromStrip` answers `select: null`, which is honest: there is nothing
 *    left on the bar to fall back to.
 *  - `App.tsx` held that selection as `activeTabId: string | null` and resolved
 *    it with `tabs.find(…) ?? tabs[0] ?? null`, so `null` meant *the first thing
 *    you have open*.
 *  - `shownTabs` always draws the active tab, promoted or not, because a window
 *    displaying a terminal must have a tab naming it.
 *
 * The three compose into a press that undoes itself. The one to give is the
 * middle one, because `null` was carrying two meanings that are not the same
 * question: **"nobody has chosen yet"**, which is a launch and a reload and
 * genuinely should show the first session you have open, and **"the person just
 * took the last one off the bar"**, which should leave an empty pane the way
 * closing every tab in a browser does. A single `null` cannot tell those apart,
 * so the app answered the first for both.
 *
 * ## Why a three-state type rather than a second boolean
 *
 * A `cleared` flag beside the id would have worked and would have had to be
 * cleared correctly at each of the seven places that set a selection — and the
 * one that forgot would be a window that refuses to show anything until you
 * clicked twice, which is a bug that reads as a freeze. Making it one value
 * makes "set the selection" a single act with no second half to forget.
 *
 * It is deliberately not a member of some larger app state: this is the whole
 * of it, it is pure, and the resolution below is the only place the fallback
 * lives.
 */
export type TabSelection =
  /** Nothing has chosen yet — a launch, a reload, a window whose tab has gone. */
  | { kind: 'auto' }
  /** This one, if it is still open. */
  | { kind: 'tab'; id: string }
  /** Nothing, and that is a decision somebody made. */
  | { kind: 'empty' }

/** The state a window starts in. A constant, so it is stable by identity. */
export const AUTO_SELECTION: TabSelection = { kind: 'auto' }

/**
 * Deliberately nothing.
 *
 * Reached from exactly two presses today: taking the last tab off the strip, and
 * closing the last thing that was open. Both are somebody saying "I am done with
 * this", and neither is an error state — every session is still running and
 * still listed in the rail, which is the whole model of the strip: *"side panel
 * will have everything inside, and above we just set a view which one we want to
 * see."*
 */
export const EMPTY_SELECTION: TabSelection = { kind: 'empty' }

/**
 * Show this tab — or, given `null`, show nothing.
 *
 * `null` maps to {@link EMPTY_SELECTION} rather than to `auto`, and that is the
 * whole behaviour change of 2026-08-17. Every caller that hands a `string | null`
 * is reporting the outcome of a *removal*: `removeFromStrip` naming the neighbour
 * that is left, or `nextActiveId` naming the tab that survives a close. In both,
 * `null` means "there was no neighbour", which is a person having emptied
 * something, not a window that has not decided yet.
 */
export function showTabSelection(id: string | null): TabSelection {
  return id === null ? EMPTY_SELECTION : { kind: 'tab', id }
}

/**
 * The tab the window should draw, or null for an empty pane.
 *
 * The fallback to `tabs[0]` survives for the two states that mean "no choice has
 * been expressed": a fresh window, and a selection naming a tab that is no
 * longer open. That second one is not the same as an empty pane either — a
 * session's process exiting, or a project being closed, is not the user asking
 * for a blank window, and blanking it there would turn every crashed agent into
 * a window that looks broken.
 */
export function resolveActiveTab(
  selection: TabSelection,
  tabs: readonly WorkspaceTab[],
): WorkspaceTab | null {
  if (selection.kind === 'empty') return null
  if (selection.kind === 'tab') {
    const found = tabs.find((tab) => tab.id === selection.id)
    if (found) return found
  }
  return tabs[0] ?? null
}

/**
 * Which of the window's three surfaces has to hold what is being shown.
 *
 * ## The failure this exists for
 *
 * Asad, 2026-08-21, sitting in a terminal on Office PC with that session's tab
 * active: *"Now if I am on this session and I want to close this session from
 * here, from top bar, I think I cannot because I am inside. So either it should
 * not matter if I am inside or not."* And a beat later, the bound on it: *"If I
 * click close, it should close, but it will stay live in side panel. But from
 * the top bar it should go."*
 *
 * The ✕ was pressed and the tab did not leave the bar — in his frames it *moved*
 * from third position to the far right and stayed selected, which is the exact
 * signature of a demotion that took effect followed by the strip drawing the tab
 * again because it is still what is on screen. Three pieces, each correct:
 *
 *  - `removeFromStrip` takes the id out of the promoted order and names the
 *    neighbour the window should show instead.
 *  - `App.tsx` holds "which session on another computer is filling the pane" in
 *    two pieces of state of its own, and `railActiveTabId` prefers them over
 *    every local tab, because when one is on screen it *is* what is on screen.
 *  - `shownTabs` always draws the active tab, promoted or not, so that the
 *    heading can never name a session with no tab.
 *
 * `showInstead` moved the *local* selection and nothing else, so those two
 * pieces of state still named the session that had just been taken off the bar,
 * `railActiveTabId` still resolved to it, and it came back as a transient tab.
 * A local tab has no such second home, which is why the same press worked there
 * and why the bug read as "only the ones on other machines".
 *
 * ## Why a function here rather than two more branches in the handler
 *
 * Because `selectTab` in `App.tsx` already carries these branches, and the two
 * are answering one question: *given an id, where does that window live*.
 * Written twice they are two answers, and the one that drifts is the one nobody
 * navigates with. Written here it is pure, and the routing can be pinned without
 * a window — which matters, because this is the half of the press no screenshot
 * shows.
 *
 * `selectTab` has not been moved onto it yet, and that is a deliberate stop
 * rather than an oversight: it is the busiest function in the largest file in
 * the renderer, its branches are held by their own wiring tests, and a rewrite
 * of them is not what a ✕ that does not work needs. It is the next caller.
 *
 * `null` is a window with nothing left to show, and it clears both: a person who
 * took the last tab off the bar has emptied the window, and a server terminal
 * still filling the pane under an empty strip would be the same contradiction
 * from the other side.
 *
 * ## What it deliberately does not decide
 *
 * Whether anything is *ended*. Nothing here reaches a pty, a machine or a
 * server; a session taken off the bar keeps running and keeps its row in the
 * rail, which is the whole model of the strip — *"side panel will have
 * everything inside, and above we just set a view which one we want to see."*
 * Ending one for real is the rail row's ⋯ → Delete and stays there.
 */
export interface PaneForTab {
  /** The session on a paired machine to show, or null to put that pane away. */
  machine: { machineId: string; sessionId: string } | null
  /** The tab id of the server terminal to show, or null to put that pane away. */
  server: string | null
  /**
   * True when the id names something this window draws itself — a local
   * session, the copilot, a browser page — or names nothing at all.
   *
   * The callers need it because the *rest* of showing a local tab (making it the
   * active session, filling the focused pane in a split) is meaningless for a
   * window on another computer, and asking `machine === null && server === null`
   * at each call site is the same test written twice more.
   */
  local: boolean
}

export function paneForTab(id: string | null): PaneForTab {
  if (id === null) return { machine: null, server: null, local: true }
  const machine = readMachineTabId(id)
  if (machine) return { machine, server: null, local: false }
  if (readServerTabId(id)) return { machine: null, server: id, local: false }
  return { machine: null, server: null, local: true }
}
