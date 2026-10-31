/**
 * Whether the person looking at this page already has an Esc key.
 *
 * ## Why this question decides anything
 *
 * `keybar.ts` explains at length why the on-screen row exists: the iOS software
 * keyboard has no Esc, no Tab, no Ctrl and no arrows, and hides `|`, `/`, `-`
 * and `~` behind two page flips. Without the row this client renders a terminal
 * that can type prose at a shell and nothing else.
 *
 * Every one of those reasons is a fact about a *soft* keyboard. On a laptop the
 * same row is eleven buttons duplicating eleven keys the person's hands are
 * already resting on, welded to the bottom of the one screen in this product
 * that should be nothing but terminal. That was the complaint, in those words:
 * "we are taking so much space with this unnecessary stuff — the ESC, Tab —
 * because if we are browsing we already have a keyboard."
 *
 * So the row is not a phone feature or a browser feature. It is a feature of
 * *not having keys*, and this module asks that question and nothing else.
 *
 * ## Why a media query and not the user agent
 *
 * A user-agent string answers a different question — what software is this —
 * and then gets the interesting cases wrong in both directions. An iPad with a
 * Magic Keyboard reports itself as an iPad and has a real Ctrl, Tab and arrow
 * cluster. A Windows tablet with the keyboard folded back reports a desktop
 * Windows and has no keys at all. Safari has spent a decade making iPadOS claim
 * to be macOS on purpose. Sniffing gets both of those backwards, and the person
 * on the wrong side of it either loses a row they need or keeps one they do not.
 *
 * `(hover: hover) and (pointer: fine)` is the browser answering about the
 * *input hardware attached right now*, which is the actual question. Both halves
 * are load-bearing and neither is sufficient alone:
 *
 *   - `pointer: fine` alone is true of a stylus. An iPad with an Apple Pencil
 *     and no keyboard has a fine pointer and no Esc key.
 *   - `hover: hover` alone is true of some hybrid reporting, and is what
 *     separates a device with a cursor that lives on screen from one where the
 *     "pointer" is a finger that only exists while it is touching.
 *
 * Together they mean a cursor and a precise device — a mouse or a trackpad —
 * which in practice arrives attached to a keyboard. It is an inference and it is
 * named as one; what makes it the honest signal rather than the clever one is
 * that it moves when the hardware moves, which is the next section.
 *
 * ## Why it is watched rather than read once
 *
 * An iPad snaps into and out of a Magic Keyboard while the page is open, and the
 * media query flips when it does. Read once at startup, the row would be missing
 * for somebody who has just undocked and is now holding a slab of glass with a
 * terminal on it and no way to send Ctrl+C. Subscribing costs one listener.
 *
 * ## Why "cannot tell" keeps the row
 *
 * A browser with no `matchMedia` at all, or one that refuses this query, gets
 * the row. The two ways to be wrong are not symmetrical: a redundant row on a
 * laptop is eleven buttons somebody ignores, and a missing row on a phone is a
 * terminal that cannot interrupt a runaway process. The fallback is the one
 * whose failure is recoverable.
 *
 * There is no DOM in this file, for the same reason there is none in the top
 * half of `keybar.ts`: vitest runs here with no DOM environment, so the decision
 * has to be a value a test can ask for.
 */

/**
 * The query, as a constant, so the suite can pin the string itself.
 *
 * Worth pinning rather than merely worth having: the failure this whole module
 * exists to prevent is somebody replacing it with a user-agent test, and a test
 * that only asserts the *behaviour* would keep passing while that happened.
 */
export const PHYSICAL_KEYBOARD_QUERY = '(hover: hover) and (pointer: fine)'

/**
 * The part of `MediaQueryList` this module uses.
 *
 * Structural, not the DOM type, so a test can hand over an object and drive the
 * change event. `addEventListener` on a `MediaQueryList` has been available
 * since Safari 14, well under this client's Safari 16.4 floor, so there is no
 * `addListener` fallback here and there should not be one.
 */
export interface MediaQueryLike {
  matches: boolean
  addEventListener(type: 'change', listener: (event: { matches: boolean }) => void): void
  removeEventListener(type: 'change', listener: (event: { matches: boolean }) => void): void
}

/** `window.matchMedia`, or nothing at all on a browser that has none. */
export type MatchMedia = (query: string) => MediaQueryLike

export interface KeyBarFit {
  /** Whether the on-screen key row is worth its space right now. */
  wanted: boolean
  /** Stop listening. Safe to call twice. */
  stop(): void
}

/**
 * Answer the question now, and keep answering it while the page is open.
 *
 * `onChange` fires only on a genuine flip, never for the initial value — the
 * caller has that in `wanted` and would otherwise have to guard against
 * rebuilding its layout on the first tick.
 */
export function watchPhysicalKeyboard(
  matchMedia: MatchMedia | undefined,
  onChange: (wanted: boolean) => void,
): KeyBarFit {
  if (matchMedia === undefined) {
    // See the header: the row stays when the question cannot be asked.
    return { wanted: true, stop: () => undefined }
  }

  let query: MediaQueryLike
  try {
    query = matchMedia(PHYSICAL_KEYBOARD_QUERY)
  } catch {
    // A browser that refuses the query is one that cannot answer it, which is
    // the same state as having no `matchMedia` and gets the same answer.
    return { wanted: true, stop: () => undefined }
  }

  const fit: KeyBarFit = {
    wanted: !query.matches,
    stop(): void {
      query.removeEventListener('change', listener)
    },
  }

  const listener = (event: { matches: boolean }): void => {
    const wanted = !event.matches
    // Guarded rather than passed on. A media query can fire for a change in
    // something this one does not read — a second pointer appearing beside an
    // existing mouse — and the caller's answer is to tear down and rebuild the
    // terminal's box, which loses focus and reflows scrollback.
    if (wanted === fit.wanted) return
    fit.wanted = wanted
    onChange(wanted)
  }

  query.addEventListener('change', listener)
  return fit
}
