import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { CdpPipe, type CdpEvent, type ReadableLike, type WritableLike } from './browser-cdp-pipe'

/**
 * The pipe, driven over a fake fd pair.
 *
 * Nothing here spawns Chromium or opens a debugger: the pipe consumes two
 * streams, and the tests hand it fakes. What is pinned is the framing (a command
 * round-trips to a reply, an event routes by session), the single write door,
 * backpressure (one frame in flight until drain), and that the module carries no
 * Electron — because it is one of the files the headless closure walks.
 */

/** A fake fd-3: records the frames written, and can signal backpressure. */
class FakeOut implements WritableLike {
  readonly frames: Buffer[] = []
  accepting = true
  private drain: (() => void) | null = null

  write(chunk: Buffer): boolean {
    this.frames.push(Buffer.from(chunk))
    return this.accepting
  }

  once(_event: 'drain', listener: () => void): this {
    this.drain = listener
    return this
  }

  /** The far end caught up: let writes flow and fire the queued drain. */
  fireDrain(): void {
    this.accepting = true
    const listener = this.drain
    this.drain = null
    if (listener) listener()
  }

  /** The frames written, parsed back from NUL-delimited JSON. */
  sent(): Record<string, unknown>[] {
    return this.frames.map((frame) => {
      const text = frame.toString('utf8')
      expect(text.endsWith('\0')).toBe(true)
      return JSON.parse(text.slice(0, -1)) as Record<string, unknown>
    })
  }
}

/** A fake fd-4: pushes bytes at the pipe on demand. */
class FakeIn implements ReadableLike {
  private handlers = new Map<string, (arg: never) => void>()

  on(event: 'data' | 'end' | 'close' | 'error', listener: (arg: never) => void): this {
    this.handlers.set(event, listener)
    return this
  }

  /** Deliver one already-framed chunk (Buffer) or JSON value (framed here). */
  push(value: Buffer | Record<string, unknown>): void {
    const chunk = Buffer.isBuffer(value)
      ? value
      : Buffer.from(JSON.stringify(value) + '\0', 'utf8')
    const data = this.handlers.get('data') as ((c: Buffer) => void) | undefined
    data?.(chunk)
  }

  end(): void {
    const end = this.handlers.get('end') as (() => void) | undefined
    end?.()
  }
}

function makePipe(): { pipe: CdpPipe; out: FakeOut; incoming: FakeIn } {
  const out = new FakeOut()
  const incoming = new FakeIn()
  const pipe = new CdpPipe(out, incoming)
  return { pipe, out, incoming }
}

describe('a command round-trips to its reply', () => {
  it('frames a command with an id, method, params and session', () => {
    const { pipe, out } = makePipe()
    void pipe.command({ method: 'Page.enable', params: { foo: 1 }, sessionId: 'S1' })
    const sent = out.sent()
    expect(sent).toHaveLength(1)
    expect(sent[0]).toEqual({ id: 1, method: 'Page.enable', params: { foo: 1 }, sessionId: 'S1' })
  })

  it('resolves with the reply result when the matching id comes back', async () => {
    const { pipe, out, incoming } = makePipe()
    const pending = pipe.command({ method: 'Page.getLayoutMetrics' })
    const { id } = out.sent()[0] as { id: number }
    incoming.push({ id, result: { cssVisualViewport: { clientWidth: 800 } } })
    await expect(pending).resolves.toEqual({ cssVisualViewport: { clientWidth: 800 } })
    expect(pipe.inFlight).toBe(0)
  })

  it('rejects with the protocol error, carrying its code', async () => {
    const { pipe, out, incoming } = makePipe()
    const pending = pipe.command({ method: 'Runtime.evaluate' })
    const { id } = out.sent()[0] as { id: number }
    incoming.push({ id, error: { code: -32000, message: 'Cannot find context' } })
    await expect(pending).rejects.toMatchObject({ message: 'Cannot find context', code: -32000 })
  })

  it('gives every command its own id, so replies cannot cross', async () => {
    const { pipe, out, incoming } = makePipe()
    const a = pipe.command({ method: 'Page.enable' })
    const b = pipe.command({ method: 'Runtime.enable' })
    const ids = out.sent().map((frame) => frame.id)
    expect(ids).toEqual([1, 2])
    // Answer them out of order; each promise still gets its own reply.
    incoming.push({ id: 2, result: { b: true } })
    incoming.push({ id: 1, result: { a: true } })
    await expect(a).resolves.toEqual({ a: true })
    await expect(b).resolves.toEqual({ b: true })
  })

  it('ignores a reply to an id it never sent', () => {
    const { pipe, incoming } = makePipe()
    expect(() => incoming.push({ id: 999, result: {} })).not.toThrow()
    expect(pipe.inFlight).toBe(0)
  })
})

