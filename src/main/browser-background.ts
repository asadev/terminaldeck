/**
 * What colour a browser view is before — and between — pages.
 *
 * ## The bug this exists for
 *
 * `browser-tab.ts` used to construct every view with a hardcoded `#ffffff`. In
 * dark mode that is a white rectangle where the app's content canvas should be,
 * and the recording of 2026-08-16 names it: "an empty browser page is white in
 * dark mode". A hex literal in the main process also breaks the house rule that
 * every colour comes from `tokens.css` — the main process cannot read a
 * stylesheet, so the value has to travel, exactly the way `recordingAccent()`
 * already carries `--color-critical` across for the in-page badge.
 *
 * ## Why the view does NOT simply wear the app's colour all the time
 *
 * This is the part somebody will want to "simplify" and must not.
 *
 * A `WebContentsView`'s background is Chromium's *base* background — the colour
 * a document is painted onto when the document itself declares none. Bare HTML
 * declares none: `html` and `body` are transparent by default, and every browser
 * on every platform paints white behind them regardless of the OS theme (Chrome
 * only changes this under an explicit force-dark flag). So a view permanently
 * set to `#191919` would render somebody's unstyled dev-server output as dark
 * grey with black text on it — unreadable, and wrong in a way no other browser
 * is.
 *
 * The honest split is therefore by *what is loaded*:
 *
 *  - nothing yet, or `about:blank` → the app's own canvas colour, because that
 *    rectangle is Terminal Deck's own empty space and should look like it;
 *  - an http(s) document → white, because that rectangle now belongs to somebody
 *    else's page and it must render the way it renders everywhere else.
 *
 * `browser-tab.ts` switches between the two on `did-start-navigation`, which is
 * before the new document paints — doing it on `did-navigate` is a frame late
 * and shows as a flash of the wrong colour.
 */

/** What a loaded web page is painted onto. Not a theme choice — see above. */
export const PAGE_BACKGROUND = '#ffffff'

/**
 * Accept a colour from the renderer, or refuse it.
 *
 * The value crosses IPC, so it is `unknown` until proven otherwise, and it is
 * handed to Electron rather than to a page — `setBackgroundColor` takes hex and
 * nothing else, and a malformed string there throws inside the native layer at
 * construction time, which would take the whole tab down rather than degrade.
 *
 * `#rgb`, `#rrggbb` and `#rrggbbaa` are all accepted because `tokens.css` uses
 * the short form in places, and expanded to the long form Electron documents.
 * The alpha is dropped rather than passed through: a translucent view lets the
 * app's own UI show through the page, which looks like a rendering fault.
 * Anything else — `rgb()`, a colour name, an empty custom property because the
 * token was renamed — is refused and the caller falls back, which is why this
 * returns null rather than a guess.
 */
export function safeBackground(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim().toLowerCase()
  const match = /^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/.exec(trimmed)
  if (!match) return null

  const digits = match[1]
  if (digits.length === 3) {
    return `#${digits[0]}${digits[0]}${digits[1]}${digits[1]}${digits[2]}${digits[2]}`
  }
  // Six or eight; the eight-digit form keeps its RGB and loses its alpha.
  return `#${digits.slice(0, 6)}`
}

/**
 * The colour a view should be wearing for the address it is about to show.
 *
 * `empty` is whatever the renderer sent for the app's canvas, already through
 * {@link safeBackground}. Null means the renderer did not send one — an older
 * preload, or a build where the token has been renamed — and the fallback is
 * white, because a wrong-but-conventional backdrop is better than a black
 * rectangle nobody chose.
 */
export function backgroundFor(url: string, empty: string | null): string {
  const target = url.trim().toLowerCase()
  if (target.startsWith('http://') || target.startsWith('https://')) return PAGE_BACKGROUND
  return empty ?? PAGE_BACKGROUND
}
