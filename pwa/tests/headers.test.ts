/**
 * The headers app.terminaldeck.dev serves, pinned.
 *
 * ## Why a test and not just the file
 *
 * `pwa/vercel.json` is JSON, so it cannot hold a sentence explaining itself, and
 * a security policy nobody can read the reasons for is a security policy the
 * next person loosens by accident. The reasons live here, next to assertions
 * that fail if the policy stops matching them.
 *
 * It also pins the one value in that file that is a copy of something else. The
 * relay origin appears in `src/shared/relay-wire.ts` as `DEFAULT_RELAY_URL` and
 * again inside the CSP's `connect-src`, because a CSP is a string a CDN serves
 * and cannot import a TypeScript constant. Two copies of one fact drift, and the
 * failure that drift produces is the worst kind: the client is correct, the
 * relay is up, the handshake never starts, and the browser's only account of it
 * is a line in a console nobody has open. So the copies are held against each
 * other here.
 *
 * ## Why this origin has its own subdomain at all
 *
 * Browsers isolate storage by origin. This client keeps a bearer credential and
 * an X25519 private key in web storage — `pwa/src/endpoint.ts` says why it must
 * — and on the marketing site's origin every one of those bytes would be
 * readable by anything that ever lands there: an analytics tag, an embedded
 * widget, a dependency that changes hands. A separate host is the only boundary
 * the platform actually enforces, so the client gets one.
 */

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { DEFAULT_RELAY_URL } from '../../src/shared/relay-wire'

interface HeaderRule {
  source: string
  headers: { key: string; value: string }[]
}

const config = JSON.parse(
  readFileSync(fileURLToPath(new URL('../vercel.json', import.meta.url)), 'utf8'),
) as { headers: HeaderRule[] }

/**
 * Every header the rules matching `path` would set, folded by lowercased name.
 *
 * Vercel matches `source` with path-to-regexp, and reimplementing that here
 * would be a second, wrong copy of somebody else's matcher. So only the two
 * shapes this file actually uses are understood — a literal path, and a literal
 * prefix followed by `(.*)` — and a source using anything else throws rather
 * than being silently treated as a miss, which would turn a header that stopped
 * being served into a test that still passes.
 */
