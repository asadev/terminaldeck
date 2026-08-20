import { useCallback, useSyncExternalStore } from 'react'
import type { WorkspaceTab } from '../shell/workspace-tabs'

/**
 * The model behind the top tab strip: which of the open windows have been
 * *promoted* out of the side panel, in what order.
 *
 * ## What he asked for, and why it is a subset rather than a second list
 *
 * From the recording of 2026-08-16: *"we should be able to just drag and drop in
 * the top whatever we want to see in the top, and the rest we can fold inside
 * the side panel."* So the sidebar keeps listing everything — every session and
 * every browser page, grouped by project, exactly as it does today — and the
 * strip holds the handful you are actually working in.
 *
 * That is why this stores **ids in an order**, not tabs. A copy of the tabs
 * would be a second source of truth for a session's title, status and account,
 * and those change constantly; a list of ids can only ever be out of date about
 * one thing (whether a tab still exists), and {@link stripTabs} resolves that on
 * every render.
 *
 * ## Why the promoted set is not "the tabs you have visited"
 *
 * An automatic strip — most-recently-used, or every browser page — was the
 * obvious alternative and is the wrong answer to what he asked. He wants to
 * *choose*, by dragging, and a strip that also rearranges itself would fight
 * that choice. Nothing promotes a tab here except a drag or an explicit
 * command; nothing demotes one except a drag out, the fold-away control, or the
 * tab being closed altogether.
 *
 * ## Both kinds, deliberately
 *
 * Sessions and browser pages promote identically. `workspace-tabs.ts` already
 * decided that a browser page is a window you opened exactly like a session is,
 * and a strip that only accepted one of them would put that decision back.
 */

const STORAGE_KEY = 'terminaldeck.strip.promoted'

/** How many tabs the strip will hold before it refuses more. */
export const MAX_PROMOTED = 12

/**
 * Put a tab in the strip, or move it if it is already there.
 *
 * `at` is an insertion index in the *resulting* list. Out-of-range values clamp
 * rather than throw, because the index comes from a pointer position and a drop
 * past the last tab is an ordinary thing to do rather than an error.
 *
 * The cap is a real refusal rather than a silent trim of the far end: a strip
 * that quietly dropped the tab at the other side while you were watching the one
 * you dragged would look like a bug in the drag.
 */
export function promote(order: readonly string[], id: string, at: number): string[] {
  const without = order.filter((entry) => entry !== id)
  if (order.length >= MAX_PROMOTED && !order.includes(id)) return [...order]

  const index = Math.min(Math.max(0, Math.trunc(at)), without.length)
  return [...without.slice(0, index), id, ...without.slice(index)]
}

/** Fold a tab back into the side panel. A no-op for one that was never in the strip. */
export function demote(order: readonly string[], id: string): string[] {
  return order.filter((entry) => entry !== id)
}

/**
 * The tabs the strip should draw, in the promoted order.
 *
 * Resolved against the live tab list on every render rather than stored,
 * which is what makes a closed session disappear from the strip with no
 * bookkeeping at the closing end — there are four ways a session can end (⌘W,
 * the row's ✕, the process exiting, a project closing) and only one of them is
 * somewhere a caller could remember to prune.
 */
export function stripTabs(
  order: readonly string[],
  tabs: readonly WorkspaceTab[],
): WorkspaceTab[] {
  const byId = new Map(tabs.map((tab) => [tab.id, tab]))
  const out: WorkspaceTab[] = []
  for (const id of order) {
    const tab = byId.get(id)
    if (tab) out.push(tab)
  }
  return out
}

/**
 * A tab as the strip draws it: the window, and whether it is *kept* there.
 *
 * The distinction is the whole of {@link shownTabs}. A promoted tab stays in
 * the strip whatever you are looking at; the other kind is in it only because
 * it is what you are looking at right now.
 */
export interface ShownTab {
  tab: WorkspaceTab
  /** True when the tab is in the promoted order, i.e. pinned there by the user. */
  promoted: boolean
}

