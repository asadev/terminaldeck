import { useEffect, useRef } from 'react'

/**
 * One menu open at a time, for the whole window.
 *
 * Reported, watching a session: *"see how it looks like — they can all open at
 * once, so they come over to each other."* Six floating surfaces live on a
 * session screen — the folder chip and the account chip under the title, and
 * the plus, the Model chip, the Permission chip, the Options panel and the
 * microphone inside the chat box — and two of them on screen together are two
 * glass panels overlapping, each showing half of the other.
 *
 * ## Why every one of them already had a dismiss listener and it still happened
 *
 * They all close on a click outside themselves. `chip-menu.ts` does it on a
 * document `pointerdown` in the capture phase; the four in the composer do it
 * on a document `mousedown`. So for most pairs the second menu's opening click
 * *is* an outside click for the first, and the first goes away — which is why
 * this looked fixed from the code and was not fixed on the screen.
 *
 * "Outside" is the word doing the damage. It is measured against a DOM subtree,
 * and one of these menus contains the buttons that open two of the others:
 * `AgentControls` tests the click against `.agent-controls`, and the Model and
 * Permission chips are *inside* `.agent-controls`, one row above the panel. So
 * pressing Model with the Options panel open is a click inside the panel's own
 * root — not a dismissal — and the chip's menu opens on top of the panel that
 * is still there. That is the overlap in the recording.
 *
 * The rest of the pairs worked by accident of markup rather than by rule. Move
 * the account chip inside the folder chip's wrapper, or draw a picker inside
 * the panel it belongs to, and the same defect comes back somewhere new. So the
 * rule is stated once, here, instead of six times as a geometry each menu
 * happens to satisfy: whichever menu opened last is the one that is open.
 *
 * ## Why a module-level holder rather than a React context
 *
 * Two of these menus render through `createPortal` into `<body>` and one of
 * them (`AttachMenu`) is mounted by a component that is rendered to a string in
 * its own tests. A context would have to be provided above every one of them —
 * which means `App.tsx`, and a provider that a test forgets is a menu that
 * silently opts out of the rule. A module-level holder is in scope for anything
 * that imports it, needs no wiring, and is a plain value two lines of test can
 * drive without a DOM. There is exactly one window per renderer process, so
 * there is exactly one "the menu that is open" to hold.
 */

interface OpenMenu {
  /**
   * Identity of the menu, not of the component.
   *
   * A symbol rather than a string key: two `ControlPicker`s are on screen at
   * once and neither knows what the other is called, so anything a component
   * could name itself would collide between them. Held in a ref for the life of
   * the component, so re-rendering while open does not look like a new menu.
   */
  readonly id: symbol
  close(): void
}

let current: OpenMenu | null = null

/**
 * Say that this menu is now open, and shut whatever was.
 *
 * `current` is assigned *before* the displaced menu is told, and that ordering
 * is load-bearing: closing it sets React state, whose cleanup then calls
 * {@link releaseMenu} for the menu that just went away. Releasing after the new
 * holder is in place is a no-op, because the id no longer matches. Releasing
 * before it would clear the holder that was just claimed, and the next menu to
 * open would find nothing to close.
 */
export function claimMenu(entry: OpenMenu): void {
  const displaced = current
  current = entry
  if (displaced && displaced.id !== entry.id) displaced.close()
}

/**
 * This menu has closed.
 *
 * Guarded on the id because a close and a claim race by construction — the
 * claim above closes the previous menu, and the previous menu's cleanup arrives
 * afterwards. Only the menu that is still holding the slot may clear it.
 */
export function releaseMenu(id: symbol): void {
  if (current?.id === id) current = null
}

/**
 * Take part in the rule.
 *
 * `open` is whatever state the menu already keeps for itself, and `close` is
 * whatever it already does to shut — deliberately not a new state machine. The
 * one thing a caller must get right is that `close` here is the *bare* shut,
 * not the full dismissal: `AttachMenu`'s own `close()` also returns focus to
 * the composer, and doing that when the user has just pressed a different chip
 * would pull focus out of the control they are reaching for.
 */
export function useOneMenu(open: boolean, close: () => void): void {
  const idRef = useRef<symbol | null>(null)
  if (idRef.current === null) idRef.current = Symbol('menu')
  const id = idRef.current

  // The latest `close`, kept out of the claim's dependencies. A menu that
  // re-renders while it is open — and these re-render on every keystroke of the
  // session's output — must not release and re-claim the slot each time, or a
  // menu opened a moment ago would displace itself and shut the one it opened
  // over. Updated in its own effect, declared first so it has run before the
  // claim below on every render.
  const closeRef = useRef(close)
  useEffect(() => {
    closeRef.current = close
  })

  useEffect(() => {
    if (!open) return
    claimMenu({ id, close: () => closeRef.current() })
    return () => releaseMenu(id)
  }, [open, id])
}
