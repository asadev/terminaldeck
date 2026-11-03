/**
 * What the URL bar does with whatever was typed into it.
 *
 * A URL bar that only takes URLs is a text field with extra steps. The three
 * cases it has to tell apart are a full URL, a bare host, and a search term —
 * and the interesting part is that two of them look identical to `new URL()`.
 *
 * ## The cases that decide the rules
 *
 * - `localhost:3000` parses as a URL whose *scheme* is `localhost:`. Checked in
 *   node, not assumed. It is also the single most likely thing to be typed here.
 * - `cats` is a legal hostname, so anything that only asks "does this parse as a
 *   host" turns every one-word search into a failed DNS lookup. That is exactly
 *   what `normalizeUrl` does with it, which is why resolution happens here first.
 * - `how do I center a div` has spaces, so it cannot be a URL at all.
 * - `1.2.3.4` is a host and `1.5` is not, and the difference is not the dot.
 *
 * ## This is a convenience, not a security boundary
 *
 * Whatever comes out of here goes to `browser:navigate`, which runs it through
 * `normalizeUrl` and refuses anything outside http(s); page-initiated navigation
 * is guarded separately by `isNavigationAllowed`. Nothing here is load-bearing
 * for safety — it decides what the user *meant*.
 *
 * That is also why there is no control-character scrub: a pasted string with a
 * newline in it fails the whitespace test and becomes a search, one with a NUL
 * fails to parse as a URL and becomes a search, and the main process refuses
 * both anyway. Adding a third check here would only make it look like the
 * important one.
 */

// Relative rather than '@shared/search': vitest runs this file without the
// alias electron-vite supplies, and `omnibox.test.ts` is the file that proves it.
import { DEFAULT_SEARCH, searchUrl } from '../../shared/search'

export type OmniboxResolution =
  | { kind: 'empty' }
  | { kind: 'url'; url: string; display: string }
  | { kind: 'search'; url: string; query: string; display: string }

/**
 * Where a search term goes. `%s` is replaced with the encoded query.
 *
 * Re-exported rather than declared: the guest page's right-click menu searches
 * too, and that menu is built in the main process, which cannot see this file.
 * `shared/search.ts` says why the one definition lives where it lives.
 */
export { DEFAULT_SEARCH }

