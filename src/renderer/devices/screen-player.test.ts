import { describe, expect, it } from 'vitest'
import {
  backingSize,
  codecOf,
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
}

function env(rec: Recorder): PlayerEnv {
  class FakeDecoder {
    state: CodecState = 'unconfigured'
    constructor(init: VideoDecoderInit) {
      rec.output = init.output
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
    requestAnimationFrame: (callback) => {
      callback()
      return 1
    },
    cancelAnimationFrame: () => undefined,
    now: () => Date.now(),
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

function frame(width: number, height: number): VideoFrame {
  return { displayWidth: width, displayHeight: height, close: () => undefined } as unknown as VideoFrame
}

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
