/**
 * Watching — and driving — the machine's browser from a phone or a desktop tab.
 *
 * A `browser.frame` is a JPEG of a web page the machine is holding, and this is
 * the surface that turns it back into something a finger can act on: one
 * `<canvas>` per watched window, the frame drawn onto it, and every tap, drag,
 * swipe and keystroke translated into a `browser.input` aimed back at that page.
 *
 * ## Why the logic lives here rather than in `main.ts`
 *
 * `main.ts` cannot be rendered by the suite, so anything it decides is anything
 * nothing checks — the split `devices.ts`, `sessions.ts` and `chat-view.ts` all
 * make. What is here is the part with rules in it: the coordinate math a tap
 * depends on, the width a viewer negotiates, and the paint/ack loop that keeps
 * the stream flowing at the phone's real draw rate. `main.ts` owns the strip of
 * surfaces and the mounting of these canvases, because that is a shape, and a
 * shape is checked by looking at it.
 *
 * ## The four rules a viewer cannot get wrong silently
 *
 *  1. **Ack from the paint callback.** The host holds exactly one un-acked frame
 *     per watcher and forwards the next only when this side says "rendered", so
 *     the ack has to fire *after* the draw, not on receipt — otherwise the phone
 *     asks for frames faster than it can show them and the socket buffers toward
 *     the drop. Mirrors `uploads.ts`' ack-from-the-write-callback exactly.
 *  2. **The page lives on the server, so the canvas never scrolls itself.** A
 *     swipe is a `browser.input` wheel, not a local scroll of a bitmap — what
 *     the canvas shows is the server's viewport, and moving it is an act the
 *     server performs.
 *  3. **Coordinates are image pixels of a named frame.** A pointer is measured
 *     against the frame currently drawn and sent with *that* frame's `seq`, so a
 *     scroll landing mid-gesture cannot desync the mapping — the host re-derives
 *     the image→viewport transform from the frame it still holds under `seq`.
 *  4. **A masked frame is a curtain, never pixels.** When the host withholds a
 *     frame's data — a person taking the baton to type a password, or a secret
 *     field in view — `data` is empty and this side draws its own lock card. The
 *     pixels never crossed the wire; the curtain is only what says so.
 */

import {
  CAPABILITY,
  MAX_INPUT_BYTES,
  MAX_WATCH_QUALITY,
  MAX_WATCH_WIDTH,
  MAX_WATCH_WINDOWS,
  MIN_WATCH_QUALITY,
  MIN_WATCH_WIDTH,
  type BrowserFrameFrame,
  type BrowserInputFrame,
  type ClientMessage,
} from '../../src/main/remote/protocol'

/**
 * The soft ceiling on how many windows one connection watches at once — a bound
 * on the map, not a resource gate. Re-exported so the mounting side (`main.ts`)
 * shares the one number rather than spelling a second.
 */
export { MAX_WATCH_WINDOWS }

/**
 * The working quality, sent unless a caller asks for another.
 *
 * 50 is the point the contract measures a content page at ~15-50 KB of JPEG,
 * which base64s to well under {@link MAX_WATCH_QUALITY}'s ceiling and the frame
 * cap behind it. A viewer may ask for more; the host clamps what it will give.
 */
export const DEFAULT_WATCH_QUALITY = 50

/** The sentence under the lock card when the host sent no prompt of its own. */
export const DEFAULT_CURTAIN_PROMPT = 'The person is entering something private.'

/**
 * What a canvas says instead of sitting dead when it may not show its window.
 *
 * A guest is never sent frames — the host withholds `watch` at the source — so
 * the honest thing on screen is a sentence, not a black rectangle a person taps
 * at wondering whether it is loading.
 */
export const WATCH_UNAVAILABLE = 'This device may not watch this window.'

/**
 * How far a touch may drift and still be a tap rather than a scroll (CSS px).
 *
 * Below it, a finger that went down and came up without travelling is a click on
 * whatever is under it; above it, the same finger was dragging the page, which
 * is a scroll. The threshold is what lets one gesture be both without a mode the
 * person has to choose.
 */
export const TAP_SLOP_PX = 8

/**
 * Whether the host advertised the live view to this connection.
 *
 * The capability is withheld from a guest at the source — `capabilitiesFor` on
 * the host only ever puts it in a welcome for one of the owner's own devices —
 * so a client that sees it in `welcome.capabilities` is both able to watch and
 * entitled to. There is no second check to make here, the same reasoning
 * `devicesOffered` follows.
 */
