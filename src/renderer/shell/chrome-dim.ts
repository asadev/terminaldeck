/**
 * Telling the operating system that the window has gone dim.
 *
 * ## What this is for
 *
 * Every dialog in the app draws `.modal-overlay` — a scrim over the whole page
 * — and everything under it recedes: the rail, both bars, the terminal. On
 * Windows that is everything *except* the window's own buttons, because they
 * are not in the page. `main/title-bar.ts` argues at length for letting the OS
 * paint the real minimise/maximise/close into the top-right of our bar rather
 * than drawing three glyphs in HTML, and the price of real buttons is that they
 * are painted above the renderer's output, where no scrim can reach them.
 *
 * Asad, on the Windows build: *"when I click on settings in the windows side
 * the buttons for minimise maximise and close on the right corner comes stays
 * light so they should also get dull just like anything else."* Three bright
 * controls in the corner of a dimmed window — the brightest thing on the screen
 * is the one part of it that is not what you just opened.
 *
 * So the renderer says when it has dimmed itself, and the main process repaints
 * the strip (`overlayFor`'s `dimmed` argument). Nothing about this is Windows-
 * specific on this side: `setChromeDimmed` is a no-op wherever there is no
 * overlay to repaint, and a renderer that branched on platform to decide
 * whether to *say* something true would be a second copy of the platform rule,
 * kept in the process that cannot check it.
 *
 * ## Why it counts instead of toggling
 *
 * Dialogs stack. Settings can open the add-account dialog over itself, and a
 * confirm can open over that; each one mounts and unmounts its own overlay, and
 * the inner one unmounts *first* on the way out — but not always, because
 * closing Settings while a child is up takes both down in one render. A boolean
 * set by whoever moved last goes wrong in both directions: an inner dialog
 * closing brightens the strip while its parent is still up, and a parent
 * closing under a child leaves it dim over a window with nothing open.
 *
 * A count has neither failure. The strip is dim while at least one surface is
 * over the window, and the transitions — 0→1 and 1→0 — are the only two moments
 * anything is sent, so a stack of three dialogs is one message on the way in
 * and one on the way out.
 *
 * ## Why it takes a host
 *
 * The same shape as `window-controls.ts` and `theme.ts`, for the same reason
 * stated there: the test process has no DOM and no bridge, so a module that
 * reached for `window.deck` could not be exercised at all. Handed a host, every
 * transition below can be.
 */

/** The one call this needs from the preload bridge. */
export interface ChromeDimHost {
  setChromeDimmed(dimmed: boolean): void
}

/** What a surface gets back: call it when the surface goes away. */
export type ReleaseDim = () => void

export interface ChromeDim {
  /** One surface is now over the window. Returns its release. */
  dim(): ReleaseDim
  /** How many surfaces are holding it, for tests and for nothing else. */
  held(): number
}

/**
 * A counter over one host.
 *
 * Each release is idempotent — it forgets its own claim the first time and does
 * nothing after that. React runs a cleanup exactly once in production and twice
 * in StrictMode's development double-invoke, and a release that decremented on
 * every call would take the count negative and brighten the strip under a
 * dialog that is still open. Holding the claim in a closure rather than
 * counting calls is what makes that impossible rather than merely unlikely.
 */
export function createChromeDim(host: ChromeDimHost): ChromeDim {
  let count = 0
  return {
    dim(): ReleaseDim {
      let holding = true
      count += 1
      if (count === 1) host.setChromeDimmed(true)
      return () => {
        if (!holding) return
        holding = false
        count -= 1
        if (count === 0) host.setChromeDimmed(false)
      }
    },
    held: () => count,
  }
}

/**
 * The bridge as a host, or a host that does nothing where there is no bridge.
 *
 * Never null, unlike `browserWindowControls`. The caller is a `useEffect` in a
 * component that has to run in a renderer *and* be rendered to a string by
 * `chrome-render.test.tsx` in a process with no `window` at all, and a nullable
 * host would put that check at every call site instead of here. A no-op host is
 * the honest answer for a surface nobody is looking at.
 */
export function bridgeChromeDim(): ChromeDimHost {
  if (typeof window === 'undefined' || typeof window.deck?.setChromeDimmed !== 'function') {
    return { setChromeDimmed: () => {} }
  }
  return { setChromeDimmed: (dimmed) => window.deck.setChromeDimmed(dimmed) }
}

/**
 * The window's own counter.
 *
 * A module singleton because the thing being counted is a property of the
 * window — how many surfaces are over it — and there is one window. A counter
 * per component would be a counter per dialog, which is the boolean this
 * exists instead of.
 */
export const chromeDim: ChromeDim = createChromeDim(bridgeChromeDim())
