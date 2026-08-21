import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { CaptureStore, type CaptureBounds } from './browser-capture-store'
import { PageNetwork, SIZE_PROBE_MS } from './browser-network'

/**
 * The engine, with Chromium replaced by a table of calls.
 *
 * Two properties are asserted here above all others, and both are properties a
 * page can be ruined by:
 *
 *  - **Every paused request is answered.** `Fetch.enable` takes requests out of
 *    the network stack; one that is never answered is a page that never
 *    finishes loading. So there are tests for the probe throwing, the probe
 *    hanging, the placeholder failing and the send itself being refused.
 *  - **Every response is an entry.** A body that could not be kept is recorded
 *    with the reason, never omitted, because a manifest that is quietly short
 *    is the failure this whole piece of work exists to end.
 */

interface Sent {
  method: string
  params: Record<string, unknown>
}

function bounds(over: Partial<CaptureBounds> = {}): CaptureBounds {
  return { maxBodyBytes: 1_000_000, maxTotalBytes: 10_000_000, maxEntries: 1_000, ...over }
}

function rig(
  options: {
    /** Answer, or throw, per method. */
    reply?: (sent: Sent) => Record<string, unknown>
    size?: (url: string) => unknown
  } = {},
) {
  const sent: Sent[] = []
  const lines: string[] = []
  const files = new Map<string, Buffer | string>()
  let handler: ((method: string, params: Record<string, unknown>) => void) | null = null
  let clock = 0
  const store = new CaptureStore('/run', bounds(), {
    now: () => (clock += 1),
    mkdir: () => undefined,
    append: (_file, line) => void lines.push(line),
    write: (file, bytes) => void files.set(file, bytes),
  })
  const network = new PageNetwork({
    send: async (method, params = {}) => {
      sent.push({ method, params })
      return options.reply ? options.reply({ method, params }) : {}
    },
    onEvent: (fn) => {
      handler = fn
      return () => {
        handler = null
      }
    },
    sizeOf: async (url) => (options.size ? options.size(url) : null),
    now: () => (clock += 1),
  })
  return {
    network,
    store,
    sent,
    files,
    entries: () => lines.map((line) => JSON.parse(line) as Record<string, unknown>),
    emit: (method: string, params: Record<string, unknown> = {}) => handler?.(method, params),
    listening: () => handler !== null,
    of: (method: string) => sent.filter((one) => one.method === method),
  }
}

/** Give the event handlers, which are `void`-dispatched, a turn to finish. */
async function settle(): Promise<void> {
  for (let n = 0; n < 6; n += 1) await Promise.resolve()
}

/* -------------------------------------------------------------- the arming -- */