function headersFor(path: string): Map<string, string> {
  const found = new Map<string, string>()
  for (const rule of config.headers) {
    const literal = rule.source.replace(/\(\.\*\)$/, '')
    if (/[:*?[\](]/.test(literal)) throw new Error(`unrecognised header source ${rule.source}`)
    const matches = literal === rule.source ? path === literal : path.startsWith(literal)
    // Later rules win, which is how Vercel resolves two rules setting one header.
    if (matches) for (const header of rule.headers) found.set(header.key.toLowerCase(), header.value)
  }
  return found
}

/** `connect-src 'self' wss://…` → `{ 'connect-src': ["'self'", 'wss://…'] }`. */
function policy(): Map<string, string[]> {
  const csp = headersFor('/index.html').get('content-security-policy')
  expect(csp, 'every response must carry a CSP').toBeTypeOf('string')
  const directives = new Map<string, string[]>()
  for (const part of (csp as string).split(';')) {
    const [name, ...values] = part.trim().split(/\s+/)
    if (name) directives.set(name.toLowerCase(), values)
  }
  return directives
}

describe('the CSP app.terminaldeck.dev serves', () => {
  it('starts from nothing, so a source nobody thought about is refused', () => {
    // `default-src 'none'` rather than `'self'`: the difference is what happens
    // to a fetch destination this client does not use today and grows tomorrow.
    // With `'self'` it would be quietly permitted; with `'none'` it fails, is
    // noticed, and is added on purpose.
    expect(policy().get('default-src')).toEqual(["'none'"])
  })

  it('reaches the relay over wss and nothing else', () => {
    const relay = new URL(DEFAULT_RELAY_URL)
    expect(relay.protocol).toBe('wss:')
    // `'self'` is here for the service worker, which shares this policy — the
    // response headers of `sw.js` are its CSP — and fetches the shell over
    // same-origin HTTP. Nothing on the page uses `fetch` at all; the only
    // network this client opens is the WebSocket in `relay-socket.ts`.
    expect(policy().get('connect-src')).toEqual(["'self'", `wss://${relay.host}`])
  })

  it('names an origin, never a scheme or a wildcard', () => {
    // `connect-src wss:` would look strict and give away the whole point:
    // exfiltrating a credential over a WebSocket to any host would still be
    // allowed, which is the exact thing this directive is here to stop. The
    // cost is real and is accepted — a pairing link pointing at somebody's own
    // relay cannot be used *on this origin*, and fails saying that address
    // cannot be opened from this page. Self-hosting the relay means serving the
    // client too, which is what the desktop already does.
    for (const source of policy().get('connect-src') ?? []) {
      expect(source).not.toMatch(/^(wss|ws|https|http):$/)
      expect(source).not.toContain('*')
    }
  })

  it('runs only script this origin served', () => {
    // No `'unsafe-inline'`, no `'unsafe-eval'`, no hashes, no nonces. The bundle
    // is one hashed file; nothing here builds script at runtime, and
    // `pwa/dist` contains no `eval` or `new Function` for a bundler to need one.
    expect(policy().get('script-src')).toEqual(["'self'"])
  })

  it("allows inline style, because xterm's renderer writes CSS at runtime", () => {
    // Not a concession made to save effort — it is forced, and by a dependency
    // that cannot be configured out of it. `@xterm/xterm`'s DOM renderer builds
    // three `<style>` elements whose text carries the measured cell dimensions
    // and the resolved theme colours, and its selection code reaches for
    // `setAttribute('style', …)` per cell. Nonces do not help: the elements are
    // created by library code this client does not own. Removing it means
    // replacing the renderer.
    //
    // The exposure is bounded and worth naming: inline *style* cannot execute,
    // and `script-src` above is what actually stands between an injected string
    // and this origin's storage.
    expect(policy().get('style-src')).toEqual(["'self'", "'unsafe-inline'"])
  })

  it('cannot be framed, and cannot be navigated somewhere else', () => {
    // `frame-ancestors 'none'` is the one that matters: framed, this client
    // would be clickjackable into approving whatever the outer page arranged.
    // `base-uri` and `form-action` close the two ways injected markup redirects
    // a page without running any script of its own.
    expect(policy().get('frame-ancestors')).toEqual(["'none'"])
    expect(policy().get('base-uri')).toEqual(["'none'"])
    expect(policy().get('form-action')).toEqual(["'none'"])
    // Kept alongside `frame-ancestors` for the browsers that still only read it.
    expect(headersFor('/index.html').get('x-frame-options')).toBe('DENY')
  })
})

describe('the rest of the response', () => {
  it('sends no referrer anywhere', () => {
    // The document already carries `<meta name="referrer" content="no-referrer">`
    // — this is the same promise made where a proxy can see it, and it covers
    // requests made before the document has parsed.
    //
    // It matters more here than on an ordinary page: a pairing link arrives as
    // `#t=<token>`, and while a fragment is never sent in a request line, a
    // `Referer` is exactly the header that has historically leaked one.
    expect(headersFor('/index.html').get('referrer-policy')).toBe('no-referrer')
  })

  it('refuses to be downgraded for two years', () => {
    const hsts = headersFor('/index.html').get('strict-transport-security') ?? ''
    expect(hsts).toMatch(/max-age=(\d+)/)
    expect(Number(/max-age=(\d+)/.exec(hsts)?.[1])).toBeGreaterThanOrEqual(31536000)
    // No `preload`. Submitting to the preload list commits every *sibling*
    // subdomain of terminaldeck.dev to HTTPS forever, and that is the apex
    // owner's decision to make, not this client's.
    expect(hsts).not.toContain('preload')
  })

  it('does not let the type of a response be guessed', () => {
    expect(headersFor('/index.html').get('x-content-type-options')).toBe('nosniff')
  })

  it('gives away no capability this client does not use', () => {
    const permissions = headersFor('/index.html').get('permissions-policy') ?? ''
    // A terminal needs a keyboard and a socket. It does not need a camera — the
    // QR code is read by the phone's own camera app, not by this page — and a
    // client holding a credential should not be one prompt away from any of
    // these if something ever gets injected into it.
    for (const feature of ['camera', 'microphone', 'geolocation', 'display-capture', 'usb']) {
      expect(permissions).toContain(`${feature}=()`)
    }
  })

  it('caches the hashed bundle forever and the worker never', () => {
    // These two are one decision. Vite fingerprints everything under `/assets`,
    // so those URLs are immutable by construction and may be cached for a year.
    // `/sw.js` cannot be fingerprinted — a service worker has to keep its URL or
    // every deploy registers a different script — so a cached copy of it is a
    // deploy that never reaches an installed phone.
    expect(headersFor('/assets/index-abc123.js').get('cache-control')).toBe(
      'public, max-age=31536000, immutable',
    )
    expect(headersFor('/sw.js').get('cache-control')).toBe('public, max-age=0, must-revalidate')
  })
})
