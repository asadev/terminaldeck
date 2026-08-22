import { describe, expect, it } from 'vitest'
import { PageCast, type CastFrame, type CastSeam, type SecretScan } from './browser-watch'
import { MAX_FRAME_DATA_CHARS } from './remote/protocol'

/**
 * The cast, driven over a fake seam — no Chromium, no debugger, no writeFile.
 *
 * Every test scripts a `Page.screencastFrame` onto the seam's event stream and
 * reads what the cast forwards and what it sends back to CDP. The seam records
 * every command so the ack chain and the input mapping can be asserted by name.
 */

/** A minimal JPEG whose SOF marker carries the width and height we ask for. */
function jpeg(width: number, height: number): string {
  return Buffer.from([
    0xff, 0xd8,
    0xff, 0xc0, 0x00, 0x11, 0x08,
    (height >> 8) & 0xff, height & 0xff,
    (width >> 8) & 0xff, width & 0xff,
    0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
    0xff, 0xd9,
  ]).toString('base64')
}

interface Sent {
  method: string
  params: Record<string, unknown>
}

class FakeSeam implements CastSeam {
  readonly sent: Sent[] = []
  human = false
  secrets: SecretScan | null = null
  private handler: ((method: string, params: Record<string, unknown>) => void) | null = null

  async send(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    this.sent.push({ method, params })
    if (this.human) throw new Error('the person has the page')
    return {}
  }
  onEvent(handler: (method: string, params: Record<string, unknown>) => void): () => void {
    this.handler = handler
    return () => {
      this.handler = null
    }
  }
  async scanSecrets(): Promise<SecretScan | null> {
    return this.secrets
  }
  isHuman(): boolean {
    return this.human
  }
  now(): number {
    return 1000
  }

  /** Push a screencast frame onto the stream. */
  emitFrame(input: {
    data?: string
    width?: number
    height?: number
    dw?: number
    dh?: number
    scrollX?: number
    scrollY?: number
    sessionId?: number
  }): void {
    const dw = input.dw ?? 800
    const dh = input.dh ?? 600
    const width = input.width ?? dw
    const height = input.height ?? dh
    this.handler?.('Page.screencastFrame', {
      data: input.data ?? jpeg(width, height),
      sessionId: input.sessionId ?? 7,
      metadata: {
        offsetTop: 0,
        pageScaleFactor: 1,
        deviceWidth: dw,
        deviceHeight: dh,
        scrollOffsetX: input.scrollX ?? 0,
        scrollOffsetY: input.scrollY ?? 0,
      },
    })
  }

  sentMethods(method: string): Sent[] {
    return this.sent.filter((s) => s.method === method)
  }
}

function collector(): { frames: CastFrame[]; emit: (f: CastFrame) => void } {
  const frames: CastFrame[] = []
  return { frames, emit: (f) => frames.push(f) }
}