/**
 * Everything the strip draws: what you kept, plus what you are in.
 *
 * ## The failure this exists for
 *
 * From the frames of his 2026-08-16 recording: **the title bar names a session
 * that has no tab in the strip.** That was not a bug in either half — the
 * heading names the session you are in, and the strip holds the subset you
 * dragged there, and those are two different questions with two different right
 * answers. But the two are stacked one above the other at the top of the same
 * window, so a reader is entitled to read them as one thing, and read as one
 * thing they were contradicting each other.
 *
 * The strip is the one that has to give, because the heading cannot: refusing
 * to name the session you are in is not an option. So the active tab is always
 * drawn, and when it is not promoted it is drawn as *transient* — present
 * because you are in it, gone the moment you leave it, and carrying a control
 * that offers to keep it. Every tabbed editor that has a preview tab arrived at
 * the same answer for the same reason.
 *
 * Appended at the end rather than inserted anywhere clever: the promoted order
 * is a hand-made arrangement and a tab that pushed into the middle of it would
 * move the tabs the user placed. A stale or unknown `activeId` adds nothing —
 * it is resolved against the live tab list, like everything else here.
 *
 * ## Every browser window, always, whether or not it was promoted
 *
 * Asad, 2026-08-20: *"Browser windows will not be on the side bar at all. They
 * will be always only on the top bar."* The side panel used to be the other
 * half of this pair — a page folded off the strip was still listed down there,
 * which is what made "kept, or merely in view" a safe distinction to draw for
 * both kinds. With the rail holding sessions only, a demoted browser window
 * would be open, running, and drawn nowhere in the window: an owned thing with
 * no way back to it, which is the one failure a tab strip must not have.
 *
 * So a browser window is not promotable — it is simply *present*. `promoted` is
 * true for one because that is what the flag means to everything downstream (it
 * stays whatever you are looking at), not because anybody dragged it here.
 */
export function shownTabs(
  order: readonly string[],
  tabs: readonly WorkspaceTab[],
  activeId: string | null,
): ShownTab[] {
  const shown: ShownTab[] = stripTabs(order, tabs).map((tab) => ({ tab, promoted: true }))
  const held = new Set(shown.map((entry) => entry.tab.id))
  for (const tab of tabs) {
    if (tab.kind !== 'browser' || held.has(tab.id)) continue
    shown.push({ tab, promoted: true })
    held.add(tab.id)
  }
  if (activeId === null || held.has(activeId)) return shown
  const active = tabs.find((tab) => tab.id === activeId)
  return active ? [...shown, { tab: active, promoted: false }] : shown
}

/**
 * What taking a tab off the strip does — to the arrangement, and to what the
 * window is showing.
 *
 * `select` is deliberately three-valued. `undefined` means *do not touch the
 * selection*, which is the answer for a tab you were not looking at; a string
 * names the tab to show instead; and `null` means there is nothing left in the
 * strip to show, which is a real state rather than an error — the session is
 * still running and still listed in the side panel, and the window falls back
 * to its empty view.
 */
export interface Removal {
  order: string[]
  select?: string | null
}

