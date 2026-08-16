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
