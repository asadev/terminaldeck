import { describe, expect, it } from 'vitest'
import type { AssetOpen as SeamAssetOpen } from './browser-asset-session'
import {
  cdpAssetFetchFor,
  cookieHeader,
  type AssetRequestInit,
  type AssetResponse,
  type CdpAssetChannel,
} from './browser-asset-session-cdp'

/**
 * The server's profile-cookied fetch, composed and checked without a browser.
 *
 * The desktop reads the jar implicitly through `net.fetch` on a partition; here
 * the jar is read explicitly, one URL at a time, over CDP, and replayed as a
 * `Cookie` header. So the two things this file pins are exactly those two moves:
 * the read is scoped to the one URL being fetched, and its result reaches the
 * request and nothing else.
 *
 * No Electron and no browser: the CDP channel and the HTTP client are both fakes.
 * The `import type` of the real seam is erased at runtime — it is here only so the
 * type check below proves the two declarations of `AssetOpen` cannot drift.
 */

/** A CDP channel that answers `Network.getCookies` with a scripted jar. */
function fakeChannel(cookies: { name: string; value: string }[]) {
  const asked: { method: string; params: unknown }[] = []
  const channel: CdpAssetChannel = {
    send: async (method, params) => {
      asked.push({ method, params })
      if (method === 'Network.getCookies') return { cookies }
      return {}
    },
  }
  return { channel, asked }
}

/** An HTTP client that records the request it was handed and answers a fixed response. */
function fakeFetch(response: AssetResponse) {
  const calls: { url: string; init: AssetRequestInit }[] = []
  return {
    calls,
    fetch: async (url: string, init: AssetRequestInit) => {
      calls.push({ url, init })
      return response
    },
  }
}

const ok: AssetResponse = {
  status: 200,
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'image/jpeg' : null) },
  body: { marker: 'the stream' },
}

describe('turning cookies into a header', () => {
  it('joins name=value pairs with a semicolon, and answers empty for none', () => {
    expect(cookieHeader([{ name: 'sid', value: 'abc' }, { name: 't', value: '2' }])).toBe('sid=abc; t=2')
    expect(cookieHeader([])).toBe('')
  })
})

describe('a fetch through the profile jar', () => {
  it('reads exactly one URL and replays its cookies onto the request', async () => {
    const rig = fakeChannel([{ name: 'sid', value: 'abc' }, { name: 't', value: '2' }])
    const http = fakeFetch(ok)
    const open = cdpAssetFetchFor({ channel: rig.channel, fetch: http.fetch })

    const res = await open('https://cdn.example/a.jpg', { method: 'GET', headers: { Accept: 'image/*' } })

    // The read is scoped to the one URL — never the whole jar.
    expect(rig.asked).toEqual([
      { method: 'Network.getCookies', params: { urls: ['https://cdn.example/a.jpg'] } },
    ])
    // The cookies reached the request, beside a header that was already there.
    expect(http.calls).toHaveLength(1)
    expect(http.calls[0].url).toBe('https://cdn.example/a.jpg')
    expect(http.calls[0].init.headers).toEqual({ Accept: 'image/*', Cookie: 'sid=abc; t=2' })
    expect(http.calls[0].init.method).toBe('GET')
    // The response is passed straight through: status, headers.get and body.
    expect(res.status).toBe(200)
    expect(res.headers.get('content-type')).toBe('image/jpeg')
    expect(res.body).toEqual({ marker: 'the stream' })
  })

  it('sends no Cookie header when the jar has none — a public CDN needs none', async () => {
    const rig = fakeChannel([])
    const http = fakeFetch(ok)
    const open = cdpAssetFetchFor({ channel: rig.channel, fetch: http.fetch })

    await open('https://cdn.example/public.jpg', { method: 'GET' })
    expect(http.calls[0].init.headers).toEqual({})
  })

  it('rejects rather than fetch the logged-out copy when the cookie read fails', async () => {
    const channel: CdpAssetChannel = {
      send: async () => {
        throw new Error('the debugger pipe is closed')
      },
    }
    const http = fakeFetch(ok)
    const open = cdpAssetFetchFor({ channel, fetch: http.fetch })

    await expect(open('https://cdn.example/a.jpg', { method: 'GET' })).rejects.toThrow(
      'the debugger pipe is closed',
    )
    // Never fell through to a cookie-less request — that is the whole point.
    expect(http.calls).toHaveLength(0)
  })

  it('produces a function assignable to the seam’s AssetOpen', () => {
    // If the local shapes ever drift from `browser-asset-session.ts`, this line
    // stops compiling — which is the guarantee, not the runtime assertion.
    const seam: SeamAssetOpen = cdpAssetFetchFor({ channel: fakeChannel([]).channel })
    expect(typeof seam).toBe('function')
  })
})
