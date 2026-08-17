import type { FocusTarget } from './focus-target'

/**
 * The one place that decides what the focus overlay is pointing at.
 *
 * ## Why a store rather than a prop
 *
 * The overlay is drawn once, at the window level, over whichever pane happens to
 * be on screen. What it points at is decided somewhere else entirely — a tour
 * player, a "take me there" button in a recap card, a keyboard shortcut. None of
 * those is an ancestor of the overlay in the React tree, and several of them do
 * not exist yet. Threading a target down from the root to a sibling of the whole
 * application is the shape that makes every intermediate component know about a
 * feature it has nothing to do with.
 *
 * Two functions and a subscription is the whole surface. It is deliberately not
 * a React context: a context would have to be provided above `<App/>`, which is
 * the one component a parallel agent may not edit, and it would re-render the
 * entire application every time a box moved.
 *
 * ## The singleton guard
 *
 * Same `Symbol.for` treatment as `terminal-registry.ts`, for the same reason and
 * from the same experience: a second copy of this module in the same window is a
 * second store, and the symptom is a `setFocus` that returns cleanly while
 * nothing appears on screen. See that file for the argument in full.
 */

export interface FocusState {
  target: FocusTarget | null
  /**
   * Whether the scrim and ring are at full strength.
   *
   * False during travel. The dim is off while the screen is moving and on once
   * it settles: animating a scrim across the window while the pane underneath
   * is also scrolling is two motions competing, and it repaints the shadow's
   * quad on every frame of the journey.
   */
  lit: boolean
}

type Listener = (state: FocusState) => void

interface Store {
  state: FocusState
  listeners: Set<Listener>
}

const STORE = Symbol.for('terminaldeck.driving.focus')

type StoreHost = { [STORE]?: Store }

function store(): Store {
  const host = globalThis as StoreHost
  const existing = host[STORE]
  if (existing) return existing
  const created: Store = { state: { target: null, lit: true }, listeners: new Set() }
  host[STORE] = created
  return created
}

export function focusState(): FocusState {
  return store().state
}

/** Point the overlay at something. */
export function setFocus(target: FocusTarget, lit = true): void {
  publish({ target, lit })
}

/**
 * Take the overlay off.
 *
 * Immediate and total — there is no fade here and there must not be one. The
 * component renders nothing at all for a null target, which is what makes "it
 * leaves no ghost" a structural property rather than a careful one. A caller
 * that wants a fade keeps the target and sets `lit` to false first; the decision
 * to stop existing stays in one place.
 */
export function clearFocus(): void {
  publish({ target: null, lit: true })
}

/** Dim off, ring off, target kept — the state to travel in. */
export function setLit(lit: boolean): void {
  publish({ ...store().state, lit })
}

function publish(next: FocusState): void {
  const current = store()
  current.state = next
  for (const listener of current.listeners) listener(next)
}

export function subscribeFocus(listener: Listener): () => void {
  const current = store()
  current.listeners.add(listener)
  return () => {
    current.listeners.delete(listener)
  }
}

/** Test seam. Nothing in the app calls this. */
export function resetFocus(): void {
  const current = store()
  current.state = { target: null, lit: true }
  current.listeners.clear()
}
