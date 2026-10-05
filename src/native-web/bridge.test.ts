import { describe, expect, it } from 'vitest'
import { decodeFromWire, encodeForWire } from '../main/native-shell/wire'
import {
  BRIDGE_PATHS,
  BYTES_KEY,
  RECONNECT_FIRST_MS,
  RECONNECT_MAX_MS,
  createTransport,
  decodeEvent,
  encodeMessage,
  invokeError,
  openEventStream,
  reviveBytes,
  type EventSourceLike,
  type TransportHost,
} from './bridge'

/**
 * The HTTP half of the native window's `ipcRenderer`, without a browser.
 *
 * Pinned: what goes on the wire for each kind of call, that an answer comes
 * back the way `ipcRenderer.invoke` would have given it (including the exact
 * shape of a rejection, which four renderer helpers unwrap), that sends arrive
 * in the order they were made, and that the one event stream comes back after
 * it drops.
 */

interface Call {
  url: string
  method: string
  headers: Record<string, string>
  body: unknown
}

/** A `fetch` that records each request and answers from a queue of replies. */
function fakeFetch(reply: (call: Call) => Promise<{ status: number; body: string }> | { status: number; body: string }) {
  const calls: Call[] = []
  const fetch: TransportHost['fetch'] = async (url, init) => {
    const call = { url, method: init.method, headers: init.headers, body: JSON.parse(init.body) as unknown }
    calls.push(call)
    const answer = await reply(call)
    return { status: answer.status, text: async () => answer.body }
  }
  return { calls, fetch }
}

const ok = (value: unknown) => ({ status: 200, body: JSON.stringify({ ok: true, value }) })

describe('values on the wire', () => {
  it('carries a channel and its arguments as JSON', () => {
    expect(JSON.parse(encodeMessage('session:write', ['s1', 'ls\r']))).toEqual({
      channel: 'session:write',
      args: ['s1', 'ls\r'],
    })
  })

  it('drops a trailing undefined, so the handler still receives undefined rather than null', () => {
    expect(JSON.parse(encodeMessage('log:recent', [undefined]))).toEqual({ channel: 'log:recent', args: [] })
    expect(JSON.parse(encodeMessage('x', ['a', undefined, undefined]))).toEqual({ channel: 'x', args: ['a'] })
  })

  it('carries bytes as {"$bytes": base64}, the engine\'s own format, and reads them back as a Uint8Array', () => {
    const audio = new Uint8Array([0, 1, 254, 255])
    const buffer = new Uint8Array([9, 8, 7]).buffer
    const wire = encodeMessage('voice:transcribe', [{ audio, filename: 'a.webm' }, buffer])
    const parsed = JSON.parse(wire) as { args: [{ audio: unknown }, unknown] }
    expect(BYTES_KEY).toBe('$bytes')
    expect(parsed.args[0].audio).toEqual({ $bytes: 'AAH+/w==' })
    expect(parsed.args[1]).toEqual({ $bytes: 'CQgH' })

    const back = JSON.parse(wire, reviveBytes) as { args: [{ audio: Uint8Array; filename: string }, Uint8Array] }
    expect(back.args[0].audio).toBeInstanceOf(Uint8Array)
    expect([...back.args[0].audio]).toEqual([0, 1, 254, 255])
    expect(back.args[0].filename).toBe('a.webm')
    expect([...back.args[1]]).toEqual([9, 8, 7])
  })

  it('sends only the bytes a view covers, not the whole buffer behind it', () => {
    const whole = new Uint8Array([1, 2, 3, 4, 5])
    const wire = encodeMessage('x', [whole.subarray(1, 3)])
    const [bytes] = (JSON.parse(wire, reviveBytes) as { args: [Uint8Array] }).args
    expect([...bytes]).toEqual([2, 3])
  })

  it('reads a pushed JPEG as bytes, the way Electron delivers a main-process Buffer', () => {
    const event = decodeEvent(JSON.stringify({ channel: 'devices:frame', args: ['d1', { $bytes: '/9g=' }] }))
    expect(event?.channel).toBe('devices:frame')
    expect(event?.args[1]).toBeInstanceOf(Uint8Array)
    expect([...(event?.args[1] as Uint8Array)]).toEqual([255, 216])
  })

  it('does not mistake an ordinary object that happens to have a $bytes field for bytes', () => {
    const event = decodeEvent(JSON.stringify({ channel: 'c', args: [{ $bytes: 'AA==', name: 'x' }, { type: 'Buffer', data: [1] }] }))
    expect(event?.args).toEqual([{ $bytes: 'AA==', name: 'x' }, { type: 'Buffer', data: [1] }])
  })

  /*
   * The two ends of one wire, written by two lanes: this file's encoder against
   * the engine's decoder, and the engine's encoder against this file's reviver.
   * A drift in either — a renamed key, a different base64 — fails here rather
   * than as a microphone that silently uploads nothing.
   */
  it('agrees with the engine\'s own wire in both directions', () => {
    const sent = decodeFromWire(JSON.parse(encodeMessage('voice:transcribe', [{ audio: new Uint8Array([1, 2, 255]) }]))) as {
      args: [{ audio: Buffer }]
    }
    expect(Buffer.isBuffer(sent.args[0].audio)).toBe(true)
    expect([...sent.args[0].audio]).toEqual([1, 2, 255])

    const pushed = decodeEvent(encodeForWire({ channel: 'devices:frame', args: ['d1', Buffer.from([255, 216])] }))
    expect(pushed?.args[1]).toBeInstanceOf(Uint8Array)
    expect([...(pushed?.args[1] as Uint8Array)]).toEqual([255, 216])
  })

  it('ignores a pushed message that is not one', () => {
    expect(decodeEvent('not json')).toBeNull()
    expect(decodeEvent('{"args":[]}')).toBeNull()
    expect(decodeEvent('{"channel":"c"}')).toEqual({ channel: 'c', args: [] })
  })
})