export function watchOffered(capabilities: readonly string[]): boolean {
  return capabilities.includes(CAPABILITY.watch)
}

function clamp(value: number, low: number, high: number): number {
  if (!Number.isFinite(value)) return low
  return Math.min(high, Math.max(low, value))
}

/**
 * The width this viewer asks the host to render at, in device pixels.
 *
 * A CSS width of the canvas times the device pixel ratio is the number of real
 * pixels the screen will show, and asking for more is bytes nobody's display can
 * resolve while asking for fewer is a blurry page. Clamped, not refused, into
 * the host's range: the number comes from a viewer sizing its own canvas, so the
 * useful answer is the nearest width the host will actually stream.
 */
export function clampWatchWidth(cssWidth: number, dpr: number): number {
  const ratio = Number.isFinite(dpr) && dpr > 0 ? dpr : 1
  return clamp(Math.round(cssWidth * ratio), MIN_WATCH_WIDTH, MAX_WATCH_WIDTH)
}

/** The jpeg quality this viewer asks for, clamped into the host's range. */
export function clampWatchQuality(quality: number): number {
  return clamp(Math.round(quality), MIN_WATCH_QUALITY, MAX_WATCH_QUALITY)
}

/**
 * A pointer at canvas CSS coordinates, in image pixels of the frame it was drawn
 * against.
 *
 * The frame fills the canvas's CSS box in both axes — the host renders at the
 * width this viewer asked for and this side stretches whatever height came back
 * to fill — so the mapping is the box ratio on each axis independently:
 * `x = cx * (w / cssW)`, `y = cy * (h / cssH)`. That is the exact transform the
 * host inverts under this frame's `seq`, which is why the two must agree to the
 * pixel and why nothing here consults `scale` — the host owns image→viewport,
 * this side owns css→image, and the frame's own width is the only bridge.
 *
 * Clamped into the image so a drag that leaves the canvas under pointer capture
 * still names a pixel on the page rather than one beside it, and rounded because
 * a fractional pixel is not a place a click can land.
 */
export function imageCoords(
  frame: Pick<BrowserFrameFrame, 'w' | 'h'>,
  cssWidth: number,
  cssHeight: number,
  cx: number,
  cy: number,
): { x: number; y: number } {
  const sx = cssWidth > 0 ? frame.w / cssWidth : 0
  const sy = cssHeight > 0 ? frame.h / cssHeight : 0
  return {
    x: clamp(Math.round(cx * sx), 0, frame.w),
    y: clamp(Math.round(cy * sy), 0, frame.h),
  }
}

/**
 * The bytes the browser needs to become a bitmap, from the base64 the wire
 * carries.
 *
 * `atob` gives a binary string one char per byte; there is no shorter honest
 * path in a browser, and the frame validator has already proved this is base64
 * of a bounded length, so this runs on exactly the input it expects.
 */
function base64ToBytes(data: string): Uint8Array<ArrayBuffer> {
  const binary = atob(data)
  const bytes = new Uint8Array(new ArrayBuffer(binary.length))
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
  return bytes
}

/** The production decoder: base64 JPEG → a bitmap the canvas can blit. */
function decodeJpeg(data: string): Promise<ImageBitmap> {
  return createImageBitmap(new Blob([base64ToBytes(data)], { type: 'image/jpeg' }))
}

/**
 * Strip the control bytes a page's input field would choke on and bound the
 * result the way a paste is bounded on the wire.
 *
 * The host refuses an over-cap paste and refuses one into a secret field; this
 * is the cheap client-side pass that keeps an ordinary paste from being refused
 * for a reason a person cannot see — a rogue NUL from a clipboard, or a
 * megabyte that was never going to cross {@link MAX_INPUT_BYTES}.
 */
function cleanPaste(text: string): string {
  const encoder = new TextEncoder()
  let bytes = 0
  let out = ''
  for (const ch of text) {
    const code = ch.codePointAt(0) ?? 0
    // Drop the C0 controls and the DEL, which no text field wants and
    // `insertText` would not know what to do with — but keep tab (0x09) and
    // newline (0x0a), which are ordinary in pasted text.
    if ((code < 0x20 && code !== 0x09 && code !== 0x0a) || code === 0x7f) continue
    const size = encoder.encode(ch).byteLength
    // Cut on a code-point boundary, measured in bytes, so a multi-byte character
    // is never split at the cap and the host never refuses the paste for a
    // length a person cannot see.
    if (bytes + size > MAX_INPUT_BYTES) break
    bytes += size
    out += ch
  }
  return out
}

