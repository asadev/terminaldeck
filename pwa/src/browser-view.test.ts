/**
 * The watch surface, exercised without a browser.
 *
 * The canvas, its 2D context and the JPEG decoder are all injected, so the suite
 * drives the exact paint/ack loop and coordinate math a phone runs — a real
 * `createImageBitmap` and a real `<canvas>` are the two things a Node test does
 * not have, and the two this file fakes. What is checked here is the pair of
 * decisions that are wrong silently: that the ack fires *after* the draw, and
 * that a pointer lands on the pixel a person touched of the frame they touched.
 */

import { describe, expect, it, vi } from 'vitest'
import {
  MAX_WATCH_QUALITY,
  MAX_WATCH_WIDTH,
  MIN_WATCH_WIDTH,
  type BrowserFrameFrame,
  type ClientMessage,
} from '../../src/main/remote/protocol'
import {
  clampWatchWidth,
  imageCoords,
  WatchCanvas,
  watchOffered,
  type KeyLike,
  type PointerLike,
  type WheelLike,
} from './browser-view'

/** An ordered log so a test can prove the draw came before the ack. */
type Event = { kind: 'draw' } | { kind: 'curtain' } | { kind: 'send'; message: ClientMessage }

function harness(
  options: {
    clientWidth?: number
    clientHeight?: number
    dpr?: number
    decodeFails?: boolean
    decode?: (data: string) => Promise<ImageBitmap>
  } = {},
) {
  const events: Event[] = []
  const bitmap = { width: 0, height: 0, close: vi.fn() } as unknown as ImageBitmap

  const ctx = {
    fillStyle: '',
    font: '',
    textAlign: '' as CanvasTextAlign,
    textBaseline: '' as CanvasTextBaseline,
    fillRect: vi.fn(),
    fillText: vi.fn(() => events.push({ kind: 'curtain' })),
    drawImage: vi.fn(() => events.push({ kind: 'draw' })),
  } as unknown as CanvasRenderingContext2D

  const canvas = {
    clientWidth: options.clientWidth ?? 400,
    clientHeight: options.clientHeight ?? 700,
    width: 0,
    height: 0,
    getContext: () => ctx,
    setPointerCapture: vi.fn(),
    releasePointerCapture: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  } as unknown as HTMLCanvasElement & { clientWidth: number; clientHeight: number }

  const send = vi.fn((message: ClientMessage): boolean => {
    events.push({ kind: 'send', message })
    return true
  })

  const decode =
    options.decode ??
    (options.decodeFails
      ? vi.fn(() => Promise.reject(new Error('not a jpeg')))
      : vi.fn(() => Promise.resolve(bitmap)))

  const view = new WatchCanvas({
    window: '',
    canvas,
    send,
    decode,
    dpr: () => options.dpr ?? 1,
    quality: 50,
  })

  return { view, canvas, ctx, send, decode, events, bitmap }
}

function frame(patch: Partial<BrowserFrameFrame> = {}): BrowserFrameFrame {
  return {
    t: 'browser.frame',
    window: '',
    seq: 7,
    w: 800,
    h: 1400,
    dw: 800,
    dh: 1400,
    scale: 1,
    offsetTop: 0,
    pageScale: 1,
    scrollX: 0,
    scrollY: 0,
    data: 'AAAA',
    ...patch,
  }
}

function pointer(patch: Partial<PointerLike> = {}): PointerLike {
  return { pointerId: 1, pointerType: 'mouse', button: 0, offsetX: 0, offsetY: 0, ...patch }
}

describe('watchOffered', () => {
  it('is true only when the host advertised the capability', () => {
    expect(watchOffered(['credential', 'watch', 'devices'])).toBe(true)
    expect(watchOffered(['credential', 'devices'])).toBe(false)
    expect(watchOffered([])).toBe(false)
  })
})