describe('events demux by session, replies do not', () => {
  it('routes an event to the listener for its session', () => {
    const { pipe, incoming } = makePipe()
    const s1: CdpEvent[] = []
    const s2: CdpEvent[] = []
    pipe.on('S1', (event) => s1.push(event))
    pipe.on('S2', (event) => s2.push(event))
    incoming.push({ sessionId: 'S1', method: 'Page.loadEventFired', params: { timestamp: 1 } })
    expect(s1).toEqual([{ sessionId: 'S1', method: 'Page.loadEventFired', params: { timestamp: 1 } }])
    expect(s2).toEqual([])
  })

  it('routes a browser-level event (no session) to the undefined subscriber', () => {
    const { pipe, incoming } = makePipe()
    const browser: CdpEvent[] = []
    const session: CdpEvent[] = []
    pipe.on(undefined, (event) => browser.push(event))
    pipe.on('S1', (event) => session.push(event))
    incoming.push({ method: 'Target.attachedToTarget', params: { sessionId: 'S9' } })
    expect(browser).toEqual([{ sessionId: undefined, method: 'Target.attachedToTarget', params: { sessionId: 'S9' } }])
    expect(session).toEqual([])
  })

  it('stops delivering after unsubscribe', () => {
    const { pipe, incoming } = makePipe()
    const seen: CdpEvent[] = []
    const off = pipe.on('S1', (event) => seen.push(event))
    incoming.push({ sessionId: 'S1', method: 'Page.frameStoppedLoading', params: {} })
    off()
    incoming.push({ sessionId: 'S1', method: 'Page.frameStoppedLoading', params: {} })
    expect(seen).toHaveLength(1)
  })

  it('does not deliver an event as if it were a reply', async () => {
    const { pipe, out, incoming } = makePipe()
    const pending = pipe.command({ method: 'Page.enable' })
    const { id } = out.sent()[0] as { id: number }
    // An event has a method and no id; it must not settle the pending command.
    incoming.push({ sessionId: 'S1', method: 'Page.loadEventFired', params: {} })
    expect(pipe.inFlight).toBe(1)
    incoming.push({ id, result: {} })
    await expect(pending).resolves.toEqual({})
  })
})

describe('the framing survives however the bytes arrive', () => {
  it('reassembles a reply split across two chunks', async () => {
    const { pipe, out, incoming } = makePipe()
    const pending = pipe.command({ method: 'Page.enable' })
    const { id } = out.sent()[0] as { id: number }
    const whole = Buffer.from(JSON.stringify({ id, result: { ok: true } }) + '\0', 'utf8')
    incoming.push(whole.subarray(0, 6))
    incoming.push(whole.subarray(6))
    await expect(pending).resolves.toEqual({ ok: true })
  })

  it('reads two frames delivered in one chunk', () => {
    const { pipe, incoming } = makePipe()
    const seen: CdpEvent[] = []
    pipe.on('S1', (event) => seen.push(event))
    const a = JSON.stringify({ sessionId: 'S1', method: 'A', params: 1 }) + '\0'
    const b = JSON.stringify({ sessionId: 'S1', method: 'B', params: 2 }) + '\0'
    incoming.push(Buffer.from(a + b, 'utf8'))
    expect(seen.map((event) => event.method)).toEqual(['A', 'B'])
  })

  it('drops a malformed frame without crashing the reader', () => {
    const { pipe, incoming } = makePipe()
    const seen: CdpEvent[] = []
    pipe.on('S1', (event) => seen.push(event))
    incoming.push(Buffer.from('{not json}\0', 'utf8'))
    incoming.push({ sessionId: 'S1', method: 'A', params: {} })
    expect(seen.map((event) => event.method)).toEqual(['A'])
  })
})

