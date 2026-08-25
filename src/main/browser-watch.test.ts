import { describe, expect, it } from 'vitest'
import { PageCast, type CastFrame, type CastSeam, type SecretScan } from './browser-watch'
import { PERSON_METHODS } from './browser-cdp'
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
  /** Which of the two doors carried it — the agent's screened send, or the person's. */
  door: 'agent' | 'person'
}

/** The real allow-list the person's door screens against, not a copy of it. */
const PERSON = new Set(PERSON_METHODS)

class FakeSeam implements CastSeam {
  readonly sent: Sent[] = []
  human = false
  secrets: SecretScan | null = null
  private handler: ((method: string, params: Record<string, unknown>) => void) | null = null

  async send(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    this.sent.push({ method, params, door: 'agent' })
    if (this.human) throw new Error('the person has the page')
    return {}
  }

  /*
   * The other door, modelled the way `screenPersonCommand` actually screens it —
   * against the real exported list, and under the *inverse* condition. A fake
   * that let anything through here would let a test pass that the shipped screen
   * would refuse, which is the one thing this fake must not do.
   */
  async sendAsPerson(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    this.sent.push({ method, params, door: 'person' })
    if (!this.human) throw new Error('nobody has been handed this page')
    if (!PERSON.has(method)) throw new Error(`${method} is not one a person may send`)
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

  /**
   * The half of a keyboard that was missing, and why it looked like it worked.
   *
   * `dispatchKey` sent `key`, `code`, `text` and `modifiers` and no virtual key
   * code. Chromium hands such an event to the **page's JavaScript** — so a
   * site's own Return handler fires and a search submits, which is exactly what
   * made this look fine — but performs none of its **own** default handling: no
   * character deletion, no caret movement, no focus traversal, no scroll.
   *
   * Measured on a real page over the relay before the fix: `hello` typed into a
   * search box stayed `hello` after Backspace, and six ArrowDowns scrolled
   * nothing.
   */
  it('gives an editing key the code Chromium acts on, not only the one the page hears', async () => {
    const seam = new FakeSeam()
    const cast = new PageCast(seam)
    const sink = collector()
    await cast.watch('c1', '', { maxWidth: 800, quality: 50 }, sink.emit)
    seam.emitFrame({ width: 800, height: 600, dw: 800, dh: 600 })

    for (const [key, code] of [['Backspace', 8], ['Tab', 9], ['ArrowDown', 40], ['Escape', 27]] as const) {
      await cast.input('c1', { t: 'browser.input', window: '', seq: 1, key: { type: 'down', key } })
      const sent = seam.sentMethods('Input.dispatchKeyEvent').at(-1)
      expect(sent?.params, key).toMatchObject({ windowsVirtualKeyCode: code, nativeVirtualKeyCode: code })
    }
  })

  it('sends a key it has no code for anyway, rather than swallowing it', async () => {
    // A media key, a function key, anything not on the small table. The page can
    // still have bound it; silence would be a keystroke that reached nothing.
    const seam = new FakeSeam()
    const cast = new PageCast(seam)
    const sink = collector()
    await cast.watch('c1', '', { maxWidth: 800, quality: 50 }, sink.emit)
    seam.emitFrame({ width: 800, height: 600, dw: 800, dh: 600 })

    await cast.input('c1', { t: 'browser.input', window: '', seq: 1, key: { type: 'down', key: 'F13' } })
    const sent = seam.sentMethods('Input.dispatchKeyEvent').at(-1)
    expect(sent?.params).toMatchObject({ key: 'F13' })
    expect(sent?.params).not.toHaveProperty('windowsVirtualKeyCode')
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

/* ------------------------------------------------- the person on the phone -- */

/**
 * The taker: one watcher stepping through the curtain to answer a handover.
 *
 * The curtain above was written for a desktop, where the person the copilot is
 * asking for is already holding the mouse. On a phone the watcher **is** that
 * person, and what the curtain used to hand them was the agent's sentence with
 * the pixels removed and the keyboard refused. These pin the hole that was cut
 * in it, and — just as much — how narrow the hole is: one watcher, one page, and
 * an agent that stays refused throughout.
 */
describe('one watcher answers the handover and the rest stay curtained', () => {
  /** Two watchers on one page, both live, both drawn a curtain by the handover. */
  async function handedOver(prompt = 'Sign in and then press Done.') {
    const seam = new FakeSeam()
    const cast = new PageCast(seam)
    const first = collector()
    const second = collector()
    await cast.watch('phone', '', { maxWidth: 800, quality: 50 }, first.emit)
    await cast.watch('laptop', '', { maxWidth: 800, quality: 50 }, second.emit)

    // The driver's own ordering: curtain while this side may still send, then
    // flip the baton.
    await cast.curtain(prompt)
    seam.human = true
    return { seam, cast, first, second }
  }

  it('shows the taker the page while a second watcher keeps its lock card', async () => {
    const { seam, cast, first, second } = await handedOver()
    // Both were curtained by the handover, before anybody took it.
    expect(first.frames[0].masked).toBe(true)
    expect(second.frames[0].masked).toBe(true)

    expect(await cast.take('phone')).toEqual({ ok: true })
    // Taking restarts the screencast the curtain stopped — through the person's
    // door, because the agent's is refused for as long as the baton is theirs.
    const restart = seam.sent.filter((s) => s.method === 'Page.startScreencast')
    expect(restart[restart.length - 1].door).toBe('person')

    // Both watchers ack their lock card so a live frame can reach them.
    cast.ack('phone', first.frames[0].seq)
    cast.ack('laptop', second.frames[0].seq)
    seam.emitFrame({ width: 800, height: 600 })

    const toTaker = first.frames[first.frames.length - 1]
    const toOther = second.frames[second.frames.length - 1]
    // One CDP frame, two different answers — which is the whole of `mine`.
    expect(toTaker.masked).toBeUndefined()
    expect(toTaker.data.length).toBeGreaterThan(0)
    expect(toOther.masked).toBe(true)
    expect(toOther.data).toBe('')
    expect(toOther.prompt).toContain('Sign in')
  })

  it('shows the taker the secret field it was handed the page to fill in', async () => {
    const { seam, cast, first, second } = await handedOver()
    // A password box at document y 100..130, in view.
    seam.secrets = { rects: [{ x: 10, y: 100, width: 200, height: 30 }], viewport: { width: 800, height: 600 } }
    await cast.refreshSecrets()

    await cast.take('phone')
    cast.ack('phone', first.frames[0].seq)
    cast.ack('laptop', second.frames[0].seq)
    seam.emitFrame({ width: 800, height: 600 })

    // The secret-rect brake is skipped for the taker and only for the taker.
    // Masking the field they were asked to fill in would hide the entire task.
    expect(first.frames[first.frames.length - 1].masked).toBeUndefined()
    expect(second.frames[second.frames.length - 1].masked).toBe(true)
  })

  it('types for the taker down the person’s door and refuses everybody else', async () => {
    const { seam, cast, first } = await handedOver()
    await cast.take('phone')
    cast.ack('phone', first.frames[0].seq)
    seam.emitFrame({ width: 800, height: 600 })
    const seq = first.frames[first.frames.length - 1].seq

    const typed = await cast.input('phone', { t: 'browser.input', window: '', seq, paste: 'hunter2' })
    expect(typed.ok).toBe(true)
    const insert = seam.sent.filter((s) => s.method === 'Input.insertText')
    expect(insert).toHaveLength(1)
    expect(insert[0].door).toBe('person')

    // The other watcher of the same page is still the wrong person, and gets the
    // sentence it always got. Nothing reaches the page.
    const refused = await cast.input('laptop', { t: 'browser.input', window: '', seq: 1, mouse: { type: 'down', x: 10, y: 10 } })
    expect(refused.ok).toBe(false)
    expect(refused.reason).toContain('the person has this page right now')
    expect(seam.sent.filter((s) => s.method === 'Input.dispatchMouseEvent')).toHaveLength(0)
  })

  it('leaves the agent refused for the whole of it, reads and writes alike', async () => {
    /*
     * The rule that must not bend, from the cast's side. `FakeSeam.send` throws
     * whenever the baton is `human`, which is what `screenCommand` does, so every
     * command the cast tries down the *agent's* door while a person holds the page
     * fails — before, during and after somebody has taken it. The taker changed
     * who may type, never who may drive.
     */
    const { seam, cast, first } = await handedOver()
    await expect(seam.send('Page.captureScreenshot', {})).rejects.toThrow()
    await cast.take('phone')
    await expect(seam.send('Page.captureScreenshot', {})).rejects.toThrow()
    await expect(seam.send('Runtime.evaluate', {})).rejects.toThrow()

    // And nothing the cast itself did on the person's behalf went that way. From
    // the moment the baton flipped, every command it sent — the restart, the
    // acks, the keystrokes — rode the person's door; the agent's carried nothing.
    const flip = seam.sent.length
    cast.ack('phone', first.frames[0].seq)
    seam.emitFrame({ width: 800, height: 600 })
    await cast.input('phone', {
      t: 'browser.input',
      window: '',
      seq: first.frames[first.frames.length - 1].seq,
      paste: 'hunter2',
    })
    const since = seam.sent.slice(flip)
    expect(since.length).toBeGreaterThan(0)
    expect(since.filter((sent) => sent.door === 'agent')).toEqual([])
  })

  it('refuses a take from a connection that is not watching, and a second taker', async () => {
    const { cast } = await handedOver()
    const stranger = await cast.take('nobody')
    expect(stranger.ok).toBe(false)
    expect(stranger.reason).toContain('not being watched')

    expect(await cast.take('phone')).toEqual({ ok: true })
    const second = await cast.take('laptop')
    expect(second.ok).toBe(false)
    expect(second.reason).toContain('somebody else')
    // The first one still holds it: a refused second take changes nothing.
    expect(cast.isTaker('phone')).toBe(true)
    // And the holder tapping its own button again is not an error.
    expect(await cast.take('phone')).toEqual({ ok: true })
  })

  it('re-curtains when the taker’s socket drops, and does not leave the page open', async () => {
    /*
     * The failure this closes: a phone that went into a tunnel mid-password. The
     * taker is gone, the baton is still `human`, and without this the cast would
     * be left unmasked for whoever watches next.
     */
    const { seam, cast, first, second } = await handedOver()
    await cast.take('phone')
    cast.ack('laptop', second.frames[0].seq)
    const before = second.frames.length

    await cast.unwatch('phone')
    expect(cast.takerId).toBeNull()
    // The stream is stopped again, through the door that is open while the baton
    // is still the person's.
    const stops = seam.sent.filter((s) => s.method === 'Page.stopScreencast')
    expect(stops[stops.length - 1].door).toBe('person')
    // And the watcher left behind is drawn its lock card again rather than being
    // handed the next live frame.
    expect(second.frames.length).toBeGreaterThan(before)
    expect(second.frames[second.frames.length - 1].masked).toBe(true)

    cast.ack('laptop', second.frames[second.frames.length - 1].seq)
    seam.emitFrame({ width: 800, height: 600 })
    for (const frame of second.frames) expect(frame.data).toBe('')
    // The frames the taker was sent stopped with it.
    expect(first.frames[first.frames.length - 1].data).toBe('')
  })

  it('draws the question for a watcher that arrives after the curtain fell', async () => {
    /*
     * A phone that reconnected, or one that rotated — a renegotiation is a second
     * `browser.watch`. Without this it would sit on a blank canvas: `curtain()`
     * drew its lock cards to the watchers that existed then, and no screencast is
     * running to produce another.
     */
    const { cast } = await handedOver('Type the code from your phone.')
    const late = collector()
    await cast.watch('newcomer', '', { maxWidth: 800, quality: 50 }, late.emit)
    expect(late.frames).toHaveLength(1)
    expect(late.frames[0].masked).toBe(true)
    expect(late.frames[0].prompt).toContain('Type the code')
  })

  it('does not draw a lock card over the taker when it renegotiates', async () => {
    // The same path, for the one watcher that must not be curtained by it:
    // turning the phone sideways must not take the password field away mid-word.
    const { cast, first } = await handedOver()
    await cast.take('phone')
    const before = first.frames.length
    const rotated = collector()
    await cast.watch('phone', '', { maxWidth: 390, quality: 50 }, rotated.emit)
    expect(rotated.frames).toHaveLength(0)
    expect(first.frames).toHaveLength(before)
    expect(cast.isTaker('phone')).toBe(true)
  })

  it('clears the taker when the page is handed back', async () => {
    const { seam, cast, first } = await handedOver()
    await cast.take('phone')
    // The driver's order: release the hands, then move the baton, then uncurtain.
    await cast.untake()
    expect(cast.takerId).toBeNull()
    seam.human = false
    await cast.uncurtain()
    expect(cast.takerId).toBeNull()

    // Back to the ordinary agent-side cast: the restart goes down the agent's
    // door, because with no taker that is the door the view rides.
    const restart = seam.sent.filter((s) => s.method === 'Page.startScreencast')
    expect(restart[restart.length - 1].door).toBe('agent')
    cast.ack('phone', first.frames[first.frames.length - 1].seq)
    seam.emitFrame({ width: 800, height: 600 })
    expect(first.frames[first.frames.length - 1].masked).toBeUndefined()

    // And the ex-taker's keystrokes are ordinary watcher input again — the
    // agent's door, which is the one that is open now.
    const typed = await cast.input('phone', {
      t: 'browser.input',
      window: '',
      seq: first.frames[first.frames.length - 1].seq,
      paste: 'ordinary',
    })
    expect(typed.ok).toBe(true)
    const insert = seam.sent.filter((s) => s.method === 'Input.insertText')
    expect(insert[insert.length - 1].door).toBe('agent')
  })
})