/**
 * Take a tab off the strip. **Not** a close.
 *
 * Asad, on the ✕ that sits on a tab: *"it should not delete the session… side
 * panel will have everything inside, and above we just set a view which one we
 * want to see."* So the strip is a set of views onto things that are open, and
 * the ✕ removes a view. Nothing here touches the session: the pty keeps
 * running, the sidebar keeps its row, and the row's own ✕ — which does end it —
 * is a different control in a different place with a different hover.
 *
 * ## Why the selection has to move as well
 *
 * Because {@link shownTabs} always draws the tab you are looking at, promoted
 * or not. Demote the active tab and it comes straight back as a *transient*
 * tab: the user presses ✕, the tab does not go away, and the strip looks
 * broken. It is not broken — the invariant is deliberate, and it is the fix for
 * the title bar naming a session with no tab — so the other half has to give:
 * removing the tab you are in means the window shows something else.
 *
 * The neighbour rule is {@link nextActiveId}'s, over the *promoted* list rather
 * than over every open window: falling to the right, then the left, then to
 * nothing. Chosen from what is left in the strip rather than from `tabs`,
 * because pulling some session you never promoted up into the bar to replace
 * the one you just took out of it would be the strip putting a tab back the
 * moment you removed one.
 *
 * A transient active tab — one that is in the strip only because you are in it
 * — has no place in the order to be a neighbour of, so the first remaining
 * promoted tab is the answer. That is also the case where the arrangement does
 * not change at all and the selection is the entire effect of the press.
 */
export function removeFromStrip(
  order: readonly string[],
  tabs: readonly WorkspaceTab[],
  id: string,
  activeId: string | null,
): Removal {
  const next = demote(order, id)
  if (id !== activeId) return { order: next }

  const index = stripTabs(order, tabs).findIndex((tab) => tab.id === id)
  const remaining = stripTabs(next, tabs)
  const select =
    index === -1
      ? (remaining[0]?.id ?? null)
      : (remaining[index]?.id ?? remaining[index - 1]?.id ?? remaining[0]?.id ?? null)
  return { order: next, select }
}

/*
 * `newcomer` used to live here and does not any more.
 *
 * It was the other half of the ＋ that sat on every tab: starting a session is
 * asynchronous, so a click had to record the ids that existed at the time and
 * recognise the arrival afterwards in order to place it *next to* the tab that
 * was pressed. There is no ＋ on a tab now — Asad, 2026-08-17: *"pills of the
 * windows will not show that plus button inside"* — so nothing opens a window
 * at a chosen position any more, and a pure function with a test and no caller
 * is exactly the kind of thing that reads as a feature and is not one.
 *
 * It is worth being clear about what it was *not*, because the name invites the
 * guess: it was never what put a new window in the strip. Nothing was. Until
 * {@link keepInStrip} below, no code path in this app promoted a window at the
 * moment it was created — a new session appeared up here only because
 * {@link shownTabs} always draws the tab you are looking at, which made it a
 * *transient* tab: italic, and gone the moment you looked at something else.
 */

/**
 * Keep a window that has just been opened, at the end of the bar.
 *
 * ## What was wrong
 *
 * Asad, 2026-08-17: *"if I open any new session and any new browser from the
 * header, it should automatically open in the top bar, in the top header, come
 * next to it in the top there. If I want to remove it from there and keep only
 * side panel, I should have to do it myself specifically."*
 *
 * Before this, opening a session from the strip's terminal glyph put a tab on
 * the bar that *looked* right and was not kept: {@link shownTabs} draws the
 * active tab whether or not it is promoted, so the new window rode up as a
 * transient tab and evaporated the first time the user clicked a different one.
 * The two halves of his sentence are one requirement — a thing that arrives on
 * its own and leaves on its own is not something you remove "specifically".
 *
 * ## Why it is not "promote whatever is active"
 *
 * That would have been one line in the component and it would have been the
 * wrong feature. This file's opening comment is explicit that the strip holds
 * what the user *chose*, and clicking a sidebar row to look at a session is not
 * choosing to keep it on the bar — a strip that filled itself up as you browsed
 * the rail is the automatic strip that was rejected in the first place.
 * Creating a window is the deliberate act; this is called there and nowhere
 * else.
 *
 * ## The two edges
 *
 * A window that is somehow already promoted stays exactly where it is rather
 * than being moved to the end: re-anchoring a tab the user placed, in response
 * to something that is not a drag, is the strip rearranging itself.
 *
 * At {@link MAX_PROMOTED} the bar refuses, like every other route in. The new
 * window is still visible up there — transient, by `shownTabs` — so the press
 * is not silent; it just does not evict a tab the user kept to make room, which
 * is the same bargain {@link promote} already strikes for a drop.
 */
