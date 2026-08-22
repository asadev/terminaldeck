import {
  MAX_FRAME_DATA_CHARS,
  MIN_WATCH_QUALITY,
  type BrowserFrameFrame,
  type BrowserInputFrame,
} from './remote/protocol'

/**
 * One page's live view, cast to whoever is watching it — the host half of
 * wave-3's watch-and-drive.
 *
 * ## What this is, and what it is deliberately not
 *
 * A {@link PageCast} owns exactly one CDP screencast of one page and fans its
 * frames out to the connections watching it. It never touches Electron, never
 * decodes an image, and never writes a byte to disk — a frame is a base64 string
 * that is forwarded to a watcher or dropped, and nothing else. The seam it drives
 * ({@link CastSeam}) is the driver's own screened `send` and the page's event
 * stream, so every command it issues — `Page.startScreencast`, the frame ack, the
 * input dispatch — passes through `browser-cdp.ts` and is refused the instant the
 * person takes the page (`state === 'human'`), exactly like every other command
 * the driver sends. A test drives a fake seam and a scripted `Page.screencastFrame`
 * event; there is no real Chromium and no debugger anywhere near it.
 *
 * ## The three guarantees, source-side
 *
 *  1. **Backpressure is one un-acked frame per watcher.** The host forwards a
 *     frame to a watcher only after that watcher's `browser.frame.ack`, and it
 *     acks CDP (`Page.screencastFrameAck`) only when it forwards — so the phone's
 *     real draw rate throttles the screencast itself and nothing grows toward the
 *     8 MB socket buffer. A CDP frame that arrives while a watcher is still
 *     un-acked *replaces* that watcher's pending frame: a slow phone sees fewer,
 *     current frames, never a queue.
 *  2. **A secret never crosses.** Two brakes stack, both here at the source. A
 *     handover (the person taking the baton to type a password) stops the cast
 *     before the baton flips and curtains every watcher of that page. A secret
 *     field merely *visible* — an autofilled dots box, a "show password" toggle,
 *     an OTP on screen — is caught by cheap arithmetic over the frame's own
 *     scroll metadata against the cached secret rectangles, and that frame's data
 *     is withheld: `masked: true`, empty `data`, the viewer draws its own lock
 *     card. The pixels never enter a wire buffer, because there is no JPEG
 *     encoder in this repo to paint them out with and withholding is the only
 *     absolutely-safe answer.
 *  3. **Watching never widens driving.** Input is refused whenever the frame the
 *     watcher would be acting on is masked — you cannot drive what you cannot
 *     see — and the coordinate mapping is re-derived from the host's own record
 *     of the frame the viewer named by `seq`, never from a scale the viewer
 *     computed, so a scroll landing mid-gesture cannot desync it.
 */

