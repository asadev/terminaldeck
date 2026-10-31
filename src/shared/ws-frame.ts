/**
 * RFC 6455 framing, in the boring subset this project uses.
 *
 * This was inside `main/remote/server.ts` until the relay needed it too. A
 * relay that shuffles frames between a Mac and a phone has to decode what the
 * client masked and re-encode it unmasked for the other side, so it needs the
 * same parser the app already had — and a second implementation of WebSocket
 * framing in one repository is a promise that the two will disagree eventually,
 * on a Tuesday, over a fragmented control frame.
 *
 * The subset is deliberate and unchanged from the original: text frames,
 * continuations, ping/pong and close. No extensions, no compression. Binary
 * frames are refused by callers rather than here — the parser reports the
 * opcode it saw and lets the layer with an opinion have it.
 *
 * ## Why the reader is a class and not a callback soup
 *
 * TCP hands you arbitrary slices. A frame header can arrive split across two
 * `data` events, and the 8-byte extended length can arrive one byte at a time.
 * The reader therefore owns a buffer, and `push` returns only the frames that
 * are *complete*, leaving the remainder for the next chunk. Every early return
 * in the loop below is "not enough bytes yet", not an error.
 *
 * ## No node built-ins beyond Buffer and crypto
 *
 * `Buffer` is used because both consumers are Node. Unlike `protocol.ts` this
 * file is never imported by the PWA, so that constraint does not apply here.
 */

import { createHash, randomBytes } from 'node:crypto'

/** The magic string from RFC 6455 §1.3. Not a secret, just a constant. */
export const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

export function acceptKey(key: string): string {
  return createHash('sha1')
    .update(key + WS_GUID)
    .digest('base64')
}

export const OPCODE = {
  continuation: 0x0,
  text: 0x1,
  binary: 0x2,
  close: 0x8,
  ping: 0x9,
  pong: 0xa,
} as const

/** Server frames are never masked (RFC 6455 §5.1); client frames always are. */
export function encodeFrame(opcode: number, payload: Buffer): Buffer {
  return frame(opcode, payload, null)
}

/**
 * The same frame, masked, for the end of a connection that dialled out.
 *
 * The Mac's link to the relay is a *client* connection, and §5.3 makes masking
 * mandatory there — an unmasked client frame is a protocol error the relay is
 * required to refuse, and refusing it is exactly what `FrameReader('server')`
 * does. So this is not an option or a hardening measure; it is the only way a
 * frame leaves this process towards a server.
 *
 * The key is four bytes from the CSPRNG per frame, as the RFC asks. Masking is
 * not encryption and buys nothing against an eavesdropper — it exists so that a
 * client cannot be tricked into emitting attacker-chosen bytes that a broken
 * intermediary would read as a second HTTP request. Everything that matters is
 * sealed underneath it.
 */
export function encodeMaskedFrame(opcode: number, payload: Buffer): Buffer {
  return frame(opcode, payload, randomBytes(4))
}

function frame(opcode: number, payload: Buffer, mask: Buffer | null): Buffer {
  const length = payload.length
  let header: Buffer
  if (length < 126) {
    header = Buffer.alloc(2)
    header[1] = length
  } else if (length < 65536) {
    header = Buffer.alloc(4)
    header[1] = 126
    header.writeUInt16BE(length, 2)
  } else {
    header = Buffer.alloc(10)
    header[1] = 127
    header.writeBigUInt64BE(BigInt(length), 2)
  }
  header[0] = 0x80 | opcode
  if (!mask) return Buffer.concat([header, payload])

  header[1] |= 0x80
  // Copied rather than masked in place: the caller owns `payload`, and one of
  // them is a slice of a buffer the sealed transport still holds.
  const masked = Buffer.from(payload)
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i & 3]
  return Buffer.concat([header, mask, masked])
}

/**
 * A frame as it came off the wire, already unmasked.
 *
 * `fin` and `opcode` are reported rather than resolved: reassembling a
 * fragmented message is a policy decision (how big may the whole be?) that
 * belongs to the caller, and the relay deliberately does not reassemble at all.
 */
export interface Frame {
  fin: boolean
  opcode: number
  payload: Buffer
}

/** Why the reader gave up. The caller turns this into a close code. */
export interface FrameError {
  reason: 'reserved-bits' | 'unmasked' | 'masked' | 'too-large'
  detail: string
}

/**
 * Frames always come back, error or not.
 *
 * A chunk can carry three good frames and then a malformed fourth. The original
 * parser inside the server delivered the good ones and *then* failed the
 * connection, and that ordering is load-bearing: the last thing a client sends
 * before it trips a protocol error is often the thing that explains why. So the
 * failure case carries `frames` too, and the caller delivers them before it
 * acts on `error`.
 */