export function keepInStrip(order: readonly string[], id: string): string[] {
  if (order.includes(id)) return [...order]
  return promote(order, id, order.length)
}

/**
 * Keep a window that has just been *opened from the rail*, next to the one you
 * were in.
 *
 * ## What changed, and why the comment above it now reads as history
 *
 * Asad, 2026-08-17: *"If I am clicking different ones, instead of switching,
 * whenever I click on side panel on anyone, it should open a new window instead
 * of switching. It should open its own new window next to it."*
 *
 * {@link keepInStrip}'s note argues at length that clicking a sidebar row is
 * *not* choosing to keep a tab on the bar, and that a strip which filled itself
 * as you browsed the rail would be the automatic strip this file rejected in its
 * opening paragraph. That argument was made before he had used it, and he has
 * now overruled it in as many words. It is left standing above rather than
 * deleted, because the reasoning is still the reasoning for everything else in
 * here — nothing promotes a tab on its own; what changed is that *opening a row*
 * is now counted as an act of opening a window, which is the category
 * `keepInStrip` already serves.
 *
 * What that fixes, beyond doing what he asked, is the complaint he made two
 * minutes later: *"If I click on commander, they go away."* The windows that
 * vanished were the ones he had reached from the rail — every one of them a
 * *transient* tab, drawn by {@link shownTabs} only because it was active, and
 * therefore replaced wholesale by the next thing he looked at. Once a click from
 * the rail keeps its window, nothing in the bar is disturbed by opening the
 * copilot, and the two complaints turn out to be one bug seen from both ends.
 *
 * ## "Next to it", literally
 *
 * `after` is the window he was in. The new one goes immediately to its right —
 * which is what a browser does when a link opens a tab from the one you are on,
 * and what "next to it" means when said out loud while pointing at a bar. Only
 * when that window is itself on the bar: a transient neighbour has no place in
 * the order to be next to, and neither has an `after` of null, so both fall back
 * to the end. Nothing else moves; the tabs somebody arranged by hand stay in the
 * order they were put in, which is the promise the whole file is built on.
 */
export function keepBesideInStrip(
  order: readonly string[],
  id: string,
  after: string | null,
): string[] {
  if (order.includes(id)) return [...order]
  const at = after === null ? -1 : order.indexOf(after)
  return promote(order, id, at === -1 ? order.length : at + 1)
}

/**
 * The same thing against the shared store, for a click handler in `App.tsx`.
 *
 * The seam {@link keepNewWindowInStrip} already establishes, for the one caller
 * that knows which window it is opening *from*. See that function for why a
 * handler cannot read {@link usePromotedOrder} and has to reach the store.
 */
export function keepWindowBesideInStrip(
  id: string,
  after: string | null,
  storage: Storage | null = defaultStorage(),
): void {
  const store = promotedStore(storage)
  store.set(keepBesideInStrip(store.get(), id, after))
}

/**
 * The same thing, against the shared store, for a caller that is not a
 * component.
 *
 * Every window in this app is opened from an event handler in `App.tsx` — a
 * click on the strip's terminal or globe, the dialog's Start button, the rail's
 * button, ⌘T — and none of those is a render, so none of them can read the
 * order out of {@link usePromotedOrder}. They reach the same store the strip
 * subscribes to, which is the entire reason that store exists; see
 * {@link promotedStore}. Two lines, kept here beside the function they are
 * built on rather than spread across four call sites in the largest file in the
 * renderer.
 */
export function keepNewWindowInStrip(id: string, storage: Storage | null = defaultStorage()): void {
  const store = promotedStore(storage)
  store.set(keepInStrip(store.get(), id))
}