describe('clampWatchWidth', () => {
  it('is the CSS width times the pixel ratio, clamped and rounded', () => {
    expect(clampWatchWidth(390, 3)).toBe(1170)
    expect(clampWatchWidth(200.4, 2)).toBe(401)
  })
  it('never asks for less than the floor or more than the ceiling', () => {
    expect(clampWatchWidth(10, 1)).toBe(MIN_WATCH_WIDTH)
    expect(clampWatchWidth(4000, 2)).toBe(MAX_WATCH_WIDTH)
  })
  it('treats a broken pixel ratio as 1 rather than propagating a NaN width', () => {
    expect(clampWatchWidth(400, Number.NaN)).toBe(400)
    expect(clampWatchWidth(400, 0)).toBe(400)
  })
})

describe('imageCoords', () => {
  it('maps a CSS point to image pixels by the box ratio on each axis', () => {
    // 400x700 canvas showing an 800x1400 frame: everything is doubled.
    expect(imageCoords({ w: 800, h: 1400 }, 400, 700, 100, 50)).toEqual({ x: 200, y: 100 })
  })
  it('clamps a point dragged past the edge into the image', () => {
    expect(imageCoords({ w: 800, h: 1400 }, 400, 700, -20, 5000)).toEqual({ x: 0, y: 1400 })
  })
})

describe('drawing a frame', () => {
  it('decodes the JPEG, blits it, and only then acks — the backpressure order', async () => {
    const h = harness()
    await h.view.onFrame(frame({ seq: 7 }))

    expect(h.decode).toHaveBeenCalledWith('AAAA')
    expect(h.ctx.drawImage).toHaveBeenCalledTimes(1)
    // The bitmap is drawn to fill the backing store, sized to the CSS box in
    // device pixels (dpr 1 here).
    expect(h.ctx.drawImage).toHaveBeenCalledWith(h.bitmap, 0, 0, 400, 700)

    // The ack is a browser.frame.ack for this window and seq...
    const ack = h.send.mock.calls.map((c) => c[0]).find((m) => m.t === 'browser.frame.ack')
    expect(ack).toEqual({ t: 'browser.frame.ack', window: '', seq: 7 })

    // ...and it is sent strictly after the draw, which is the whole of the
    // rendered-not-received contract.
    const drawAt = h.events.findIndex((e) => e.kind === 'draw')
    const ackAt = h.events.findIndex((e) => e.kind === 'send' && e.message.t === 'browser.frame.ack')
    expect(drawAt).toBeGreaterThanOrEqual(0)
    expect(ackAt).toBeGreaterThan(drawAt)
  })

  it('acks even when a frame will not decode, so one bad frame cannot stall the cast', async () => {
    const h = harness({ decodeFails: true })
    await h.view.onFrame(frame({ seq: 9 }))
    expect(h.ctx.drawImage).not.toHaveBeenCalled()
    const ack = h.send.mock.calls.map((c) => c[0]).find((m) => m.t === 'browser.frame.ack')
    expect(ack).toEqual({ t: 'browser.frame.ack', window: '', seq: 9 })
  })

  it('ignores a frame addressed to another window', async () => {
    const h = harness()
    await h.view.onFrame(frame({ window: 'B2' }))
    expect(h.decode).not.toHaveBeenCalled()
    expect(h.send).not.toHaveBeenCalled()
  })
})

describe('a masked frame', () => {
  it('draws the curtain, never the pixels, and still acks', async () => {
    const h = harness()
    await h.view.onFrame(frame({ seq: 4, masked: true, data: '', prompt: 'Signing in on the phone' }))

    // The image path is never entered: no decode, no drawImage.
    expect(h.decode).not.toHaveBeenCalled()
    expect(h.ctx.drawImage).not.toHaveBeenCalled()

    // The curtain is drawn — a filled card and the prompt.
    expect(h.ctx.fillRect).toHaveBeenCalled()
    expect(h.ctx.fillText).toHaveBeenCalledWith('Signing in on the phone', expect.any(Number), expect.any(Number))

    // And a masked frame is still acked, so the host keeps the stream alive to
    // send the unmasked frame the moment the secret leaves the screen.
    const ack = h.send.mock.calls.map((c) => c[0]).find((m) => m.t === 'browser.frame.ack')
    expect(ack).toEqual({ t: 'browser.frame.ack', window: '', seq: 4 })
  })
})