describe('invoke', () => {
  it('posts {channel, args} to the invoke path and resolves with the value', async () => {
    const { calls, fetch } = fakeFetch(() => ok({ name: 'Terminal Deck' }))
    const transport = createTransport({ fetch })
    await expect(transport.invoke('brand:get', [])).resolves.toEqual({ name: 'Terminal Deck' })
    await expect(transport.invoke('projects:remove', ['/tmp/a'])).resolves.toEqual({ name: 'Terminal Deck' })
    expect(calls).toEqual([
      {
        url: BRIDGE_PATHS.invoke,
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: { channel: 'brand:get', args: [] },
      },
      {
        url: BRIDGE_PATHS.invoke,
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: { channel: 'projects:remove', args: ['/tmp/a'] },
      },
    ])
  })

  it('resolves bytes in an answer as bytes', async () => {
    const { fetch } = fakeFetch(() => ({
      status: 200,
      body: JSON.stringify({ ok: true, value: { $bytes: 'AQI=' } }),
    }))
    const value = await createTransport({ fetch }).invoke('x', [])
    expect(value).toBeInstanceOf(Uint8Array)
  })

  /*
   * Character for character, because four renderer helpers peel exactly this
   * prefix off to show the person the sentence inside: `deadline.ts`
   * `readFailure`, `browser/bridge.ts` `humanError`, `session-switch.ts`
   * `switchProblem` and `AccountChip.tsx`. They are not imported here — this
   * file is compiled with the preload, not the renderer — so the string they
   * match is pinned instead, and `humanError`'s two patterns are run over it.
   */
  it('rejects with the message Electron gives, prefix and all', async () => {
    const { fetch } = fakeFetch(() => ({
      status: 200,
      body: JSON.stringify({ ok: false, error: 'Error: The page has to be on screen to capture it.' }),
    }))
    const failure = await createTransport({ fetch })
      .invoke('browser-view:frame', [])
      .catch((error: unknown) => error)
    expect(failure).toBeInstanceOf(Error)
    expect((failure as Error).message).toBe(
      "Error invoking remote method 'browser-view:frame': Error: The page has to be on screen to capture it.",
    )
    const sentence = (failure as Error).message
      .replace(/^Error invoking remote method '[^']*':\s*/, '')
      .replace(/^[A-Za-z]*Error:\s*/, '')
    expect(sentence).toBe('The page has to be on screen to capture it.')
  })

  it('words a bare message and a named error class the same way Electron would', () => {
    expect(invokeError('a:b', 'No such file').message).toBe("Error invoking remote method 'a:b': Error: No such file")
    expect(invokeError('a:b', 'ProfileError: taken').message).toBe("Error invoking remote method 'a:b': ProfileError: taken")
    expect(invokeError('a:b', { message: 'gone' }).message).toBe("Error invoking remote method 'a:b': Error: gone")
  })

  it('rejects, never hangs, when the engine cannot be reached or answers with no result', async () => {
    const down = createTransport({
      fetch: () => Promise.reject(new TypeError('Load failed')),
    })
    await expect(down.invoke('brand:get', [])).rejects.toThrow(/^Error invoking remote method 'brand:get': Error: The engine could not be reached/)

    const { fetch } = fakeFetch(() => ({ status: 502, body: 'Bad Gateway' }))
    await expect(createTransport({ fetch }).invoke('brand:get', [])).rejects.toThrow(/HTTP 502/)
  })

  it('rejects an argument that cannot cross instead of throwing out of the call', async () => {
    const { fetch } = fakeFetch(() => ok(null))
    const loop: Record<string, unknown> = {}
    loop.self = loop
    await expect(createTransport({ fetch }).invoke('x', [loop])).rejects.toThrow(/Error invoking remote method 'x'/)
  })
})