/** The little of the driver a cast needs — the screened send and the event stream. */
export interface CastSeam {
  /**
   * Send one command to the page, screened by the driver first.
   *
   * This is the driver's own `send`, so `browser-cdp.ts` has already refused it
   * if the person holds the page. A cast never reaches a raw transport.
   */
  send(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>>
  /** Subscribe to the page's CDP events; the returned function unsubscribes. */
  onEvent(handler: (method: string, params: Record<string, unknown>) => void): () => void
  /**
   * Run the secret-rects scan in the page's isolated world, or null when the
   * page cannot be asked. The rectangles are the page's own
   * `getBoundingClientRect` values — viewport-relative CSS pixels — and the
   * viewport is what they are measured in.
   */
  scanSecrets(): Promise<SecretScan | null>
  /** Does the person hold this page right now (a handover in progress)? */
  isHuman(): boolean
  /** Epoch ms, injected so a test can freeze it. */
  now(): number
}

/** The secret-rects scan, exactly as `SECRET_RECTS_SCRIPT` returns it. */
export interface SecretScan {
  rects: Array<{ x: number; y: number; width: number; height: number }>
  viewport: { width: number; height: number }
}

/** What a viewer asks for when it watches, already clamped by `protocol.ts`. */
export interface CastOptions {
  maxWidth: number
  quality: number
  everyNth?: number
}

/** A frame as it leaves the host, minus the `t` the serializer adds back. */
export type CastFrame = Omit<BrowserFrameFrame, 't'>

/** How a page's frame is emitted to one watcher. */
type EmitFrame = (frame: CastFrame) => void

/** The geometry a watcher needs to remember so it can map a later gesture. */
interface FrameGeometry {
  seq: number
  w: number
  dw: number
  dh: number
  scale: number
  pageScale: number
}

/** How many past frames' geometry a watcher keeps, to map a gesture by its `seq`. */
const GEOMETRY_HISTORY = 8

/** How far quality steps down when a frame overruns the cap. */
const QUALITY_STEP = 10

/** The sentence under a watcher's lock card while a secret field is on screen. */
const SECRET_PROMPT = 'The person is entering something private.'

/** The raw shape of a `Page.screencastFrame` event's metadata. */
interface ScreencastMetadata {
  offsetTop: number
  pageScaleFactor: number
  deviceWidth: number
  deviceHeight: number
  scrollOffsetX: number
  scrollOffsetY: number
}

/** One connection watching this page. */
class Watcher {
  seq = 0
  inFlight = false
  /** The seq of the frame currently un-acked, so a stale ack can be ignored. */
  flightSeq = 0
  pending: CastFrame | null = null
  readonly geometry: FrameGeometry[] = []
  constructor(
    readonly id: string,
    readonly window: string,
    readonly emit: EmitFrame,
  ) {}
}

/** The parsed base64 dimensions of a JPEG, read from its SOF marker. */
function jpegSize(data: string): { width: number; height: number } | null {
  let bytes: Buffer
  try {
    bytes = Buffer.from(data, 'base64')
  } catch {
    return null
  }
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null
  let offset = 2
  while (offset + 1 < bytes.length) {
    if (bytes[offset] !== 0xff) {
      offset += 1
      continue
    }
    let marker = bytes[offset + 1]
    // Skip any run of 0xFF fill bytes before the marker.
    let cursor = offset + 1
    while (cursor < bytes.length && bytes[cursor] === 0xff) cursor += 1
    if (cursor >= bytes.length) return null
    marker = bytes[cursor]
    // Standalone markers (no length): padding, restart markers, SOI/EOI.
    if (marker === 0xd8 || marker === 0xd9 || (marker >= 0xd0 && marker <= 0xd7)) {
      offset = cursor + 1
      continue
    }
    if (cursor + 3 >= bytes.length) return null
    const length = bytes.readUInt16BE(cursor + 1)
    // The SOF markers that carry frame dimensions — every SOFn except the
    // DHT (C4), DAC (CC) and RSTn tables, which are not start-of-frame.
    const isSof =
      (marker >= 0xc0 && marker <= 0xc3) ||
      (marker >= 0xc5 && marker <= 0xc7) ||
      (marker >= 0xc9 && marker <= 0xcb) ||
      (marker >= 0xcd && marker <= 0xcf)
    if (isSof) {
      if (cursor + 7 >= bytes.length) return null
      const height = bytes.readUInt16BE(cursor + 4)
      const width = bytes.readUInt16BE(cursor + 6)
      if (width <= 0 || height <= 0) return null
      return { width, height }
    }
    offset = cursor + 1 + length
  }
  return null
}

export class PageCast {
  private readonly watchers = new Map<string, Watcher>()
  private options: CastOptions | null = null
  private unsubscribe: (() => void) | null = null
  private started = false
  /** The most recent CDP frame not yet forwarded to a free watcher, or null. */
  private pending: { frame: CastFrame; sessionId: number } | null = null
  /** The last CDP session id seen, so a frame can be acked. */
  private lastSessionId: number | null = null
  /** The scroll of the most recent frame, the reference a secret scan is pinned to. */
  private lastScrollX = 0
  private lastScrollY = 0
  /** Secret rectangles in DOCUMENT coordinates, or null when none is known yet. */
  private secretDocRects: Array<{ x: number; y: number; width: number; height: number }> | null = null
  /** The person has the page: the whole cast is curtained. */
  private curtained = false
  private curtainPrompt = ''
  private disposed = false

  constructor(private readonly seam: CastSeam) {}

  /** How many connections are watching this page right now. */
  get watcherCount(): number {
    return this.watchers.size
  }