/** The CDP modifier bitmask CDP's key events read: Alt 1, Ctrl 2, Meta 4, Shift 8. */
function keyModifiers(event: {
  altKey: boolean
  ctrlKey: boolean
  metaKey: boolean
  shiftKey: boolean
}): number {
  return (
    (event.altKey ? 1 : 0) |
    (event.ctrlKey ? 2 : 0) |
    (event.metaKey ? 4 : 0) |
    (event.shiftKey ? 8 : 0)
  )
}

function mouseButton(button: number): 'left' | 'right' | 'middle' {
  if (button === 2) return 'right'
  if (button === 1) return 'middle'
  return 'left'
}

/** The subset of a pointer event this view reads — the whole of it in tests. */
export interface PointerLike {
  pointerId: number
  pointerType: string
  button: number
  offsetX: number
  offsetY: number
}

/** The subset of a wheel event this view reads. */
export interface WheelLike {
  offsetX: number
  offsetY: number
  deltaX: number
  deltaY: number
}

/** The subset of a keyboard event this view reads. */
export interface KeyLike {
  type: string
  key: string
  code: string
  altKey: boolean
  ctrlKey: boolean
  metaKey: boolean
  shiftKey: boolean
}

/** What a canvas needs from the host that mounts it. */
export interface WatchCanvasDeps {
  /** The surface this canvas shows: '' is the front/own tab, else a slot name. */
  window: string
  /** The `<canvas>` this draws onto and measures gestures against. */
  canvas: HTMLCanvasElement
  /** The wire, returning whether the frame left — the same `Connection.send`. */
  send: (message: ClientMessage) => boolean
  /** base64 JPEG → bitmap. Injected so the suite needs no real decoder. */
  decode?: (data: string) => Promise<ImageBitmap>
  /** The device pixel ratio, read live so a window moved between screens renews it. */
  dpr?: () => number
  /** The jpeg quality this viewer asks for; clamped host-side regardless. */
  quality?: number
}

/**
 * One watched window: a canvas, the paint/ack loop, and the gestures that drive
 * the page behind it.
 */
export class WatchCanvas {
  private readonly window: string
  private readonly canvas: HTMLCanvasElement
  private readonly ctx: CanvasRenderingContext2D | null
  private readonly send: (message: ClientMessage) => boolean
  private readonly decode: (data: string) => Promise<ImageBitmap>
  private readonly dpr: () => number
  private readonly quality: number

  /** The last frame actually drawn — what a gesture is measured against. */
  private lastFrame: BrowserFrameFrame | null = null
  /** The width last asked for, so a resize renegotiates only on a real change. */
  private requestedWidth = 0

  /** One paint at a time; a frame arriving mid-paint replaces the one waiting. */
  private painting = false
  private queued: BrowserFrameFrame | null = null

  /** The gesture in progress, if any. */
  private gesture: 'none' | 'pending' | 'drag' | 'scroll' = 'none'
  private touch = false
  private startX = 0
  private startY = 0
  private lastX = 0
  private lastY = 0

  private readonly onPointerDown = (event: Event): void => this.pointerDown(event as unknown as PointerLike)
  private readonly onPointerMove = (event: Event): void => this.pointerMove(event as unknown as PointerLike)
  private readonly onPointerUp = (event: Event): void => this.pointerUp(event as unknown as PointerLike)
  private readonly onWheel = (event: Event): void => {
    event.preventDefault()
    this.wheel(event as unknown as WheelLike)
  }
  private readonly onKey = (event: Event): void => {
    // The page is on the server, so the key belongs to it, not to the tab this
    // canvas sits in — otherwise Space scrolls the PWA and Tab leaves the canvas.
    event.preventDefault()
    this.key(event as unknown as KeyLike)
  }
  private readonly onPaste = (event: Event): void => {
    const clip = (event as ClipboardEvent).clipboardData
    const text = clip?.getData('text') ?? ''
    if (text !== '') {
      event.preventDefault()
      this.paste(text)
    }
  }

  constructor(deps: WatchCanvasDeps) {
    this.window = deps.window
    this.canvas = deps.canvas
    this.ctx = deps.canvas.getContext('2d')
    this.send = deps.send
    this.decode = deps.decode ?? decodeJpeg
    this.dpr = deps.dpr ?? (() => (typeof devicePixelRatio === 'number' ? devicePixelRatio : 1))
    this.quality = clampWatchQuality(deps.quality ?? DEFAULT_WATCH_QUALITY)
  }