describe('send', () => {
  it('posts {channel, args} to the send path and returns nothing', async () => {
    const { calls, fetch } = fakeFetch(() => ({ status: 204, body: '' }))
    const transport = createTransport({ fetch })
    expect(transport.send('session:resize', ['s1', 80, 24])).toBeUndefined()
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(calls).toEqual([
      {
        url: BRIDGE_PATHS.send,
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: { channel: 'session:resize', args: ['s1', 80, 24] },
      },
    ])
  })

  it('delivers sends in the order they were made, one after another', async () => {
    const releases: Array<() => void> = []
    const { calls, fetch } = fakeFetch(
      () => new Promise((resolve) => releases.push(() => resolve({ status: 204, body: '' }))),
    )
    const transport = createTransport({ fetch, warn: () => {} })
    transport.send('session:write', ['s1', 'l'])
    transport.send('session:write', ['s1', 's'])
    await new Promise((resolve) => setTimeout(resolve, 0))
    // The second keystroke is not on the wire while the first is still in flight.
    expect(calls.map((call) => call.body)).toEqual([{ channel: 'session:write', args: ['s1', 'l'] }])
    releases.shift()?.()
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(calls.map((call) => (call.body as { args: string[] }).args[1])).toEqual(['l', 's'])
  })

  it('lets an invoke made after a send land after it, and a failed send does not stop the queue', async () => {
    const order: string[] = []
    const { fetch } = fakeFetch((call) => {
      const { channel } = call.body as { channel: string }
      order.push(channel)
      if (channel === 'first') return Promise.reject(new Error('dropped'))
      return channel === 'ask' ? ok(1) : { status: 204, body: '' }
    })
    const warnings: string[] = []
    const transport = createTransport({ fetch, warn: (message) => warnings.push(message) })
    transport.send('first', [])
    transport.send('second', [])
    await expect(transport.invoke('ask', [])).resolves.toBe(1)
    expect(order).toEqual(['first', 'second', 'ask'])
    expect(warnings).toHaveLength(1)
  })

  it('encodes at the moment of the call, as Electron’s clone does', async () => {
    const { calls, fetch } = fakeFetch(() => ({ status: 204, body: '' }))
    const transport = createTransport({ fetch })
    const labels = ['one']
    transport.send('session:labels', [labels])
    labels.push('two')
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(calls[0].body).toEqual({ channel: 'session:labels', args: [['one']] })
  })
})