/** `host:port` with an optional path — the shape that fools `new URL`. */
const HOST_PORT = /^(?:[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*|\[[0-9a-fA-F:]+\]):\d{1,5}(?:[/?#].*)?$/

/** Any scheme at all, per RFC 3986. */
const HAS_SCHEME = /^[a-zA-Z][a-zA-Z0-9+.-]*:/

/** Hosts that never have a dot and are still hosts. */
const LOCAL_HOSTS = new Set(['localhost', 'localhost.', '[::1]', '0.0.0.0'])

/** A dotted quad. `1.2.3.4` is a host; `1.5` is a number someone typed. */
const IPV4 = /^\d{1,3}(?:\.\d{1,3}){3}$/

/** Bracketed IPv6, which is how a literal address is written in a URL. */
const IPV6 = /^\[[0-9a-fA-F:]+\]$/

/**
 * The last label of a hostname: two or more letters, no digits.
 *
 * Chrome consults the public suffix list here. This does not, on purpose — the
 * list is thousands of lines that go stale, and the cost of being wrong is one
 * navigation the user retypes, in a browser panel that mostly points at
 * localhost. Letters-only is the rule that separates `example.com` from `1.5`
 * and `v2.0`.
 */
const TLD = /^[a-zA-Z]{2,}\.?$/

/**
 * The host part of something typed without a scheme, port removed.
 *
 * `127.0.0.1:8080` never reaches the scheme branch — a scheme has to start with
 * a letter — so the port has to come off here or the last label reads `1:8080`
 * and a perfectly good dev server becomes a web search.
 */
function hostOf(candidate: string): string | null {
  const authority = candidate.split(/[/?#]/, 1)[0]
  if (!authority) return null

  if (authority.startsWith('[')) {
    const end = authority.indexOf(']')
    if (end < 0) return null
    const after = authority.slice(end + 1)
    if (after !== '' && !/^:\d{1,5}$/.test(after)) return null
    return authority.slice(0, end + 1)
  }

  const colon = authority.indexOf(':')
  if (colon < 0) return authority
  return /^\d{1,5}$/.test(authority.slice(colon + 1)) ? authority.slice(0, colon) : null
}

function looksLikeHost(candidate: string): boolean {
  const host = hostOf(candidate)
  if (!host) return false
  const bare = host.toLowerCase()
  if (LOCAL_HOSTS.has(bare) || IPV4.test(bare) || IPV6.test(bare)) return true
  const split = bare.split('.')
  // A fully-qualified `example.com.` splits with an empty label on the end, and
  // leaving it there means the last label is `''` — so the TLD test fails and a
  // legal absolute hostname becomes a web search. `LOCAL_HOSTS` already carries
  // `localhost.` and TLD already tolerates a trailing dot; this is the third
  // place that had to agree and did not.
  const labels = split.length > 1 && split[split.length - 1] === '' ? split.slice(0, -1) : split
  if (labels.length < 2) return false
  // An empty label anywhere but the end is `a..b`, which is not a host.
  if (labels.some((label) => label === '')) return false
  return TLD.test(labels[labels.length - 1])
}

function toUrl(candidate: string): string | null {
  try {
    const parsed = new URL(candidate)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null
    if (!parsed.hostname) return null
    return parsed.href
  } catch {
    return null
  }
}

function searchFor(query: string, template: string): OmniboxResolution {
  return { kind: 'search', url: searchUrl(query, template), query, display: query }
}

/**
 * Decide what to do with the contents of the URL bar.
 *
 * `display` is what the bar should show afterwards: the resolved URL for a
 * navigation, and the untouched query for a search — nobody wants to see their
 * question percent-encoded back at them.
 */
export function resolveOmnibox(input: string, searchTemplate = DEFAULT_SEARCH): OmniboxResolution {
  const trimmed = input.trim()
  if (!trimmed) return { kind: 'empty' }

  if (HAS_SCHEME.test(trimmed)) {
    const scheme = trimmed.slice(0, trimmed.indexOf(':')).toLowerCase()
    if (scheme === 'http' || scheme === 'https') {
      const url = toUrl(trimmed)
      return url ? { kind: 'url', url, display: url } : searchFor(trimmed, searchTemplate)
    }
    // `localhost:3000` and `127.0.0.1:8080` look like schemes and are not.
    if (HOST_PORT.test(trimmed)) {
      const url = toUrl(`http://${trimmed}`)
      if (url) return { kind: 'url', url, display: url }
    }
    // `mailto:`, `chrome:`, `javascript:` — this panel opens none of them, and
    // treating them as text is more useful than refusing outright.
    return searchFor(trimmed, searchTemplate)
  }

  if (/\s/.test(trimmed)) return searchFor(trimmed, searchTemplate)

  // Protocol-relative and bare hosts both become http: a dev server is
  // overwhelmingly what is opened here, and https on localhost is rare.
  if (trimmed.startsWith('//')) {
    const url = toUrl(`http:${trimmed}`)
    return url ? { kind: 'url', url, display: url } : searchFor(trimmed, searchTemplate)
  }

  if (looksLikeHost(trimmed)) {
    const url = toUrl(`http://${trimmed}`)
    if (url) return { kind: 'url', url, display: url }
  }

  return searchFor(trimmed, searchTemplate)
}

/*
 * There is no security indicator here any more, and that is deliberate.
 *
 * `securityOf`/`securityLabel` used to classify the page's URL so the address
 * field could draw a padlock, a monitor or a warning triangle beside it. He
 * removed the whole indicator by hand:
 *
 *   > *"since we already have here a selection, why do we show inside the link
 *   > bar also local? … It doesn't make any sense to keep in both side the same
 *   > thing. So from inside the link bar, it should be only the link, not this
 *   > thing."*
 *
 * The classifier went with the drawing rather than being left behind as a
 * tested, exported, unreferenced function — which is the shape a deleted UI
 * element comes back from. What it was reading is still visible: the field
 * prints the whole URL, scheme included, and the machine picker beside it names
 * the machine.
 */
