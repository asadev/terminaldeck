/**
 * URL handling for the embedded browser tab.
 *
 * Pure and separate from `browser-tab.ts` so it can be tested without an
 * Electron window. Two things here are load-bearing:
 *
 * 1. `localhost:3000` — the single most likely thing to be typed into this URL
 *    bar — parses as a URL whose *scheme* is `localhost:`. Verified in node:
 *    `new URL('localhost:3000').protocol === 'localhost:'`. Naive scheme
 *    detection therefore sends the most common input down the "unknown scheme"
 *    path and fails it.
 * 2. The guest is untrusted, so navigation is allow-listed rather than
 *    deny-listed. `file:` is the one that matters most — a page that can talk
 *    the view into `file:///Users/...` can read the user's disk through the
 *    same inspection channel the feature exists to provide.
 */

/** Everything the embedded browser is allowed to load. */
const ALLOWED_PROTOCOLS = new Set(['http:', 'https:'])

/** Loaded into a fresh view before the user navigates anywhere. */
export const BLANK_URL = 'about:blank'

export type NormalizeResult = { ok: true; url: string } | { ok: false; reason: string }

/** `host:port` with an optional path — the shape that fools `new URL`. */
const HOST_PORT = /^(?:[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*|\[[0-9a-fA-F:]+\]):\d{1,5}(?:[/?#].*)?$/

/** Any scheme at all, per RFC 3986. */
const HAS_SCHEME = /^[a-zA-Z][a-zA-Z0-9+.-]*:/

/**
 * Turn whatever the user typed into a URL worth loading, or explain why not.
 *
 * The refusal messages are written to be shown in the URL bar, so they say what
 * the user should do rather than what the parser thought.
 */
export function normalizeUrl(input: unknown): NormalizeResult {
  if (typeof input !== 'string') return { ok: false, reason: 'Enter a URL to open.' }
  const trimmed = input.trim()
  if (!trimmed) return { ok: false, reason: 'Enter a URL to open.' }
  // Inner whitespace or control characters mean a paste went wrong, or is
  // smuggling a second target past the eye. A real URL percent-encodes them.
  if (/[\u0000-\u0020\u007f]/.test(trimmed)) {
    return { ok: false, reason: 'That URL contains characters a URL cannot contain.' }
  }

  let candidate = trimmed
  if (HAS_SCHEME.test(trimmed)) {
    const scheme = trimmed.slice(0, trimmed.indexOf(':')).toLowerCase()
    // `localhost:3000` and `127.0.0.1:8080` look like schemes and are not.
    if (!ALLOWED_PROTOCOLS.has(`${scheme}:`)) {
      if (!HOST_PORT.test(trimmed)) {
        return { ok: false, reason: `Only http and https can be opened here, not ${scheme}:.` }
      }
      candidate = `http://${trimmed}`
    }
  } else {
    // Protocol-relative and bare hosts both become http; a dev server is
    // overwhelmingly the thing being opened, and https on localhost is rare.
    candidate = trimmed.startsWith('//') ? `http:${trimmed}` : `http://${trimmed}`
  }

  let parsed: URL
  try {
    parsed = new URL(candidate)
  } catch {
    return { ok: false, reason: 'That is not a URL this can open.' }
  }

  if (!ALLOWED_PROTOCOLS.has(parsed.protocol)) {
    return {
      ok: false,
      reason: `Only http and https can be opened here, not ${parsed.protocol}`,
    }
  }
  if (!parsed.hostname) return { ok: false, reason: 'That URL has no host.' }

  return { ok: true, url: parsed.href }
}

/**
 * Guard for navigations the *page* initiates — links, redirects, `location =`.
 *
 * `about:blank` is permitted because it is what an empty view holds and what a
 * cancelled navigation can land on. Everything else outside http(s) is refused,
 * including `file:`, `javascript:`, `data:` and Chrome's internal schemes.
 */
export function isNavigationAllowed(url: unknown): boolean {
  if (typeof url !== 'string' || url === '') return false
  if (url === BLANK_URL) return true
  try {
    return ALLOWED_PROTOCOLS.has(new URL(url).protocol)
  } catch {
    return false
  }
}

/**
 * Longest label we will hand back. A URL's path has no length limit and the
 * page picks it, so an unclamped label goes straight into the tab strip and
 * into refusal messages — `http://x/` plus a megabyte of path is a legal URL.
 */
const MAX_LABEL_LENGTH = 120

/**
 * What a page with no name of its own is called.
 *
 * The renderer keeps its own copy in `browser/tabs.ts` — it cannot import from
 * `src/main` — and `tabs.test.ts` pins the two to the same string.
 */
export const NEW_TAB_LABEL = 'New tab'

/** Origin plus path, for the tab label. Falls back to the raw string. */
export function shortLabel(url: unknown): string {
  if (typeof url !== 'string' || !url || url === BLANK_URL) return NEW_TAB_LABEL
  const source = url.length > MAX_LABEL_LENGTH * 4 ? url.slice(0, MAX_LABEL_LENGTH * 4) : url
  let label: string
  try {
    const parsed = new URL(source)
    const path = parsed.pathname === '/' ? '' : parsed.pathname
    label = `${parsed.host}${path}`
  } catch {
    label = source
  }
  // `new URL` percent-encodes control characters, but the fallback branch never
  // went through it, and this string is rendered as-is.
  label = label.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, ' ').trim()
  return label.length > MAX_LABEL_LENGTH ? `${label.slice(0, MAX_LABEL_LENGTH)}…` : label
}

/**
 * The page's own title — or nothing, when what Chromium handed back is really
 * the address wearing a title's clothes.
 *
 * `webContents.getTitle()` never returns empty. A document with no `<title>`
 * gets the URL instead, and for a tab that has not been anywhere that URL is
 * `about:blank`. Nothing downstream questioned it, so Terminal Deck's own start
 * page — the one headed "Open a page", with the list of dev servers on it —
 * introduced itself as `about:blank` in the sidebar, in the tab strip, in the
 * pane bar, and in the tooltip on all three. Every one of those is one string
 * read four times: `shortLabel` had already decided the page is called
 * "New tab", and the fallback title buried it.
 *
 * Chromium's fallback is dropped rather than special-cased on `about:blank`,
 * because the general shape is the bug: a title identical to the address is not
 * a name, it is the address — and `shortLabel` renders the address better,
 * `localhost:3000/pricing` rather than `http://localhost:3000/pricing`. A page
 * that genuinely titles itself with its own URL therefore reads as its host,
 * which is what that surface wanted in the first place.
 *
 * Compared against the raw `getURL()`, before {@link BLANK_URL} is blanked out
 * of the state, so both halves of the check are looking at the same string.
 */
export function pageTitle(title: unknown, url: unknown): string {
  if (typeof title !== 'string') return ''
  const trimmed = title.trim()
  if (!trimmed || trimmed === BLANK_URL) return ''
  return typeof url === 'string' && trimmed === url.trim() ? '' : trimmed
}
