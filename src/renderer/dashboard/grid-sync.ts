/**
 * Which tiles gridstack should let go of and which it should adopt.
 *
 * ## The bug this is the fix for
 *
 * From the recording: **a widget on the Overview page disappeared mid-session
 * and never came back**, leaving a hole in the grid beside the tiles that
 * survived. It reads as a rendering glitch and it is not — it is a bookkeeping
 * one, and it is permanent for the life of the window.
 *
 * `Dashboard` keeps two records of the same tiles. `elements` maps a widget id
 * to the DOM node React last gave it; `managed` was a `Set` of the ids
 * gridstack had been told about. The reconcile loop read:
 *
 *     if (live.has(id)) continue                  // still in the layout: keep
 *     …
 *     if (!managed.has(widget.id)) grid.makeWidget(el, …)   // new: adopt
 *
 * Both lines are about *ids*, and the thing that actually changes is the
 * *node*. A tile that renders `null` for one commit and comes back — which is
 * exactly what happens when a feature that owns a widget is switched off and on
 * again in Settings — unmounts its `<div>` and mounts a brand new one under the
 * same id. After that, `elements` holds the new node, `managed` still holds the
 * id, and:
 *
 *   - nothing removes the **old** node from gridstack's engine, so the cells it
 *     occupied stay reserved by a node that is no longer in the document;
 *   - nothing calls `makeWidget` on the **new** node, because its id is already
 *     "managed" — so it never gets the absolute position gridstack applies, and
 *     inside a `.grid-stack` that means it has no size and no place. It is in
 *     the DOM and it is invisible.
 *
 * Nothing ever recovers from that: the ids agree with each other for the rest
 * of the session, so every later pass takes the same two `continue`s.
 *
 * So the record has to be keyed on the id *and* hold the node, and the decision
 * has to compare nodes. That decision is this function — pure, and generic over
 * the element type so it can be tested without a DOM, which this project does
 * not have.
 */

export interface GridSync<T> {
  /** Managed nodes gridstack must be told to release, oldest bookkeeping first. */
  drop: Array<{ id: string; element: T }>
  /** Nodes gridstack has not been told about, in the order they were given. */
  adopt: Array<{ id: string; element: T }>
}

/**
 * @param managed What gridstack currently has, id → the node it was handed.
 * @param drawn   What React currently renders, id → node, in the order they
 *                should be added. Visual order matters to gridstack: adding
 *                top-left tiles first means its upward packing has nothing to
 *                pull up, so a saved arrangement lands exactly as it was left.
 */
export function reconcileGrid<T>(
  managed: ReadonlyMap<string, T>,
  drawn: ReadonlyMap<string, T>,
): GridSync<T> {
  const drop: Array<{ id: string; element: T }> = []
  const adopt: Array<{ id: string; element: T }> = []

  for (const [id, element] of managed) {
    // Gone from the page, **or** the same id wearing a different node. The
    // second half is the whole fix: an id alone cannot tell those apart, and
    // the node is what gridstack actually holds.
    if (drawn.get(id) === element) continue
    drop.push({ id, element })
  }

  for (const [id, element] of drawn) {
    if (managed.get(id) === element) continue
    adopt.push({ id, element })
  }

  return { drop, adopt }
}
