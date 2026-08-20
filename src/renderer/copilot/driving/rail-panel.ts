/**
 * The copilot's side panel: when it is drawn, where, and how wide.
 *
 * Everything about the panel except its markup, kept in one place because the
 * three things that need it are in three different trees — `DriveHost`, which
 * is a sibling of `<App/>` and is the only thing subscribed to the drive; the
 * sidebar, which draws the panel; and `useSidebar`, which owns the width of the
 * column the panel takes. Threading any of it through props would run up through
 * `App.tsx` and back down twice.
 *
 * ## What the panel is now, and what it was
 *
 * It was `position: fixed` over the rail's column at a static 264px token, drawn
 * whenever a drive was live. Asad drove with it on 2026-08-21 and every sentence
 * he said about it was about that arrangement:
 *
 * > *"this should actually replace with this instead of coming in front of it
 * > somehow."*
 *
 * > *"It will be starting from the first pill of commander, not from the top with
 * > the top header also should not be covering it."*
 *
 * > *"And this will not always stay like in the side panel… As soon as I click on
 * > any other thing, it is coming up. So maybe I need to stop this."*
 *
 * So it now **takes the rail's slot** — the sidebar draws the panel *instead of*
 * its own list, at the column's real width, below the New session header — and
 * it is drawn only while the page being driven is the page on screen. Both
 * follow from this module: {@link railPanelState} is the whole decision and
 * every consumer asks it rather than deciding again.
 *
 * ## Why the fold is durable
 *
 * The old put-away was remembered per browser tab, and the file said so plainly:
 * *"the panel comes back on the next errand."* That is exactly what he hit —
 * *"this side panel thing is not going away"* — and the cost of getting the rail
 * back was stopping the copilot mid-drive. So folding is now a plain flag: once
 * it is put away it stays away across pages, tabs and further errands, and the
 * only thing that brings it back is the person asking for it on the sidebar's
 * Commander row.
 *
 * It is deliberately **not** persisted to disk. A relaunch is not a page, a tab
 * or an errand, and a panel that stayed hidden for a week because of one click
 * in a session nobody remembers is a feature that has quietly uninstalled
 * itself.
 */

import { useSyncExternalStore } from 'react'
import { useFrontPage, type FrontPage } from '../../browser/front-page'
import { readRailWidth } from '../../shell/rail-width'
import type { DriveNow } from './browser-trace'

const WIDTH_KEY = 'deck.copilot.railWidth'

/**
 * What the rail should be showing.
 *
 *  - `panel` — the copilot's panel has the column.
 *  - `folded` — it is put away, the rail is back, and the Commander row carries
 *    the mark that says where it went. Only ever answered while the driven page
 *    is in front, because that is the only moment the row can bring it back.
 *  - `away` — the rail is simply the rail.
 */
export type RailPanelState = 'panel' | 'folded' | 'away'

/**
 * The whole decision, as one pure function.
 *
 * Pure and exported so it can be pinned: there is no DOM in this project's
 * tests, so the hook below cannot be driven, and a rule that decides whether a
 * panel covers the sidebar at all cannot be the one piece with no test.
 *
 * `front.viewId === drive.tabId` is the load-bearing line and it is why the
 * store publishes both ids. A drive names the page it holds by its main-process
 * view id; a browser window in front names itself by both. Without the join,
 * "a drive is live" and "a browser page is in front" were being read as "this
 * page is being driven", which drew the panel over a *different* browser tab —
 * and over the MCP servers page, and over a terminal session, which is where he
 * found it.
 *
 * The copilot's own page needs no clause of its own any more. It is not a
 * browser page, so it has no `FrontPage`, so the panel is `away` there — which
 * is the rule he restated on the same recording: *"If I am inside commander, it
 * should not be here, just like now it is not."*
 */
export function railPanelState(
  drive: DriveNow | null,
  front: FrontPage | null,
  folded: boolean,
): RailPanelState {
  if (drive === null || drive.state === 'idle') return 'away'
  if (front === null || front.viewId === '' || front.viewId !== drive.tabId) return 'away'
  return folded ? 'folded' : 'panel'
}

/* ------------------------------------------------------------- the drive -- */

let drive: DriveNow | null = null
let copilotSessionId: string | null = null
let folded = false
let width: number | null = null
let widthRead = false
const watchers = new Set<() => void>()

function wake(): void {
  for (const watcher of watchers) watcher()
}

function subscribe(listener: () => void): () => void {
  watchers.add(listener)
  return () => {
    watchers.delete(listener)
  }
}

/**
 * The same subscription, for a reader that is not a component.
 *
 * Exported for the tests, and named rather than smuggled: this project has no
 * DOM in its test setup, so a hook cannot be driven, and the guard that stops a
 * scrape re-rendering the sidebar on every step is exactly the kind of thing
 * that is wrong invisibly. `browser-binding.ts` exports its `subscribe` for the
 * same reason.
 */
