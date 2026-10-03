/**
 * The live device screen: the engine's H.264 stream, decoded by the hardware
 * and painted sharp at this display's own pixel density.
 *
 * ## Why this replaced a JPEG per change
 *
 * Asad, on 0.16.1: *"simulator still works too slow"* and *"rendering too bad
 * quality"*. Both were measured, on an iPhone 17 Pro simulator scrolling
 * Settings, before anything changed:
 *
 *  - The engine was asked for MJPEG, and an MJPEG frame is a whole
 *    1206 × 2622 JPEG of about 233 KB. It managed **11.8 frames a second**
 *    while scrolling, at 21 Mbit/s, with the engine at 28% of a core — and the
 *    main process then let through at most one picture every 33 ms on top.
 *  - Each JPEG was decoded and drawn at its own size into a canvas, and the
 *    canvas was then shrunk by CSS to fit the stage. A 1206-pixel picture
 *    squeezed into ~670 device pixels by the compositor's quick filter is
 *    soft and shimmers on small text; the JPEG's own blocks were on top.
 *
 * The engine's preferred stream is H.264 (VideoToolbox), and its own preview
 * decodes it with WebCodecs. Same simulator, same scroll: **34.4 frames a
 * second at 2.7 Mbit/s**, full resolution. So this does the same: the decoder
 * configuration and every coded picture arrive tagged with the engine's own
 * frame kind, a `VideoDecoder` turns them into frames in hardware, and the
 * newest frame is painted once per display refresh.
 *
 * ## Sharp at Retina density
 *
 * The canvas's backing store is the size it is *shown* at times
 * `devicePixelRatio` — never the picture's size — and each frame is drawn into
 * it once, with `imageSmoothingQuality: 'high'`, which downsamples properly
 * rather than with the compositor's bilinear. One resample, at the right size,
 * done well: the same thing Simulator.app does with the same framebuffer.
 *
 * ## Under load (0.16.4)
 *
 * Asad, on the merged 0.16.2: *"simulator is still too slow"*. Measured in the
 * real app, built and launched on its own, beside SimView's own preview window
 * on the same simulator at the same moment, with the Mac at a load average of
 * 650–1000 on ten cores (another session's Xcode builds):
 *
 *  - While the simulator itself was starved, it drew about **2.8 frames a
 *    second** whatever was done to it, and both windows showed exactly that:
 *    every frame the engine sent was decoded and painted in both, and
 *    tap-to-picture spread over one frame interval (15–400 ms) in both.
 *    Nothing a viewer does can show frames the simulator never drew.
 *  - When the simulator did keep up, a drag showed **36–42 frames a second
 *    here against 28–31 in SimView's preview**, taps 26–29 against 16–17, and
 *    tap-to-picture was a median of about 10–25 ms here against about 70 ms
 *    there. SimView's pictures take one more hop — a relay process that costs
 *    20–25% of a core even at rest — and arrive fewer and later.
 *  - The engine cannot be asked for a smaller stream: it ignores `maxWidth` and
 *    `maxHeight` for H.264 and for MJPEG (read from the stream's own SPS at
 *    three sizes), and SimView never sends them. The stream is always the full
 *    framebuffer, so the decode is too — about 2 ms a picture in hardware. What
 *    this window controls is the rest, and it does the least it can: the
 *    decoder is asked for the hardware (`prefer-hardware`, dropped if refused),
 *    nothing is sent or decoded while the window is hidden or minimised (the
 *    engine is told to stop sending — `DeviceScreen.tsx`; 0% of a core hidden,
 *    the picture back 37 ms after showing), the canvas is a low-latency one
 *    like SimView's, and only the newest frame is ever painted.
 *
 * {@link ScreenPlayer.stats} is what the hidden diagnostics readout shows
 * (Option-click the device's name).
 *
 * ## Falling behind
 *
 * A coded picture is a difference from the one before, so none may be skipped
 * — and none are, on the way here. If this window cannot keep up (the decoder
 * queue grows), it drops what it has not decoded, waits for a keyframe, and
 * asks for one; the person sees a stall of a frame or two, never a smear.
 */

/** The engine's frame kinds, the first byte of every packet. Mirrors `session.ts`. */
export const PACKET_CONFIG = 0x10
export const PACKET_PICTURE = 0x11
export const PACKET_JPEG = 0x12
export const PACKET_STILL = 0x20

/** More coded pictures than this waiting to decode means this window is behind. */
const MAX_BACKLOG = 12

/** A keyframe is asked for at most this often. */
const KEYFRAME_GAP_MS = 500

/** `avc1.PPCCLL` from an AVCDecoderConfigurationRecord: profile, compatibility, level. */
export function codecOf(avcC: Uint8Array): string {
  const hex = (value: number | undefined): string => (value ?? 0).toString(16).padStart(2, '0')
  return `avc1.${hex(avcC[1])}${hex(avcC[2])}${hex(avcC[3])}`
}