  /**
   * Add (or renegotiate) a watcher and make sure the screencast is running.
   *
   * Idempotent per watcher id: a second call with the same id is a renegotiation
   * — a viewer that resized its canvas — and it replaces that watcher's window
   * and emit without minting a second subscription. The newest options win, the
   * same way the newest scroll wins on a page two people are watching.
   */
  async watch(watcherId: string, window: string, options: CastOptions, emit: EmitFrame): Promise<void> {
    if (this.disposed) return
    const existing = this.watchers.get(watcherId)
    if (existing) {
      // A renegotiation carries a fresh emit closure (the server rebuilds it per
      // call so the grant is re-read), so replace the watcher rather than mutate.
      const fresh = new Watcher(watcherId, window, emit)
      fresh.seq = existing.seq
      this.watchers.set(watcherId, fresh)
    } else {
      this.watchers.set(watcherId, new Watcher(watcherId, window, emit))
    }
    this.options = options
    await this.ensureStarted(options)
  }

  /** Drop one watcher; stop the screencast when the last one leaves. */
  async unwatch(watcherId: string): Promise<void> {
    if (!this.watchers.delete(watcherId)) return
    if (this.watchers.size === 0) await this.stop()
  }

  /** Drop every watcher and stop — a page going away, or the cast being torn down. */
  async dispose(): Promise<void> {
    this.disposed = true
    this.watchers.clear()
    await this.stop()
  }

  private async ensureStarted(options: CastOptions): Promise<void> {
    if (!this.unsubscribe) {
      this.unsubscribe = this.seam.onEvent((method, params) => this.onEvent(method, params))
    }
    // A renegotiation re-issues startScreencast with the new width/quality; CDP
    // treats a second start as a reconfigure of the running cast.
    await this.startScreencast(options)
    // Learn where the secret fields are before the first frame is forwarded, so
    // a login page open at the moment a watch begins is curtained, not leaked.
    void this.refreshSecrets()
  }

  private async startScreencast(options: CastOptions): Promise<void> {
    if (this.curtained) return
    const params: Record<string, unknown> = {
      format: 'jpeg',
      quality: options.quality,
      maxWidth: options.maxWidth,
    }
    if (options.everyNth !== undefined) params.everyNthFrame = options.everyNth
    try {
      await this.seam.send('Page.startScreencast', params)
      this.started = true
    } catch {
      // Refused (the person may have just taken the page) or the page is gone.
      // Either way there is nothing to stream; the next state change re-tries.
      this.started = false
    }
  }

  private async stop(): Promise<void> {
    if (this.unsubscribe) {
      this.unsubscribe()
      this.unsubscribe = null
    }
    this.pending = null
    if (this.started) {
      this.started = false
      await this.seam.send('Page.stopScreencast', {}).catch(() => undefined)
    }
  }

  /**
   * Curtain the cast because the person is about to take the page.
   *
   * Called by the driver **before** the baton flips to `human`, while the
   * screened send still permits a command — the same "before the baton moves,
   * never after" ordering the network suspend uses. It stops the screencast at
   * the source, marks every future frame masked, and draws one lock card on each
   * watcher now so the curtain does not wait for a frame that will never come.
   */
  async curtain(prompt: string): Promise<void> {
    this.curtained = true
    this.curtainPrompt = prompt
    this.pending = null
    if (this.started) {
      this.started = false
      await this.seam.send('Page.stopScreencast', {}).catch(() => undefined)
    }
    for (const watcher of this.watchers.values()) this.drawCurtain(watcher)
  }

  /** The person handed the page back: restart the screencast and re-scan secrets. */
  async uncurtain(): Promise<void> {
    if (!this.curtained) return
    this.curtained = false
    this.curtainPrompt = ''
    this.secretDocRects = null
    if (this.options && this.watchers.size > 0) {
      await this.startScreencast(this.options)
      void this.refreshSecrets()
    }
  }

  /** A watcher rendered a frame: it may have the next one. */
  ack(watcherId: string, seq: number): void {
    const watcher = this.watchers.get(watcherId)
    if (!watcher || !watcher.inFlight) return
    // Only the frame it is holding clears the flight; an ack for a frame it has
    // already superseded — a duplicate, or one that crossed a newer send — is
    // ignored rather than mistaken for the current one being rendered.
    if (seq !== watcher.flightSeq) return
    watcher.inFlight = false
    if (watcher.pending) {
      const next = watcher.pending
      watcher.pending = null
      this.forward(watcher, next)
    }
    // With that watcher free, the held CDP frame may move and CDP may be acked.
    this.pump()
  }

