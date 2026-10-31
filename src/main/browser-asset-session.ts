import { net } from 'electron'
import { partitionFor, sessionForPartition } from './browser-profiles'

/**
 * One place that turns a profile id into the thing that makes the request.
 *
 * ## Why this is its own module rather than two similar lines
 *
 * Because a probe and a fetch that disagree about the cookie jar is a failure
 * with no symptom worth the name. `browser-asset-probe.ts` asks a URL what it
 * is; `browser-asset-fetch.ts` then asks the same URL for its bytes. If the
 * first goes out of the logged-in partition and the second out of a bare HTTP
 * client, the probe says `200 · image/jpeg · 4.1MB` and the fetch comes back
 * `403` on every asset in the run — and the thing that reads like is *"the
 * rewrite rule is wrong"*, which is the one conclusion that will send somebody
 * off to rewrite a working rule.
 *
 * So both of them ask this function, and there is exactly one answer.
 *
 * ## The jar is the whole point of this browser
 *
 * A CDN behind a signed cookie, a site behind a login, a host that has decided
 * this machine is a person because it solved something once — none of that is
 * in a bare request. It is in the partition. `browser-profiles.ts` mints those
 * partitions, `browser-workers.ts` registers some of them as workers, and a
 * worker id *is* a profile id: `workerSessionFor` is the narrower check
 * `browser-tab.ts` needs before it opens a page in a jar, and it is deliberately
 * not what is used here, because fetching an asset out of the person's own
 * signed-in profile is the feature rather than the risk. What bounds this is the
 * caller: the asset tools refuse a paired device outright.
 *
 * ## An id that is not a profile is refused, never quietly answered
 *
 * `partitionFor` accepts the default profile or a UUID and nothing shaped
 * differently — `fromPartition` will happily mint a directory for any string it
 * is handed. Which leaves the case that matters: a caller *named* a profile and
 * the name is not one of ours. Answering that with a cookie-less request is the
 * worst of the three options, because it succeeds. The run then fetches every
 * asset anonymously, gets the logged-out copy of each one, writes them all to
 * disk and reports success — the exact shape of every failure this round of work
 * exists to stop. So it throws, and the tools refuse it at the door before it
 * can get here.
 *
 * Naming *no* profile is a different thing and is allowed: a public CDN needs no
 * cookies, and `net.fetch` is the right client for it.
 */

/** The one thing anything here asks a header bag for. */
export interface AssetHeaders {
  get(name: string): string | null
}

/** Just enough of `Response` for a probe or a fetch. Keeps tests off Electron. */
export interface AssetResponse {
  readonly status: number
  readonly headers: AssetHeaders
  /** A web stream, or nothing. Read by `browser-asset-fetch.ts`, never by a probe. */
  readonly body: unknown
}

/**
 * Let go of a body nobody wants, without caring what shape it is.
 *
 * A response that is being refused — a `404`, an HTML page under a `.jpg` name,
 * the one byte of a ranged probe — still holds a socket until its body is read
 * or cancelled. Sixty thousand of those is sixty thousand sockets. Shared by the
 * probe and the fetch because they refuse the same responses for the same
 * reasons, and neither of them should have to know whether it was handed a web
 * stream or an async iterator.
 */
export async function cancelBody(response: AssetResponse): Promise<void> {
  const body = response.body as { cancel?: () => Promise<unknown> } | null | undefined
  if (body === null || body === undefined || typeof body.cancel !== 'function') return
  try {
    await body.cancel()
  } catch {
    // Nothing to do about a body that will not close. It is one socket.
  }
}

export interface AssetRequestInit {
  method?: string
  headers?: Record<string, string>
  signal?: AbortSignal
}

/** Make one request. The unit both the probe and the fetch are built out of. */
export type AssetOpen = (url: string, init: AssetRequestInit) => Promise<AssetResponse>

/**
 * The fetcher for a profile, or the bare one when no profile was named.
 *
 * The session is resolved per call rather than when this is bound, so a fetcher
 * held for a batch of sixty thousand does not pin a `Session` object that
 * `sessionForPartition` is already caching anyway.
 *
 * Throws for an id that is not a profile. See the header for why that is not a
 * silent fall-through to an anonymous request.
 */
export function assetFetchFor(profileId?: string | null): AssetOpen {
  if (profileId === undefined || profileId === null || profileId === '') {
    return (url, init) => net.fetch(url, init as RequestInit) as unknown as Promise<AssetResponse>
  }
  const partition = partitionFor(profileId)
  if (partition === null) {
    throw new Error(
      `${profileId} is not a profile in this browser. Fetching it without one would use nobody's ` +
        'cookies, which is how a run comes home with sixty thousand logged-out copies.',
    )
  }
  return (url, init) =>
    sessionForPartition(partition).fetch(url, init as RequestInit) as unknown as Promise<AssetResponse>
}

/**
 * Is this a profile id something may be fetched through?
 *
 * For a tool's `precheck`, which has to refuse before anything runs and cannot
 * catch an exception out of a function it has not called yet. `undefined` and
 * `''` are true: naming no profile is allowed.
 */
export function isFetchableProfileId(profileId: unknown): boolean {
  if (profileId === undefined || profileId === null || profileId === '') return true
  return partitionFor(profileId) !== null
}