/** One coded picture's fields, out of the engine's framing: an 8-byte BE microsecond timestamp, a keyframe flag, the data. */
export function readPicture(packet: Uint8Array): { timestamp: number; key: boolean; data: Uint8Array } | null {
  if (packet.length < 11) return null
  const view = new DataView(packet.buffer, packet.byteOffset + 1, 8)
  return { timestamp: Number(view.getBigUint64(0, false)), key: packet[9] === 1, data: packet.subarray(10) }
}

/** The backing-store size for a canvas shown at `css` pixels on a display of `dpr`. */
export function backingSize(css: { width: number; height: number }, dpr: number): { width: number; height: number } {
  const ratio = Number.isFinite(dpr) && dpr > 0 ? dpr : 1
  return { width: Math.max(1, Math.round(css.width * ratio)), height: Math.max(1, Math.round(css.height * ratio)) }
}

type Source = VideoFrame | ImageBitmap

function sizeOf(source: Source): { width: number; height: number } {
  return 'displayWidth' in source
    ? { width: source.displayWidth, height: source.displayHeight }
    : { width: source.width, height: source.height }
}

export interface PlayerHooks {
  /** The decoder needs a fresh keyframe — the window watches again, which asks the engine for one. */
  needKeyframe(): void
  /** A picture of a new size arrived — first, or after a rotation. The layout re-fits the canvas. */
  onPicture(size: { width: number; height: number }): void
  /** Counted per painted frame, for anything measuring smoothness. */
  onPaint?(): void
}

/** What this needs from the window, so a test can hand it fakes. */
export interface PlayerEnv {
  VideoDecoder?: typeof VideoDecoder
  EncodedVideoChunk?: typeof EncodedVideoChunk
  createImageBitmap(blob: Blob): Promise<ImageBitmap>
  requestAnimationFrame(callback: () => void): number
  cancelAnimationFrame(handle: number): void
  now(): number
}

/** What the diagnostics readout shows. Counts run from the player's start. */
export interface PlayerStats {
  /** Coded pictures that arrived. */
  received: number
  /** Pictures the decoder handed back. */
  decoded: number
  /** Pictures painted. Fewer than decoded when two arrived within one refresh. */
  painted: number
  /** Decoded pictures replaced by a newer one before they could be painted. */
  dropped: number
  /** Times the decoder fell behind and started again from a keyframe. */
  resets: number
  /** Recent decode times: a picture handed in to its frame coming out, in ms. */
  decodeMs: number[]
  /** Recent times from a touch, key or wheel to the next picture painted, in ms. */
  inputToPictureMs: number[]
  /** The stream's own size, once a picture has arrived. */
  stream: { width: number; height: number } | null
  /** The canvas's backing store. */
  canvas: { width: number; height: number }
  /** Whether the decoder runs in hardware: asked for and working, refused, or not known yet. */
  hardware: 'yes' | 'no' | 'unknown'
  codec: string | null
}

/** How many recent timings the readout keeps. */
const RECENT = 60

function windowEnv(): PlayerEnv {
  return {
    VideoDecoder: typeof VideoDecoder === 'undefined' ? undefined : VideoDecoder,
    EncodedVideoChunk: typeof EncodedVideoChunk === 'undefined' ? undefined : EncodedVideoChunk,
    createImageBitmap: (blob) => createImageBitmap(blob),
    requestAnimationFrame: (callback) => requestAnimationFrame(callback),
    cancelAnimationFrame: (handle) => cancelAnimationFrame(handle),
    now: () => performance.now(),
  }
}

function remember(list: number[], value: number): void {
  list.push(Math.round(value * 10) / 10)
  if (list.length > RECENT) list.splice(0, list.length - RECENT)
}

export class ScreenPlayer {
  private decoder: VideoDecoder | null = null
  private config: VideoDecoderConfig | null = null
  private waitingForKey = true
  private pending: Source | null = null
  private shown: Source | null = null
  private shownSize: { width: number; height: number } | null = null
  private frame = 0
  private lastAsk = -Infinity
  private disposed = false
  /** Set once the hardware decoder refused this stream; the hint is left off from then on. */
  private softwareOnly = false
  private hardware: PlayerStats['hardware'] = 'unknown'
  private readonly counts = { received: 0, decoded: 0, painted: 0, dropped: 0, resets: 0 }
  private readonly decodeStarted = new Map<number, number>()
  private readonly decodeMs: number[] = []
  private readonly inputToPicture: number[] = []
  private inputAt: number | null = null