export type FrameBatch =
  | { ok: true; frames: Frame[] }
  | { ok: false; frames: Frame[]; error: FrameError }

/**
 * Which side of the connection this reader is on.
 *
 * RFC 6455 §5.1 makes masking directional and mandatory both ways: a client
 * MUST mask every frame it sends, and a server MUST NOT mask any. So a reader
 * has to know which it is, and the wrong answer is not a lenient parse — it is
 * a parser that rejects every legitimate frame.
 *
 * That is not hypothetical. The first version of this class hard-coded the
 * server's rule, which was correct for the app's own listener and silently
 * unusable for the Mac's outbound connection to the relay: every frame the
 * relay sent back came in unmasked and was refused as a protocol violation.
 *
 * Both directions are enforced rather than merely tolerated. Accepting an
 * unmasked client frame is the classic cache-poisoning hole; accepting a masked
 * server frame is harmless but means we are talking to something that is not
 * following the spec, which is worth knowing early.
 */
export type FrameSide = 'server' | 'client'

/**
 * Incremental frame parser.
 *
 * `maxFrameBytes` is checked against the *declared* length before the payload
 * is buffered. The point of a cap is not to hold the memory in the first place,
 * so a peer announcing a gigabyte is closed while its header is still the only
 * thing we have read.
 */
export class FrameReader {
  private incoming: Buffer = Buffer.alloc(0)
  private readonly expectMask: boolean

  /**
   * @param side which end this reader is. `'server'` reads frames from clients
   *   and therefore requires them masked; `'client'` reads frames from a server
   *   and requires them unmasked. Defaults to `'server'`, which is what the
   *   app's own listener wants and what this class did before it had a choice.
   */
  constructor(
    private readonly maxFrameBytes: number,
    side: FrameSide = 'server',
  ) {
    this.expectMask = side === 'server'
  }

  /** Drop buffered bytes. Called when a connection ends mid-frame. */
  reset(): void {
    this.incoming = Buffer.alloc(0)
  }

  push(chunk: Buffer): FrameBatch {
    this.incoming = this.incoming.length === 0 ? chunk : Buffer.concat([this.incoming, chunk])
    const frames: Frame[] = []

    for (;;) {
      const buf = this.incoming
      if (buf.length < 2) return { ok: true, frames }

      const first = buf[0]
      const second = buf[1]
      if ((first & 0x70) !== 0) {
        return { ok: false, frames, error: { reason: 'reserved-bits', detail: 'reserved bits set' } }
      }

      const fin = (first & 0x80) !== 0
      const opcode = first & 0x0f
      const masked = (second & 0x80) !== 0
      if (masked !== this.expectMask) {
        return this.expectMask
          ? { ok: false, frames, error: { reason: 'unmasked', detail: 'client frame was not masked' } }
          : { ok: false, frames, error: { reason: 'masked', detail: 'server frame was masked' } }
      }

      let length = second & 0x7f
      let offset = 2
      if (length === 126) {
        if (buf.length < offset + 2) return { ok: true, frames }
        length = buf.readUInt16BE(offset)
        offset += 2
      } else if (length === 127) {
        if (buf.length < offset + 8) return { ok: true, frames }
        const wide = buf.readBigUInt64BE(offset)
        offset += 8
        // Compared as BigInt: a 2^63 length would round to a plausible Number.
        if (wide > BigInt(this.maxFrameBytes)) {
          return { ok: false, frames, error: { reason: 'too-large', detail: 'frame too large' } }
        }
        length = Number(wide)
      }
      if (length > this.maxFrameBytes) {
        return { ok: false, frames, error: { reason: 'too-large', detail: 'frame too large' } }
      }

      // The 4-byte masking key is present only on masked frames, so it is part
      // of the length calculation rather than a constant. Assuming it is always
      // there reads the first four payload bytes as a key and shifts everything.
      const keyBytes = masked ? 4 : 0
      const total = offset + keyBytes + length
      if (buf.length < total) return { ok: true, frames }

      const payload = Buffer.from(buf.subarray(offset + keyBytes, total))
      if (masked) {
        const mask = buf.subarray(offset, offset + keyBytes)
        for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i & 3]
      }

      this.incoming = buf.subarray(total)
      frames.push({ fin, opcode, payload })
    }
  }
}

/**
 * The `Sec-WebSocket-Accept` handshake response, minus the status line.
 *
 * Shared so the relay and the app cannot drift on the header set. Nothing here
 * negotiates an extension, because neither side implements one and echoing a
 * `Sec-WebSocket-Extensions` we do not honour would be worse than silence.
 */
export function handshakeResponse(key: string): string {
  return (
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${acceptKey(key)}\r\n` +
    '\r\n'
  )
}
