import { useEffect, useState, type RefObject } from 'react'

/**
 * Where a pane's body is, in the pane area's own coordinates, so a terminal
 * that cannot live inside the pane tree can be drawn over the hole it leaves.
 *
 * ## Why any of this exists
 *
 * Three kinds of session are drawn in this window and only one of them can be
 * mounted and unmounted freely. A local terminal is redrawn from the main
 * process's scrollback, so the split view mounts it inside the pane and throws
 * it away when the pane goes. The other two cannot take that:
 *
 *  - A **session on a paired machine** replays its whole scrollback on every
 *    attach, over the relay. Unmounting it is a detach, and coming back is
 *    another machine sending the conversation again — *"if I go to other page
 *    and come back, it will start from beginning again."*
 *  - A **terminal on a server** has nothing keeping its output but the xterm it
 *    is written into, and unmounting `ServerSessionPane` closes the SSH shell
 *    for real.
 *
 * So both are mounted *beside* the pane tree, for as long as their tab exists,
 * and hidden rather than unmounted. That is what made them impossible to put in
 * a split: a pane is a box inside a layout, and these two live outside it.
 *
 *   > *"Like I cannot even split"* — 2026-08-21, on a server session.
 *
 * ## The arrangement
 *
 * The pane draws its bar and leaves its body **empty**, marked with
 * {@link SLOT_ATTR} naming the tab it is holding. This module measures those
 * holes against the pane area itself, and the always-mounted terminal is given
 * the box as inline `top/left/width/height`. The terminal never moves in the
 * React tree, so it is never remounted, never re-attached and never re-replayed
 * — it is simply somewhere else on screen.
 *
 * This is the same trick the browser pages already play one level down: a
 * `WebContentsView` is a native surface composited over the renderer, and
 * `BrowserWorkspace` pushes it the rectangle of the element standing in for it.
 * A remote terminal is the renderer's own version of the same problem.
 *
 * ## Why not a portal
 *
 * A React portal whose container changes unmounts its children from the old
 * container and mounts new ones in the new — new DOM, new xterm, and for a
 * server shell that is the SSH session closed. Moving the element with
 * `appendChild` would preserve it, but then two owners write to one subtree.
 * Positioning is the only arrangement where React keeps owning the terminal and
 * the layout keeps owning where it goes.
 */

/** The attribute a pane's empty body carries, naming the tab it is holding. */
export const SLOT_ATTR = 'data-pane-slot'

/** A rectangle in the pane area's coordinates. */
export interface SlotBox {
  top: number
  left: number
  width: number
  height: number
}

/**
 * As little of an element as the measuring needs.
 *
 * Structural rather than `HTMLElement` so the arithmetic below can be tested
 * without a layout engine — jsdom answers every `getBoundingClientRect` with
 * zeroes, which would make a test of this pass while measuring nothing.
 */
export interface SlotElement {
  getAttribute(name: string): string | null
  getBoundingClientRect(): { top: number; left: number; width: number; height: number }
}

export interface SlotHost {
  getBoundingClientRect(): { top: number; left: number; width: number; height: number }
  querySelectorAll(selector: string): ArrayLike<SlotElement>
}

/**
 * Every slot in the host, keyed by the tab it names.
 *
 * Relative to the host and not to the viewport, because the host is the
 * positioning parent the terminals are absolutely placed in: an absolute box
 * given viewport coordinates would be off by the sidebar's width and the tab
 * strip's height, and would drift the moment either changed.
 *
 * A slot with no tab id, or one with no area yet, is left out rather than
 * recorded as a zero box — the caller draws nothing where there is no box, and
 * drawing a terminal at 0×0 in the corner is a worse answer than not drawing it
 * for one frame.
 */