  /** The surface name, for a host keying canvases by window. */
  get target(): string {
    return this.window
  }

  /** The canvas this draws onto, for a host that mounts it into a screen. */
  get element(): HTMLCanvasElement {
    return this.canvas
  }

  /**
   * Wire the pointer, wheel and keyboard listeners.
   *
   * Separate from the constructor so the suite can drive the handlers directly
   * without a DOM that can `addEventListener`. `main.ts` calls it once, after
   * mounting the canvas.
   */
  attach(): void {
    this.canvas.addEventListener('pointerdown', this.onPointerDown)
    this.canvas.addEventListener('pointermove', this.onPointerMove)
    this.canvas.addEventListener('pointerup', this.onPointerUp)
    this.canvas.addEventListener('pointercancel', this.onPointerUp)
    // `passive: false` so the swipe can be a driven scroll rather than the
    // browser scrolling the page the canvas sits in — the canvas never scrolls
    // its own content.
    this.canvas.addEventListener('wheel', this.onWheel, { passive: false })
    // A real keyboard, for a desktop viewer or a tablet with one attached. The
    // canvas has to be focusable (the host sets `tabIndex`) for these to fire.
    this.canvas.addEventListener('keydown', this.onKey)
    this.canvas.addEventListener('keyup', this.onKey)
    this.canvas.addEventListener('paste', this.onPaste)
  }

  /**
   * Start, or renegotiate, the cast of this window to this canvas.
   *
   * Sends `browser.watch` with the width this canvas can actually show. Sending
   * it again for a window already watched is how a resize renegotiates — the
   * frame is idempotent on the host, which reads it as "stream me this width
   * now".
   */
  watch(): boolean {
    const maxWidth = clampWatchWidth(this.canvas.clientWidth, this.dpr())
    this.requestedWidth = maxWidth
    return this.send({ t: 'browser.watch', window: this.window, maxWidth, quality: this.quality })
  }

  /** Stop the cast of this window. The mirror of {@link watch}. */
  unwatch(): boolean {
    return this.send({ t: 'browser.unwatch', window: this.window })
  }

  /**
   * The canvas changed size or the device rotated: re-fit and, if the width the
   * host should render at actually moved, renegotiate.
   *
   * A re-watch only when the width changed, because orientation with no width
   * change — or a resize that rounds to the same device width — is not worth a
   * frame, and a host reading a stream of identical watches would restart a
   * screencast for nothing.
   */
  onResize(): void {
    this.syncBackingStore()
    const maxWidth = clampWatchWidth(this.canvas.clientWidth, this.dpr())
    if (maxWidth !== this.requestedWidth) this.watch()
  }

  /**
   * A frame arrived: draw it (or its curtain) and, when the draw is done, ack.
   *
   * Coalesces rather than queues: a frame that arrives while another is still
   * decoding replaces the one waiting, so a phone that falls behind shows fewer,
   * current frames rather than a growing backlog of stale ones — the same
   * newest-wins the host applies to its own pending frame. In the common case
   * the host is waiting on this side's ack, so nothing is ever in flight when a
   * frame arrives and this is a clean 1:1 chain.
   */
  async onFrame(frame: BrowserFrameFrame): Promise<void> {
    if (frame.window !== this.window) return
    if (this.painting) {
      this.queued = frame
      return
    }
    this.painting = true
    try {
      await this.paint(frame)
    } finally {
      this.painting = false
      const next = this.queued
      this.queued = null
      if (next) void this.onFrame(next)
    }
  }

  private async paint(frame: BrowserFrameFrame): Promise<void> {
    const ctx = this.ctx
    if (ctx === null) return
    this.syncBackingStore()

    if (frame.masked) {
      // The pixels never crossed the wire; the curtain is only what says so.
      this.drawCurtain(ctx, frame.prompt ?? DEFAULT_CURTAIN_PROMPT)
      this.lastFrame = frame
      this.ack(frame.seq)
      return
    }

    let bitmap: ImageBitmap
    try {
      bitmap = await this.decode(frame.data)
    } catch {
      // A frame the browser could not turn into a bitmap is dropped — but still
      // acked, because the stream is one-in-flight and withholding the ack would
      // stall the whole cast on a single bad frame. The canvas keeps the last
      // good frame under the finger, and its `seq` is what the next gesture maps
      // against.
      this.ack(frame.seq)
      return
    }

    ctx.drawImage(bitmap, 0, 0, this.canvas.width, this.canvas.height)
    bitmap.close?.()
    this.lastFrame = frame
    this.ack(frame.seq)
  }

