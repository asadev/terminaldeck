import { deflateSync } from 'node:zlib'
import { describe, expect, it } from 'vitest'
import { decodePngDataUrl, markedName, readPngSize } from './marked-image'

/**
 * The door a marked-up screenshot comes through.
 *
 * The bytes are composed in the renderer — the main process has no way to draw a
 * line — and they end up in the user's Pictures folder. Every rule below is one
 * that has to fail here rather than in that folder.
 */

/** A real, minimal PNG: signature, IHDR, one IDAT, IEND. */
function png(width: number, height: number): Buffer {
  const chunk = (type: string, body: Buffer): Buffer => {
    const head = Buffer.alloc(8)
    head.writeUInt32BE(body.length, 0)
    head.write(type, 4, 'latin1')
    // The CRC is not checked by anything under test; four zero bytes keep the
    // chunk the right length, which is what the reader navigates by.
    return Buffer.concat([head, body, Buffer.alloc(4)])
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 6 // truecolour with alpha
  const pixels = Buffer.alloc(height * (width * 4 + 1))
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(pixels)),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

function dataUrl(bytes: Buffer): string {
  return `data:image/png;base64,${bytes.toString('base64')}`
}

describe('reading a PNG’s own size', () => {
  it('reads width and height out of the IHDR', () => {
    expect(readPngSize(png(2048, 1280))).toEqual({ width: 2048, height: 1280 })
  })

  it('refuses anything without the PNG signature', () => {
    const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(40)])
    expect(readPngSize(jpeg)).toBeNull()
  })

  it('refuses a PNG whose first chunk is not IHDR', () => {
    const bytes = png(10, 10)
    bytes.write('IDAT', 12, 'latin1')
    expect(readPngSize(bytes)).toBeNull()
  })

  it('refuses a file too short to hold a header', () => {
    expect(readPngSize(Buffer.from([0x89, 0x50, 0x4e, 0x47]))).toBeNull()
  })
})

describe('decoding what the renderer sent', () => {
  it('accepts the exact string a canvas toDataURL produces', () => {
    const decoded = decodePngDataUrl(dataUrl(png(1600, 900)))
    expect(decoded?.width).toBe(1600)
    expect(decoded?.height).toBe(900)
  })

  it('reports the size the FILE claims, never the one the caller claimed', () => {
    // The renderer passes no dimensions at all, and this is why: the popup, the
    // agent's prompt and the folder listing all have to agree with the bytes.
    const decoded = decodePngDataUrl(dataUrl(png(3, 7)))
    expect(decoded).toEqual({ bytes: expect.any(Buffer), width: 3, height: 7 })
  })

  it('refuses a media type that is not PNG', () => {
    expect(decodePngDataUrl(`data:image/jpeg;base64,${png(4, 4).toString('base64')}`)).toBeNull()
    expect(decodePngDataUrl(`data:text/html;base64,${png(4, 4).toString('base64')}`)).toBeNull()
  })

  it('refuses a PNG media type wrapped round something that is not a PNG', () => {
    // The media type is part of the string being validated, so it asserts
    // nothing. The signature is the file saying what it is.
    const html = Buffer.from('<script>alert(1)</script>')
    expect(decodePngDataUrl(`data:image/png;base64,${html.toString('base64')}`)).toBeNull()
  })

  it('refuses characters base64 does not have', () => {
    expect(decodePngDataUrl('data:image/png;base64,../../etc/passwd')).toBeNull()
    expect(decodePngDataUrl('data:image/png;base64,')).toBeNull()
  })

  it('refuses anything that is not a string', () => {
    for (const value of [null, undefined, 42, {}, [], Buffer.alloc(4)]) {
      expect(decodePngDataUrl(value)).toBeNull()
    }
  })

  it('refuses a payload larger than any screenshot, without decoding it', () => {
    // The length check is on the base64 rather than on the result, so a renderer
    // bug cannot make the main process materialise hundreds of megabytes before
    // it is turned down.
    const huge = `data:image/png;base64,${'A'.repeat(4 * Math.ceil((64 * 1024 * 1024) / 3) + 8)}`
    expect(decodePngDataUrl(huge)).toBeNull()
  })
})

describe('what a marked capture is called', () => {
  it('is the plain screenshot’s name with -marked before the extension', () => {
    expect(markedName('localhost-3000-20260817-041530.png')).toBe(
      'localhost-3000-20260817-041530-marked.png',
    )
  })

  it('never loses the extension, whatever it was handed', () => {
    expect(markedName('page')).toBe('page-marked.png')
  })
})
