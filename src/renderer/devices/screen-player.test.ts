import { describe, expect, it } from 'vitest'
import {
  backingSize,
  codecOf,
  diagnosticLines,
  PACKET_CONFIG,
  PACKET_PICTURE,
  readPicture,
  ScreenPlayer,
  type PlayerEnv,
} from './screen-player'

/**
 * The player, with a decoder and a canvas that record what they were asked.
 *
 * What matters is visible in the calls: the decoder is configured from the
 * engine's own configuration, deltas are never fed before a keyframe, a decoder
 * that falls behind is reset and asks for a keyframe instead of decoding a
 * backlog, and the canvas is drawn into at its shown size times the density —
 * once, with high-quality smoothing — rather than at the picture's size.
 */

interface Recorder {
  configured: VideoDecoderConfig[]
  decoded: Array<{ type: string; timestamp: number }>
  resets: number
  queue: number
  output: ((frame: VideoFrame) => void) | null
  error?: ((error: DOMException) => void) | null
  /** What `isConfigSupported` answers; left out, the fake has no such method. */
  supported?: boolean
}

function env(rec: Recorder, frames?: Array<() => void>, clock?: { now: number }): PlayerEnv {
  class FakeDecoder {
    static isConfigSupported = rec.supported === undefined ? undefined : async (config: VideoDecoderConfig) => ({ supported: rec.supported, config })
    state: CodecState = 'unconfigured'
    constructor(init: VideoDecoderInit) {
      rec.output = init.output
      rec.error = init.error as (error: DOMException) => void
    }
    get decodeQueueSize(): number {
      return rec.queue
    }
    configure(config: VideoDecoderConfig): void {
      rec.configured.push(config)
      this.state = 'configured'
    }
    decode(chunk: { type: string; timestamp: number }): void {
      rec.decoded.push({ type: chunk.type, timestamp: chunk.timestamp })
    }
    reset(): void {
      rec.resets += 1
      this.state = 'unconfigured'
    }
    close(): void {
      this.state = 'closed'
    }
  }
  class FakeChunk {
    type: string
    timestamp: number
    constructor(init: { type: string; timestamp: number }) {
      this.type = init.type
      this.timestamp = init.timestamp
    }
  }
  return {
    VideoDecoder: FakeDecoder as unknown as typeof VideoDecoder,
    EncodedVideoChunk: FakeChunk as unknown as typeof EncodedVideoChunk,
    createImageBitmap: async () => ({ width: 1, height: 1, close: () => undefined }) as unknown as ImageBitmap,
    // Paints at once, unless the test holds the refreshes to run them itself.
    requestAnimationFrame: (callback) => {
      if (frames) frames.push(callback)
      else callback()
      return 1
    },
    cancelAnimationFrame: () => undefined,
    now: () => (clock ? clock.now : Date.now()),
  }
}

function canvas(): { element: HTMLCanvasElement; draws: Array<{ w: number; h: number; quality: string }> } {
  const draws: Array<{ w: number; h: number; quality: string }> = []
  const context = {
    imageSmoothingEnabled: false,
    imageSmoothingQuality: 'low',
    drawImage(_source: unknown, _x: number, _y: number, w: number, h: number) {
      draws.push({ w, h, quality: context.imageSmoothingQuality })
    },
  }
  const element = { width: 300, height: 150, getContext: () => context } as unknown as HTMLCanvasElement
  return { element, draws }
}

const AVCC = new Uint8Array([PACKET_CONFIG, 1, 0x64, 0x00, 0x33, 0xff, 0xe1])

function picture(timestamp: number, key: boolean): Uint8Array {
  const packet = new Uint8Array(12)
  packet[0] = PACKET_PICTURE
  new DataView(packet.buffer).setBigUint64(1, BigInt(timestamp), false)
  packet[9] = key ? 1 : 0
  packet[10] = 0xaa
  packet[11] = 0xbb
  return packet
}

function frame(width: number, height: number, timestamp = 0): VideoFrame {
  return { displayWidth: width, displayHeight: height, timestamp, close: () => undefined } as unknown as VideoFrame
}

const fresh = (extra: Partial<Recorder> = {}): Recorder => ({ configured: [], decoded: [], resets: 0, queue: 0, output: null, ...extra })