  /**
   * Forward an input event to the page, mapped from image pixels to CSS
   * viewport coordinates using the host's own record of the frame the viewer
   * named by `seq`.
   *
   * Refused when the watcher is not one this cast knows, when the frame it is
   * acting on is masked (a curtain, or a secret on screen — you cannot drive
   * what you cannot see), or when the page could not be measured. The dispatch
   * itself rides the driver's screened send, so the baton refuses it during a
   * handover as it refuses every other command.
   */
  async input(watcherId: string, frame: BrowserInputFrame): Promise<{ ok: boolean; reason?: string }> {
    const watcher = this.watchers.get(watcherId)
    if (!watcher) return { ok: false, reason: 'that window is not being watched on this connection' }
    if (this.curtained || this.seam.isHuman()) {
      return { ok: false, reason: 'the person has this page right now' }
    }
    // The frame the coordinates were measured against, by its seq — never the
    // viewer's own idea of the scale.
    const geom = watcher.geometry.find((g) => g.seq === frame.seq) ?? watcher.geometry[watcher.geometry.length - 1]
    if (frame.mouse) return this.dispatchMouse(geom, frame.mouse)
    if (frame.touch) return this.dispatchTouch(geom, frame.touch)
    if (frame.key) return this.dispatchKey(frame.key)
    if (frame.paste !== undefined) return this.dispatchPaste(frame.paste)
    return { ok: false, reason: 'an input names no mouse, key, touch or paste' }
  }

  /* --------------------------------------------------------------- events -- */

  private onEvent(method: string, params: Record<string, unknown>): void {
    if (method === 'Page.screencastFrame') {
      this.onScreencastFrame(params)
      return
    }
    // A settle or a navigation may have changed where the secret fields are.
    if (
      method === 'Page.loadEventFired' ||
      method === 'Page.frameStoppedLoading' ||
      method === 'Page.frameNavigated'
    ) {
      void this.refreshSecrets()
    }
  }

  private onScreencastFrame(params: Record<string, unknown>): void {
    const data = typeof params.data === 'string' ? params.data : ''
    const sessionId = typeof params.sessionId === 'number' ? params.sessionId : this.lastSessionId ?? 0
    this.lastSessionId = sessionId
    const meta = this.readMetadata(params.metadata)
    if (!meta) {
      // A frame we cannot place — ack it so CDP keeps producing, and drop it.
      this.ackCdp(sessionId)
      return
    }
    this.lastScrollX = meta.scrollOffsetX
    this.lastScrollY = meta.scrollOffsetY

    // A frame over the per-field cap never goes on the wire; drop it, step the
    // quality down a notch so the next one fits, and ack CDP to keep it flowing.
    if (data.length > MAX_FRAME_DATA_CHARS) {
      this.ackCdp(sessionId)
      void this.stepQualityDown()
      return
    }

    const size = jpegSize(data)
    const w = size?.width ?? Math.round(meta.deviceWidth)
    const h = size?.height ?? Math.round(meta.deviceHeight)
    const dw = meta.deviceWidth || w
    const dh = meta.deviceHeight || h
    const scale = dw > 0 ? w / dw : 1
    const base: CastFrame = {
      window: '',
      seq: 0,
      w,
      h,
      dw,
      dh,
      scale,
      offsetTop: meta.offsetTop,
      pageScale: meta.pageScaleFactor || 1,
      scrollX: meta.scrollOffsetX,
      scrollY: meta.scrollOffsetY,
      data,
    }
    this.pending = { frame: base, sessionId }
    this.pump()
  }

  /**
   * Move the held CDP frame to whichever watchers are free, then ack CDP.
   *
   * The whole of the backpressure: CDP is acked only when a frame is forwarded,
   * so its production rate follows the fastest watcher's draw rate and the held
   * frame is the newest one — a watcher that frees late gets current pixels, not
   * a queue.
   */
  private pump(): void {
    if (!this.pending) return
    const free: Watcher[] = []
    for (const watcher of this.watchers.values()) {
      if (!watcher.inFlight) free.push(watcher)
    }
    if (free.length === 0) return
    const { frame, sessionId } = this.pending
    this.pending = null
    for (const watcher of free) this.forward(watcher, frame)
    this.ackCdp(sessionId)
  }