describe('a page cast forwards frames and acks CDP behind them', () => {
  it('starts a jpeg screencast and forwards the first frame with its geometry', async () => {
    const seam = new FakeSeam()
    const cast = new PageCast(seam)
    const sink = collector()
    await cast.watch('c1', '', { maxWidth: 800, quality: 50 }, sink.emit)

    const start = seam.sentMethods('Page.startScreencast')
    expect(start).toHaveLength(1)
    expect(start[0].params).toMatchObject({ format: 'jpeg', quality: 50, maxWidth: 800 })

    seam.emitFrame({ width: 800, height: 600, dw: 800, dh: 600 })
    expect(sink.frames).toHaveLength(1)
    const frame = sink.frames[0]
    expect(frame.window).toBe('')
    expect(frame.seq).toBe(1)
    expect(frame.w).toBe(800)
    expect(frame.h).toBe(600)
    expect(frame.dw).toBe(800)
    expect(frame.scale).toBe(1)
    expect(frame.masked).toBeUndefined()
    expect(frame.data.length).toBeGreaterThan(0)
    // Acked CDP once, so the next frame will be produced.
    expect(seam.sentMethods('Page.screencastFrameAck')).toHaveLength(1)
    expect(seam.sentMethods('Page.screencastFrameAck')[0].params).toEqual({ sessionId: 7 })
  })

  it('holds one un-acked frame per watcher and lets the newest replace the pending one', async () => {
    const seam = new FakeSeam()
    const cast = new PageCast(seam)
    const sink = collector()
    await cast.watch('c1', '', { maxWidth: 800, quality: 50 }, sink.emit)

    seam.emitFrame({ scrollY: 0 })
    expect(sink.frames).toHaveLength(1)
    // A second frame while the first is un-acked is NOT forwarded.
    seam.emitFrame({ scrollY: 10 })
    seam.emitFrame({ scrollY: 20 })
    expect(sink.frames).toHaveLength(1)
    // CDP was acked only for the one frame that was forwarded.
    expect(seam.sentMethods('Page.screencastFrameAck')).toHaveLength(1)

    // The viewer renders it; the newest pending frame (scrollY 20) is forwarded.
    cast.ack('c1', 1)
    expect(sink.frames).toHaveLength(2)
    expect(sink.frames[1].seq).toBe(2)
    expect(sink.frames[1].scrollY).toBe(20)
  })

  it('never lets one watcher’s grant deliver frames to another', async () => {
    const seam = new FakeSeam()
    const cast = new PageCast(seam)
    const a = collector()
    const b = collector()
    await cast.watch('a', 'B2', { maxWidth: 800, quality: 50 }, a.emit)
    await cast.watch('b', '', { maxWidth: 800, quality: 50 }, b.emit)
    seam.emitFrame({})
    expect(a.frames).toHaveLength(1)
    expect(b.frames).toHaveLength(1)
    // Each got the frame under its own window name and its own seq counter.
    expect(a.frames[0].window).toBe('B2')
    expect(b.frames[0].window).toBe('')
    // Dropping A stops its stream; B still gets frames.
    await cast.unwatch('a')
    cast.ack('b', 1)
    seam.emitFrame({})
    expect(a.frames).toHaveLength(1)
    expect(b.frames).toHaveLength(2)
  })
})

describe('a secret never crosses the cast', () => {
  it('masks a frame with empty data when a secret rect is in the viewport', async () => {
    const seam = new FakeSeam()
    seam.secrets = { rects: [{ x: 40, y: 100, width: 200, height: 30 }], viewport: { width: 800, height: 600 } }
    const cast = new PageCast(seam)
    const sink = collector()
    await cast.watch('c1', '', { maxWidth: 800, quality: 50 }, sink.emit)
    await cast.refreshSecrets()

    seam.emitFrame({ dw: 800, dh: 600, scrollY: 0 })
    expect(sink.frames).toHaveLength(1)
    expect(sink.frames[0].masked).toBe(true)
    expect(sink.frames[0].data).toBe('')
    expect(sink.frames[0].prompt).toBeTruthy()
  })

  it('lets the frame through once the secret has scrolled out of view', async () => {
    const seam = new FakeSeam()
    seam.secrets = { rects: [{ x: 40, y: 100, width: 200, height: 30 }], viewport: { width: 800, height: 600 } }
    const cast = new PageCast(seam)
    const sink = collector()
    await cast.watch('c1', '', { maxWidth: 800, quality: 50 }, sink.emit)
    await cast.refreshSecrets()

    // The secret sits at document y 100..130; scroll past it so the viewport is
    // 400..1000 and it is no longer visible.
    seam.emitFrame({ dw: 800, dh: 600, scrollY: 400 })
    expect(sink.frames[0].masked).toBeUndefined()
    expect(sink.frames[0].data.length).toBeGreaterThan(0)
  })

  it('curtains the whole cast during a handover and refuses input', async () => {
    const seam = new FakeSeam()
    const cast = new PageCast(seam)
    const sink = collector()
    await cast.watch('c1', '', { maxWidth: 800, quality: 50 }, sink.emit)

    // The driver curtains before the baton flips: stopScreencast is sent and a
    // lock card is drawn now.
    await cast.curtain('Type your password on the page.')
    expect(seam.sentMethods('Page.stopScreencast')).toHaveLength(1)
    expect(sink.frames).toHaveLength(1)
    expect(sink.frames[0].masked).toBe(true)
    expect(sink.frames[0].data).toBe('')
    expect(sink.frames[0].prompt).toContain('password')

    // With the person holding the page, input is refused and nothing is sent.
    seam.human = true
    const refused = await cast.input('c1', { t: 'browser.input', window: '', seq: 1, mouse: { type: 'down', x: 10, y: 10 } })
    expect(refused.ok).toBe(false)
    expect(seam.sentMethods('Input.dispatchMouseEvent')).toHaveLength(0)

    // Handing it back restarts the screencast.
    seam.human = false
    await cast.uncurtain()
    expect(seam.sentMethods('Page.startScreencast').length).toBeGreaterThanOrEqual(2)
  })
})

