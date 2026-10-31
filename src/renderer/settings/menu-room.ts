/**
 * Where a row's ⋯ menu opens, when the pane it lives in has no room under it.
 *
 * ## The defect, measured rather than reasoned about
 *
 * The per-row menu in Settings → Coding AI is an absolutely-positioned panel
 * hanging off its own row, inside `.settings-panel`, which is the sheet's one
 * scrolling element and is followed by a footer. Opening it on the last account
 * in the list drew a grey sliver: rendered at 1280×900 on 2026-08-20 the box
 * measured `{y: 757.8, h: 98, bottom: 855.8}` against a panel whose bottom edge
 * is 786, so `Use by default`, `Rename` and `Remove` were all under the footer
 * and none of them could be pressed.
 *
 * It is the same family as the folded Session-controls sheet — a popover with no
 * room check — and `shell/sheet-room.ts` is that fix. This is not that file
 * because the two answer different questions. That one clamps a *height* against
 * the window, and deliberately never flips, because both of its panels hang off
 * a bar at the top of a pane where there is always more room below. This one is
 * anchored to a row that can be anywhere in a list, so the honest answer at the
 * bottom of the list is to open *upwards*.
 *
 * ## Why measured in script rather than spelled in CSS
 *
 * The number that decides it is the distance from this row to the bottom of the
 * scrolling pane, and there is no CSS length that names it: the row's position
 * is whatever the list and the scroll offset make it, and `bottom` percentages
 * in `max-height` resolve against the containing block's height, not against
 * where that block sits. So the element is asked where it is, at the moment it
 * opens, and again if the window is resized while it is open.
 *
 * `data-up` is an attribute rather than a class so the stylesheet reads as the
 * two states it is — see `.settings-rowmenu[data-up]` in `SettingsWindow.css`.
 */

/** The gap kept between the menu and the foot of the pane. */
const MARGIN_PX = 8

/**
 * The scrolling box a menu is clipped by, or the window.
 *
 * Walked rather than hard-coded to `.settings-panel`: the same row menu is
 * rendered by `AccountsView`, which is also mounted on its own, and a helper
 * that only works inside one named ancestor is a helper that silently stops
 * working the first time the pane is reused.
 */
export function clipperOf(el: HTMLElement): { top: number; bottom: number } {
  for (let node = el.parentElement; node !== null; node = node.parentElement) {
    const style = getComputedStyle(node)
    if (/(auto|scroll|hidden)/.test(`${style.overflowY} ${style.overflow}`)) {
      const rect = node.getBoundingClientRect()
      return { top: rect.top, bottom: rect.bottom }
    }
  }
  return { top: 0, bottom: window.innerHeight }
}

/**
 * Decide, for one open `<details>`, whether its panel opens down or up.
 *
 * Down is the default and stays the default: this only flips when the panel
 * genuinely does not fit below *and* there is more room above it, so a menu near
 * the top of a short pane is left where it was rather than being flipped into
 * the ceiling.
 *
 * @param details the disclosure. Closed, the attribute is cleared, so the next
 *   open measures again from a known state rather than from the last answer.
 * @param panel the floating part. Absent — no markup for it yet — is a no-op.
 */
export function placeRowMenu(details: HTMLElement, panel: HTMLElement | null): void {
  if (panel === null) return
  if (!(details as HTMLDetailsElement).open) {
    details.removeAttribute('data-up')
    return
  }
  // Measure the downward placement, always: the attribute may be left over from
  // the previous open at a different scroll position.
  details.removeAttribute('data-up')
  const box = panel.getBoundingClientRect()
  const clip = clipperOf(details)
  const anchor = details.getBoundingClientRect()
  const roomBelow = clip.bottom - anchor.bottom - MARGIN_PX
  const roomAbove = anchor.top - clip.top - MARGIN_PX
  if (box.height <= roomBelow) return
  // Up only when it is actually better up there. A pane too short for the menu
  // either way keeps it downward, where the panel's own scroll can reach the
  // rows — see `max-block-size` on `.settings-rowmenu-items`.
  if (roomAbove > roomBelow) details.setAttribute('data-up', '')
  /*
   * And a height it can live inside either way, published for the stylesheet to
   * spend. Without this a menu with nowhere to go is a menu with items below the
   * fold and no way to scroll to them, which is the bug this file is about
   * wearing a smaller hat.
   */
  const room = Math.max(roomAbove, roomBelow)
  panel.style.setProperty('--menu-room', `${Math.max(0, Math.round(room))}px`)
}

/**
 * The `onToggle` handler itself, so a component is one line rather than five.
 *
 * `currentTarget` is the `<details>`, which is where React puts the listener,
 * and the panel is found by class inside it — the same class the stylesheet
 * positions, so the two cannot come to disagree about which element moves.
 */
export function onMenuToggle(event: { currentTarget: HTMLElement }): void {
  const details = event.currentTarget
  placeRowMenu(details, details.querySelector<HTMLElement>('.settings-rowmenu-items'))
}
