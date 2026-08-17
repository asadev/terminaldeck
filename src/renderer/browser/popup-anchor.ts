/**
 * Where a popup goes when it is meant to be *at* the thing it is about.
 *
 * His words, of the capture panel that used to dock at the bottom of the
 * window: *"rather than it comes here down, it should open a pop up here"* —
 * "here" being the element he had just clicked. So the popup is placed against
 * the element's own rectangle, and this file is the arithmetic for that.
 *
 * Pure and DOM-free, because it is the part that has edge cases: an element at
 * the very bottom of the page, an element wider than the window, an element
 * partly scrolled off. Every one of those has a test rather than a look.
 *
 * All coordinates are window CSS pixels, which is what `position: fixed` wants
 * and what `getBoundingClientRect` gives.
 */

export interface Box {
  x: number
  y: number
  width: number
  height: number
}

export interface Size {
  width: number
  height: number
}

export interface Placement {
  left: number
  top: number
  /** Which side of the anchor it ended up on, for the little pointer. */
  side: 'below' | 'above'
}

/** How far the popup sits from the element, and from the window's edges. */
const GAP = 8
const MARGIN = 8

/**
 * Place `popup` against `anchor`, inside `viewport`.
 *
 * Below the element by preference and left-aligned with it, because that is
 * where the eye already is after a click and it reads as belonging to the thing
 * above it. Three corrections, in this order:
 *
 *  1. **Flip above** when there is not enough room below *and* there is more
 *     room above. Both halves matter: on a short window neither side fits, and
 *     flipping to the worse one for the sake of flipping is how a popup ends up
 *     half off the top of the screen.
 *  2. **Slide horizontally** so the whole popup is inside the viewport. Sliding,
 *     not flipping — a popup that jumps to the other side of a wide element has
 *     visibly stopped pointing at anything.
 *  3. **Clamp**, which only bites when the popup is bigger than the window. It
 *     pins the top-left corner in view, so the popup is cut off at the far edge
 *     rather than at the edge with the close button on it.
 */
export function anchorPopup(anchor: Box, popup: Size, viewport: Size): Placement {
  const roomBelow = viewport.height - (anchor.y + anchor.height) - GAP - MARGIN
  const roomAbove = anchor.y - GAP - MARGIN

  const side: Placement['side'] =
    roomBelow >= popup.height || roomBelow >= roomAbove ? 'below' : 'above'

  let top = side === 'below' ? anchor.y + anchor.height + GAP : anchor.y - popup.height - GAP
  let left = anchor.x

  const maxLeft = viewport.width - popup.width - MARGIN
  if (left > maxLeft) left = maxLeft
  if (left < MARGIN) left = MARGIN

  const maxTop = viewport.height - popup.height - MARGIN
  if (top > maxTop) top = maxTop
  if (top < MARGIN) top = MARGIN

  return { left: Math.round(left), top: Math.round(top), side }
}

/**
 * The element's box in *window* coordinates.
 *
 * The guest reports where the element is inside the page, and the page is a
 * native view floating at some rectangle of the window. Adding one to the other
 * is the whole conversion — but it has to be clipped to the view, or an element
 * scrolled half off the top of the page anchors a popup over the toolbar,
 * pointing at nothing.
 *
 * A null rect means the page said nothing usable. The answer then is the middle
 * of the top edge of the view: still on the page, still near where a click
 * plausibly was, and never off screen.
 */
export function anchorInWindow(rect: Box | null, view: Box): Box {
  if (!rect) {
    return { x: view.x + view.width / 2, y: view.y, width: 0, height: 0 }
  }
  const x = view.x + rect.x
  const y = view.y + rect.y
  const left = Math.max(view.x, Math.min(x, view.x + view.width))
  const top = Math.max(view.y, Math.min(y, view.y + view.height))
  return {
    x: left,
    y: top,
    // Clipped so a box that starts inside the view and runs past its bottom
    // does not push the popup below the workspace.
    width: Math.max(0, Math.min(x + rect.width, view.x + view.width) - left),
    height: Math.max(0, Math.min(y + rect.height, view.y + view.height) - top),
  }
}
