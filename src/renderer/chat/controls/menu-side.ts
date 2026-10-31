/**
 * Which edge a chip's dropdown hangs from, so it stops leaving the window.
 *
 * ## The defect
 *
 * Asad, walking the session screen: *"see this window is going out of the frame.
 * This one also going out of the frame."* Both of them were `.ac-menu` — the
 * panel a `cc-chip` opens — and both were on chips near the **right-hand end of
 * the session bar**, which is where Model, Effort and the permission toggle all
 * live. The stylesheet anchors that panel with `left: 0` against its chip, and
 * the panel is up to 304px wide, so a chip whose left edge is within 300px of
 * the window's right edge opens a menu that runs off it. Measured off the frame
 * of his 2026-08-20 recording: the Model chip at x=1218 on a 1400px window, a
 * menu that wants 240-304px, and 120-180px of it outside the glass.
 *
 * The vertical half of this was already handled — both components measure and
 * flip above when there is no room below — which is why the horizontal half
 * looked like it must have been handled too.
 *
 * ## Why a flip and not a pixel offset
 *
 * A pixel offset ("shift it left by the overflow") unhooks the menu from the
 * thing that opened it: the panel ends up straddling the chip with neither edge
 * lined up with anything, which reads as a positioning bug even when nothing is
 * clipped. Flipping the anchor keeps one edge of the menu on one edge of its
 * chip, which is the relationship that says *this panel belongs to that chip* —
 * and it is what every menu bar on both platforms does at the end of a row.
 *
 * ## Why this is a module of its own
 *
 * `ControlPicker` and `ControlToggle` both open `.ac-menu`, both already
 * measure their own root for the vertical flip, and a second copy of this
 * decision is the copy that would keep the bug. Pure, so the arithmetic is
 * testable without a layout engine — this repository's tests have neither a DOM
 * nor a compositor, and the numbers are the whole of it.
 */

/**
 * The widest `.ac-menu` can be, from `AgentControls.css`.
 *
 * Duplicated from the stylesheet rather than measured, and the reason is timing
 * rather than laziness: the side has to be decided in the same layout pass that
 * first paints the menu, and the menu cannot be measured before it exists.
 * Measuring it after the fact would place it correctly on the *second* frame,
 * which is a visible jump on a surface that opens under the pointer.
 *
 * Using the cap rather than the actual width is deliberately pessimistic: a
 * narrow menu near the right edge may flip when it would just have fitted, and
 * a menu hanging from the wrong edge of its own chip is invisible as a defect
 * where one hanging off the window is not. `menu-side.test.ts` pins this
 * against the stylesheet so the two cannot drift.
 */
export const AC_MENU_MAX = 304

/** The clearance kept between the menu and the window's edge. */
export const AC_MENU_GAP = 8

/**
 * `'right'` means *align the menu's right edge with the chip's* — it opens
 * leftwards. `'left'` is the default, the menu opening rightwards from the
 * chip's left edge.
 */
export type MenuSide = 'left' | 'right'

/**
 * Where a menu opened from this box should hang.
 *
 * `anchor` is the chip's rectangle in viewport coordinates, which is what
 * `getBoundingClientRect` gives.
 *
 * The window can be narrower than the menu — a pane dragged very small, a
 * window on a phone-sized display — and then neither side fits. That is a real
 * state rather than an error, and the answer is `'left'`: the menu overflows to
 * the right, where the *end* of a row is cut off, rather than to the left,
 * where the ticks and the first characters of every option would be.
 */
export function menuSide(
  anchor: { left: number; right: number },
  viewportWidth: number,
  menuWidth: number = AC_MENU_MAX,
): MenuSide {
  const fitsRightwards = anchor.left + menuWidth + AC_MENU_GAP <= viewportWidth
  if (fitsRightwards) return 'left'
  const fitsLeftwards = anchor.right - menuWidth >= AC_MENU_GAP
  return fitsLeftwards ? 'right' : 'left'
}