describe('reading the engine’s packets', () => {
  it('names the codec from the configuration’s profile, compatibility and level', () => {
    expect(codecOf(new Uint8Array([1, 0x64, 0x00, 0x33]))).toBe('avc1.640033')
  })

  it('reads a coded picture’s timestamp, keyframe flag and data', () => {
    const read = readPicture(picture(16_666, true))
    expect(read?.timestamp).toBe(16_666)
    expect(read?.key).toBe(true)
    expect([...(read?.data ?? [])]).toEqual([0xaa, 0xbb])
  })

  it('sizes the backing store to the shown size times the density', () => {
    expect(backingSize({ width: 333, height: 724 }, 2)).toEqual({ width: 666, height: 1448 })
    expect(backingSize({ width: 333, height: 724 }, 0)).toEqual({ width: 333, height: 724 })
  })
})

describe('the player', () => {
  it('configures the decoder from the engine and never feeds it a delta before a keyframe', () => {
    const rec: Recorder = { configured: [], decoded: [], resets: 0, queue: 0, output: null }
    const { element } = canvas()
    const player = new ScreenPlayer(element, { needKeyframe: () => undefined, onPicture: () => undefined }, env(rec))
    player.push(AVCC)
    expect(rec.configured[0]).toMatchObject({ codec: 'avc1.640033', optimizeForLatency: true })
    player.push(picture(1, false))
    player.push(picture(2, true))
    player.push(picture(3, false))
    expect(rec.decoded).toEqual([
      { type: 'key', timestamp: 2 },
      { type: 'delta', timestamp: 3 },
    ])
  })

  it('asks for a fresh start instead of decoding a backlog when it falls behind', () => {
    const rec: Recorder = { configured: [], decoded: [], resets: 0, queue: 0, output: null }
    const asks: number[] = []
    const { element } = canvas()
    const player = new ScreenPlayer(element, { needKeyframe: () => asks.push(1), onPicture: () => undefined }, env(rec))
    player.push(AVCC)
    player.push(picture(1, true))
    rec.queue = 50
    player.push(picture(2, false))
    expect(rec.resets).toBe(1)
    expect(asks).toHaveLength(1)
    expect(rec.decoded.map((d) => d.timestamp)).toEqual([1])
  })

  it('asks for the configuration when a picture arrives before it', () => {
    const rec: Recorder = { configured: [], decoded: [], resets: 0, queue: 0, output: null }
    const asks: number[] = []
    const { element } = canvas()
    const player = new ScreenPlayer(element, { needKeyframe: () => asks.push(1), onPicture: () => undefined }, env(rec))
    player.push(picture(1, true))
    expect(asks).toHaveLength(1)
    expect(rec.decoded).toEqual([])
  })

  it('paints the newest frame into the shown size at this density, smoothly, and reports a new size once', () => {
    const rec: Recorder = { configured: [], decoded: [], resets: 0, queue: 0, output: null }
    const sizes: string[] = []
    const { element, draws } = canvas()
    const player = new ScreenPlayer(
      element,
      { needKeyframe: () => undefined, onPicture: (size) => sizes.push(`${size.width}x${size.height}`) },
      env(rec),
    )
    player.push(AVCC)
    rec.output?.(frame(1206, 2622))
    player.resize({ width: 333, height: 724 }, 2)
    rec.output?.(frame(1206, 2622))
    expect(sizes).toEqual(['1206x2622'])
    expect(element.width).toBe(666)
    expect(element.height).toBe(1448)
    expect(draws.at(-1)).toEqual({ w: 666, h: 1448, quality: 'high' })
  })
})