  constructor(
    private readonly canvas: HTMLCanvasElement,
    private readonly hooks: PlayerHooks,
    private readonly env: PlayerEnv = windowEnv(),
  ) {}

  /** One packet from the main process, tagged with the engine's frame kind. */
  push(packet: Uint8Array): void {
    if (this.disposed || packet.length === 0) return
    const kind = packet[0]
    if (kind === PACKET_CONFIG) this.configure(packet.slice(1))
    else if (kind === PACKET_PICTURE) this.decode(packet)
    else if (kind === PACKET_JPEG || kind === PACKET_STILL) this.still(packet.subarray(1), kind)
  }

  private configure(avcC: Uint8Array): void {
    const Decoder = this.env.VideoDecoder
    if (!Decoder || avcC.length < 4) return
    const codec = codecOf(avcC)
    this.config = {
      codec,
      description: avcC,
      optimizeForLatency: true,
      ...(this.softwareOnly ? {} : { hardwareAcceleration: 'prefer-hardware' as const }),
    }
    if (!this.decoder || this.decoder.state === 'closed') {
      this.decoder = new Decoder({
        output: (frame) => this.decoded(frame),
        error: (error) => this.failed(error),
      })
    }
    if (!this.softwareOnly && this.hardware === 'unknown') this.checkHardware(Decoder, this.config)
    try {
      this.decoder.configure(this.config)
      this.waitingForKey = true
    } catch {
      this.recover()
    }
  }

  /**
   * Asks, once, whether this stream can be decoded in hardware at all. A "no"
   * drops the hint and starts again from a keyframe, rather than waiting for
   * the decoder to fail on the first picture.
   */
  private checkHardware(Decoder: typeof VideoDecoder, config: VideoDecoderConfig): void {
    if (typeof Decoder.isConfigSupported !== 'function') return
    const { description: _description, ...probe } = config
    void Decoder.isConfigSupported(probe).then(
      (answer) => {
        if (this.disposed || answer.supported !== false || this.softwareOnly) return
        this.refuseHardware()
        this.recover()
      },
      () => undefined,
    )
  }

  private refuseHardware(): void {
    this.softwareOnly = true
    this.hardware = 'no'
    if (this.config) {
      const { hardwareAcceleration: _hint, ...rest } = this.config
      this.config = rest
    }
  }

  private failed(error: unknown): void {
    const name = error instanceof Error || (typeof DOMException !== 'undefined' && error instanceof DOMException) ? error.name : ''
    if (!this.softwareOnly && this.config?.hardwareAcceleration === 'prefer-hardware' && name === 'NotSupportedError') {
      this.refuseHardware()
    }
    this.recover()
  }

  private decode(packet: Uint8Array): void {
    this.counts.received += 1
    const decoder = this.decoder
    const Chunk = this.env.EncodedVideoChunk
    if (!decoder || !Chunk || decoder.state !== 'configured') {
      // A picture with nothing to decode it: this window joined after the
      // configuration went past. Watching again sends it.
      this.askForKeyframe()
      return
    }
    const picture = readPicture(packet)
    if (!picture) return
    if (this.waitingForKey && !picture.key) return
    if (decoder.decodeQueueSize > MAX_BACKLOG) {
      // Behind. Drop everything not yet decoded and start again from a
      // keyframe, rather than paint a minute-old screen in slow motion.
      decoder.reset()
      if (this.config) decoder.configure(this.config)
      this.counts.resets += 1
      this.decodeStarted.clear()
      this.waitingForKey = true
      this.askForKeyframe()
      if (!picture.key) return
    }
    this.waitingForKey = false
    try {
      if (this.decodeStarted.size > RECENT) this.decodeStarted.clear()
      this.decodeStarted.set(picture.timestamp, this.env.now())
      decoder.decode(new Chunk({ type: picture.key ? 'key' : 'delta', timestamp: picture.timestamp, data: picture.data }))
    } catch {
      this.recover()
    }
  }

  private still(bytes: Uint8Array, kind: number): void {
    const blob = new Blob([bytes as BlobPart], { type: kind === PACKET_STILL ? 'image/png' : 'image/jpeg' })
    void this.env.createImageBitmap(blob).then(
      (bitmap) => this.show(bitmap),
      () => undefined,
    )
  }

  private recover(): void {
    this.waitingForKey = true
    if (this.decoder && this.decoder.state !== 'closed') {
      try {
        this.decoder.reset()
        if (this.config) this.decoder.configure(this.config)
      } catch {
        this.decoder = null
      }
    } else {
      this.decoder = null
    }
    this.askForKeyframe()
  }

  private askForKeyframe(): void {
    const now = this.env.now()
    if (now - this.lastAsk < KEYFRAME_GAP_MS) return
    this.lastAsk = now
    this.hooks.needKeyframe()
  }

