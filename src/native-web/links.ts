/**
 * Links the page opens, handed to the native window.
 *
 * In Electron the main process catches every way a page opens a link —
 * `window.open`, a `target="_blank"` anchor, a session's link routed to a
 * browser tab (`link:open-tab`), "Open in System Browser" (`link:system`) — and
 * sends it to a browser tab or the system browser. A WKWebView does none of
 * that by itself, so each is turned into one message to the native side:
 *
 *     { type: 'open-link', url, disposition: 'tab' | 'external' }
 *
 * The rule for which is the engine's own: a URL the app's browser may load
 * opens in a tab (`isNavigationAllowed`, `main/browser-url.ts`); anything else
 * that may leave the app at all goes to the system (`canOpenOutside` in
 * `main/link-open.ts`, whose list of schemes that never leave is copied below
 * and held equal to it by `links.test.ts`); and the rest is refused.
 */

import { isNavigationAllowed } from '../main/browser-url'

export type LinkDisposition = 'tab' | 'external'

export interface OpenLinkMessage {
  type: 'open-link'
  url: string
  disposition: LinkDisposition
}

/** `NEVER_LEAVES` in `main/link-open.ts`: script and in-process URLs, never handed to the system. */
export const NEVER_LEAVES: ReadonlySet<string> = new Set([
  'javascript:',
  'vbscript:',
  'data:',
  'blob:',
  'about:',
  'chrome:',
  'chrome-extension:',
  'devtools:',
  'filesystem:',
  'view-source:',
])

function schemeOf(url: string): string | null {
  const match = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(url.trim())
  return match ? `${match[1].toLowerCase()}:` : null
}

/** `canOpenOutside` in `main/link-open.ts`: whether a URL may be handed to the system at all. */
export function canOpenOutside(url: unknown): boolean {
  if (typeof url !== 'string' || url.trim() === '') return false
  const scheme = schemeOf(url)
  return scheme !== null && !NEVER_LEAVES.has(scheme)
}

/** Where a link opens: a tab in the native browser, the system, or nowhere (null). */
export function linkDisposition(url: unknown): LinkDisposition | null {
  if (typeof url !== 'string' || url.trim() === '') return null
  if (isNavigationAllowed(url)) return 'tab'
  return canOpenOutside(url) ? 'external' : null
}

/** One link to the native side, said once even when two of the page's handlers report the same press. */
export function createLinkOpener(post: (message: OpenLinkMessage) => void, now: () => number = () => Date.now()) {
  let last: { key: string; at: number } | null = null
  return (url: string, disposition: LinkDisposition | null = linkDisposition(url)): boolean => {
    if (disposition === null) return false
    const key = `${disposition} ${url}`
    const at = now()
    if (last !== null && last.key === key && at - last.at < 500) return true
    last = { key, at }
    post({ type: 'open-link', url, disposition })
    return true
  }
}

interface LinkHost {
  location: { href: string; origin: string }
  open?: unknown
  document: {
    addEventListener(type: 'click', listener: (event: LinkClick) => void, capture?: boolean): void
  }
}

interface LinkClick {
  defaultPrevented: boolean
  button?: number
  target: unknown
  preventDefault(): void
}

/** The anchor a click landed in, if any. */
function anchorOf(target: unknown): { href: string; target: string } | null {
  const element = target as { closest?(selector: string): unknown } | null
  const anchor = typeof element?.closest === 'function' ? (element.closest('a[href]') as { href?: unknown; target?: unknown } | null) : null
  if (!anchor || typeof anchor.href !== 'string') return null
  return { href: anchor.href, target: typeof anchor.target === 'string' ? anchor.target : '' }
}

/**
 * `window.open` and anchors that leave the app. A click the page has already
 * handled (`preventDefault`) is left to it; a link inside the app's own origin
 * that is not for a new window navigates as usual.
 */
export function installPageLinks(host: LinkHost, open: (url: string) => boolean): void {
  host.open = (url?: unknown): null => {
    if (url === undefined || url === null || url === '') return null
    try {
      open(new URL(String(url), host.location.href).toString())
    } catch {
      /* not a URL: nothing to open */
    }
    return null
  }
  host.document.addEventListener('click', (event) => {
    if (event.defaultPrevented || (event.button ?? 0) !== 0) return
    const anchor = anchorOf(event.target)
    if (anchor === null) return
    let url: URL
    try {
      url = new URL(anchor.href, host.location.href)
    } catch {
      return
    }
    if (anchor.target !== '_blank' && url.origin === host.location.origin) return
    event.preventDefault()
    open(url.toString())
  })
}
