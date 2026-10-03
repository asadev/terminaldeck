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
    this.config = { codec: codecOf(avcC), description: avcC, optimizeForLatency: true }
    if (!this.decoder || this.decoder.state === 'closed') {
      this.decoder = new Decoder({
        output: (frame) => this.show(frame),
        error: () => this.recover(),
      })
    }
    try {
      this.decoder.configure(this.config)
      this.waitingForKey = true
    } catch {
      this.recover()
    }
  }

  private decode(packet: Uint8Array): void {
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
      this.waitingForKey = true
      this.askForKeyframe()
      if (!picture.key) return
    }
    this.waitingForKey = false
    try {
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

  /** The newest decoded picture; the one waiting before it was never shown and is let go. */
  private show(source: Source): void {
    if (this.disposed) {
      source.close()
      return
    }
    this.pending?.close()
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
    this.hooks.onPaint?.()
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
    const context = this.canvas.getContext('2d', { alpha: false })
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