export const subscribeRailPanel = subscribe

/**
 * What the copilot is driving, published by `DriveHost`.
 *
 * Null while nothing is driving and while a scan is playing — the scan wants
 * this same column and it is the one somebody asked to watch, so `DriveHost`
 * publishes null for the duration rather than the panel growing a second rule
 * about a feature it cannot see.
 *
 * The no-op guard matters here for the same reason it does in
 * `window-machine.ts`: `browser:drive-state` is pushed on every step of a
 * scrape, and most of those pushes change nothing this panel draws.
 */
export function setRailDrive(next: DriveNow | null): void {
  if (drive === next) return
  if (
    drive !== null &&
    next !== null &&
    drive.state === next.state &&
    drive.tabId === next.tabId &&
    drive.url === next.url &&
    drive.step === next.step
  ) {
    return
  }
  drive = next
  wake()
}

/**
 * The copilot's own session, published by `DriveHost` when it reads it.
 *
 * The panel's fallback subject, and only that. A driven page is normally
 * *attached* to the session that asked for it — that is what the `B1` in the
 * copilot's own trace means — so the panel names the session out of the binding
 * and talks to it, whichever session that is. A page with no binding is still a
 * page somebody's copilot is driving, and the copilot is the honest answer to
 * "who is doing this"; without it the panel would have a live drive on screen
 * and no one to ask about it.
 */
export function setRailCopilot(id: string | null): void {
  if (copilotSessionId === id) return
  copilotSessionId = id
  wake()
}

/**
 * Put the panel away and give the rail back — the panel's own collapse control.
 *
 * Durable for the reasons in the header. Nothing clears it but
 * {@link openRailPanel}.
 */
export function foldRailPanel(): void {
  if (folded) return
  folded = true
  wake()
}

/** Bring it back. The sidebar's Commander row, and nothing else, calls this. */
export function openRailPanel(): void {
  if (!folded) return
  folded = false
  wake()
}

/**
 * The width the panel was last dragged to, or null while it has never been.
 *
 * Null is a real answer and the useful one: with no width of its own the panel
 * takes the column at *the rail's* current width, which is what he asked for
 * — the panel replaces the rail rather than resizing the window on the way in.
 * A default number here would make every first drive jump the seam.
 */
export function railPanelWidth(): number | null {
  if (widthRead) return width
  widthRead = true
  // Guarded because this module is imported by tests that run in plain Node,
  // where there is no `localStorage` at all — the same reason `finish.test.ts`
  // can read this file without a DOM. A window that cannot store a width simply
  // never has one, which is the `null` branch below.
  if (typeof localStorage === 'undefined') return width
  // `readRailWidth` answers 0 for absent, unparseable and out-of-bounds alike,
  // and 0 is below `RAIL_MIN`, so it cannot collide with a real stored width.
  const stored = readRailWidth(WIDTH_KEY, 0)
  width = stored === 0 ? null : stored
  return width
}

export function setRailPanelWidth(next: number): void {
  if (width === next) return
  width = next
  widthRead = true
  if (typeof localStorage !== 'undefined') localStorage.setItem(WIDTH_KEY, String(next))
  wake()
}

/** Test seam. Every real write comes from the drive or from a press. */
export function resetRailPanelForTests(): void {
  drive = null
  copilotSessionId = null
  folded = false
  width = null
  widthRead = false
  wake()
}

function driveSnapshot(): DriveNow | null {
  return drive
}

function foldedSnapshot(): boolean {
  return folded
}

function copilotSnapshot(): string | null {
  return copilotSessionId
}

/** The copilot's session id, or null when this build has no copilot running. */
export function useRailCopilot(): string | null {
  return useSyncExternalStore(subscribe, copilotSnapshot, copilotSnapshot)
}

/** The live drive, for anything drawing it. */
export function useRailDrive(): DriveNow | null {
  return useSyncExternalStore(subscribe, driveSnapshot, driveSnapshot)
}

/**
 * Everything the rail needs to know, in one read.
 *
 * One hook rather than three because the three answers have to be consistent
 * within a render: the sidebar deciding it has the column while `useSidebar`
 * still believes the rail does would draw the panel at the wrong width for one
 * frame, on every single open.
 */
export interface RailPanel {
  state: RailPanelState
  /** The drive being drawn, present exactly when `state` is `panel`. */
  drive: DriveNow | null
  /** The page it is on, present exactly when `state` is not `away`. */
  page: FrontPage | null
  /** Its own width, or null to take the rail's. See {@link railPanelWidth}. */
  width: number | null
}

export function useRailPanel(): RailPanel {
  const now = useRailDrive()
  const front = useFrontPage()
  const away = useSyncExternalStore(subscribe, foldedSnapshot, foldedSnapshot)
  const state = railPanelState(now, front, away)
  return {
    state,
    drive: state === 'panel' ? now : null,
    page: state === 'away' ? null : front,
    width: railPanelWidth(),
  }
}
