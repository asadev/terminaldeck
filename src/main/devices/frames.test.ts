import { describe, expect, it } from 'vitest'
import { encodeFrame, FRAME, FrameReader, MAX_FRAME_BYTES } from './frames'

describe('the device engine frame format', () => {
  it('round-trips a frame', () => {
    const wire = encodeFrame(FRAME.response, Buffer.from('{"id":"1"}'))
    expect(wire[0]).toBe(FRAME.response)
    expect(wire.readUInt32BE(1)).toBe(10)
    const frames = new FrameReader().push(wire)
    expect(frames).toHaveLength(1)
    expect(frames[0].kind).toBe(FRAME.response)
    expect(frames[0].payload.toString()).toBe('{"id":"1"}')
  })

  it('waits for the rest of a frame split across reads, one byte at a time', () => {
    // A socket may hand over a frame in any pieces at all; the engine's own
    // documentation says so, and a JPEG of a few hundred kilobytes always
    // arrives in many.
    const wire = encodeFrame(FRAME.jpeg, Buffer.alloc(300, 7))
    const reader = new FrameReader()
    const seen = []
    for (let i = 0; i < wire.length; i++) seen.push(...reader.push(wire.subarray(i, i + 1)))
    expect(seen).toHaveLength(1)
    expect(seen[0].payload.length).toBe(300)
  })

  it('hands back every frame when several arrive in one read', () => {
    const wire = Buffer.concat([
      encodeFrame(FRAME.response, Buffer.from('a')),
      encodeFrame(FRAME.jpeg, Buffer.from('bb')),
      encodeFrame(FRAME.png, Buffer.from('ccc')),
    ])
    const frames = new FrameReader().push(wire)
    expect(frames.map((f) => [f.kind, f.payload.toString()])).toEqual([
      [FRAME.response, 'a'],
      [FRAME.jpeg, 'bb'],
      [FRAME.png, 'ccc'],
    ])
  })

  it('keeps a frame’s bytes after the reader has moved on', () => {
    const reader = new FrameReader()
    const [first] = reader.push(encodeFrame(FRAME.jpeg, Buffer.from('first')))
    reader.push(encodeFrame(FRAME.jpeg, Buffer.from('second')))
    expect(first.payload.toString()).toBe('first')
  })

  it('refuses a length the protocol forbids instead of allocating it', () => {
    const head = Buffer.alloc(5)
    head[0] = FRAME.jpeg
    head.writeUInt32BE(MAX_FRAME_BYTES + 1, 1)
    expect(() => new FrameReader().push(head)).toThrow(/never should/)
  })
})
