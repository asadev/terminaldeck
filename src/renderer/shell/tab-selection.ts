import type { WorkspaceTab } from './workspace-tabs'

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