/**
 * The inverse, against the same store: put a window away.
 *
 * The other half of the seam above, and it exists for one caller — ⌘W on the
 * **copilot**. Every other window ⌘W closes is a session or a page that can be
 * closed; the copilot is a singleton with no row in the rail and therefore no ✕
 * that ends it, so the honest answer to "close this window" is the one the tab's
 * own ✕ already gives: take it off the bar and leave the process running. That
 * has to happen from a keyboard handler, which cannot read `usePromotedOrder`,
 * which is exactly what {@link promotedStore} is for.
 *
 * The {@link Removal} is handed back rather than acted on, because moving the
 * selection is the window's business and this file has no idea what else is on
 * screen — see {@link removeFromStrip} for why the selection has to move at all.
 */
export function removeWindowFromStrip(
  id: string,
  tabs: readonly WorkspaceTab[],
  activeId: string | null,
  storage: Storage | null = defaultStorage(),
): Removal {
  const store = promotedStore(storage)
  const result = removeFromStrip(store.get(), tabs, id, activeId)
  store.set(result.order)
  return result
}

/**
 * One id has become another and the tab must not move.
 *
 * The strip is an arrangement somebody made by hand — this file's opening
 * comment is emphatic that it holds what the user *chose*, and {@link keepInStrip}
 * refuses even to re-anchor a tab it is asked to promote twice. So when
 * switching a session's account replaces its process, and with it its id, the
 * tab has to stay exactly where it was rather than being taken off the end and
 * pushed back on.
 *
 * Done by index rather than remove-then-add for that reason: the remove-and-add
 * spelling produces the right *set* and the wrong *order*, and the difference is
 * invisible until somebody with four tabs switches the account on the first one
 * and watches it jump to the end.
 *
 * An id that was never promoted stays unpromoted. A switch is not a promotion —
 * the session was already a transient tab or already on the bar, and this
 * changes neither, it only keeps whichever was true from breaking.
 */
export function replaceInStrip(order: readonly string[], oldId: string, newId: string): string[] {
  const at = order.indexOf(oldId)
  if (at < 0) return [...order]
  const next = [...order]
  next[at] = newId
  return next
}

/** The same thing against the shared store, for a caller that is not a render. */
export function replaceWindowInStrip(
  oldId: string,
  newId: string,
  storage: Storage | null = defaultStorage(),
): void {
  const store = promotedStore(storage)
  store.set(replaceInStrip(store.get(), oldId, newId))
}

/**
 * Whether the window has a tab strip at all.
 *
 * One predicate, read by both ends, because the answer decides two things that
 * must not disagree: whether {@link shownTabs} has anything to draw, and — since
 * the strip became the window's top band — whether the *session bar below it* is
 * the top band instead. Getting those two out of step puts the macOS traffic
 * lights on top of a session's title, or leaves an 82-pixel hole where they are
 * not.
 */
export function stripIsPresent(tabs: readonly WorkspaceTab[]): boolean {
  return tabs.length > 0
}

/**
 * Drop the ids of tabs this window has watched close.
 *
 * Only worth calling when something is about to be written to storage — reading
 * goes through {@link stripTabs}, which ignores dead ids anyway. What this is
 * for is keeping the stored arrangement from filling up with the ids of windows
 * that are gone.
 *
 * ## The `seen` argument, and the bug it exists for
 *
 * Measured, not imagined. Promote five sessions, reload the renderer, and one
 * of them is gone from the strip for good — reproduced four times out of four,
 * with the write caught in the act: a single `setItem` during the load, holding
 * four ids where storage had five, at a moment when the sidebar had not drawn a
 * single row yet.
 *
 * The cause is that a reload does not restore the session list in one step. The
 * renderer comes up empty, asks the main process which ptys are still running,
 * and fills the list as the answers land — so for a few frames `tabs` is a
 * *partial* view of what is open. Pruning against a partial list deletes the
 * ids that have not arrived yet, and because the result is written straight
 * through to storage, the deletion is permanent. The `tabs.length === 0` guard
 * at the call site was written for exactly this hazard and only covers the
 * empty case, which is the one frame of it that is easy to think of.
 *
 * So an id is forgotten only when this window has actually *seen* its tab alive
 * and then seen it go. An id that has never appeared is left alone: it costs
 * nothing to keep — {@link stripTabs} ignores it — and it is the only way to
 * tell "closed" apart from "still on its way". That is safe against filling up
 * with rubbish because the order does not survive an app restart at all; see
 * {@link defaultStorage}.
 *
 * The default makes `seen` optional and means "everything in the order has been
 * seen", which is the old behaviour and the right answer for a caller that
 * genuinely knows the list is complete.
 */