  /**
   * The lock card, drawn instead of a frame that was withheld.
   *
   * A flat dark card, a lock glyph and the host's sentence — no attempt to look
   * like the page underneath, because the point is that the page is not being
   * shown. Sized in device pixels off the backing store so it is crisp on a
   * retina phone.
   */
  private drawCurtain(ctx: CanvasRenderingContext2D, prompt: string): void {
    const w = this.canvas.width
    const h = this.canvas.height
    const dpr = this.dpr()
    ctx.fillStyle = '#101216'
    ctx.fillRect(0, 0, w, h)
    ctx.fillStyle = '#e6e8ec'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.font = `${Math.round(30 * dpr)}px system-ui, sans-serif`
    ctx.fillText('\u{1F512}', w / 2, h / 2 - 22 * dpr)
    ctx.font = `${Math.round(15 * dpr)}px system-ui, sans-serif`
    ctx.fillText(prompt, w / 2, h / 2 + 20 * dpr)
  }

  /**
   * The honest sentence for a window this device may not watch.
   *
   * Drawn rather than left black so a guest — or an owner looking at a surface
   * the host withheld — sees why nothing is coming rather than a dead rectangle.
   */
  drawUnavailable(text = WATCH_UNAVAILABLE): void {
    const ctx = this.ctx
    if (ctx === null) return
    this.syncBackingStore()
    const w = this.canvas.width
    const h = this.canvas.height
    const dpr = this.dpr()
    ctx.fillStyle = '#101216'
    ctx.fillRect(0, 0, w, h)
    ctx.fillStyle = '#9aa0aa'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.font = `${Math.round(15 * dpr)}px system-ui, sans-serif`
    ctx.fillText(text, w / 2, h / 2)
  }

  /**
   * Match the backing store to the CSS box in device pixels.
   *
   * A canvas whose `width`/`height` do not match its displayed size times the
   * pixel ratio paints blurry, so this keeps them in step — but only writes when
   * a dimension actually changed, because assigning `width` clears the canvas and
   * doing it every frame would flicker.
   */
  private syncBackingStore(): void {
    const dpr = this.dpr()
    const w = Math.max(1, Math.round(this.canvas.clientWidth * dpr))
    const h = Math.max(1, Math.round(this.canvas.clientHeight * dpr))
    if (this.canvas.width !== w) this.canvas.width = w
    if (this.canvas.height !== h) this.canvas.height = h
  }

  /** Rendered — tell the host to send the next frame of this window. */
  private ack(seq: number): void {
    this.send({ t: 'browser.frame.ack', window: this.window, seq })
  }

  private drive(input: Omit<BrowserInputFrame, 't' | 'window' | 'seq'>, seq: number): void {
    this.send({ t: 'browser.input', window: this.window, seq, ...input })
  }

  /** The image coordinates and the frame `seq` a gesture at (offsetX, offsetY) names. */
  private locate(event: { offsetX: number; offsetY: number }): { seq: number; x: number; y: number } | null {
    const frame = this.lastFrame
    if (frame === null || frame.masked) return null
    const { x, y } = imageCoords(frame, this.canvas.clientWidth, this.canvas.clientHeight, event.offsetX, event.offsetY)
    return { seq: frame.seq, x, y }
  }

  private pointerDown(event: PointerLike): void {
    const at = this.locate(event)
    if (at === null) return
    // Take focus so a keyboard drives this window rather than the tab around it.
    this.canvas.focus?.()
    this.canvas.setPointerCapture?.(event.pointerId)
    this.touch = event.pointerType === 'touch'
    this.startX = event.offsetX
    this.startY = event.offsetY
    this.lastX = event.offsetX
    this.lastY = event.offsetY
    if (this.touch) {
      // A touch has not decided yet whether it is a tap or a scroll — that is
      // settled by whether it travels. So nothing is sent on the way down; the
      // click, if it stays put, is synthesised on the way up.
      this.gesture = 'pending'
      return
    }
    // A mouse or pen presses immediately, which is what makes an element drag or
    // a text selection work — the always-works path is a real button-down.
    this.gesture = 'drag'
    this.drive({ mouse: { type: 'down', x: at.x, y: at.y, button: mouseButton(event.button), clicks: 1 } }, at.seq)
  }

