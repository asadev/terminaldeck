import { assetFetchFor, cancelBody, type AssetHeaders } from './browser-asset-session'
import type { RenditionProbe } from './browser-asset-rendition'

/**
 * Asking a URL what it is, without downloading it.
 *
 * The one part of rendition upgrading that has to touch the network, kept in its
 * own file so `browser-asset-rendition.ts` stays a set of decisions that can be
 * driven from a test with no Electron and no socket around them.
 *
 * ## Through the browser's own session, when one is named
 *
 * A CDN behind a signed cookie answers `403` to a bare request and `200` to the
 * same request from the browser that is logged in. Probing without the cookie
 * would therefore reject every upgrade on a site worth scraping — which reads,
 * from the outside, exactly like "the rewrite rule is wrong". So a caller may
 * name a profile, and the probe goes out of that profile's own partition with
 * its own cookie jar, which is the same jar the page and the download use.
 *
 * Which jar, exactly, is `browser-asset-session.ts`'s answer and not this file's
 * — because `browser-asset-fetch.ts` asks the same question about the same URL a
 * moment later, and a probe and a fetch that disagree about the cookies produce
 * a run where every `HEAD` says `200` and every `GET` says `403`. One function,
 * one answer, and it refuses an id that is not a profile rather than quietly
 * making the request with nobody's cookies.
 *
 * ## HEAD first, then one byte
 *
 * Servers refuse `HEAD` more often than people expect — some return `405`, some
 * return `200` with no length, some hang. A `405` or a `501` is not evidence
 * about the file, so it is retried as a `GET` with `Range: bytes=0-0`, which
 * costs one byte and gets a real `Content-Type` and, from `Content-Range`, the
 * real length. Anything that still will not answer is `null`, which
 * `chooseRendition` reads as "this candidate did not hold" and moves on — down
 * to the original, which is always last.
 */

/** Long enough for a slow CDN, short enough that 60,000 of them are not a night. */
export const PROBE_TIMEOUT_MS = 8_000

function contentTypeOf(headers: AssetHeaders): string {
  const raw = headers.get('content-type') ?? ''
  return raw.split(';')[0].trim().toLowerCase()
}

/**
 * The length, from `Content-Length` or from a `Content-Range` on a ranged reply.
 *
 * `null` when neither is present, which is a real and common answer — a chunked
 * response states no length at all. Every caller treats `null` as "not
 * comparable" rather than as zero; see `acceptsRendition`.
 */
function lengthOf(headers: AssetHeaders, ranged: boolean): number | null {
  if (ranged) {
    const range = headers.get('content-range') ?? ''
    const total = /\/(\d+)\s*$/.exec(range)
    if (total !== null) {
      const value = Number(total[1])
      return Number.isSafeInteger(value) ? value : null
    }
    // A ranged request that was answered with the whole file: the length is the
    // length, and there is no range header to read it out of.
    if (range === '') {
      const plain = headers.get('content-length')
      if (plain === null) return null
      const value = Number(plain)
      return Number.isSafeInteger(value) && value > 1 ? value : null
    }
    return null
  }
  const plain = headers.get('content-length')
  if (plain === null) return null
  const value = Number(plain)
  return Number.isSafeInteger(value) && value >= 0 ? value : null
}

/**
 * Probe one URL. `null` means the request itself did not answer.
 *
 * `profileId` picks the cookie jar; omitted, the request carries no cookies at
 * all, which is the right default for a public CDN and the wrong one for a
 * signed URL — hence the argument.
 */
export async function probeAsset(
  url: string,
  options: { profileId?: string; timeoutMs?: number } = {},
): Promise<RenditionProbe | null> {
  if (!/^https?:\/\//i.test(url)) return null
  const timeoutMs = options.timeoutMs ?? PROBE_TIMEOUT_MS
  let fetcher: ReturnType<typeof assetFetchFor>
  try {
    fetcher = assetFetchFor(options.profileId)
  } catch {
    /*
     * A profile id that is not one of ours. `null` is "this candidate did not
     * hold", which walks the caller down to the original URL — the safe
     * direction. The tools refuse the id at the door long before this, so this
     * branch is the second guard rather than the message anybody reads.
     */
    return null
  }

  const once = async (ranged: boolean): Promise<RenditionProbe | null> => {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), timeoutMs)
    timer.unref?.()
    try {
      const response = await fetcher(url, {
        method: ranged ? 'GET' : 'HEAD',
        signal: controller.signal,
        ...(ranged ? { headers: { Range: 'bytes=0-0' } } : {}),
      })
      /*
       * The body of a ranged reply is one byte and it still has to be read or
       * cancelled, or the socket stays open until it is collected. Cancelled
       * rather than read: nothing here wants the byte.
       */
      if (ranged) await cancelBody(response)
      return {
        // 206 is a success for a ranged request and every caller here is asking
        // "did this answer", so it is reported as the 200 it stands for.
        status: response.status === 206 ? 200 : response.status,
        bytes: lengthOf(response.headers, ranged),
        contentType: contentTypeOf(response.headers),
      }
    } catch {
      return null
    } finally {
      clearTimeout(timer)
    }
  }

  const head = await once(false)
  if (head !== null && head.status !== 405 && head.status !== 501 && head.status !== 403) {
    /*
     * A `HEAD` that answered, with one exception worth spelling out: a `200`
     * with no length is not much of an answer, and a ranged `GET` usually turns
     * it into one. Worth the extra byte, because the length is the check that
     * catches a server quietly re-serving the small copy.
     */
    if (head.status >= 200 && head.status < 300 && head.bytes === null) {
      const ranged = await once(true)
      if (ranged !== null) return ranged
    }
    return head
  }
  /*
   * `403` is retried too, and that is not the same as ignoring it. Some CDNs
   * sign the method into the signature and refuse `HEAD` on a URL whose `GET`
   * is perfectly fine. If the ranged `GET` also refuses, that `403` is the
   * answer and it is returned as one.
   */
  const ranged = await once(true)
  return ranged ?? head
}