  private forward(watcher: Watcher, frame: CastFrame): void {
    if (watcher.inFlight) {
      // Already holding a frame — the newest replaces its pending one.
      watcher.pending = frame
      return
    }
    const seq = (watcher.seq += 1)
    const masked = this.maskFor(frame)
    const out: CastFrame = masked
      ? {
          ...frame,
          seq,
          window: watcher.window,
          data: '',
          masked: true,
          ...(masked.prompt ? { prompt: masked.prompt } : {}),
        }
      : { ...frame, seq, window: watcher.window }
    // Remember this frame's geometry so a gesture naming its seq maps by the
    // scale the host actually sent, never one the viewer computed.
    watcher.geometry.push({ seq, w: frame.w, dw: frame.dw, dh: frame.dh, scale: frame.scale, pageScale: frame.pageScale })
    if (watcher.geometry.length > GEOMETRY_HISTORY) watcher.geometry.shift()
    watcher.inFlight = true
    watcher.flightSeq = seq
    watcher.emit(out)
  }

  /** Draw a lock card on one watcher without a frame under it. */
  private drawCurtain(watcher: Watcher): void {
    watcher.seq += 1
    watcher.inFlight = true
    watcher.flightSeq = watcher.seq
    watcher.emit({
      window: watcher.window,
      seq: watcher.seq,
      w: 0,
      h: 0,
      dw: 0,
      dh: 0,
      scale: 1,
      offsetTop: 0,
      pageScale: 1,
      scrollX: 0,
      scrollY: 0,
      masked: true,
      prompt: this.curtainPrompt || SECRET_PROMPT,
      data: '',
    })
  }

  /**
   * Should this frame be masked, and under what sentence?
   *
   * Returns null when the frame may cross with its pixels, or an object naming
   * the curtain sentence when it may not. The handover curtain wins first; a
   * secret field visible in the frame's own viewport wins second.
   */
  private maskFor(frame: CastFrame): { prompt?: string } | null {
    if (this.curtained || this.seam.isHuman()) return { prompt: this.curtainPrompt || SECRET_PROMPT }
    if (this.secretVisible(frame)) return { prompt: SECRET_PROMPT }
    return null
  }

  /**
   * Does any known secret rectangle fall inside this frame's viewport?
   *
   * Cheap arithmetic over the frame's own scroll metadata — no image decode. The
   * cached rectangles are in document coordinates (the scan's viewport-relative
   * values plus the scroll they were read at), so a rectangle is in view when it
   * overlaps the window `[scrollY, scrollY + dh)` the frame reports. Headless
   * Chromium runs at pageScaleFactor 1 with no visual-viewport offset, so scroll
   * offsets (CSS px) and `getBoundingClientRect` (CSS px) share one space; a
   * scaled visual viewport is recorded as a later refinement.
   */
  private secretVisible(frame: CastFrame): boolean {
    const rects = this.secretDocRects
    if (!rects || rects.length === 0) return false
    const top = frame.scrollY
    const bottom = frame.scrollY + frame.dh
    const left = frame.scrollX
    const right = frame.scrollX + frame.dw
    for (const rect of rects) {
      if (rect.width <= 0 || rect.height <= 0) continue
      const rTop = rect.y
      const rBottom = rect.y + rect.height
      const rLeft = rect.x
      const rRight = rect.x + rect.width
      if (rBottom > top && rTop < bottom && rRight > left && rLeft < right) return true
    }
    return false
  }

  /**
   * Re-read where the page's secret fields are, and pin them to document
   * coordinates using the scroll of the most recent frame.
   *
   * Exposed so a test can drive it directly; called on every settle, navigation
   * and watch. A failed scan leaves the previous rectangles in place rather than
   * clearing them — forgetting a password field is the direction that ends with
   * one on screen.
   */
  async refreshSecrets(): Promise<void> {
    const scan = await this.seam.scanSecrets().catch(() => null)
    if (!scan) return
    const scrollX = this.lastScrollX
    const scrollY = this.lastScrollY
    this.secretDocRects = scan.rects.map((rect) => ({
      x: rect.x + scrollX,
      y: rect.y + scrollY,
      width: rect.width,
      height: rect.height,
    }))
  }

  private async stepQualityDown(): Promise<void> {
    if (!this.options) return
    const next = Math.max(MIN_WATCH_QUALITY, this.options.quality - QUALITY_STEP)
    if (next === this.options.quality) return
    this.options = { ...this.options, quality: next }
    if (!this.curtained && this.watchers.size > 0) await this.startScreencast(this.options)
  }

  private ackCdp(sessionId: number): void {
    void this.seam.send('Page.screencastFrameAck', { sessionId }).catch(() => undefined)
  }