describe('sendSync', () => {
  it('blocks on a synchronous XMLHttpRequest to the send-sync path and returns its value', () => {
    const seen: Array<{ method: string; url: string; async: boolean; body?: string }> = []
    class FakeXhr {
      status = 200
      responseText = JSON.stringify({ value: 'answered' })
      open(method: string, url: string, async: boolean) {
        seen.push({ method, url, async })
      }
      setRequestHeader() {}
      send(body: string) {
        seen[seen.length - 1].body = body
      }
    }
    const transport = createTransport({ fetch: () => Promise.reject(new Error('unused')), XMLHttpRequest: FakeXhr })
    expect(transport.sendSync('x:sync', [1])).toBe('answered')
    expect(seen).toEqual([
      { method: 'POST', url: BRIDGE_PATHS.sendSync, async: false, body: JSON.stringify({ channel: 'x:sync', args: [1] }) },
    ])
  })
})

/* ------------------------------------------------------------- events -- */

class FakeEventSource implements EventSourceLike {
  static opened: FakeEventSource[] = []
  onopen: ((event: unknown) => void) | null = null
  onmessage: ((event: { data: string }) => void) | null = null
  onerror: ((event: unknown) => void) | null = null
  closed = false
  constructor(readonly url: string) {
    FakeEventSource.opened.push(this)
  }
  close() {
    this.closed = true
  }
  push(channel: string, args: unknown[]) {
    this.onmessage?.({ data: JSON.stringify({ channel, args }) })
  }
}

function fakeTimers() {
  const pending: Array<{ callback: () => void; ms: number }> = []
  return {
    pending,
    setTimeout: (callback: () => void, ms: number) => {
      pending.push({ callback, ms })
      return pending.length
    },
    fire() {
      pending.shift()?.callback()
    },
  }
}

describe('the event stream', () => {
  it('opens one EventSource on the events path and dispatches each message by channel', () => {
    FakeEventSource.opened = []
    const heard: Array<[string, unknown[]]> = []
    openEventStream({ EventSource: FakeEventSource, setTimeout: fakeTimers().setTimeout }, (channel, args) =>
      heard.push([channel, args]),
    )
    expect(FakeEventSource.opened.map((source) => source.url)).toEqual([BRIDGE_PATHS.events])
    FakeEventSource.opened[0].push('session:data', ['s1', 'hello'])
    FakeEventSource.opened[0].onmessage?.({ data: 'garbage' })
    FakeEventSource.opened[0].push('prefs:changed', [{ theme: 'light' }])
    expect(heard).toEqual([
      ['session:data', ['s1', 'hello']],
      ['prefs:changed', [{ theme: 'light' }]],
    ])
  })

  it('reconnects after a drop with a backoff that doubles, caps, and resets once connected', () => {
    FakeEventSource.opened = []
    const timers = fakeTimers()
    openEventStream({ EventSource: FakeEventSource, setTimeout: timers.setTimeout }, () => {})
    const delays: number[] = []
    for (let drop = 0; drop < 7; drop++) {
      const current = FakeEventSource.opened[FakeEventSource.opened.length - 1]
      current.onerror?.({})
      expect(current.closed).toBe(true)
      delays.push(timers.pending[0].ms)
      timers.fire()
    }
    expect(delays).toEqual([
      RECONNECT_FIRST_MS,
      RECONNECT_FIRST_MS * 2,
      RECONNECT_FIRST_MS * 4,
      RECONNECT_FIRST_MS * 8,
      RECONNECT_FIRST_MS * 16,
      RECONNECT_MAX_MS,
      RECONNECT_MAX_MS,
    ])
    expect(FakeEventSource.opened).toHaveLength(8)

    // A connection that opens resets the wait.
    const live = FakeEventSource.opened[7]
    live.onopen?.({})
    live.onerror?.({})
    expect(timers.pending[0].ms).toBe(RECONNECT_FIRST_MS)
  })

  it('ignores a late error from a source it has already replaced, and stops for good when closed', () => {
    FakeEventSource.opened = []
    const timers = fakeTimers()
    const stream = openEventStream({ EventSource: FakeEventSource, setTimeout: timers.setTimeout }, () => {})
    const first = FakeEventSource.opened[0]
    first.onerror?.({})
    timers.fire()
    first.onerror?.({})
    expect(timers.pending).toHaveLength(0)

    stream.close()
    expect(FakeEventSource.opened[1].closed).toBe(true)
    FakeEventSource.opened[1].onerror?.({})
    expect(timers.pending).toHaveLength(0)
    expect(FakeEventSource.opened).toHaveLength(2)
  })
})
