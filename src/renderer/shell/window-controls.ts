/**
 * The room the operating system takes out of our own toolbar for its window
 * buttons, measured rather than guessed.
 *
 * ## What this is for
 *
 * On Windows the app now hides the OS title bar and asks Windows to draw the
 * real minimise/maximise/close buttons *inside* our bar, in its top-right
 * corner (`main/title-bar.ts` argues at length for using the real buttons
 * rather than three glyphs in HTML). Those buttons are painted over the page,
 * not laid out in it, so nothing in this document knows they are there — and
 * whatever the toolbar puts on its right-hand side ends up underneath them.
 * Today that is the mode switch, which would be three unclickable words with a
 * close button sitting on top of them.
 *
 * ## Why the width is read from the browser and not written down
 *
 * It is tempting to reserve a constant. 138px is the usual figure. It is also
 * wrong about half the time: the caption buttons are a different width on
 * Windows 10 and Windows 11, they change again when the window is maximised,
 * they scale with the display's DPI, and the tablet-mode and touch-target
 * settings widen them further. Chromium already knows the exact rectangle and
 * offers it — `navigator.windowControlsOverlay.getTitlebarAreaRect()` is the
 * part of the title bar we are still allowed to use, and it fires
 * `geometrychange` whenever that changes. Reading it is both simpler than a
 * table of magic numbers and correct on machines nobody here can test on.
 *
 * The measurement is published as a CSS custom property on the root element
 * rather than returned to a component, because the two things that have to move
 * out of the way — the toolbar's right-hand padding and, on the other side of
 * the window, the sidebar's traffic-light gutter — are in different subtrees.
 * `theme.ts` writes an attribute on the same element for the same reason: some
 * facts belong to the window, not to a component.
 */

/** Set on the root element while the OS is drawing window buttons in our bar. */
export const WINDOW_CONTROLS_ATTRIBUTE = 'data-window-controls'

/** How much room they take on the right, in px, as a CSS custom property. */
export const WINDOW_CONTROLS_INSET = '--window-controls-inset'

/** The slice of a `DOMRect` this needs. */
export interface TitlebarArea {
  x: number
  width: number
}

/**
 * The slice of `navigator.windowControlsOverlay` this needs.
 *
 * Declared rather than imported: TypeScript's DOM library has no entry for the
 * Window Controls Overlay API, and widening the global `Navigator` type from
 * here would be a change every other file has to live with. A structural type
 * plus the guard below is the same safety with none of the reach.
 */
export interface WindowControlsOverlay {
  visible: boolean
  getTitlebarAreaRect(): TitlebarArea
  addEventListener(type: 'geometrychange', listener: () => void): void
  removeEventListener(type: 'geometrychange', listener: () => void): void
}

/**
 * Everything this touches outside itself, as a value.
 *
 * The same shape `theme.ts` takes, and for the same reason: the test process
 * here has no DOM at all — deliberately, see CLAUDE.md — so a module that
 * reached for `document` could not be exercised in a single test. Handed a
 * host, every branch below can be.
 */
export interface WindowControlsHost {
  root: {
    setAttribute(name: string, value: string): void
    removeAttribute(name: string): void
    style: {
      setProperty(name: string, value: string): void
      removeProperty(name: string): void
    }
  }
  overlay: WindowControlsOverlay | null
  windowWidth(): number
}

/**
 * How far the window buttons reach in from the right edge.
 *
 * The rect handed over is the part of the title bar that is *ours*; what the OS
 * has taken is whatever is left over on the right of it. Deriving it by
 * subtraction rather than assuming a button width is what makes this right at
 * every DPI and on both Windows versions.
 *
 * Zero for anything that does not describe a strip of buttons on the right — a
 * rect wider than the window, a negative remainder, a NaN out of a mocked API.
 * Zero is the safe answer because it is what every platform without an overlay
 * already renders, so a nonsense measurement degrades to today's layout instead
 * of pushing the mode switch into the middle of the bar.
 *
 * A right-to-left Windows install puts the caption buttons on the *left*, and
 * this would then return 0. That is left alone on purpose: the shell is
 * left-to-right throughout — the sidebar is the first child of a plain flex row
 * — so a window whose buttons had moved would need the whole layout mirrored,
 * not a padding swapped, and half of that is worse than none of it.
 */
export function controlsInset(area: TitlebarArea | null, windowWidth: number): number {
  if (!area) return 0
  const inset = windowWidth - (area.x + area.width)
  if (!Number.isFinite(inset) || inset <= 0) return 0
  return Math.round(inset)
}

function isWindowControlsOverlay(value: unknown): value is WindowControlsOverlay {
  if (typeof value !== 'object' || value === null) return false
  const candidate = value as Partial<WindowControlsOverlay>
  return (
    typeof candidate.visible === 'boolean' &&
    typeof candidate.getTitlebarAreaRect === 'function' &&
    typeof candidate.addEventListener === 'function' &&
    typeof candidate.removeEventListener === 'function'
  )
}

/**
 * Publish the geometry, and keep publishing it. Returns the undo.
 *
 * ## Why `visible` gates the attribute and not just the measurement
 *
 * `visible` is false in two quite different situations: this platform draws no
 * overlay at all (macOS, Linux), and this window is full screen, where Windows
 * takes its buttons away. The stylesheet reads the attribute for a third fact —
 * that there are no traffic lights on the left, so the sidebar's 82px gutter
 * reserve is dead space — and getting *that* wrong on macOS would drop the
 * sidebar's collapse arrow directly on top of the traffic lights, on the
 * platform that works today.
 *
 * So `visible` gates everything, and the cost is paid where it is cheapest: a
 * full-screen Windows window keeps an 82px gap at the top of the sidebar where
 * traffic lights would be on a Mac. A gap in full screen is a blemish; an arrow
 * on top of the close button is a broken window.
 */
export function installWindowControls(host: WindowControlsHost): () => void {
  const overlay = host.overlay
  const clear = (): void => {
    host.root.removeAttribute(WINDOW_CONTROLS_ATTRIBUTE)
    host.root.style.removeProperty(WINDOW_CONTROLS_INSET)
  }
  if (!overlay) return clear

  const apply = (): void => {
    if (!overlay.visible) {
      clear()
      return
    }
    host.root.setAttribute(WINDOW_CONTROLS_ATTRIBUTE, 'overlay')
    // Written even when it is zero — an overlay that is visible and measures
    // nothing is a rect that has not been laid out yet, and leaving the
    // previous window's number in place would reserve room for buttons that
    // have moved.
    host.root.style.setProperty(
      WINDOW_CONTROLS_INSET,
      `${controlsInset(overlay.getTitlebarAreaRect(), host.windowWidth())}px`,
    )
  }

  apply()
  overlay.addEventListener('geometrychange', apply)
  return () => {
    overlay.removeEventListener('geometrychange', apply)
    clear()
  }
}

/**
 * The real window, as a host — or null where there is no document to write to.
 *
 * Called from an effect, never at import time: this module is imported by
 * `WindowToolbar.tsx`, which is rendered to a string by `chrome-render.test.tsx`
 * in a process that has no `document` at all. A module that touched a global on
 * the way in would take that whole file down with it.
 */
export function browserWindowControls(): WindowControlsHost | null {
  if (typeof document === 'undefined' || typeof navigator === 'undefined') return null
  const overlay = (navigator as Navigator & { windowControlsOverlay?: unknown })
    .windowControlsOverlay
  return {
    root: document.documentElement,
    overlay: isWindowControlsOverlay(overlay) ? overlay : null,
    windowWidth: () => window.innerWidth,
  }
}
