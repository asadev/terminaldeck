import type { Platform } from './platform/host'

/**
 * What the window wears at the top, per platform.
 *
 * ## The problem this exists for
 *
 * On Windows the app was drawing three stacked horizontal strips before any
 * work was visible: the OS title bar (icon, the app's name, minimise/maximise/
 * close), the application menu bar (File Edit View Window Help), and only then
 * our own toolbar. Three bars to say what one bar says. Every modern Windows
 * app — including the one this was compared against, side by side, in a
 * screenshot — draws exactly one. macOS has been right for a long time
 * (`hiddenInset` puts the traffic lights inside our own header); Windows was
 * the platform that had never caught up, and it is the first thing a Windows
 * user sees.
 *
 * ## Why `titleBarStyle: 'hidden'` + `titleBarOverlay`, and not `frame: false`
 *
 * `frame: false` removes the OS strip and everything that came with it: the
 * window buttons, the resize borders, Aero Snap, the snap-layouts flyout that
 * Windows 11 shows when you hover maximise, and the high-contrast and
 * right-to-left handling that all of those get for free. Every app that goes
 * that way ends up hand-drawing three glyph buttons in HTML, and they are never
 * right — the hover flyout is missing, the hit targets do not extend into the
 * screen corner the way the real ones do (Fitts's law: the real maximise button
 * is reachable by slamming the pointer at the top edge), and a high-contrast
 * theme leaves them painted in colours the user explicitly asked not to see.
 *
 * `titleBarStyle: 'hidden'` with `titleBarOverlay` removes the strip and keeps
 * **real** window buttons, drawn by Windows itself, in the top-right of our own
 * bar. The resize borders and snap behaviour stay too, because the window still
 * has a frame — it is simply not drawing a caption. So there is nothing here
 * pretending to be a window button; the window buttons are the window buttons.
 *
 * ## Why the colours are written out by hand here
 *
 * The overlay's background is painted by the OS, outside the page, so it cannot
 * read a CSS variable — the same wall `index.ts`'s pre-paint `backgroundColor`
 * hits, and `src/renderer/styles/tokens.test.ts` opens by listing the three
 * hand-copies of that kind that had all silently gone stale. So the two values
 * below are copies, and `title-bar.test.ts` is the mechanism that keeps them
 * honest: it reads `tokens.css`, composites the toolbar's real recipe, and
 * fails naming the token that moved. Do not "fix" a failure there by editing
 * the hex until it passes — the point of the test is that the strip and the bar
 * beside it are the same colour, and the arithmetic is written out below so the
 * next reader can check it by hand.
 *
 * The toolbar (`.toolbar` in `shell/shell.css`) is `--material-bg` over the
 * content canvas `--bg-primary`, with `--material-sheen` on top. The blur in
 * `--material-filter` contributes nothing there because what is behind the
 * toolbar is `.main`'s flat `--bg-primary`, so the composite is exact rather
 * than an approximation:
 *
 *   dark:  36×0.68 + 25×0.32 = 32.48, then the sheen's mean alpha 0.0331 of
 *          white over that → 39.85 → #282828
 *   light: 250×0.72 + 255×0.28 = 251.4, then the sheen's mean alpha 0.2986 of
 *          white over that → 252.47 → #fcfcfc
 *
 * The sheen is a vertical gradient and the OS paints a flat strip, so its
 * *mean* alpha over the bar's height is the value that minimises the seam. The
 * bar is 48px tall and the gradient runs top-to-bottom across it; a flat colour
 * cannot match a gradient everywhere, and the mean is where it is least wrong.
 *
 * The symbols take `--text-secondary`, which is what `.toolbar-btn` next to
 * them is set in. The window buttons and our own toolbar buttons are the only
 * controls on that bar, and two sets of controls on one bar drawn at two
 * different weights is the thing that makes a bar look assembled rather than
 * designed.
 */

/** The two things that can actually be painted. `system` resolves to one. */
export type Appearance = 'dark' | 'light'

/** What `store.ts` persists — the user's choice, which may defer to the OS. */
export type ThemePreference = Appearance | 'system'

/** The subset of Electron's `TitleBarOverlay` this app sets. */
export interface WindowControlsOverlay {
  color: string
  symbolColor: string
  height: number
}