export function measureSlots(host: SlotHost | null): Record<string, SlotBox> {
  if (host === null) return {}
  const origin = host.getBoundingClientRect()
  const boxes: Record<string, SlotBox> = {}
  const slots = host.querySelectorAll(`[${SLOT_ATTR}]`)
  for (let index = 0; index < slots.length; index += 1) {
    const slot = slots[index]
    if (slot === undefined) continue
    const id = slot.getAttribute(SLOT_ATTR)
    if (id === null || id === '') continue
    const box = slot.getBoundingClientRect()
    if (box.width <= 0 || box.height <= 0) continue
    boxes[id] = {
      top: box.top - origin.top,
      left: box.left - origin.left,
      width: box.width,
      height: box.height,
    }
  }
  return boxes
}

/**
 * Whether two measurements are the same picture.
 *
 * The measuring runs on every resize frame while a divider is being dragged, and
 * `setState` with a fresh object each time would re-render the whole window
 * sixty times a second for a rectangle that has not moved. Compared to the
 * nearest tenth of a pixel: sub-pixel jitter from a scrollbar appearing is not a
 * layout change anybody can see, and chasing it is the same wasted render.
 */
export function sameBoxes(a: Record<string, SlotBox>, b: Record<string, SlotBox>): boolean {
  const keys = Object.keys(a)
  if (keys.length !== Object.keys(b).length) return false
  for (const key of keys) {
    const one = a[key]
    const two = b[key]
    if (one === undefined || two === undefined) return false
    if (Math.round(one.top * 10) !== Math.round(two.top * 10)) return false
    if (Math.round(one.left * 10) !== Math.round(two.left * 10)) return false
    if (Math.round(one.width * 10) !== Math.round(two.width * 10)) return false
    if (Math.round(one.height * 10) !== Math.round(two.height * 10)) return false
  }
  return true
}

/**
 * The live boxes, re-measured whenever the layout or the window moves.
 *
 * `signature` is the caller's own description of the arrangement — which panes
 * hold which tabs — so a layout change re-measures on the render that caused it
 * rather than waiting for an observer callback a frame later. The observers
 * cover everything a render cannot see: a divider being dragged, the sidebar
 * being resized, the window itself.
 *
 * Empty while `active` is false, which is the unsplit window: there are no
 * slots then, the terminals fill the whole pane area from CSS, and measuring
 * would be work per resize for an answer nobody reads.
 */
export function usePaneSlots(
  hostRef: RefObject<HTMLElement | null>,
  active: boolean,
  signature: string,
): Record<string, SlotBox> {
  const [boxes, setBoxes] = useState<Record<string, SlotBox>>({})

  useEffect(() => {
    if (!active) {
      setBoxes((current) => (Object.keys(current).length === 0 ? current : {}))
      return
    }
    const host = hostRef.current
    if (host === null) return

    const measure = (): void => {
      const next = measureSlots(host)
      setBoxes((current) => (sameBoxes(current, next) ? current : next))
    }
    measure()

    /*
     * `ResizeObserver` is absent in the string-rendering harness this file's
     * callers are tested in, and a missing global here would take the whole
     * window down rather than lose a rectangle. The window's own resize event
     * is the fallback, which covers the case that matters most on a machine
     * without one — the window being made bigger.
     */
    const Observer = globalThis.ResizeObserver
    const observer = typeof Observer === 'function' ? new Observer(measure) : null
    observer?.observe(host)
    for (const slot of Array.from(host.querySelectorAll(`[${SLOT_ATTR}]`))) observer?.observe(slot)
    globalThis.addEventListener?.('resize', measure)
    return () => {
      observer?.disconnect()
      globalThis.removeEventListener?.('resize', measure)
    }
  }, [hostRef, active, signature])

  return boxes
}

/**
 * The inline style an always-mounted terminal takes to stand in a pane's hole.
 *
 * `inset` is cleared as well as the four sides being set, because the stylesheet
 * places these panes with `inset: 0` to fill the whole pane area — the state
 * this returns `undefined` for. A `top` alone would leave `right` and `bottom`
 * pinned to the far edges and the pane would be stretched rather than moved.
 */
export function slotStyle(box: SlotBox | undefined): Record<string, string> | undefined {
  if (box === undefined) return undefined
  return {
    inset: 'auto',
    top: `${box.top}px`,
    left: `${box.left}px`,
    width: `${box.width}px`,
    height: `${box.height}px`,
  }
}