describe('input maps image pixels to the frame it named', () => {
  it('divides by the acked frame’s scale, not a scale the viewer sent', async () => {
    const seam = new FakeSeam()
    const cast = new PageCast(seam)
    const sink = collector()
    await cast.watch('c1', '', { maxWidth: 400, quality: 50 }, sink.emit)

    // Image is 400px wide for a 800px CSS viewport → scale 0.5.
    seam.emitFrame({ width: 400, height: 300, dw: 800, dh: 600 })
    expect(sink.frames[0].scale).toBe(0.5)

    // A tap at image (200, 150) maps to CSS viewport (400, 300).
    const res = await cast.input('c1', {
      t: 'browser.input',
      window: '',
      seq: 1,
      mouse: { type: 'down', x: 200, y: 150, button: 'left', clicks: 1 },
    })
    expect(res.ok).toBe(true)
    const click = seam.sentMethods('Input.dispatchMouseEvent')
    expect(click).toHaveLength(1)
    expect(click[0].params).toMatchObject({ type: 'mousePressed', x: 400, y: 300, button: 'left', clickCount: 1 })
  })

  it('turns a wheel into a scroll with the sign flipped', async () => {
    const seam = new FakeSeam()
    const cast = new PageCast(seam)
    const sink = collector()
    await cast.watch('c1', '', { maxWidth: 800, quality: 50 }, sink.emit)
    seam.emitFrame({ width: 800, height: 600, dw: 800, dh: 600 })

    await cast.input('c1', { t: 'browser.input', window: '', seq: 1, mouse: { type: 'wheel', x: 100, y: 100, dx: 0, dy: 40 } })
    const wheel = seam.sentMethods('Input.dispatchMouseEvent')
    expect(wheel[0].params).toMatchObject({ type: 'mouseWheel', deltaY: -40 })
  })

  it('refuses input for a window this connection is not watching', async () => {
    const seam = new FakeSeam()
    const cast = new PageCast(seam)
    const sink = collector()
    await cast.watch('c1', '', { maxWidth: 800, quality: 50 }, sink.emit)
    const res = await cast.input('other', { t: 'browser.input', window: '', seq: 1, mouse: { type: 'down', x: 1, y: 1 } })
    expect(res.ok).toBe(false)
    expect(seam.sentMethods('Input.dispatchMouseEvent')).toHaveLength(0)
  })
})

describe('a frame over the field cap is dropped, never chunked', () => {
  it('drops an over-cap frame, acks CDP, and steps quality down', async () => {
    const seam = new FakeSeam()
    const cast = new PageCast(seam)
    const sink = collector()
    await cast.watch('c1', '', { maxWidth: 800, quality: 50 }, sink.emit)

    const tooBig = 'A'.repeat(MAX_FRAME_DATA_CHARS + 4)
    seam.emitFrame({ data: tooBig })
    expect(sink.frames).toHaveLength(0)
    // CDP still acked so the stream continues.
    expect(seam.sentMethods('Page.screencastFrameAck')).toHaveLength(1)
    // Quality was re-issued lower.
    const starts = seam.sentMethods('Page.startScreencast')
    expect(starts.length).toBeGreaterThanOrEqual(2)
    expect((starts[starts.length - 1].params.quality as number)).toBeLessThan(50)

    // A frame within the cap now forwards normally.
    seam.emitFrame({ width: 800, height: 600 })
    expect(sink.frames).toHaveLength(1)
    expect(sink.frames[0].data.length).toBeGreaterThan(0)
  })

  it('never writes a frame to disk', () => {
    // The source assertion the handover-mask note asks for: no filesystem write
    // anywhere on the cast path.
    const source = require('node:fs').readFileSync(require('node:path').join(__dirname, 'browser-watch.ts'), 'utf8')
    expect(source).not.toContain('writeFile')
    expect(source).not.toContain('mkdir')
  })
})