describe('what arming actually turns on', () => {
  it('intercepts only the kinds a rule names, and never the document', async () => {
    const r = rig()
    await r.network.arm({ rules: { image: 'fulfill', font: 'block' }, capture: null })
    const [enable] = r.of('Fetch.enable')
    expect(enable.params.patterns).toEqual([
      { urlPattern: '*', resourceType: 'Image', requestStage: 'Request' },
      { urlPattern: '*', resourceType: 'Font', requestStage: 'Request' },
    ])
    // No `handleAuthRequests` — `browser-cdp.ts` refuses it, and asking for it
    // would deadlock every authentication prompt on the page.
    expect(enable.params.handleAuthRequests).toBeUndefined()
  })

  it('does not intercept at all when every rule is allow', async () => {
    const r = rig()
    await r.network.arm({ rules: { image: 'allow' }, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    expect(r.of('Fetch.enable')).toHaveLength(0)
    expect(r.of('Network.enable')).toHaveLength(1)
  })

  it('raises Chromium’s response buffer, which is what makes eager capture possible', async () => {
    const r = rig()
    await r.network.arm({ rules: {}, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    const [enable] = r.of('Network.enable')
    expect(Number(enable.params.maxTotalBufferSize)).toBeGreaterThanOrEqual(64 * 1024 * 1024)
    expect(Number(enable.params.maxResourceBufferSize)).toBeGreaterThanOrEqual(8 * 1024 * 1024)
  })
})

/* ---------------------------------------------------- answering cheaply --- */

describe('a paused image is answered with a picture the page can measure', () => {
  async function pause(r: ReturnType<typeof rig>, url = 'https://x.example/a.jpg'): Promise<void> {
    r.emit('Fetch.requestPaused', { requestId: 'r1', resourceType: 'Image', request: { url } })
    await settle()
  }

  it('carries the size the page states, not one pixel', async () => {
    /*
     * The correction the whole feature turns on. A 1×1 satisfies "an image
     * arrived" and fails every `naturalWidth > 1` gate, every `<picture>`
     * candidate choice and every masonry column measurement — so it loses the
     * same URLs that blocking would, for a new reason and with no sign that it
     * happened.
     */
    const r = rig({ size: () => ({ width: 800, height: 600, from: 'attributes', derivedHeight: false }) })
    await r.network.arm({ rules: { image: 'fulfill' }, capture: null })
    await pause(r)

    const [fulfil] = r.of('Fetch.fulfillRequest')
    expect(fulfil.params.responseCode).toBe(200)
    const png = Buffer.from(String(fulfil.params.body), 'base64')
    expect(png.readUInt32BE(16)).toBe(800)
    expect(png.readUInt32BE(20)).toBe(600)
    // A real PNG, not a data URL somebody pasted. The pixels themselves are
    // decoded in `browser-placeholder.test.ts`, which owns the encoder.
    expect(png.subarray(1, 4).toString('ascii')).toBe('PNG')
    expect(headerOf(fulfil, 'content-type')).toBe('image/png')
    expect(headerOf(fulfil, 'cache-control')).toBe('no-store')
  })

  it('counts where every size came from, so a run of guesses is visible', async () => {
    const sizes: Record<string, unknown> = {
      'https://x.example/1.jpg': { width: 100, height: 50, from: 'attributes', derivedHeight: false },
      'https://x.example/2.jpg': { width: 200, height: 200, from: 'srcset', derivedHeight: true },
      'https://x.example/3.jpg': { width: 30, height: 40, from: 'box', derivedHeight: false },
      'https://x.example/4.jpg': null,
    }
    const r = rig({ size: (url) => sizes[url] })
    await r.network.arm({ rules: { image: 'fulfill' }, capture: null })
    for (const url of Object.keys(sizes)) {
      r.emit('Fetch.requestPaused', { requestId: url, resourceType: 'Image', request: { url } })
    }
    await settle()
    const counts = r.network.status().counts
    expect(counts.sized).toEqual({ attributes: 1, srcset: 1, box: 1, none: 0, unknown: 1 })
    expect(counts.derivedHeights).toBe(1)
    expect(counts.fulfilled).toBe(4)
  })

  it('falls back to one pixel only when the page states nothing', async () => {
    const r = rig({ size: () => null })
    await r.network.arm({ rules: { image: 'fulfill' }, capture: null })
    await pause(r)
    const png = Buffer.from(String(r.of('Fetch.fulfillRequest')[0].params.body), 'base64')
    expect(png.readUInt32BE(16)).toBe(1)
    expect(r.network.status().counts.sized.unknown).toBe(1)
  })

  it('answers a kind that is not an image with something that parses', async () => {
    const r = rig()
    await r.network.arm({ rules: { stylesheet: 'fulfill', xhr: 'fulfill' }, capture: null })
    r.emit('Fetch.requestPaused', {
      requestId: 'c1',
      resourceType: 'Stylesheet',
      request: { url: 'https://x.example/a.css' },
    })
    r.emit('Fetch.requestPaused', {
      requestId: 'c2',
      resourceType: 'XHR',
      request: { url: 'https://x.example/a.json' },
    })
    await settle()
    const [css, json] = r.of('Fetch.fulfillRequest')
    expect(headerOf(css, 'content-type')).toBe('text/css')
    expect(Buffer.from(String(json.params.body), 'base64').toString('utf8')).toBe('{}')
  })

  it('blocks with an extension-shaped refusal, not a fake network failure', async () => {
    // `Failed` reads as a flaky network and triggers the aggressive retry loops
    // that make a blocked crawl slower than an allowed one.
    const r = rig()
    await r.network.arm({ rules: { media: 'block' }, capture: null })
    r.emit('Fetch.requestPaused', {
      requestId: 'm1',
      resourceType: 'Media',
      request: { url: 'https://x.example/a.mp4' },
    })
    await settle()
    expect(r.of('Fetch.failRequest')[0].params.errorReason).toBe('BlockedByClient')
    expect(r.network.status().counts.blocked).toBe(1)
  })

  it('lets through a resource type no rule can name', async () => {
    const r = rig()
    await r.network.arm({ rules: { image: 'fulfill' }, capture: null })
    r.emit('Fetch.requestPaused', {
      requestId: 'w1',
      resourceType: 'WebSocket',
      request: { url: 'wss://x.example/' },
    })
    await settle()
    expect(r.of('Fetch.continueRequest')).toHaveLength(1)
  })
})

describe('a paused request is answered whatever goes wrong', () => {
  it('continues it when the size probe throws', async () => {
    const r = rig({
      size: () => {
        throw new Error('the page is gone')
      },
    })
    await r.network.arm({ rules: { image: 'fulfill' }, capture: null })
    r.emit('Fetch.requestPaused', {
      requestId: 'r1',
      resourceType: 'Image',
      request: { url: 'https://x.example/a.jpg' },
    })
    await settle()
    // A throwing probe is not a reason to fail the request: it falls back to
    // the 1×1 and the page still gets an answer.
    expect(r.of('Fetch.fulfillRequest')).toHaveLength(1)
    expect(r.network.status().counts.stuck).toBe(0)
  })

  it('gives up on a probe that never answers, inside the bound', async () => {
    const r = rig({ size: () => new Promise(() => undefined) })
    await r.network.arm({ rules: { image: 'fulfill' }, capture: null })
    r.emit('Fetch.requestPaused', {
      requestId: 'r1',
      resourceType: 'Image',
      request: { url: 'https://x.example/a.jpg' },
    })
    await new Promise((resolve) => setTimeout(resolve, SIZE_PROBE_MS + 60))
    await settle()
    expect(r.of('Fetch.fulfillRequest')).toHaveLength(1)
    expect(r.network.status().counts.sized.unknown).toBe(1)
  })

  it('counts a request it could not answer at all, rather than reporting a clean run', async () => {
    /*
     * The loudest number in the result. It happens when the channel shuts under
     * a paused request — the person took the page, or the window closed — and a
     * caller that was told nothing would be looking at a hung page with a
     * successful tool result beside it.
     */
    const r = rig({
      reply: ({ method }) => {
        if (method.startsWith('Fetch.') && method !== 'Fetch.enable') {
          throw new Error('the person is using this page right now')
        }
        return {}
      },
    })
    await r.network.arm({ rules: { image: 'fulfill' }, capture: null })
    r.emit('Fetch.requestPaused', {
      requestId: 'r1',
      resourceType: 'Image',
      request: { url: 'https://x.example/a.jpg' },
    })
    await settle()
    expect(r.network.status().counts.stuck).toBe(1)
  })

  it('asks the page once per URL, however many cards point at it', async () => {
    let asked = 0
    const r = rig({
      size: () => {
        asked += 1
        return { width: 10, height: 10, from: 'box', derivedHeight: false }
      },
    })
    await r.network.arm({ rules: { image: 'fulfill' }, capture: null })
    for (let n = 0; n < 5; n += 1) {
      r.emit('Fetch.requestPaused', {
        requestId: `r${n}`,
        resourceType: 'Image',
        request: { url: 'https://x.example/same.jpg' },
      })
    }
    await settle()
    expect(asked).toBe(1)
    expect(r.of('Fetch.fulfillRequest')).toHaveLength(5)
  })
})

/* ------------------------------------------------------------- capturing -- */

describe('capture reads the body at the one moment it exists', () => {
  function response(r: ReturnType<typeof rig>, over: Record<string, unknown> = {}): void {
    r.emit('Network.requestWillBeSent', {
      requestId: 'q1',
      type: 'XHR',
      request: { url: 'https://x.example/api/list.json', method: 'POST' },
    })
    r.emit('Network.responseReceived', {
      requestId: 'q1',
      type: 'XHR',
      response: {
        url: 'https://x.example/api/list.json',
        status: 200,
        mimeType: 'application/json',
        headers: { 'content-type': 'application/json', 'set-cookie': 'session=secret' },
        ...over,
      },
    })
  }

  it('does not ask on responseReceived, which is too early, and does on loadingFinished', async () => {
    const r = rig({ reply: () => ({ body: '{"n":1}', base64Encoded: false }) })
    await r.network.arm({ rules: {}, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    response(r)
    await settle()
    expect(r.of('Network.getResponseBody')).toHaveLength(0)

    r.emit('Network.loadingFinished', { requestId: 'q1', encodedDataLength: 7 })
    await settle()
    expect(r.of('Network.getResponseBody')).toHaveLength(1)

    const [entry] = r.entries()
    expect(entry).toMatchObject({ bodyState: 'saved', status: 200, method: 'POST', kind: 'xhr' })
    expect(r.files.get(join('/run/bodies', String(entry.bodyPath).slice('bodies/'.length)))?.toString()).toBe(
      '{"n":1}',
    )
  })

  it('never writes a session cookie into the capture beside the data', async () => {
    const r = rig({ reply: () => ({ body: '{}', base64Encoded: false }) })
    await r.network.arm({ rules: {}, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    response(r)
    r.emit('Network.loadingFinished', { requestId: 'q1', encodedDataLength: 2 })
    await settle()
    expect(JSON.stringify(r.entries())).not.toContain('secret')
    expect(r.entries()[0].headers).toEqual({ 'content-type': 'application/json' })
  })

  it('decodes a base64 body rather than storing the encoding', async () => {
    const r = rig({ reply: () => ({ body: Buffer.from([1, 2, 3]).toString('base64'), base64Encoded: true }) })
    await r.network.arm({ rules: {}, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    response(r, { mimeType: 'application/octet-stream' })
    r.emit('Network.loadingFinished', { requestId: 'q1', encodedDataLength: 3 })
    await settle()
    const [entry] = r.entries()
    expect(entry.bytes).toBe(3)
    expect(entry.bodyState).toBe('saved')
  })

  it('writes down a body the browser would not hand back, with Chromium’s own words', async () => {
    /*
     * The trap this module is built around. `getResponseBody` fails when the
     * buffer has evicted the entry, and a capture that dropped those would look
     * exactly like a capture of a page that made fewer requests.
     */
    const r = rig({
      reply: ({ method }) => {
        if (method === 'Network.getResponseBody') {
          throw new Error('No resource with given identifier found')
        }
        return {}
      },
    })
    await r.network.arm({ rules: {}, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    response(r)
    r.emit('Network.loadingFinished', { requestId: 'q1', encodedDataLength: 9 })
    await settle()
    const [entry] = r.entries()
    expect(entry.bodyState).toBe('lost')
    expect(entry.message).toContain('No resource with given identifier found')
    // It is still an entry, with its URL, so a re-run knows what to go back for.
    expect(entry.url).toBe('https://x.example/api/list.json')
  })

  it('records a response whose kind it was not asked to keep, rather than nothing', async () => {
    const r = rig()
    await r.network.arm({ rules: {}, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    r.emit('Network.requestWillBeSent', {
      requestId: 'i1',
      type: 'Image',
      request: { url: 'https://x.example/a.jpg', method: 'GET' },
    })
    r.emit('Network.responseReceived', {
      requestId: 'i1',
      type: 'Image',
      response: { url: 'https://x.example/a.jpg', status: 200, mimeType: 'image/jpeg', headers: {} },
    })
    r.emit('Network.loadingFinished', { requestId: 'i1', encodedDataLength: 40_000 })
    await settle()
    expect(r.of('Network.getResponseBody')).toHaveLength(0)
    expect(r.entries()[0]).toMatchObject({ bodyState: 'not-requested', kind: 'image', bytes: 40_000 })
  })

  it('refuses an oversized body before pulling it across, using the size on the wire', async () => {
    const r = rig({ reply: () => ({ body: 'x', base64Encoded: false }) })
    const store = new CaptureStore('/run', bounds({ maxBodyBytes: 100 }), {
      now: () => 1,
      mkdir: () => undefined,
      append: () => undefined,
      write: () => undefined,
    })
    await r.network.arm({ rules: {}, capture: { store, bodyKinds: new Set(['xhr']) } })
    r.emit('Network.requestWillBeSent', {
      requestId: 'q1',
      type: 'XHR',
      request: { url: 'https://x.example/huge.json', method: 'GET' },
    })
    r.emit('Network.responseReceived', {
      requestId: 'q1',
      type: 'XHR',
      response: { url: 'https://x.example/huge.json', status: 200, mimeType: 'application/json', headers: {} },
    })
    r.emit('Network.loadingFinished', { requestId: 'q1', encodedDataLength: 200_000_000 })
    await settle()
    expect(r.of('Network.getResponseBody')).toHaveLength(0)
    expect(store.snapshot().tooLarge).toBe(1)
  })

  it('records a request that failed on the wire', async () => {
    const r = rig()
    await r.network.arm({ rules: {}, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    r.emit('Network.requestWillBeSent', {
      requestId: 'q1',
      type: 'XHR',
      request: { url: 'https://x.example/a.json', method: 'GET' },
    })
    r.emit('Network.loadingFailed', { requestId: 'q1', errorText: 'net::ERR_NAME_NOT_RESOLVED' })
    await settle()
    expect(r.entries()[0]).toMatchObject({
      bodyState: 'failed',
      message: 'net::ERR_NAME_NOT_RESOLVED',
    })
  })
})

/* ------------------------------------------------------- stopping and holes -- */

describe('stopping never leaves a hole unrecorded', () => {
  it('writes every in-flight request down as unfinished', async () => {
    const r = rig()
    await r.network.arm({ rules: {}, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    for (const id of ['a', 'b', 'c']) {
      r.emit('Network.requestWillBeSent', {
        requestId: id,
        type: 'XHR',
        request: { url: `https://x.example/${id}.json`, method: 'GET' },
      })
    }
    const status = await r.network.disarm('the caller stopped it')
    expect(status.capture?.unfinished).toBe(3)
    expect(status.capture?.incomplete).toBe(true)
    expect(status.capture?.shortfall).toContain('3 still in flight')
    expect(r.entries().map((entry) => entry.bodyState)).toEqual([
      'unfinished',
      'unfinished',
      'unfinished',
    ])
  })

  it('turns both domains off and stops listening', async () => {
    const r = rig()
    await r.network.arm({ rules: { image: 'fulfill' }, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    expect(r.listening()).toBe(true)
    await r.network.disarm()
    expect(r.of('Fetch.disable')).toHaveLength(1)
    expect(r.of('Network.disable')).toHaveLength(1)
    expect(r.listening()).toBe(false)
    expect(r.network.isArmed).toBe(false)
  })

  it('closes the books without sending anything when the page has gone', async () => {
    const r = rig()
    await r.network.arm({ rules: { image: 'fulfill' }, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    const before = r.sent.length
    const status = r.network.abandon('the page was released')
    // Nothing sent — a command to a destroyed WebContents is an unhandled
    // rejection rather than an error anybody sees.
    expect(r.sent).toHaveLength(before)
    expect(status?.capture).not.toBeNull()
    expect(r.network.isArmed).toBe(false)
  })
})

describe('the baton', () => {
  it('stops intercepting when the person is given the page, and starts again after', async () => {
    /*
     * Not tidiness. `screenCommand` refuses every command while the person has
     * the page, so an interception left armed across a handover would pause his
     * images and be unable to answer them — he would be handed a page that
     * never finishes loading, in order to type a password into it.
     */
    const r = rig()
    await r.network.arm({ rules: { image: 'fulfill' }, capture: { store: r.store, bodyKinds: new Set(['xhr']) } })
    await r.network.suspend('the person was given the page')
    expect(r.of('Fetch.disable')).toHaveLength(1)
    expect(r.network.status().suspended).toBe(true)

    // And events that arrive while suspended change nothing.
    r.emit('Fetch.requestPaused', {
      requestId: 'r1',
      resourceType: 'Image',
      request: { url: 'https://x.example/a.jpg' },
    })
    await settle()
    expect(r.of('Fetch.fulfillRequest')).toHaveLength(0)

    await r.network.resume()
    expect(r.of('Fetch.enable')).toHaveLength(2)
    expect(r.network.status().suspended).toBe(false)
  })
})

/* ------------------------------------------------------------- the source -- */

describe('the credentials a paused request carries are never read', () => {
  /*
   * `Fetch.enable` was denied until 2026-08-21 with the reason *"how an agent
   * ends up reading Authorization headers off somebody's logged-in session"*.
   * The method is allowed now; the reason is answered by construction, and this
   * is the assertion that keeps it answered. A source assertion, deliberately —
   * a behavioural test can only show that today's code does not read the field,
   * and this fails the day somebody adds a line that does.
   */
  it('reads no request header, in the module that sees them all', () => {
    const source = readFileSync(join(__dirname, 'browser-network.ts'), 'utf8')
    const code = source.replace(/\/\*[\s\S]*?\*\/|(^|[^:])\/\/.*$/gm, '$1')
    expect(code).not.toContain('request.headers')
    expect(code).not.toContain("'headers'")
    expect(code).not.toContain('authorization')
    expect(code).not.toContain('Authorization')
    // The only thing taken off the request object is its URL.
    expect(code).toContain('asRecord(params.request).url')
  })
})

function headerOf(sent: Sent, name: string): string | undefined {
  const headers = sent.params.responseHeaders as { name: string; value: string }[]
  return headers.find((header) => header.name === name)?.value
}
