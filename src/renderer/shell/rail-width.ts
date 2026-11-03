/**
 * The rail's column, as a number and as a drag.
 *
 * Both halves used to live inside `useSidebar`, which was the only thing that
 * could ever want them. That stopped being true on 2026-08-21: the copilot's
 * side panel now *takes* the rail's column while it is driving a page, at a
 * width of its own, and it is dragged by the same seam —
 *
 * > *"And this one should be also like the other panel. It should be like we
 * > should be able to make it bigger or smaller, this side panel of Copilot."*
 *
 * — so the clamp, the storage shape and the pointer bookkeeping are shared
 * rather than written twice. Two copies of a drag is how the panel and the rail
 * come to disagree about where the seam is, which is the defect this whole round
 * of side-panel work is about.
 *
 * The bounds are the rail's own and are deliberately not widened for the panel.
 * `shell.css` caps `.sidebar` at `--sidebar-max` and tightens both bounds again
 * under 1000px and 760px of window, so a panel allowed past 380 would be clamped
 * by CSS at a width its own drag believed it had — the pointer would come away
 * from the seam. He asked for the panel to resize *like the rail*, and the rail
 * is 220 to 380.
 */

/** Matches `--sidebar-min` / `--sidebar-max` / `--sidebar-width` in tokens.css. */
export const RAIL_MIN = 220
export const RAIL_MAX = 380
export const RAIL_DEFAULT = 264

export function clampRail(width: number): number {
  return Math.min(RAIL_MAX, Math.max(RAIL_MIN, width))
}

/**
 * A stored width, or the fallback.
 *
 * Anything outside the bounds is treated as absent rather than clamped into
 * range: a number that far out came from an older build's bounds or from a hand
 * edit, and silently honouring half of it is how a window opens at a width
 * nobody chose.
 */
export function readRailWidth(key: string, fallback: number): number {
  const raw = Number(localStorage.getItem(key))
  return Number.isFinite(raw) && raw >= RAIL_MIN && raw <= RAIL_MAX ? raw : fallback
}

/**
 * Where a drag that started at `startX` with `startWidth` has reached.
 *
 * Pure, exported and tested, because it is the one line of a resize that can be
 * wrong in a way nobody sees until they are holding the seam.
 */
export function widthAfterDrag(startWidth: number, startX: number, clientX: number): number {
  return clampRail(startWidth + (clientX - startX))
}

/**
 * Follow the pointer until it is let go.
 *
 * The window's listeners rather than the element's, because a fast drag leaves
 * the 7px seam long before it leaves the window, and a handler on the seam would
 * stop tracking the moment it did. Text selection is suppressed for the duration
 * or the drag paints half the rail blue.
 */
export function trackRailDrag(startX: number, startWidth: number, apply: (width: number) => void): void {
  let dragging = true

  const onMove = (event: MouseEvent): void => {
    if (!dragging) return
    apply(widthAfterDrag(startWidth, startX, event.clientX))
  }
  const onUp = (): void => {
    dragging = false
    window.removeEventListener('mousemove', onMove)
    window.removeEventListener('mouseup', onUp)
    document.body.style.userSelect = ''
  }

  document.body.style.userSelect = 'none'
  window.addEventListener('mousemove', onMove)
  window.addEventListener('mouseup', onUp)
}