export function pruneOrder(
  order: readonly string[],
  tabs: readonly WorkspaceTab[],
  seen: ReadonlySet<string> = new Set(order),
): string[] {
  const live = new Set(tabs.map((tab) => tab.id))
  return order.filter((id) => live.has(id) || !seen.has(id))
}

/**
 * Where a drop between tabs should land, given each tab's box and the pointer.
 *
 * The midpoint rule every tab strip uses: past the middle of a tab means after
 * it. Written against rectangles rather than reading the DOM so the interesting
 * half is testable in a project whose test run has no DOM at all.
 *
 * `rects` is in strip order and is the *dragged-over* strip, so an index equal
 * to its length means "at the end", which is a legitimate answer rather than an
 * overflow.
 */
export function dropIndex(rects: ReadonlyArray<{ left: number; width: number }>, x: number): number {
  for (let index = 0; index < rects.length; index++) {
    const rect = rects[index]
    if (x < rect.left + rect.width / 2) return index
  }
  return rects.length
}

/* ------------------------------------------------------------- storage -- */

/**
 * The strip, as it was left before the last reload.
 *
 * The thing worth surviving is a renderer reload — ⌘R, a recovered crash, a
 * rebuild while the app is running — where every pty is still alive and every
 * id still names something. An app restart is not: the ptys are gone and so are
 * their ids. {@link defaultStorage} is what draws that line, and it draws it
 * with the storage's own lifetime rather than with a rule this file would have
 * to remember to apply.
 */
export function readPromoted(storage: Storage | null): string[] {
  if (!storage) return []
  try {
    const raw = storage.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter((entry): entry is string => typeof entry === 'string' && entry !== '')
  } catch {
    // Corrupt JSON, or a store disabled between reads. An empty strip is a
    // worse start than a full one and no reason at all to refuse to render.
    return []
  }
}

export function writePromoted(storage: Storage | null, order: readonly string[]): void {
  if (!storage) return
  try {
    storage.setItem(STORAGE_KEY, JSON.stringify([...order]))
  } catch {
    // Quota, or a disabled store. Forgetting the arrangement costs a drag.
  }
}

/* --------------------------------------------------------------- sharing -- */

/**
 * The promoted order, held where more than one part of the window can reach it.
 *
 * ## Why this stopped being `useState` inside the strip
 *
 * A drag is a mouse-only gesture, and this one was the only way in or out of
 * the strip. Anything else that wants to promote a tab — the "Show at the top"
 * toggle on a sidebar row, which is what makes the feature reachable from a
 * keyboard — has to change the same list the strip is rendering from, and it
 * lives in a different component with no ancestor to hold the state between
 * them. Lifting it to `App.tsx` would work and would put a piece of tab-strip
 * bookkeeping in the file that is already the largest in the renderer; a store
 * the two of them read directly keeps it beside the functions that operate on
 * it.
 *
 * ## Why it is a store rather than a module-level array
 *
 * Because React has to be told. `useSyncExternalStore` is the supported way to
 * read a value that changes outside React, and it is what makes the sidebar's
 * toggle repaint the strip in the same commit — a plain array plus a re-render
 * hope is the shape of the bug where the aria state and the screen disagree.
 *
 * The snapshot is a cached array, not a fresh copy per call: `getSnapshot` is
 * compared by identity, and returning `[...order]` each time is an infinite
 * render loop with a confusing error message.
 */