describe('negotiating width', () => {
  it('watches at the canvas width, and re-watches at the new width after a resize', () => {
    const h = harness({ clientWidth: 400, dpr: 1 })
    h.view.watch()
    expect(h.send).toHaveBeenLastCalledWith({ t: 'browser.watch', window: '', maxWidth: 400, quality: 50 })

    // The canvas grew — a rotation, a split-screen change — so the viewer asks
    // the host to render at the new width. Idempotent on the host: same window.
    ;(h.canvas as unknown as { clientWidth: number }).clientWidth = 800
    h.view.onResize()
    expect(h.send).toHaveBeenLastCalledWith({ t: 'browser.watch', window: '', maxWidth: 800, quality: 50 })
  })

  it('does not re-watch when the width did not actually change', () => {
    const h = harness({ clientWidth: 400, dpr: 1 })
    h.view.watch()
    h.send.mockClear()
    h.view.onResize()
    expect(h.send).not.toHaveBeenCalled()
  })

  it('clamps the requested quality into the host range', () => {
    const h = harness()
    const loud = new WatchCanvas({ window: '', canvas: h.canvas, send: h.send, decode: h.decode, dpr: () => 1, quality: 999 })
    loud.watch()
    expect(h.send).toHaveBeenLastCalledWith(
      expect.objectContaining({ t: 'browser.watch', quality: MAX_WATCH_QUALITY }),
    )
  })
})

describe('driving from a pointer', () => {
  it('maps a mouse press to image pixels of the frame under it, and names that frame’s seq', async () => {
    const h = harness({ clientWidth: 400, clientHeight: 700 })
    await h.view.onFrame(frame({ seq: 7 }))
    h.send.mockClear()

    h.view['pointerDown'](pointer({ offsetX: 100, offsetY: 50, button: 0 }))
    const input = h.send.mock.calls.map((c) => c[0]).find((m) => m.t === 'browser.input')
    expect(input).toEqual({
      t: 'browser.input',
      window: '',
      seq: 7,
      mouse: { type: 'down', x: 200, y: 100, button: 'left', clicks: 1 },
    })
  })

  it('sends nothing until a frame exists to measure against', () => {
    const h = harness()
    h.view['pointerDown'](pointer({ offsetX: 100, offsetY: 50 }))
    expect(h.send).not.toHaveBeenCalled()
  })

  it('turns a touch that stays put into a click on the way up', async () => {
    const h = harness({ clientWidth: 400, clientHeight: 700 })
    await h.view.onFrame(frame({ seq: 3 }))
    h.send.mockClear()

    h.view['pointerDown'](pointer({ pointerId: 2, pointerType: 'touch', offsetX: 40, offsetY: 80 }))
    // A touch does not press on the way down — it waits to see if it is a scroll.
    expect(h.send).not.toHaveBeenCalled()

    h.view['pointerUp'](pointer({ pointerId: 2, pointerType: 'touch', offsetX: 41, offsetY: 81 }))
    const inputs = h.send.mock.calls.map((c) => c[0]).filter((m) => m.t === 'browser.input')
    expect(inputs.map((m) => (m.t === 'browser.input' ? m.mouse?.type : null))).toEqual(['down', 'up'])
    expect(inputs.every((m) => m.t === 'browser.input' && m.seq === 3)).toBe(true)
  })

  it('turns a touch that travels into a wheel — the page scrolls on the server, not the canvas', async () => {
    const h = harness({ clientWidth: 400, clientHeight: 700 })
    await h.view.onFrame(frame({ seq: 5 }))
    h.send.mockClear()

    h.view['pointerDown'](pointer({ pointerId: 3, pointerType: 'touch', offsetX: 200, offsetY: 500 }))
    h.view['pointerMove'](pointer({ pointerId: 3, pointerType: 'touch', offsetX: 200, offsetY: 400 }))
    const wheel = h.send.mock.calls.map((c) => c[0]).find((m) => m.t === 'browser.input')
    expect(wheel && wheel.t === 'browser.input' && wheel.mouse?.type).toBe('wheel')
    expect(wheel && wheel.t === 'browser.input' && wheel.seq).toBe(5)
  })

  it('turns a wheel into a wheel input against the current frame', async () => {
    const h = harness({ clientWidth: 400, clientHeight: 700 })
    await h.view.onFrame(frame({ seq: 6 }))
    h.send.mockClear()

    const wheelEvent = { offsetX: 100, offsetY: 100, deltaX: 0, deltaY: 120 } as WheelLike
    h.view['wheel'](wheelEvent)
    const input = h.send.mock.calls.map((c) => c[0]).find((m) => m.t === 'browser.input')
    expect(input && input.t === 'browser.input' && input.mouse?.type).toBe('wheel')
    expect(input && input.t === 'browser.input' && input.seq).toBe(6)
  })
})

