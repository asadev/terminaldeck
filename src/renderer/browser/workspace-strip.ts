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
 * Drop the ids of tabs that no longer exist.
 *
 * Only worth calling when something is about to be written to storage — reading
 * goes through {@link stripTabs}, which ignores them anyway. Kept separate so a
 * transient absence (a tab list that has not loaded yet) cannot permanently
 * erase somebody's strip.
 */
export function pruneOrder(order: readonly string[], tabs: readonly WorkspaceTab[]): string[] {
  const live = new Set(tabs.map((tab) => tab.id))
  return order.filter((id) => live.has(id))
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
 * The strip, as it was left last time.
 *
 * Ids of sessions are not stable across a restart — a pty does not survive
 * quitting — so most of what is read back will be gone by the time
 * {@link stripTabs} looks for it, and that is fine: it costs nothing, and it is
 * what makes the strip survive the far more common case of a renderer reload
 * with everything still running.
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
 * `window.localStorage`, when this window has one.
 *
 * Reading the property can itself throw where storage is disabled by policy,
 * so this is a try/catch and not a `typeof` test alone — the same guard
 * `NewSessionDialog` uses, for the same reason.
 */
export function defaultStorage(): Storage | null {
  try {
    return typeof window === 'undefined' ? null : window.localStorage
  } catch {
    return null
  }
}

/**
 * One store per backing storage.
 *
 * Keyed on the storage object rather than kept as a single global, so a test
 * that hands the strip its own `Storage` stand-in gets its own order and cannot
 * leak it into the next test. The real app passes `window.localStorage` every
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
