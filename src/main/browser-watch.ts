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
 * There is a **second** screened seam beside that one, and it is the inverse of
 * it rather than a way around it: {@link CastSeam.sendAsPerson}, screened by
 * `screenPersonCommand`, which refuses everything *unless* `state === 'human'`
 * and permits only the four `Input.*` dispatches and the three screencast
 * commands. It carries exactly two things — the taps of the one watcher holding a
 * handover ({@link PageCast.take}), and this cast's own view commands while that
 * watcher holds it. The agent's refusal is untouched by its existence; see
 * `browser-cdp.ts` for why a flag on the first door would have been the wrong
 * shape.
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
 *     before the baton flips and curtains every watcher of that page — every
 *     watcher **except the one who said the person is me**, which is the taker
 *     and is the whole of {@link PageCast.take}. A secret
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
  /**
   * Send one command **as the person holding the page**, screened by the other
   * door.
   *
   * The sibling of {@link send} and the inverse of it: `send` is screened by
   * `screenCommand`, which refuses everything while `state === 'human'`;
   * this is screened by `screenPersonCommand`, which refuses everything *unless*
   * `state === 'human'` and permits only the four `Input.*` dispatches and the
   * three screencast commands. Neither is a flag on the other — see
   * `browser-cdp.ts` for why a bypass flag would have turned the baton refusal
   * from a mechanism back into a policy.
   *
   * Used for exactly two things: the taps and keystrokes of the one watcher
   * holding a handover, and the cast's own screencast commands while that
   * watcher holds it (`curtain()` stopped the stream, and a person who cannot
   * see the page cannot fill in the form on it).
   */
  sendAsPerson(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>>
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

/**
 * The door one input event goes out through.
 *
 * Passed down to each dispatch rather than read off the seam inside them,
 * because which door an event uses is decided once, at the top of
 * {@link PageCast.input}, from a fact about *who sent it* — and a dispatch that
 * reached for a door itself would be a fifth place that has to get that
 * question right.
 */
type Dispatch = (method: string, params: Record<string, unknown>) => Promise<Record<string, unknown>>

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
  /**
   * The one watcher who answered the handover, or null.
   *
   * ## Why a curtain needs a hole in it, and why the hole is one watcher wide
   *
   * The curtain above was written for a desktop, where the person the copilot is
   * asking for is already holding the mouse: the pixels stop, every watcher sees
   * a lock card, and the person types on the real screen. On a phone that is the
   * wrong shape end to end — the watcher **is** the person being asked, and what
   * the curtain hands them is the agent's sentence with the pixels removed and
   * the keyboard refused. *"The person has this page right now"*, said to the
   * person.
   *
   * So one watcher may step through: the one that sent `browser.handover.take`.
   * For that watcher and no other, {@link maskFor} returns null — including over
   * a secret rectangle, because filling in the password field is the entire
   * reason they were asked — and {@link input} dispatches down the person's door
   * rather than the agent's.
   *
   * What it deliberately does **not** do is move the baton. The slot stays
   * `human` for as long as this is set, so `screenCommand` goes on refusing the
   * agent every read and every write exactly as it does today. The taker is a
   * second, narrower door beside that refusal, never a weakening of it.
   *
   * Null again the moment the page is handed back or the taker's socket drops —
   * see {@link untake}. A taker left behind by a phone that went into a tunnel
   * would be an unmasked cast waiting for whoever reconnects onto that id.
   */
  private taker: string | null = null
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
    /*
     * A viewer that arrived while the person holds the page.
     *
     * Two ways to get here and both are ordinary on a phone: a socket that
     * dropped and came back mid-handover, and a viewer *renegotiating* — a phone
     * that rotated, which is a second `browser.watch` on the same window. Without
     * this they would sit on a blank canvas with no sentence on it, because
     * `curtain()` drew its lock cards once, to the watchers that existed then,
     * and `startScreencast` above returned early rather than producing a frame.
     *
     * The taker is skipped: they are being shown the real page, and drawing a
     * lock card over it because they turned their phone sideways would take the
     * password field away mid-word.
     */
    if (this.curtained && watcherId !== this.taker) {
      const watcher = this.watchers.get(watcherId)
      if (watcher) this.drawCurtain(watcher)
    }
  }

  /**
   * Drop one watcher; stop the screencast when the last one leaves.
   *
   * A taker that leaves this way — the socket closed, the app went into a tunnel
   * — hands the page back to nobody: {@link untake} puts the curtain over the
   * whole cast again before the watcher is forgotten, so the next connection to
   * watch this window finds a curtained page rather than a live view of a
   * half-filled login form.
   */
  async unwatch(watcherId: string): Promise<void> {
    if (!this.watchers.has(watcherId)) return
    if (watcherId === this.taker) await this.untake()
    this.watchers.delete(watcherId)
    if (this.watchers.size === 0) await this.stop()
  }

  /** Drop every watcher and stop — a page going away, or the cast being torn down. */
  async dispose(): Promise<void> {
    this.disposed = true
    this.taker = null
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

  /**
   * The door this cast's own screencast commands ride.
   *
   * `Page.startScreencast`, `Page.stopScreencast` and `Page.screencastFrameAck`
   * are not the agent's and they are not the person's — they are the *view*, and
   * which door the view goes through is a fact about who is holding the page.
   * With no taker the cast is running on the agent's behalf and rides the agent's
   * screened send, refused during a handover exactly as it is today. With a
   * taker it is running on the person's behalf and rides the person's door,
   * which permits those three and refuses them the moment the baton comes back.
   *
   * Not a bypass: neither door is widened by the other's existence, and a
   * command outside both lists is refused by whichever one it was handed to.
   */
  private castSend(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    return this.taker === null
      ? this.seam.send(method, params)
      : this.seam.sendAsPerson(method, params)
  }

  private async startScreencast(options: CastOptions): Promise<void> {
    // Curtained and nobody has taken it: there is nothing to stream and the
    // agent's door would refuse the start anyway. A taker is the exception the
    // whole handover path exists for — the pixels have to reach the hands.
    if (this.curtained && this.taker === null) return
    const params: Record<string, unknown> = {
      format: 'jpeg',
      quality: options.quality,
      maxWidth: options.maxWidth,
    }
    if (options.everyNth !== undefined) params.everyNthFrame = options.everyNth
    try {
      await this.castSend('Page.startScreencast', params)
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
      await this.castSend('Page.stopScreencast', {}).catch(() => undefined)
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
      await this.castSend('Page.stopScreencast', {}).catch(() => undefined)
    }
    // Every watcher except the one who is answering the question. A taker is
    // being shown the page on purpose; drawing a lock card over it would be the
    // curtain closing on the person it was raised for.
    for (const watcher of this.watchers.values()) {
      if (watcher.id === this.taker) continue
      this.drawCurtain(watcher)
    }
  }

  /** The person handed the page back: restart the screencast and re-scan secrets. */
  async uncurtain(): Promise<void> {
    if (!this.curtained) return
    this.curtained = false
    this.curtainPrompt = ''
    // Cleared with the curtain, always. Uncurtaining means the baton has gone
    // back to the agent, and a taker left set past that point would be a watcher
    // still holding the person's door open onto a page the agent is driving.
    this.taker = null
    this.secretDocRects = null
    if (this.options && this.watchers.size > 0) {
      await this.startScreencast(this.options)
      void this.refreshSecrets()
    }
  }

  /* -------------------------------------------------------- the handover -- */

  /** The watcher holding this page's handover, or null. */
  get takerId(): string | null {
    return this.taker
  }

  /** Is this watcher the one holding it? */
  isTaker(watcherId: string): boolean {
    return this.taker !== null && this.taker === watcherId
  }

  /**
   * *That person is you? That person is me.*
   *
   * One watcher steps through the curtain: its frames stop being masked and its
   * taps start being dispatched down the person's door. Everything else about
   * the handover is untouched — the slot stays `human`, the agent stays refused
   * at the mechanism for reads and writes both, and every other watcher stays
   * curtained.
   *
   * Refused for a connection this cast does not know (you cannot take a page you
   * are not being shown) and for a second connection when one already holds it:
   * two people typing into one password field is not a state worth having, which
   * is the same argument `browser-driver.ts` makes for allowing one outstanding
   * handover at a time.
   *
   * Restarting the screencast is the load-bearing half. `curtain()` stopped it at
   * the source before the baton flipped, so at this moment there is no stream at
   * all; without the restart the taker would hold a live keyboard over a frozen
   * lock card. It goes out through the person's door, which is the only one open
   * while the slot is `human` — see {@link castSend}.
   *
   * Idempotent for the watcher that already holds it: a second tap on the same
   * button re-asserts the same state rather than being an error, and re-tries the
   * screencast start if the first one did not take.
   */
  async take(watcherId: string): Promise<{ ok: boolean; reason?: string }> {
    if (this.disposed) return { ok: false, reason: 'that page is not being watched any more' }
    if (!this.watchers.has(watcherId)) {
      return { ok: false, reason: 'that window is not being watched on this connection' }
    }
    if (this.taker !== null && this.taker !== watcherId) {
      return { ok: false, reason: 'somebody else is already filling this in' }
    }
    this.taker = watcherId
    if (this.options && !this.started) await this.startScreencast(this.options)
    return { ok: true }
  }

  /**
   * The taker let go — handed the page back, or its socket dropped.
   *
   * Puts the curtain back over the whole cast: the stream stops and every
   * watcher, the ex-taker included while it is still here, gets a lock card
   * again. That is the right end state for **both** ways of arriving:
   *
   *  - A **disconnect** leaves the page in the person's hands with nobody in
   *    them, and the next watcher of this window must find it masked. A taker
   *    left behind by a phone that went into a tunnel would be a live view of a
   *    half-filled login form waiting for whoever reconnects.
   *  - A **hand-back** is followed immediately by the driver's `resume`, which
   *    either lifts the curtain for everybody ({@link uncurtain}) or ends the
   *    drive. Re-curtaining first costs one frame and means there is no instant
   *    in between where the page is unmasked and unowned.
   *
   * The stop is sent **before** the taker is cleared, so it still goes through
   * the person's door — the baton is `human` until the driver moves it, and the
   * agent's door would refuse a `Page.stopScreencast` at this moment.
   */
  async untake(): Promise<void> {
    if (this.taker === null) return
    if (this.started) {
      this.started = false
      await this.castSend('Page.stopScreencast', {}).catch(() => undefined)
    }
    this.taker = null
    this.pending = null
    if (this.curtained) {
      for (const watcher of this.watchers.values()) this.drawCurtain(watcher)
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
   *
   * ## The one watcher that is not refused during a handover
   *
   * The taker. It is not an exception to the rule above so much as the other
   * side of it: the sentence *"the person has this page right now"* is true, and
   * the taker **is** that person. Its events go out through
   * {@link CastSeam.sendAsPerson} — a different function, a different allow-list,
   * and a condition that is the exact inverse of the agent's — so nothing about
   * this widens what the agent may send. If the baton has meanwhile gone back,
   * that door refuses on its own, which is what catches the last keystroke still
   * in flight when somebody presses Done.
   */
  async input(watcherId: string, frame: BrowserInputFrame): Promise<{ ok: boolean; reason?: string }> {
    const watcher = this.watchers.get(watcherId)
    if (!watcher) return { ok: false, reason: 'that window is not being watched on this connection' }
    const mine = this.isTaker(watcherId)
    if (!mine && (this.curtained || this.seam.isHuman())) {
      return { ok: false, reason: 'the person has this page right now' }
    }
    const send: Dispatch = mine
      ? (method, params) => this.seam.sendAsPerson(method, params)
      : (method, params) => this.seam.send(method, params)
    // The frame the coordinates were measured against, by its seq — never the
    // viewer's own idea of the scale.
    const geom = watcher.geometry.find((g) => g.seq === frame.seq) ?? watcher.geometry[watcher.geometry.length - 1]
    if (frame.mouse) return this.dispatchMouse(send, geom, frame.mouse)
    if (frame.touch) return this.dispatchTouch(send, geom, frame.touch)
    if (frame.key) return this.dispatchKey(send, frame.key)
    if (frame.paste !== undefined) return this.dispatchPaste(send, frame.paste)
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
    const masked = this.maskFor(frame, watcher)
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
   * Should this frame be masked **for this watcher**, and under what sentence?
   *
   * Returns null when the frame may cross with its pixels, or an object naming
   * the curtain sentence when it may not. The handover curtain wins first; a
   * secret field visible in the frame's own viewport wins second.
   *
   * ## Why the answer is per watcher and not per frame
   *
   * It used to be per frame, which was right while a masked page was masked for
   * everybody. It is not any more: the taker is one connection among several
   * looking at one page, and *whether I may see this* is a fact about who is
   * asking. One frame therefore leaves here twice — with pixels to the person
   * filling in the form, empty to everyone else — which is exactly the shape
   * `BrowserHandoverStateFrame.mine` describes on the wire for the same reason.
   *
   * The taker skips the **secret-rect** brake as well as the curtain, and that
   * is deliberate rather than an oversight in the ordering. They were handed this
   * page to type a password into it; a lock card over the password field would
   * hide the one thing they are here to do. Nobody else's frames change, and
   * outside a handover there is no taker at all, so the secret mask is exactly
   * what it was for every ordinary watcher.
   */
  private maskFor(frame: CastFrame, watcher: Watcher): { prompt?: string } | null {
    if (this.isTaker(watcher.id)) return null
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

  /*
   * Through {@link castSend}, because this is the backpressure and the
   * backpressure is what makes a stream a stream. CDP produces the next frame
   * only after this ack, so an ack refused during a handover would leave the
   * taker looking at exactly one frame of the page they were asked to fill in.
   */
  private ackCdp(sessionId: number): void {
    void this.castSend('Page.screencastFrameAck', { sessionId }).catch(() => undefined)
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
    send: Dispatch,
    geom: FrameGeometry | undefined,
    mouse: NonNullable<BrowserInputFrame['mouse']>,
  ): Promise<{ ok: boolean; reason?: string }> {
    if (!Number.isFinite(mouse.x) || !Number.isFinite(mouse.y)) {
      return { ok: false, reason: 'an input coordinate must be a real number' }
    }
    const { x, y } = this.mapPoint(geom, mouse.x, mouse.y)
    if (mouse.type === 'wheel') {
      await send('Input.dispatchMouseEvent', {
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
    await send('Input.dispatchMouseEvent', params)
    return { ok: true }
  }

  private async dispatchTouch(
    send: Dispatch,
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
    await send('Input.dispatchTouchEvent', { type, touchPoints })
    return { ok: true }
  }

  /**
   * One key, as Chromium's input pipeline needs it rather than as the wire
   * spells it.
   *
   * ## Why a virtual key code has to be here
   *
   * This used to send `key`, `code`, `text` and `modifiers` and nothing else,
   * and the result was a keyboard that could type and could not edit. Measured
   * on a real page over the relay: `hello` typed into a search box stayed
   * `hello` after Backspace, and six ArrowDowns scrolled nothing.
   *
   * The reason is not obvious and is worth writing down. Chromium hands a key
   * event with no `windowsVirtualKeyCode` to the **page's JavaScript** — which is
   * why a site's own Return handler fires and a search submits — but performs
   * none of its **own** default handling: no character deletion, no caret
   * movement, no focus traversal, no scroll. Those are the browser's behaviours
   * and it looks them up by virtual key code. So a key with no code is a key the
   * page can hear and the browser will not act on, which is exactly the half
   * that was missing.
   *
   * ## The table is small on purpose
   *
   * Only the keys that have no character of their own, because every key that
   * *does* already works: `text` reaches the page as a `char` event and inserts
   * itself. Adding the printable range would be forty entries that change
   * nothing and one more place for `A` and `a` to disagree.
   *
   * A key this table does not know is still sent, without a code — the same
   * event as before, which the page can still hear. Silence would be worse: a
   * media key or a function key nobody listed would stop reaching a page that
   * had bound it.
   */
  private static readonly VIRTUAL_KEYS: Readonly<Record<string, number>> = {
    Backspace: 8,
    Tab: 9,
    Enter: 13,
    Escape: 27,
    ' ': 32,
    PageUp: 33,
    PageDown: 34,
    End: 35,
    Home: 36,
    ArrowLeft: 37,
    ArrowUp: 38,
    ArrowRight: 39,
    ArrowDown: 40,
    Insert: 45,
    Delete: 46,
  }

  private async dispatchKey(
    send: Dispatch,
    key: NonNullable<BrowserInputFrame['key']>,
  ): Promise<{ ok: boolean; reason?: string }> {
    const type = key.type === 'down' ? 'rawKeyDown' : key.type === 'up' ? 'keyUp' : 'char'
    const params: Record<string, unknown> = { type }
    if (key.key !== undefined) params.key = key.key
    if (key.code !== undefined) params.code = key.code
    if (key.text !== undefined) params.text = key.text
    if (key.mods !== undefined) params.modifiers = key.mods
    /*
     * By `key` first and `code` second, because they answer different questions
     * and only the first is the one being asked. `key` is what the keystroke
     * *means* — `Backspace`, `ArrowDown` — and `code` is which physical key was
     * pressed. A client that sent only a `code` still gets the right behaviour
     * for the keys in the table, since for these two the spellings coincide.
     */
    const virtual =
      PageCast.VIRTUAL_KEYS[key.key ?? ''] ?? PageCast.VIRTUAL_KEYS[key.code ?? '']
    if (virtual !== undefined) {
      params.windowsVirtualKeyCode = virtual
      // The two Chromium reads on other platforms, set together so a build that
      // is not Windows behaves the same. `nativeVirtualKeyCode` is the one macOS
      // and Linux consult.
      params.nativeVirtualKeyCode = virtual
    }
    await send('Input.dispatchKeyEvent', params)
    return { ok: true }
  }

  private async dispatchPaste(send: Dispatch, text: string): Promise<{ ok: boolean; reason?: string }> {
    await send('Input.insertText', { text })
    return { ok: true }
  }
}