export interface PromotedStore {
  /** The current order. Stable by identity until it actually changes. */
  get(): readonly string[]
  /** Replace it. A no-op — and no notification — when nothing moved. */
  set(next: readonly string[]): void
  subscribe(listener: () => void): () => void
}

export function createPromotedStore(storage: Storage | null): PromotedStore {
  let order: readonly string[] = readPromoted(storage)
  const listeners = new Set<() => void>()

  return {
    get: () => order,
    set(next) {
      /*
       * The guard is load-bearing, not an optimisation. The strip prunes its
       * order against the live tab list in an effect on every render; without
       * this, that effect would write a new array identity every time, wake
       * every subscriber, and re-run itself for ever.
       */
      if (next.length === order.length && next.every((id, index) => id === order[index])) return
      order = [...next]
      writePromoted(storage, order)
      // A copy of the set, so a listener that unsubscribes itself while being
      // notified does not shorten the list being walked.
      for (const listener of [...listeners]) listener()
    },
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}

/**
 * `window.sessionStorage`, when this window has one.
 *
 * ## Why session storage and not local
 *
 * Because it already has exactly the lifetime this arrangement wants, and
 * `localStorage` had one that was too long by a whole class of problem.
 *
 * A promoted tab is identified by a session id, and a session is a pty in this
 * main process. Quit the app and every one of those ids names nothing for ever
 * — so an order kept in `localStorage` accumulates, run after run, twelve dead
 * ids at a time, and {@link promote} counts them against its cap. Two runs of
 * that and the cap is full of ghosts: the strip looks empty and refuses to
 * accept anything, with no way for the user to see why. Nothing about the
 * strip's behaviour after a restart changes by moving here, because
 * {@link stripTabs} was already resolving those ids to nothing.
 *
 * What the arrangement genuinely has to survive is a **renderer reload** — ⌘R,
 * a crash React recovered from, a rebuild during development — where the main
 * process and every pty are still running and the ids are still good. Session
 * storage survives exactly that and nothing more. Verified in the running app
 * rather than taken from the specification: written, reloaded, read back.
 *
 * Reading the property can itself throw where storage is disabled by policy,
 * so this is a try/catch and not a `typeof` test alone — the same guard
 * `NewSessionDialog` uses, for the same reason.
 */
export function defaultStorage(): Storage | null {
  try {
    return typeof window === 'undefined' ? null : window.sessionStorage
  } catch {
    return null
  }
}

/**
 * One store per backing storage.
 *
 * Keyed on the storage object rather than kept as a single global, so a test
 * that hands the strip its own `Storage` stand-in gets its own order and cannot
 * leak it into the next test. The real app passes `window.sessionStorage` every
 * time, which is one object, so the sidebar and the strip meet on one store.
 */
const stores = new WeakMap<Storage, PromotedStore>()
/** The store for `storage === null`: nothing to key a WeakMap on. */
let unbacked: PromotedStore | null = null

export function promotedStore(storage: Storage | null): PromotedStore {
  if (!storage) return (unbacked ??= createPromotedStore(null))
  const existing = stores.get(storage)
  if (existing) return existing
  const made = createPromotedStore(storage)
  stores.set(storage, made)
  return made
}

/**
 * The promoted order, as React state, from either end of the window.
 *
 * The third argument to `useSyncExternalStore` is the server snapshot, and it
 * is not optional here even though this is a desktop app: every render test in
 * this project goes through `react-dom/server`, and React throws
 * "Missing getServerSnapshot" rather than rendering without it.
 */
export function usePromotedOrder(
  storage: Storage | null = defaultStorage(),
): [readonly string[], (next: readonly string[]) => void] {
  const store = promotedStore(storage)
  const order = useSyncExternalStore(store.subscribe, store.get, store.get)
  const set = useCallback((next: readonly string[]) => store.set(next), [store])
  return [order, set]
}