  private decoded(frame: VideoFrame): void {
    this.counts.decoded += 1
    const started = this.decodeStarted.get(frame.timestamp)
    if (started !== undefined) {
      this.decodeStarted.delete(frame.timestamp)
      remember(this.decodeMs, this.env.now() - started)
    }
    if (this.hardware === 'unknown' && this.config?.hardwareAcceleration === 'prefer-hardware') this.hardware = 'yes'
    this.show(frame)
  }

  /** The newest decoded picture; the one waiting before it was never shown and is let go. */
  private show(source: Source): void {
    if (this.disposed) {
      source.close()
      return
    }
    if (this.pending) {
      this.pending.close()
      this.counts.dropped += 1
    }
    this.pending = source
    if (this.frame === 0) this.frame = this.env.requestAnimationFrame(() => this.paint())
  }

  private paint(): void {
    this.frame = 0
    const next = this.pending
    this.pending = null
    if (!next) return
    this.shown?.close()
    this.shown = next
    const size = sizeOf(next)
    if (!this.shownSize || this.shownSize.width !== size.width || this.shownSize.height !== size.height) {
      this.shownSize = size
      this.hooks.onPicture(size)
    }
    this.draw()
    this.counts.painted += 1
    if (this.inputAt !== null) {
      remember(this.inputToPicture, this.env.now() - this.inputAt)
      this.inputAt = null
    }
    this.hooks.onPaint?.()
  }

  /** A touch, key or wheel just went to the device: the next picture painted is timed from here. */
  markInput(): void {
    if (this.inputAt === null) this.inputAt = this.env.now()
  }

  /** A copy of the numbers, for the diagnostics readout. */
  stats(): PlayerStats {
    return {
      ...this.counts,
      decodeMs: [...this.decodeMs],
      inputToPictureMs: [...this.inputToPicture],
      stream: this.shownSize ? { ...this.shownSize } : null,
      canvas: { width: this.canvas.width, height: this.canvas.height },
      hardware: this.hardware,
      codec: this.config?.codec ?? null,
    }
  }

  /** Size the backing store to the shown size at this density, and redraw what is on screen. */
  resize(css: { width: number; height: number }, dpr: number): void {
    const backing = backingSize(css, dpr)
    if (this.canvas.width !== backing.width) this.canvas.width = backing.width
    if (this.canvas.height !== backing.height) this.canvas.height = backing.height
    this.draw()
  }

  private draw(): void {
    const source = this.shown
    if (!source) return
    // `desynchronized`: SimView's preview asks for the same low-latency canvas,
    // which may skip the compositor's queue where the platform allows it.
    const context = this.canvas.getContext('2d', { alpha: false, desynchronized: true })
    if (!context) return
    context.imageSmoothingEnabled = true
    context.imageSmoothingQuality = 'high'
    context.drawImage(source, 0, 0, this.canvas.width, this.canvas.height)
  }

  dispose(): void {
    this.disposed = true
    if (this.frame !== 0) this.env.cancelAnimationFrame(this.frame)
    this.pending?.close()
    this.shown?.close()
    this.pending = null
    this.shown = null
    if (this.decoder && this.decoder.state !== 'closed') this.decoder.close()
    this.decoder = null
  }
}

/* ---------------------------------------------------- the diagnostics -- */

const median = (values: number[]): number | null => {
  if (values.length === 0) return null
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.floor(sorted.length / 2)] ?? null
}
const p95 = (values: number[]): number | null => {
  if (values.length === 0) return null
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))] ?? null
}

/** The readout's lines, from two looks at the player's numbers `seconds` apart. */
export function diagnosticLines(
  before: PlayerStats | null,
  now: PlayerStats,
  seconds: number,
  dpr: number,
  paused: boolean,
): string[] {
  const rate = (key: 'painted' | 'received'): string =>
    before && seconds > 0 ? ((now[key] - before[key]) / seconds).toFixed(1) : '–'
  const ms = (value: number | null): string => (value === null ? '–' : `${Math.round(value)} ms`)
  const size = (box: { width: number; height: number } | null): string => (box ? `${box.width}×${box.height}` : '–')
  return [
    paused ? 'paused — window hidden' : `shown ${rate('painted')} fps · arriving ${rate('received')} fps`,
    `decode ${ms(median(now.decodeMs))} (p95 ${ms(p95(now.decodeMs))}) · hardware ${now.hardware}`,
    `touch → picture ${ms(median(now.inputToPictureMs))} (last ${ms(now.inputToPictureMs.at(-1) ?? null)})`,
    `dropped ${now.dropped} · restarts ${now.resets}`,
    `stream ${size(now.stream)} → canvas ${size(now.canvas)} @${dpr}x${now.codec ? ` · ${now.codec}` : ''}`,
  ]
}