describe('driving from a keyboard', () => {
  it('forwards a printable key with its text, and a named key with none', async () => {
    const h = harness()
    await h.view.onFrame(frame({ seq: 2 }))
    h.send.mockClear()

    const printable = {
      type: 'keydown',
      key: 'a',
      code: 'KeyA',
      altKey: false,
      ctrlKey: false,
      metaKey: false,
      shiftKey: false,
    } as KeyLike
    h.view.key(printable)
    const first = h.send.mock.calls.map((c) => c[0]).find((m) => m.t === 'browser.input')
    expect(first).toEqual({
      t: 'browser.input',
      window: '',
      seq: 2,
      key: { type: 'down', key: 'a', code: 'KeyA', text: 'a', mods: 0 },
    })

    h.send.mockClear()
    const enter = {
      type: 'keydown',
      key: 'Enter',
      code: 'Enter',
      altKey: false,
      ctrlKey: true,
      metaKey: false,
      shiftKey: false,
    } as KeyLike
    h.view.key(enter)
    const named = h.send.mock.calls.map((c) => c[0]).find((m) => m.t === 'browser.input')
    expect(named).toEqual({
      t: 'browser.input',
      window: '',
      seq: 2,
      // No text for a named key; Ctrl folded into the CDP modifier bitmask (2).
      key: { type: 'down', key: 'Enter', code: 'Enter', text: undefined, mods: 2 },
    })
  })

  it('refuses to type while a frame is curtained — the human baton holds', async () => {
    const h = harness()
    await h.view.onFrame(frame({ seq: 8, masked: true, data: '' }))
    h.send.mockClear()
    h.view.key({
      type: 'keydown',
      key: 'a',
      code: 'KeyA',
      altKey: false,
      ctrlKey: false,
      metaKey: false,
      shiftKey: false,
    } as KeyLike)
    expect(h.send).not.toHaveBeenCalled()
  })
})

describe('a paste', () => {
  it('is cleaned of control bytes and forwarded as insertText', async () => {
    const h = harness()
    await h.view.onFrame(frame({ seq: 1 }))
    h.send.mockClear()
    h.view.paste('hel\u0000lo\tthere')
    const input = h.send.mock.calls.map((c) => c[0]).find((m) => m.t === 'browser.input')
    // The NUL is gone; the tab, an ordinary byte in pasted text, survives.
    expect(input).toEqual({ t: 'browser.input', window: '', seq: 1, paste: 'hello\tthere' })
  })
})

describe('coalescing frames', () => {
  it('keeps only the newest frame that arrives while one is still painting', async () => {
    let resolveFirst: (bitmap: ImageBitmap) => void = () => {}
    const bmp = { width: 0, height: 0, close: vi.fn() } as unknown as ImageBitmap
    const decode = vi
      .fn()
      .mockImplementationOnce(() => new Promise<ImageBitmap>((resolve) => (resolveFirst = resolve)))
      .mockImplementation(() => Promise.resolve(bmp))
    const h = harness({ decode })

    const first = h.view.onFrame(frame({ seq: 1 }))
    // Two more arrive while the first is still decoding: only the last survives.
    void h.view.onFrame(frame({ seq: 2 }))
    void h.view.onFrame(frame({ seq: 3 }))
    resolveFirst(bmp)
    await first
    await Promise.resolve()
    await Promise.resolve()

    const acked = h.send.mock.calls
      .map((c) => c[0])
      .filter((m) => m.t === 'browser.frame.ack')
      .map((m) => (m.t === 'browser.frame.ack' ? m.seq : -1))
    // The first painted and acked; then the newest of the two that queued (3),
    // never the one it replaced (2).
    expect(acked).toEqual([1, 3])
  })
})
