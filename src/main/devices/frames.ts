/**
 * The device engine's wire format, as two pure functions.
 *
 * ## Whose format this is
 *
 * The phone and simulator screens are driven by SimView's native engine
 * (`simview-core`, from the `@toolingtools/simview` package, Apache-2.0), which
 * this app ships as a dependency rather than re-implementing. Capturing an iOS
 * Simulator's screen and injecting touches into it go through private Apple
 * frameworks, and Android goes through an agent pushed over adb — both are a
 * year of somebody else's careful work, and redoing them here would be a second,
 * worse copy of it.
 *
 * What is written *here* is the client: this file and `core-client.ts` speak
 * the engine's documented protocol (`docs/protocol.md` in that project) from
 * this app's own main process. No code was copied from the engine's TypeScript
 * client; the frame layout below is a fact about the protocol, not anybody's
 * expression of it.
 *
 * ## The layout
 *
 * Every frame is a one-byte kind, a four-byte big-endian length, and that many
 * bytes. A socket delivers bytes in whatever pieces it likes — two frames in one
 * read, one frame across three — so the decoder keeps what it has not used yet
 * and only ever hands back whole frames.
 */

/** What the first byte of a frame says it carries. */
export const FRAME = {
  request: 0x01,
  response: 0x02,
  /** H.264 decoder configuration. Never asked for — this app reads JPEG. */
  h264Config: 0x10,
  h264Data: 0x11,
  /** One whole JPEG picture of the screen. */
  jpeg: 0x12,
  /** One whole PNG, the answer to a screenshot request. */
  png: 0x20,
} as const

/**
 * The largest payload the engine will send, from its own documentation.
 *
 * A length above this is not a big frame, it is a desynchronised stream — four
 * bytes of a JPEG being read as a length — and the only honest thing to do with
 * one is to stop reading rather than allocate gigabytes on its say-so.
 */
export const MAX_FRAME_BYTES = 64 * 1024 * 1024

const HEADER = 5

export interface Frame {
  kind: number
  payload: Buffer
}

/** One frame, ready to write. */
export function encodeFrame(kind: number, payload: Buffer): Buffer {
  const head = Buffer.alloc(HEADER)
  head[0] = kind
  head.writeUInt32BE(payload.length, 1)
  return Buffer.concat([head, payload])
}

/**
 * Turns a stream of chunks into whole frames.
 *
 * A class because the leftover bytes between two reads are state, and the
 * state belongs to one connection. `push` throws on a length the protocol
 * forbids; the caller closes the connection, because nothing after a corrupt
 * header can be trusted to start on a frame boundary.
 */
export class FrameReader {
  private pending: Buffer = Buffer.alloc(0)

  push(chunk: Buffer): Frame[] {
    this.pending = this.pending.length === 0 ? chunk : Buffer.concat([this.pending, chunk])
    const frames: Frame[] = []
    while (this.pending.length >= HEADER) {
      const length = this.pending.readUInt32BE(1)
      if (length > MAX_FRAME_BYTES) {
        this.pending = Buffer.alloc(0)
        throw new Error(`The device engine sent a frame of ${length} bytes, which it never should.`)
      }
      if (this.pending.length < HEADER + length) break
      // A copy, not a view. A view would pin the whole receive buffer — every
      // frame behind it — for as long as anybody holds this one picture.
      const payload = Buffer.from(this.pending.subarray(HEADER, HEADER + length))
      frames.push({ kind: this.pending[0], payload })
      this.pending = this.pending.subarray(HEADER + length)
    }
    return frames
  }
}