  private pointerMove(event: PointerLike): void {
    if (this.gesture === 'none') return
    const at = this.locate(event)
    if (at === null) return

    if (this.touch) {
      if (
        this.gesture === 'pending' &&
        Math.hypot(event.offsetX - this.startX, event.offsetY - this.startY) < TAP_SLOP_PX
      ) {
        // Still within tap distance — keep waiting to see if it is a click.
        return
      }
      // It has travelled: this is a scroll of the page on the server, sent as a
      // wheel. The finger delta becomes the wheel delta in image pixels; the
      // host negates it, so dragging the page up scrolls its content up.
      this.gesture = 'scroll'
      const frame = this.lastFrame
      if (frame !== null) {
        const dx = (event.offsetX - this.lastX) * (frame.w / Math.max(1, this.canvas.clientWidth))
        const dy = (event.offsetY - this.lastY) * (frame.h / Math.max(1, this.canvas.clientHeight))
        this.drive({ mouse: { type: 'wheel', x: at.x, y: at.y, dx: Math.round(dx), dy: Math.round(dy) } }, at.seq)
      }
      this.lastX = event.offsetX
      this.lastY = event.offsetY
      return
    }

    // A mouse/pen drag is a real move with the button held.
    this.drive({ mouse: { type: 'move', x: at.x, y: at.y } }, at.seq)
    this.lastX = event.offsetX
    this.lastY = event.offsetY
  }

  private pointerUp(event: PointerLike): void {
    const gesture = this.gesture
    this.gesture = 'none'
    this.canvas.releasePointerCapture?.(event.pointerId)
    if (gesture === 'none') return
    const at = this.locate(event)
    if (at === null) return

    if (gesture === 'pending') {
      // A touch that never travelled: a tap, synthesised as a click so a page
      // that has no touch handlers still responds — the always-works path.
      this.drive({ mouse: { type: 'down', x: at.x, y: at.y, button: 'left', clicks: 1 } }, at.seq)
      this.drive({ mouse: { type: 'up', x: at.x, y: at.y, button: 'left' } }, at.seq)
      return
    }
    if (gesture === 'drag') {
      this.drive({ mouse: { type: 'up', x: at.x, y: at.y, button: mouseButton(event.button) } }, at.seq)
    }
    // A scroll needs no release — the wheels it sent were the whole of it.
  }

  private wheel(event: WheelLike): void {
    const at = this.locate(event)
    if (at === null) return
    // A wheel already points the way the user wants to scroll, which is the
    // opposite of a finger drag, so it is negated here to reach the host in the
    // same convention a touch scroll does — the host negates once for both.
    this.drive(
      { mouse: { type: 'wheel', x: at.x, y: at.y, dx: -Math.round(event.deltaX), dy: -Math.round(event.deltaY) } },
      at.seq,
    )
  }

  /** A keystroke, forwarded to the page. Desktop viewers with a real keyboard. */
  key(event: KeyLike): void {
    const frame = this.lastFrame
    if (frame === null || frame.masked) return
    const type = event.type === 'keyup' ? 'up' : 'down'
    // A single-character key carries its text so the page receives the character;
    // a named key (Enter, ArrowLeft) carries none, and the host turns the key and
    // code into the event a page listens for.
    const text = event.key.length === 1 ? event.key : undefined
    this.drive({ key: { type, key: event.key, code: event.code, text, mods: keyModifiers(event) } }, frame.seq)
  }

  /** A paste, forwarded as `insertText`, cleaned and bounded the way the wire is. */
  paste(text: string): void {
    const frame = this.lastFrame
    if (frame === null || frame.masked) return
    const cleaned = cleanPaste(text)
    if (cleaned === '') return
    this.drive({ paste: cleaned }, frame.seq)
  }

  /** Stop the cast and drop the listeners. */
  dispose(): void {
    this.canvas.removeEventListener('pointerdown', this.onPointerDown)
    this.canvas.removeEventListener('pointermove', this.onPointerMove)
    this.canvas.removeEventListener('pointerup', this.onPointerUp)
    this.canvas.removeEventListener('pointercancel', this.onPointerUp)
    this.canvas.removeEventListener('wheel', this.onWheel)
    this.canvas.removeEventListener('keydown', this.onKey)
    this.canvas.removeEventListener('keyup', this.onKey)
    this.canvas.removeEventListener('paste', this.onPaste)
    this.queued = null
    this.lastFrame = null
  }
}