describe('backpressure keeps one frame in flight', () => {
  it('holds the next frame until the pipe drains', () => {
    const { pipe, out } = makePipe()
    out.accepting = false // the far end's buffer is full
    void pipe.command({ method: 'A' })
    void pipe.command({ method: 'B' })
    // Only the first frame went out; the second is held rather than piled on.
    expect(out.sent().map((frame) => frame.method)).toEqual(['A'])
    out.fireDrain()
    expect(out.sent().map((frame) => frame.method)).toEqual(['A', 'B'])
  })
})

describe('closing the pipe', () => {
  it('rejects everything in flight on EOF and tells the close listeners', async () => {
    const { pipe, incoming } = makePipe()
    let closed = false
    pipe.onClose(() => {
      closed = true
    })
    const pending = pipe.command({ method: 'Page.enable' })
    incoming.end()
    await expect(pending).rejects.toThrow()
    expect(closed).toBe(true)
    expect(pipe.inFlight).toBe(0)
  })

  it('refuses to send once closed, without touching any process', async () => {
    const { pipe, incoming } = makePipe()
    incoming.end()
    await expect(pipe.command({ method: 'Page.enable' })).rejects.toThrow()
  })
})

/* ------------------------------------------------ writing into a dead pipe -- */

/**
 * The write end of a pipe onto a browser that has died.
 *
 * A Node stream with no `'error'` listener re-raises the error as an uncaught
 * exception and takes the process down. Measured on Ubuntu 24.04 on 2026-08-22
 * against a Chromium that aborted at startup: writing one `Browser.getVersion`
 * frame into its fd 3 produced `throw er; // Unhandled 'error' event` and killed
 * Node. On a headless host that process is the daemon — the sessions, the
 * pairing and the relay connection all go with it, and the only trace left is a
 * V8 stack trace in a log.
 */
class DyingOut implements WritableLike {
  private handler: ((error: Error) => void) | null = null
  /** True once something subscribed — the assertion that the listener exists. */
  subscribed = false

  write(): boolean {
    // EPIPE arrives asynchronously, the way a real stream delivers it.
    setImmediate(() => this.handler?.(Object.assign(new Error('write EPIPE'), { code: 'EPIPE' })))
    return true
  }

  once(_event: 'drain', _listener: () => void): this {
    return this
  }

  on(_event: 'error', listener: (error: Error) => void): this {
    this.subscribed = true
    this.handler = listener
    return this
  }
}

/** A write end that is already destroyed, so `write` throws instead of emitting. */
class DestroyedOut implements WritableLike {
  write(): boolean {
    throw Object.assign(new Error('Cannot call write after a stream was destroyed'), {
      code: 'ERR_STREAM_DESTROYED',
    })
  }
  once(_event: 'drain', _listener: () => void): this {
    return this
  }
  on(_event: 'error', _listener: (error: Error) => void): this {
    return this
  }
}

describe('the browser died while a command was in flight', () => {
  it('subscribes to the write side, and turns EPIPE into a rejection', async () => {
    const out = new DyingOut()
    const pipe = new CdpPipe(out, new FakeIn())
    expect(out.subscribed).toBe(true)

    const closed: (Error | undefined)[] = []
    pipe.onClose((error) => closed.push(error))
    const inFlight = pipe.command({ method: 'Browser.getVersion' })

    await expect(inFlight).rejects.toThrow('EPIPE')
    expect(closed).toHaveLength(1)
    // Nothing is left waiting for a reply that cannot come.
    expect(pipe.inFlight).toBe(0)
  })

  it('turns a write onto a destroyed stream into a rejection too', async () => {
    const pipe = new CdpPipe(new DestroyedOut(), new FakeIn())
    await expect(pipe.command({ method: 'Browser.getVersion' })).rejects.toThrow(
      'Cannot call write after a stream was destroyed',
    )
    expect(pipe.inFlight).toBe(0)
  })
})

describe('the module is a single send door and carries no Electron', () => {
  const src = readFileSync(join(__dirname, 'browser-cdp-pipe.ts'), 'utf8')

  it('writes to the fd from exactly one place', () => {
    // The mirror of `browser-cdp.test.ts`'s single-`sendCommand` count. The
    // screening that precedes it lives in `browser-driver.ts`'s `send()`, which
    // calls this door only after `screenCommand({ transport: 'cdp', … })`.
    const writes = src.match(/this\.out\.write\(/g) ?? []
    expect(writes).toHaveLength(1)
  })

  it('imports nothing from Electron, because the headless closure walks it', () => {
    expect(src).not.toContain("from 'electron'")
    expect(src).not.toContain("require('electron')")
  })
})
