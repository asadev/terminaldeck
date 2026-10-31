/**
 * Which machine is behind each browser window — for everything that draws a
 * browser window but is not the browser.
 *
 * ## What he asked for
 *
 * Asad, 2026-08-20, having pointed a browser window at his PC:
 *
 * > *"if I open any browser here and if I connect it to, let's say, desktop, now
 * > this is in desktop, it should come under this table, under the desktop
 * > sessions. So all the desktop browser, including session, should be at one
 * > place."*
 *
 * and, a minute later, having lost track of one:
 *
 * > *"Now I don't know if it is actually there or here… we always need a truth.
 * > So just be sure we always be able to see the truth."*
 *
 * The first sentence asked for a grouping in the sidebar, and later in the same
 * recording he took browser windows out of the sidebar altogether — *"Browser
 * windows will not be on the side bar at all. They will be always only on the top
 * bar."* Those two are only compatible one way: the top bar has to be able to
 * say which machine a window is on, or the fact he asked to see is on no surface
 * at all and has to be dug out of a menu.
 *
 * ## Why a module store and not a prop
 *
 * Exactly the argument `binding-view.ts` makes one file over, and for the same
 * pair of components. The fact is computed inside `BrowserWorkspace`, which is a
 * *leaf* of the tree — the panel that owns the tunnels is the only thing that can
 * answer it — and it is drawn in `WorkspaceTabStrip`, which is a sibling. The
 * only prop route between them runs up through `App.tsx` and back down, which
 * means the top bar and the browser would hold two copies of one fact and could
 * disagree about it. They already did, in the shape this store replaces: the
 * main process was told (`browserWindowOpened`) and the renderer was not, so the
 * two native menus grouped windows by machine while the strip drew a window on
 * his PC identically to one on this Mac.
 *
 * ## Why it is not read off the URL
 *
 * It cannot be. A page reached through the tunnel wears a `127.0.0.1:<n>` address
 * on **this** machine — that is the whole mechanism — so the address is precisely
 * the thing that cannot answer the question. `machines-bridge.ts`'s `servedBy`
 * resolves it against the tunnels the window itself opened, and that answer is
 * what is published here.
 *
 * ## The two rules copied from `binding-view.ts`, both measured rather than
 * reasoned about
 *
 *  - **`getSnapshot` must return an identity-stable value.** A fresh object per
 *    call is an infinite render loop, not a slow render.
 *  - **A write that changes nothing must wake nobody.** The publisher's effect
 *    re-runs on every url and title change of every window, so the common call
 *    by a wide margin is one that sets what is already set.
 */

import { useSyncExternalStore } from 'react'

/** A machine, as a window names it. Never the empty id — see {@link setWindowMachine}. */
export interface WindowMachine {
  id: string
  /** What to call it. Falls back to the id, which is what the menus do. */
  name: string
}

/**
 * The published answer, keyed by shell tab id.
 *
 * Only windows on *another* machine are in here. A window on this computer is an
 * absence rather than an entry, because every reader draws nothing for it and an
 * entry meaning "ordinary" is a row every consumer has to remember to skip.
 */
let current: ReadonlyMap<string, WindowMachine> = new Map()
const watchers = new Set<() => void>()

function wake(): void {
  for (const watcher of watchers) watcher()
}

/**
 * Say which machine is serving the page in one window — or that it is this one.
 *
 * `machine` is null for this computer, which *removes* the entry. Callers pass
 * the result of `servedBy` straight through, so "this machine" and "no tunnel"
 * are the same call and neither has to be special-cased at the call site.
 */
export function setWindowMachine(tabId: string, machine: WindowMachine | null): void {
  const held = current.get(tabId) ?? null
  if (machine === null) {
    if (held === null) return
    const next = new Map(current)
    next.delete(tabId)
    current = next
    wake()
    return
  }
  // The no-op guard. This is the call that arrives on every navigation of every
  // window; without the comparison every one of them would re-render the strip.
  if (held !== null && held.id === machine.id && held.name === machine.name) return
  const next = new Map(current)
  next.set(tabId, machine)
  current = next
  wake()
}

/** A window that has gone. Safe to call for one that was never in here. */
export function forgetWindowMachine(tabId: string): void {
  setWindowMachine(tabId, null)
}

/** Test seam. Nothing in the app calls this. */
export function resetWindowMachinesForTests(): void {
  current = new Map()
  wake()
}

function subscribe(listener: () => void): () => void {
  watchers.add(listener)
  return () => {
    watchers.delete(listener)
  }
}

/**
 * Every window that is somewhere else.
 *
 * A hook rather than a getter because the answer changes under a window that is
 * doing nothing: following a link out of a tunnelled page moves it back onto
 * this machine, and a bar that only re-read this when its own props changed
 * would keep the old machine's name over a tab whose page had left it.
 *
 * The whole map rather than one window's answer, because the one consumer left
 * has to *arrange* by this rather than mark a single tab: the strip cuts its row
 * into a run per machine, which is one decision about the whole bar and cannot
 * be assembled out of a hook call inside each child. `useWindowMachine`, the
 * per-tab reader this replaced, went with the 12px mark it was written for —
 * see the note where that mark used to live, in `BindChip.tsx`.
 *
 * The map is the stored value itself, never a copy: `useSyncExternalStore`
 * requires an identity-stable snapshot, and a fresh `new Map(current)` here
 * would be an infinite render loop rather than a slow render. Every writer above
 * replaces the map instead of mutating it, so a reader holding this reference
 * holds a value that cannot change underneath it.
 */
export function useWindowMachines(): ReadonlyMap<string, WindowMachine> {
  return useSyncExternalStore(
    subscribe,
    () => current,
    () => current,
  )
}
