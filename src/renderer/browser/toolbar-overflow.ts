import type { Box } from './popup-anchor'

/**
 * Which toolbar buttons the bar could not fit — read off the bar itself.
 *
 * ## The item
 *
 *   > *"So we can have a bigger link bar because when it is smaller, then it
 *   > becomes too small, the link bar. So I want more space for link bar. Let's
 *   > make these icons smaller and make this maybe bigger."*
 *
 * The icons did get smaller and the captions did come off, and at his own window
 * width that put 292 pixels into the address field. At the width he was
 * describing — *"when it is smaller"* — it put seven, because the old bar had
 * already dropped its captions there to survive. Measured on the running app:
 * panel 592, address 173 → 180, while the action group stayed a fixed 240. The
 * row of icons was wider than the link bar it was supposed to be making room
 * for.
 *
 * So below a narrow panel the page actions come off the bar and into the ⋯
 * menu, which is what Chrome does with the same problem and what he was pointing
 * at when he asked for the ⋮ in the first place. The threshold lives in
 * `BrowserWorkspace.css`, next to the measurements that chose it.
 *
 * ## Why the menu reads the bar rather than being told
 *
 * The alternative is a width constant in CSS and the same width again in a
 * component, and those two drift: the machine picker's threshold moved once
 * already when the bar changed under it. Here the CSS decides, alone, and this
 * module asks the buttons what happened — a button with no width is a button
 * that folded. The menu then offers exactly what is not on the bar, so the two
 * can never both show the same control, which is the duplication he objected to
 * by name elsewhere in the same review.
 *
 * It also means the row inherits the button's own name (`Inspect`, `Record`,
 * `Shot`) and its own disabled state, rather than a second copy of either.
 *
 * ## No DOM in the tests
 *
 * This project has no jsdom — see `dialog-render.test.tsx` — so both functions
 * take the narrowest slice of `Element` they actually use, in the same way
 * `tooltip.ts` takes {@link Tipped}. A real `HTMLButtonElement` satisfies
 * {@link FoldableButton} without an adapter, and a six-line fake satisfies it
 * too.
 */

/** The slice of an element {@link groupFor} reads. */
export interface Placed {
  getBoundingClientRect(): Box
}

/** The slice of a button {@link foldedActions} reads. */
export interface FoldableButton extends Placed {
  getAttribute(name: string): string | null
  readonly disabled: boolean
}

/**
 * The action group the given rectangle sits inside, or null.
 *
 * A window can hold several browser panels at once — a split shows two — and the
 * menu is portalled to `<body>`, so "the bar" is not simply the first one in the
 * document. The anchor it was opened against is the ⋯ button's own rectangle,
 * and that button is inside exactly one group, so the containing group is the
 * one that opened this menu.
 */
export function groupFor<T extends Placed>(groups: ArrayLike<T>, anchor: Box): T | null {
  const x = anchor.x + anchor.width / 2
  const y = anchor.y + anchor.height / 2
  for (let i = 0; i < groups.length; i++) {
    const group: T | undefined = groups[i]
    if (group === undefined) continue
    const box = group.getBoundingClientRect()
    if (x >= box.x && x <= box.x + box.width && y >= box.y && y <= box.y + box.height) {
      return group
    }
  }
  return null
}

/** A control that is not on the bar, and how to offer it. */
export interface FoldedAction<T> {
  /** The button itself. Pressing the menu row presses this. */
  button: T
  /** Its own one-word name, which is also what its hover says. */
  label: string
  disabled: boolean
}

/**
 * The foldable buttons that are currently off the bar, in bar order.
 *
 * Width and not `display` or a class: a folded button is folded by whatever the
 * stylesheet decided, and the only thing every way of hiding it has in common is
 * that it occupies nothing. A button that is on the bar is skipped, which is why
 * a recording in progress keeps its Stop button *and* keeps it out of the menu —
 * the CSS leaves a pressed control on the bar.
 */
export function foldedActions<T extends FoldableButton>(buttons: ArrayLike<T>): FoldedAction<T>[] {
  const out: FoldedAction<T>[] = []
  for (let i = 0; i < buttons.length; i++) {
    const button: T | undefined = buttons[i]
    if (button === undefined) continue
    if (button.getBoundingClientRect().width > 0) continue
    const label = button.getAttribute('title') ?? button.getAttribute('aria-label') ?? ''
    if (label === '') continue
    out.push({ button, label, disabled: button.disabled })
  }
  return out
}
