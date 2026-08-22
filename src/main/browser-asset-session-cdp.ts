/**
 * The profile-cookied asset fetcher for the server that has no Electron under it.
 *
 * ## The seam this fills, and why it is a second implementation rather than one
 *
 * `browser-asset-session.ts` turns a profile id into an `AssetOpen` — one
 * function `(url, init) => Promise<AssetResponse>` that `browser-asset-probe.ts`
 * and `browser-asset-fetch.ts` are both built out of. On the desktop it does
 * that with Electron's `net.fetch` bound to the profile's partition, which reads
 * the logged-in cookie jar *implicitly*: the jar is the session, and the fetch
 * comes out of it. Its header states the property the whole module exists for —
 * "the jar is the whole point of this browser" — because a CDN behind a signed
 * cookie, a site behind a login, a host that decided this machine is a person:
 * none of that is in a bare request, and a run that fetches without the jar
 * "comes home with sixty thousand logged-out copies".
 *
 * There is no `net.fetch` and no partition on the server. The jar lives in the
 * headless Chromium this app is driving, and the only way to read it is over CDP.
 * So this module composes the same `AssetOpen` from two pieces the desktop got
 * for free: a **single-URL cookie read** from that profile's browser
 * (`Network.getCookies { urls: [url] }`, the one genuine relaxation the CDP
 * allow-list makes, scoped in `screenCommand` to exactly one http(s) URL), and an
 * HTTP request that replays those cookies as a `Cookie` header. The result is
 * behaviourally the desktop's: the logged-in copy, out of this profile's jar.
 *
 * ## The one discipline the relaxation is bought with
 *
 * The cookie values are read for exactly one URL, turned straight into the
 * `Cookie` header of exactly one request, and never touched again. They are not
 * written to a capture file, not put on a tool result, not logged — the same
 * rule `browser-session.ts` keeps for the renderer, and the reason
 * `Network.getAllCookies` (the whole-jar dump) stays denied while this
 * single-URL read is allowed. `browser-asset-session-cdp.test.ts` asserts the
 * cookie reaches the request and nothing else.
 *
 * ## Why the types are declared here rather than imported from the seam
 *
 * `AssetOpen`, `AssetResponse` and their parts are also exported from
 * `browser-asset-session.ts` — but that module opens with `import { net } from
 * 'electron'`, and this file is in the headless closure `seam.test.ts` walks. A
 * mere `import type` from it would pull Electron into that walk (the walker
 * follows every `from`, type-only or not), so the shapes are restated here. They
 * are structural and identical, so the value this module produces is assignable
 * to the seam's `AssetOpen` at the host wiring site with no cast;
 * `browser-asset-session-cdp.test.ts` pins that assignability so the two
 * declarations can never drift.
 *
 * ## No Electron
 *
 * Nothing from `electron`, and no partition. The CDP channel is injected, the
 * HTTP client defaults to the runtime's built-in undici (`globalThis.fetch` is
 * undici under Node, the same client `browser-chromium-install.ts` fetches its
 * Chromium with) and is injectable for tests.
 */

/* ------------------------------------------------------------- the shapes -- */

/** The one thing anything here asks a header bag for. Mirrors `browser-asset-session.ts`. */
export interface AssetHeaders {
  get(name: string): string | null
}

export interface AssetRequestInit {
  method?: string
  headers?: Record<string, string>
  signal?: AbortSignal
}

/** Just enough of `Response` for a probe or a fetch. Mirrors `browser-asset-session.ts`. */
export interface AssetResponse {
  readonly status: number
  readonly headers: AssetHeaders
  /** A web stream, or nothing. Read by `browser-asset-fetch.ts`, never by a probe. */
  readonly body: unknown
}

/** Make one request. The unit both the probe and the fetch are built out of. */
export type AssetOpen = (url: string, init: AssetRequestInit) => Promise<AssetResponse>

/* ------------------------------------------------------------ the channel -- */

/**
 * The slice of the CDP transport this module needs: one screened `send`.
 *
 * `send` is the driver's screened send — `Network.getCookies` is checked by
 * `screenCommand({ transport: 'cdp', … })` before it reaches the wire, which is
 * where the "exactly one http(s) URL" rule is enforced, not from in here.
 */
export interface CdpAssetChannel {
  send(method: string, params?: unknown): Promise<unknown>
}

/** One cookie, reduced to the two fields a `Cookie` header is built from. */
export interface CdpCookie {
  name: string
  value: string
}

/**
 * The HTTP client. The runtime's `fetch` (undici) satisfies it, and so does a
 * fake in a test. Kept as a seam for the same reason `AssetOpen` is one.
 */
export type AssetFetch = (url: string, init: AssetRequestInit) => Promise<AssetResponse>

export interface CdpAssetDeps {
  channel: CdpAssetChannel
  /** The HTTP client. Defaults to the runtime's built-in undici via `globalThis.fetch`. */
  fetch?: AssetFetch
}

const defaultFetch: AssetFetch = (url, init) =>
  fetch(url, init as RequestInit) as unknown as Promise<AssetResponse>

/**
 * Read the cookies for exactly one URL out of the profile's CDP browser.
 *
 * The single-URL carve-out, and nothing wider: `{ urls: [url] }` is the shape
 * `screenCommand` allows, and `Network.getAllCookies` (the jar) and
 * `Storage.getCookies` (the context) both stay denied. Values that are not a
 * usable name/value pair are dropped rather than sent as `undefined`.
 */
async function readCookies(channel: CdpAssetChannel, url: string): Promise<CdpCookie[]> {
  const result = (await channel.send('Network.getCookies', { urls: [url] })) as {
    cookies?: unknown
  } | null
  const list = result !== null && Array.isArray(result.cookies) ? result.cookies : []
  const out: CdpCookie[] = []
  for (const raw of list) {
    if (typeof raw !== 'object' || raw === null) continue
    const cookie = raw as Record<string, unknown>
    if (typeof cookie.name !== 'string' || cookie.name === '') continue
    if (typeof cookie.value !== 'string') continue
    out.push({ name: cookie.name, value: cookie.value })
  }
  return out
}

/** Turn a cookie list into one `Cookie` header value, or `''` when there are none. */
export function cookieHeader(cookies: readonly CdpCookie[]): string {
  return cookies.map((cookie) => `${cookie.name}=${cookie.value}`).join('; ')
}

/**
 * The fetcher for a profile driven over CDP.
 *
 * The `channel` is already bound by the host to one profile's browser — that is
 * what scopes the cookies to this profile, the way the partition does on the
 * desktop — so unlike the desktop `assetFetchFor` there is no profile id to
 * validate here: a channel that reaches the wrong browser is the host's error to
 * make, not a string the agent hands in.
 *
 * A cookie read that *fails* is allowed to reject: falling through to a
 * cookie-less request would fetch the logged-out copy, which is the exact
 * failure `browser-asset-session.ts` exists to stop, and `browser-asset-fetch.ts`
 * already turns a rejected `open` into a failed attempt it can retry. A cookie
 * read that succeeds with *no* cookies is not a failure — a public CDN needs
 * none — so the request just goes without a `Cookie` header.
 */
export function cdpAssetFetchFor(deps: CdpAssetDeps): AssetOpen {
  const client = deps.fetch ?? defaultFetch
  return async (url, init) => {
    const header = cookieHeader(await readCookies(deps.channel, url))
    const headers: Record<string, string> = { ...(init.headers ?? {}) }
    // The jar is the point: its cookie wins over anything already on the request.
    if (header !== '') headers.Cookie = header
    return client(url, { method: init.method, headers, signal: init.signal })
  }
}
