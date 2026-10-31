/**
 * Which browser page is the one on screen — for everything outside the browser
 * that has to draw only while a page is in front.
 *
 * ## What he asked for
 *
 * Asad, 2026-08-21, with the copilot driving a page and the app's own MCP
 * servers screen in the window:
 *
 * > *"And this will not always stay like in the side panel… As soon as I click
 * > on any other thing, it is coming up. So maybe I need to stop this."*
 *
 * The copilot's rail panel was mounted on "a drive is live" and nothing else, so
 * it sat over the sidebar on the MCP servers page, on Machines, and on a
 * terminal session — every screen in the app except the copilot's own. Stopping
 * the copilot was the only way to get the rail back. The panel now needs the
 * fact this store publishes: *a browser page is what the window is showing, and
 * it is this one*.
 *
 * ## Why a module store and not a prop
 *
 * The same argument `window-machine.ts` and `binding-view.ts` make one file
 * over, and for the same pair of components. The answer is computed inside
 * `BrowserWorkspace`, which is a leaf, and it is needed in the sidebar, which is
 * a sibling — the only prop route between them runs up through `App.tsx` and
 * back down, so the two would hold copies of one fact and could disagree about
 * it.
 *
 * `visible` is the whole answer and is already exact: `App.tsx` computes it as
 * "this page is the thing on screen", excluding a sidebar view covering the
 * window, a split, the swarm grid, a machine session and a server shell. Reading
 * that rather than re-deriving it here is what keeps this store from becoming a
 * second, slightly different, idea of what is in front.
 *
 * ## Both ids, because the two halves of the app name a window differently
 *
 * The shell tab id is what a session ↔ browser binding is keyed on, so it is how
 * the panel finds the session that owns this page. The view id is what the drive
 * reports in `DriveStatus.tabId`, so it is how the panel knows this page is the
 * one being driven. Publishing one and looking the other up would put the join
 * in whoever asked; publishing both keeps it here, where the only component that
 * knows both is standing.
 *
 * The two rules below are copied from `window-machine.ts`, and both were
 * measured rather than reasoned about:
 *
 *  - **`getSnapshot` must return an identity-stable value.** A fresh object per
 *    call is an infinite render loop, not a slow render.
 *  - **A write that changes nothing must wake nobody.** The publisher's effect
 *    re-runs on every url and title change of every window, so the common call
 *    by a wide margin is one that sets what is already set.
 */

import { useSyncExternalStore } from 'react'

/** The browser page in front, as the app names it twice. */
export interface FrontPage {
  /** The shell tab id — what a session ↔ browser binding is keyed on. */
  tabId: string
  /**
   * The main-process view id of the page it is showing, or empty.
   *
   * Empty while a window has no page yet, which is a real state: the panel is
   * created before its `WebContentsView` exists. Never guessed from the tab id —
   * the view id is re-minted when the isolation switch closes and reopens the
   * view, and the tab id is not.
   */
  viewId: string
}

/** Nothing in front, as one frozen value. See the identity rule in the header. */
const NONE: FrontPage | null = null

let current: FrontPage | null = NONE
const watchers = new Set<() => void>()

function wake(): void {
  for (const watcher of watchers) watcher()
}

/**
 * Say that this window is the page on screen — or that it is not.
 *
 * `page` is null for a window that is hidden, and a null from a window that is
 * not the one currently in front is ignored rather than clearing the store. That
 * guard is what makes this safe to call from every mounted panel: they all
 * publish on every navigation, and without it the last hidden window to render
 * would blank the answer the visible one had just given.
 */
export function setFrontPage(tabId: string, page: FrontPage | null): void {
  if (page === null) {
    if (current === null || current.tabId !== tabId) return
    current = null
    wake()
    return
  }
  // The no-op guard. This is the call that arrives on every navigation of every
  // window; without the comparison every one of them would re-render the rail.
  if (current !== null && current.tabId === page.tabId && current.viewId === page.viewId) return
  current = page
  wake()
}

/** A window that has gone. Safe to call for one that was never in here. */
export function forgetFrontPage(tabId: string): void {
  setFrontPage(tabId, null)
}

/** Test seam. Every real write comes from a mounted browser panel. */
export function resetFrontPageForTests(): void {
  current = NONE
  wake()
}

/** What the store holds, for tests and for code outside React. */
export function frontPage(): FrontPage | null {
  return current
}

function subscribe(listener: () => void): () => void {
  watchers.add(listener)
  return () => {
    watchers.delete(listener)
  }
}

/**
 * The browser page in front, or null when the window is showing anything else.
 *
 * A hook rather than a getter because the answer changes under a component that
 * is doing nothing: switching to a session, opening Settings and closing a page
 * all move it, and none of them is a prop change for the rail.
 */
export function useFrontPage(): FrontPage | null {
  return useSyncExternalStore(
    subscribe,
    () => current,
    () => current,
  )
}