/** The title-bar half of `BrowserWindowConstructorOptions`. */
export interface TitleBarChrome {
  titleBarStyle: 'default' | 'hidden' | 'hiddenInset'
  trafficLightPosition?: { x: number; y: number }
  titleBarOverlay?: WindowControlsOverlay
}

/**
 * Where macOS puts the traffic lights inside our own header.
 *
 * Not a free number: `shell.css` positions the sidebar's collapse arrow and the
 * toolbar's reveal button against it — both comments there do the arithmetic
 * from `{ x: 14, y: 12 }` and land a control on the lights' own centre line. It
 * moved from `index.ts` to here so the two platforms' answers sit side by side
 * in one file, which is the only way a Mac can review the Windows one.
 */
export const TRAFFIC_LIGHT_POSITION = { x: 14, y: 12 } as const

/**
 * The height of the Windows overlay, which must be the toolbar's height.
 *
 * `--toolbar-h` in `tokens.css`. If they disagree the window buttons are either
 * floating in a band of their own above our bar, or overhanging its bottom edge
 * onto the content — which is the three-strips look arriving by a different
 * door. Pinned in `title-bar.test.ts` against the token.
 */
export const OVERLAY_HEIGHT = 48

/** The composite worked out in the header comment, one per appearance. */
const OVERLAY: Record<Appearance, WindowControlsOverlay> = {
  dark: { color: '#282828', symbolColor: '#a8a8a8', height: OVERLAY_HEIGHT },
  light: { color: '#fcfcfc', symbolColor: '#545454', height: OVERLAY_HEIGHT },
}

/**
 * The user's theme plus the OS setting, collapsed to what is actually painted.
 *
 * The renderer has its own copy of this rule (`renderer/theme.ts`), and it has
 * to: it is the side that owns the `data-theme` attribute. This one exists
 * because the OS paints the overlay strip and the OS only understands a colour,
 * so the main process has to reach the same answer independently. They agree by
 * being the same three-line rule rather than by one calling the other, because
 * there is no call to make — they are in different processes.
 */
export function resolveAppearance(
  preference: ThemePreference,
  systemPrefersDark: boolean,
): Appearance {
  if (preference === 'system') return systemPrefersDark ? 'dark' : 'light'
  return preference
}

/**
 * Whether this platform draws its window buttons inside our own bar.
 *
 * macOS is deliberately excluded even though it also hides its title bar: there
 * the buttons are drawn by the system at a position we *ask* for
 * (`trafficLightPosition`), not by an overlay we hand a colour to, and
 * `setTitleBarOverlay` is not a method that exists there. Linux is excluded
 * because Electron's overlay support there depends on the window manager and
 * nobody on this project has a Linux machine to look at it on; leaving it with
 * the ordinary system title bar is the honest answer rather than shipping a
 * frameless window that might have no way to be moved.
 */
export function usesWindowControlsOverlay(platform: Platform): boolean {
  return platform === 'win32'
}

/**
 * The overlay to install, or null on a platform that has none.
 *
 * Null rather than a default object, because the caller must not call
 * `setTitleBarOverlay` on a window that was not created with one — it is a
 * Windows/Linux-only method and the guard has to be the same value that decided
 * the constructor options, or the two can disagree.
 */
export function overlayFor(
  platform: Platform,
  appearance: Appearance,
): WindowControlsOverlay | null {
  if (!usesWindowControlsOverlay(platform)) return null
  return OVERLAY[appearance]
}

/**
 * Everything the BrowserWindow constructor needs to know about its top edge.
 *
 * One function returning one object rather than three ternaries at the call
 * site: the previous shape (`titleBarStyle: platform === 'darwin' ? … : 'default'`
 * with `trafficLightPosition` passed unconditionally on every platform) is how
 * Windows ended up with the default frame for as long as it did. A ternary
 * inline in a constructor is a branch that can only be read on the machine that
 * takes it; this takes the platform as a value, so `title-bar.test.ts` pins
 * both answers in one run on one machine — the argument `platform/host.ts`
 * makes at length for every other platform decision in this folder.
 */
export function titleBarChrome(platform: Platform, appearance: Appearance): TitleBarChrome {
  if (platform === 'darwin') {
    return { titleBarStyle: 'hiddenInset', trafficLightPosition: { ...TRAFFIC_LIGHT_POSITION } }
  }
  const overlay = overlayFor(platform, appearance)
  if (!overlay) return { titleBarStyle: 'default' }
  return { titleBarStyle: 'hidden', titleBarOverlay: overlay }
}