describe('the hardware decoder', () => {
  it('is asked for, and the readout says so once it works', () => {
    const rec = fresh()
    const { element } = canvas()
    const player = new ScreenPlayer(element, { needKeyframe: () => undefined, onPicture: () => undefined }, env(rec))
    player.push(AVCC)
    expect(rec.configured[0]).toMatchObject({ hardwareAcceleration: 'prefer-hardware' })
    expect(player.stats().hardware).toBe('unknown')
    player.push(picture(1, true))
    rec.output?.(frame(1206, 2622, 1))
    expect(player.stats().hardware).toBe('yes')
  })

  it('is dropped when it refuses the stream, and the stream starts again from a keyframe without it', () => {
    const rec = fresh()
    const asks: number[] = []
    const { element } = canvas()
    const player = new ScreenPlayer(element, { needKeyframe: () => asks.push(1), onPicture: () => undefined }, env(rec))
    player.push(AVCC)
    rec.error?.(new DOMException('No hardware decoder for this stream.', 'NotSupportedError'))
    expect(asks).toHaveLength(1)
    expect(rec.configured.at(-1)?.hardwareAcceleration).toBeUndefined()
    expect(player.stats().hardware).toBe('no')
    // Later configurations — after a rotation, say — leave it off too.
    player.push(AVCC)
    expect(rec.configured.at(-1)?.hardwareAcceleration).toBeUndefined()
  })

  it('is dropped up front when the browser says it cannot do this stream', async () => {
    const rec = fresh({ supported: false })
    const { element } = canvas()
    const player = new ScreenPlayer(element, { needKeyframe: () => undefined, onPicture: () => undefined }, env(rec))
    player.push(AVCC)
    expect(rec.configured[0]).toMatchObject({ hardwareAcceleration: 'prefer-hardware' })
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(rec.configured.at(-1)?.hardwareAcceleration).toBeUndefined()
    expect(player.stats().hardware).toBe('no')
  })
})

describe('the diagnostics numbers', () => {
  it('count what arrived, what was decoded, what was painted and what was let go unpainted', () => {
    const rec = fresh()
    const frames: Array<() => void> = []
    const clock = { now: 1_000 }
    const { element } = canvas()
    const player = new ScreenPlayer(element, { needKeyframe: () => undefined, onPicture: () => undefined }, env(rec, frames, clock))
    player.push(AVCC)
    player.push(picture(1, true))
    player.push(picture(2, false))
    clock.now += 3
    // Two pictures decoded inside one refresh: only the newer is painted.
    rec.output?.(frame(1206, 2622, 1))
    rec.output?.(frame(1206, 2622, 2))
    frames.splice(0).forEach((paint) => paint())
    const stats = player.stats()
    expect(stats).toMatchObject({ received: 2, decoded: 2, painted: 1, dropped: 1, resets: 0, codec: 'avc1.640033' })
    expect(stats.decodeMs).toEqual([3, 3])
    expect(stats.stream).toEqual({ width: 1206, height: 2622 })
  })

  it('time a touch to the next picture painted', () => {
    const rec = fresh()
    const frames: Array<() => void> = []
    const clock = { now: 0 }
    const { element } = canvas()
    const player = new ScreenPlayer(element, { needKeyframe: () => undefined, onPicture: () => undefined }, env(rec, frames, clock))
    player.push(AVCC)
    player.push(picture(1, true))
    clock.now = 100
    player.markInput()
    clock.now = 120
    player.markInput() // a move in the same gesture: still timed from the first
    clock.now = 180
    rec.output?.(frame(1206, 2622, 1))
    frames.splice(0).forEach((paint) => paint())
    expect(player.stats().inputToPictureMs).toEqual([80])
  })
})

describe('the diagnostics readout', () => {
  const stats = (painted: number, received: number) => ({
    received,
    decoded: received,
    painted,
    dropped: 1,
    resets: 0,
    decodeMs: [2, 3, 9],
    inputToPictureMs: [120, 80, 95],
    stream: { width: 1206, height: 2622 },
    canvas: { width: 355, height: 772 },
    hardware: 'yes' as const,
    codec: 'avc1.640033',
  })

  it('reads frames per second from two looks, and says what the stream and canvas are', () => {
    expect(diagnosticLines(stats(10, 12), stats(40, 42), 1, 1, false)).toEqual([
      'shown 30.0 fps · arriving 30.0 fps',
      'decode 3 ms (p95 9 ms) · hardware yes',
      'touch → picture 95 ms (last 95 ms)',
      'dropped 1 · restarts 0',
      'stream 1206×2622 → canvas 355×772 @1x · avc1.640033',
    ])
  })

  it('says it is paused while the window is hidden, and shows dashes before it has two looks', () => {
    expect(diagnosticLines(null, stats(0, 0), 0, 2, true)[0]).toBe('paused — window hidden')
    expect(diagnosticLines(null, stats(0, 0), 0, 2, false)[0]).toBe('shown – fps · arriving – fps')
  })
})
