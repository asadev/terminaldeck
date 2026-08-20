import { useLayoutEffect, type RefObject } from 'react'

/**
 * How much window there actually is under a panel that hangs off a bar.
 *
 * ## The defect, measured rather than reasoned about
 *
 * Asad, on the recording of 2026-08-20, watching two panels on the same header
 * row: *"Now, see this window is going out of the frame. This one also going out
 * of the frame."*
 *
 * Both sheets on that row already carried a clamp that looked like it answered
 * exactly this — `max-height: min(560px, calc(100vh - 100% - var(--sp-8)))` —
 * and it does not, for a reason that only shows up on a short window. In
 * `max-height`, a percentage resolves against the *containing block's height*,
 * not against where that block sits. So the formula subtracts the 28-pixel chip
 * row the sheet hangs off and nothing at all for the 58 pixels of title bar and
 * toolbar above it. Rendered in the running app at a 560-pixel window the folded
 * Session-controls sheet measured `top: 92, height: 500, bottom: 592` — 32
 * pixels past the bottom edge, with no scroll to reach the rows below the fold
 * because the element believed it was already inside its cap.
 *
 * ## Why this is measured in script and not spelled in CSS
 *
 * Because the number CSS cannot name is the one that matters: the distance from
 * the top of the viewport to the top of *this* sheet. It is not a constant — a
 * pane bar in a split is hundreds of pixels lower than the window's own toolbar
 * — and there is no percentage, `100%` or otherwise, that resolves to it.
 *
 * So the element is asked where it is, once, at the moment it opens. Reading
 * `top` off the sheet itself rather than off its anchor is deliberate: it is the
 * exact number, it costs the same one `getBoundingClientRect`, and it holds
 * whatever the panel's containing block turns out to be — which is the
 * assumption the CSS formula was quietly making and getting wrong.
 *
 * Setting `max-height` cannot move the element's own top, so there is no second
 * pass and no loop.
 *
 * ## What it does not do
 *
 * It does not flip the panel above its anchor. Both of these hang off a bar at
 * the *top* of a pane, so "above" is the title bar and, in a split, another
 * pane's terminal — there is more room below at every window size the app can be
 * made, and a flip would trade a clipped panel for one drawn over the chrome it
 * belongs to.
 */

/**
 * The foot of the window the sheet may not touch. Matches the margin the old
 * formula was trying to keep with `--sp-8`, less the `--sp-15` gap that is
 * already inside the measured `top`.
 */
const FOOT_PX = 16

/**
 * And a floor, for the geometry where the honest answer is "there is no room".
 *
 * A pane bar low in a tall split can leave under a hundred pixels below it. A
 * sheet clamped to that is a sliver, but a sliver that scrolls can be read; the
 * alternative — letting the clamp go to nothing — is the panel disappearing at
 * the moment it opens, which is a worse bug than the one this file fixes.
 */
const MIN_ROOM_PX = 120

/**
 * Publish `--sheet-room` on a panel element: the pixels between its own top and
 * the foot of the window.
 *
 * The stylesheet is what decides *whether* to spend them — every sheet here caps
 * itself at a design height first and takes this only when the window is
 * shorter than that — so the CSS keeps its own `min(…)` and this is one term
 * inside it.
 *
 * `active` is for the caller that keeps the element in the tree and toggles it —
 * pass whether the panel is open. A caller that mounts the sheet only while it
 * is open can leave it alone: mounting *is* the open.
 */
export function useSheetRoom(sheet: RefObject<HTMLElement | null>, active = true): void {
  useLayoutEffect(() => {
    const el = active ? sheet.current : null
    if (el === null) return
    const measure = (): void => {
      const top = el.getBoundingClientRect().top
      const room = Math.max(MIN_ROOM_PX, window.innerHeight - top - FOOT_PX)
      el.style.setProperty('--sheet-room', `${Math.round(room)}px`)
    }
    measure()
    // The window itself changing size is the one thing that moves the foot while
    // a panel is open. A pane being dragged does too, and that path re-renders
    // this subtree anyway.
    window.addEventListener('resize', measure)
    return () => window.removeEventListener('resize', measure)
  }, [sheet, active])
}