  private readMetadata(value: unknown): ScreencastMetadata | null {
    if (typeof value !== 'object' || value === null) return null
    const meta = value as Record<string, unknown>
    const num = (key: string): number => (typeof meta[key] === 'number' ? (meta[key] as number) : 0)
    const deviceWidth = num('deviceWidth')
    const deviceHeight = num('deviceHeight')
    if (deviceWidth <= 0 || deviceHeight <= 0) return null
    return {
      offsetTop: num('offsetTop'),
      pageScaleFactor: num('pageScaleFactor'),
      deviceWidth,
      deviceHeight,
      scrollOffsetX: num('scrollOffsetX'),
      scrollOffsetY: num('scrollOffsetY'),
    }
  }

  /* ------------------------------------------------------- input dispatch -- */

  private mapPoint(geom: FrameGeometry | undefined, x: number, y: number): { x: number; y: number } {
    // Image pixels → CSS viewport pixels: divide by the frame's own scale. The
    // page-scale divide is a no-op at headless's factor of 1 and is kept for the
    // day a scaled visual viewport is streamed. Offsets add nothing: CDP mouse
    // coordinates are viewport (clientX-style), not document, so scroll is not
    // added back here.
    const scale = geom && geom.scale > 0 ? geom.scale : 1
    const pageScale = geom && geom.pageScale > 0 ? geom.pageScale : 1
    return { x: (x / scale) / pageScale, y: (y / scale) / pageScale }
  }

  private async dispatchMouse(
    geom: FrameGeometry | undefined,
    mouse: NonNullable<BrowserInputFrame['mouse']>,
  ): Promise<{ ok: boolean; reason?: string }> {
    if (!Number.isFinite(mouse.x) || !Number.isFinite(mouse.y)) {
      return { ok: false, reason: 'an input coordinate must be a real number' }
    }
    const { x, y } = this.mapPoint(geom, mouse.x, mouse.y)
    if (mouse.type === 'wheel') {
      await this.seam.send('Input.dispatchMouseEvent', {
        type: 'mouseWheel',
        x,
        y,
        deltaX: -(mouse.dx ?? 0),
        deltaY: -(mouse.dy ?? 0),
      })
      return { ok: true }
    }
    const type = mouse.type === 'down' ? 'mousePressed' : mouse.type === 'up' ? 'mouseReleased' : 'mouseMoved'
    const params: Record<string, unknown> = { type, x, y }
    if (mouse.type !== 'move') {
      params.button = mouse.button ?? 'left'
      params.clickCount = mouse.clicks ?? 1
    } else if (mouse.button && mouse.button !== 'none') {
      params.button = mouse.button
    }
    await this.seam.send('Input.dispatchMouseEvent', params)
    return { ok: true }
  }

  private async dispatchTouch(
    geom: FrameGeometry | undefined,
    touch: NonNullable<BrowserInputFrame['touch']>,
  ): Promise<{ ok: boolean; reason?: string }> {
    const type =
      touch.type === 'start'
        ? 'touchStart'
        : touch.type === 'move'
          ? 'touchMove'
          : touch.type === 'end'
            ? 'touchEnd'
            : 'touchCancel'
    const touchPoints = touch.points.map((point) => {
      const { x, y } = this.mapPoint(geom, point.x, point.y)
      return { x, y }
    })
    if (touchPoints.some((point) => !Number.isFinite(point.x) || !Number.isFinite(point.y))) {
      return { ok: false, reason: 'a touch coordinate must be a real number' }
    }
    await this.seam.send('Input.dispatchTouchEvent', { type, touchPoints })
    return { ok: true }
  }

  private async dispatchKey(
    key: NonNullable<BrowserInputFrame['key']>,
  ): Promise<{ ok: boolean; reason?: string }> {
    const type = key.type === 'down' ? 'rawKeyDown' : key.type === 'up' ? 'keyUp' : 'char'
    const params: Record<string, unknown> = { type }
    if (key.key !== undefined) params.key = key.key
    if (key.code !== undefined) params.code = key.code
    if (key.text !== undefined) params.text = key.text
    if (key.mods !== undefined) params.modifiers = key.mods
    await this.seam.send('Input.dispatchKeyEvent', params)
    return { ok: true }
  }

  private async dispatchPaste(text: string): Promise<{ ok: boolean; reason?: string }> {
    await this.seam.send('Input.insertText', { text })
    return { ok: true }
  }
}
