import { useCallback, useEffect, useLayoutEffect, useRef, useState, type RefObject } from 'react'
import { useOneMenu } from './one-menu'

/**
 * The mechanics behind a chip's dropdown, shared by the two of them.
 *
 * There are two chips under the session's name now — the folder it runs in and
 * the account it runs as — and both open the same kind of menu in the same
 * place. That menu is not a `<select>`: it is portalled under `<body>`, placed
 * from its button's rectangle, and dismissed by a document-level listener, and
 * every one of those is a decision with a failure behind it rather than a
 * preference. Writing it twice would mean fixing it twice, and the second copy
 * is the one that keeps the old bug.
 *
 * ## Why the menu leaves the toolbar
 *
 * An element carrying `backdrop-filter` is a *backdrop root*, and a
 * descendant's own `backdrop-filter` may only sample what is painted inside
 * that ancestor. Inside the toolbar's glass the menu declared a 26px blur and
 * blurred nothing at all — the terminal beneath read through it razor sharp.
 * Rendered under `<body>` the backdrop is the document, and the blur has the
 * window to work with. The price is that a fixed element has no anchor, so its
 * coordinates have to be computed: {@link placeMenu}.
 *
 * ## Why dismissal is on the document, in the capture phase
 *
 * A transparent full-window backdrop is the usual trick and it is wrong here:
 * the browser panel's pages are native views layered *above* the HTML, so a
 * backdrop would be under them and the first click on a web page would not
 * close the menu. Listening on the document catches the click wherever in the
 * HTML it lands, and `pointerdown` rather than `click` so the menu is gone
 * before whatever was clicked reacts.
 *
 * ## Why that listener is not enough on its own
 *
 * It answers "was this click outside me", which is a question about markup —
 * and one of the other menus on a session screen contains the buttons that open
 * two more, so "outside" gives the wrong answer for that pair. `one-menu.ts`
 * has the whole account of it; {@link useOneMenu} below is this hook taking
 * part in the rule. Neither replaces the other: the document listener closes a
 * menu when the click lands on nothing in particular, and the rule closes it
 * when the click lands on another menu's button.
 */

/** Between the chip and its menu, and between the menu and the window's edges. */
export const MENU_GAP = 8

/**
 * Where the portalled menu goes, in viewport coordinates.
 *
 * Clamped so a chip near the right-hand edge does not push a 420px menu off the
 * window, and flipped above the button only when there is genuinely no room
 * below *and* more room above — a menu that flips on a window one pixel too
 * short is worse than one that is a little tight at the bottom.
 */
export function placeMenu(
  anchor: { left: number; top: number; bottom: number },
  menu: { width: number; height: number },
  viewport: { width: number; height: number } = {
    width: window.innerWidth,
    height: window.innerHeight,
  },
): { left: number; top: number } {
  const maxLeft = viewport.width - menu.width - MENU_GAP
  // -4px so the menu's first item aligns with the chip's label rather than with
  // the chip's rounded hit area, which is inset by that much.
  const left = Math.max(MENU_GAP, Math.min(anchor.left - 4, Math.max(MENU_GAP, maxLeft)))

  const below = anchor.bottom + MENU_GAP
  const roomBelow = viewport.height - below
  const flip = roomBelow < menu.height && anchor.top - MENU_GAP > roomBelow
  const top = flip ? Math.max(MENU_GAP, anchor.top - MENU_GAP - menu.height) : below

  return { left, top }
}

export interface ChipMenu {
  open: boolean
  /** Wraps the chip's button. */
  hostRef: RefObject<HTMLDivElement | null>
  /** Wraps the portalled menu. */
  menuRef: RefObject<HTMLDivElement | null>
  /** Viewport coordinates for the menu, recomputed before every paint. */
  at: { left: number; top: number }
  toggle(): void
  /** Close, then do the thing the row was for. */
  choose(next: () => void): void
}

/**
 * `remeasure` is any value that changes when the menu's *contents* change —
 * the folder list, the account list. The menu is measured to be placed, so a
 * row appearing after it opened (a sign-in state arriving, a folder added)
 * changes its height and leaves it positioned for the height it used to have.
 *
 * `holdEscape` is for a menu with something *inside* it that Escape should
 * cancel first — the account chip renames an account in place, and Escape there
 * means "stop renaming", not "close the menu and throw the field away". It has
 * to be a flag rather than the row's own key handler because the listener below
 * is registered on the document in the **capture** phase, so it runs before
 * anything inside the menu ever sees the key; `stopPropagation` from a row is
 * too late by then. Held only while the caller says so, so a menu with nothing
 * being edited still closes on Escape the way every other one does.
 */
export function useChipMenu(remeasure?: unknown, holdEscape = false): ChipMenu {
  const [open, setOpen] = useState(false)
  const [at, setAt] = useState({ left: 0, top: 0 })
  const hostRef = useRef<HTMLDivElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)

  /** Shut, and nothing else. What both dismissals and the window rule call. */
  const closeSelf = useCallback(() => setOpen(false), [])

  /**
   * Measure the button, then the menu, then place it. In a layout effect so the
   * move happens before paint — in a plain effect the menu renders at 0,0 for
   * one frame, which on a dark window is a visible flash in the corner.
   */
  const place = useCallback(() => {
    const button = hostRef.current?.querySelector('button')
    const menu = menuRef.current
    if (!button || !menu) return
    setAt(
      placeMenu(button.getBoundingClientRect(), {
        width: menu.offsetWidth,
        height: menu.offsetHeight,
      }),
    )
  }, [])

  useLayoutEffect(() => {
    if (!open) return
    place()
  }, [open, place, remeasure])

  // A fixed element does not follow its anchor, and the toolbar's anchor moves
  // whenever the window is resized or the sidebar is pinned or peeked away.
  useEffect(() => {
    if (!open) return
    window.addEventListener('resize', place)
    return () => window.removeEventListener('resize', place)
  }, [open, place])

  useEffect(() => {
    if (!open) return
    const onDown = (event: PointerEvent) => {
      const target = event.target
      if (target instanceof Node) {
        if (hostRef.current?.contains(target)) return
        // Checked separately from the chip: the menu is portalled under
        // <body>, so a click on one of its own rows is not inside `hostRef` and
        // would otherwise be read as a click outside — dismissing the menu
        // before the row's handler ran.
        if (menuRef.current?.contains(target)) return
      }
      setOpen(false)
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      // Something inside the menu owns this key right now. Not stopped either:
      // the thing that owns it is inside the menu and has to receive it.
      if (holdEscape) return
      // Stopped here so Escape does not travel on to whatever else in the
      // window treats it as "close" — the menu is the innermost thing open.
      event.stopPropagation()
      setOpen(false)
    }
    document.addEventListener('pointerdown', onDown, true)
    document.addEventListener('keydown', onKey, true)
    return () => {
      document.removeEventListener('pointerdown', onDown, true)
      document.removeEventListener('keydown', onKey, true)
    }
  }, [open, holdEscape])

  // Opening this chip's menu shuts whatever else in the window was open — the
  // other chip beside it, or any of the four inside the chat box. See the head
  // of this file, and `one-menu.ts` for why a dismiss listener per menu was not
  // already doing it.
  useOneMenu(open, closeSelf)

  const toggle = useCallback(() => setOpen((value) => !value), [])
  const choose = useCallback((next: () => void) => {
    setOpen(false)
    next()
  }, [])

  return { open, hostRef, menuRef, at, toggle, choose }
}
