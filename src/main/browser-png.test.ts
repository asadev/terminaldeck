import { inflateSync } from 'node:zlib'
import { describe, expect, it } from 'vitest'
import { bitmapShape, encodeRgbaPng, maskFrame, paintMasks, type RawFrame } from './browser-png'

/**
 * The arithmetic that decides whether a password is still legible in a PNG —
 * which is exactly the kind of defect nobody notices by looking, and exactly the
 * kind a sentinel value catches — plus the encoder those masks are written
 * through. No Electron: these are pure functions over a `Buffer`, which is the
 * whole reason they were lifted out of the driver.
 */

/** A colour nothing else in the buffer uses, so finding it means the mask missed. */
const SENTINEL_A = 0xff
const SENTINEL_C = 0xee

function canvas(width: number, height: number, scale: number): Buffer {
  return Buffer.alloc(width * scale * height * scale * 4, 0x11)
}

function paintSentinel(
  bitmap: Buffer,
  pixelWidth: number,
  rect: { x: number; y: number; width: number; height: number },
  scale: number,
): void {
  for (let y = rect.y * scale; y < (rect.y + rect.height) * scale; y++) {
    for (let x = rect.x * scale; x < (rect.x + rect.width) * scale; x++) {
      const at = (y * pixelWidth + x) * 4
      bitmap[at] = SENTINEL_A
      bitmap[at + 1] = SENTINEL_A
      bitmap[at + 2] = SENTINEL_C
      bitmap[at + 3] = 0xff
    }
  }
}

describe('a password is painted out before the file exists', () => {
  it('covers every pixel of the field, at a retina scale factor', () => {
    /*
     * The scale factor is where this goes wrong quietly. The rectangles arrive
     * in CSS pixels from the page and the buffer is in device pixels, so a
     * driver that forgot the ratio would paint a grey square over the top-left
     * quarter of the field on a Retina display and leave the rest of the
     * password perfectly readable — in a picture that *looks* redacted.
     */
    const scale = 2
    const size = { width: 200, height: 100 }
    const pixelWidth = size.width * scale
    const bitmap = canvas(size.width, size.height, scale)
    const field = { x: 20, y: 30, width: 120, height: 24 }
    paintSentinel(bitmap, pixelWidth, field, scale)

    /*
     * The viewport is 200 CSS pixels wide and the image is 400 device pixels
     * wide, so a device pixel is half a CSS pixel. Deriving that from the
     * buffer's own length instead — which is what this did first — answers 1,
     * because the frame's size and its buffer are both device measurements. The
     * mask then landed at half the offset and half the size: a grey bar above
     * the form and a legible password box below it, in a picture that looked
     * redacted. Caught by looking at the picture.
     */
    const viewport = { width: size.width, height: size.height }
    const shape = bitmapShape({ width: pixelWidth, height: 200 }, bitmap.length, viewport)
    expect(shape).toEqual({ pixelWidth: 400, pixelHeight: 200, scale: 2, viewport })
    const painted = paintMasks(bitmap, shape!, [field])
    expect(painted).toBe(1)

    let survivors = 0
    for (let i = 0; i < bitmap.length; i += 4) {
      if (bitmap[i] === SENTINEL_A && bitmap[i + 2] === SENTINEL_C) survivors++
    }
    expect(survivors).toBe(0)
  })

  it('paints the whole field even when its box lands between device pixels', () => {
    // Sub-pixel geometry is the ordinary case, not the edge case: a field at a
    // fractional offset is what a CSS layout produces. Rounding inward here
    // would leave a one-pixel band of the password along an edge.
    const scale = 2
    const size = { width: 100, height: 50 }
    const bitmap = canvas(size.width, size.height, scale)
    const shape = bitmapShape({ width: size.width * scale, height: size.height * scale }, bitmap.length, size)!
    const painted = paintMasks(bitmap, shape, [{ x: 10.4, y: 5.6, width: 30.3, height: 12.7 }])
    expect(painted).toBe(1)
    // The mask must start no later than floor(10.4*2)=20 and end no earlier
    // than ceil((10.4+30.3)*2)=82.
    const row = 12 * shape.pixelWidth * 4
    expect(bitmap[row + 20 * 4]).toBe(0x80)
    expect(bitmap[row + 81 * 4]).toBe(0x80)
  })

  it('does not paint a rectangle that is entirely off the page', () => {
    const size = { width: 100, height: 50 }
    const bitmap = canvas(size.width, size.height, 1)
    const shape = bitmapShape(size, bitmap.length, size)!
    expect(paintMasks(bitmap, shape, [{ x: 500, y: 500, width: 10, height: 10 }])).toBe(0)
    expect(paintMasks(bitmap, shape, [{ x: 0, y: 0, width: 0, height: 0 }])).toBe(0)
  })

  it('refuses the whole picture when the buffer is not the shape it expected', () => {
    /*
     * Returning the unmasked image is the single outcome this path exists to
     * prevent, so an arithmetic surprise throws rather than degrading. A
     * screenshot that never appears is a bug report; one that appears with the
     * password in it is not noticed at all.
     */
    expect(() =>
      bitmapShape({ width: 100, height: 50 }, 100 * 50 * 4 + 17, { width: 100, height: 50 }),
    ).toThrow(/could not be masked/)
  })

  it('answers null for an image with no pixels rather than pretending', () => {
    expect(bitmapShape({ width: 0, height: 0 }, 0, { width: 100, height: 50 })).toBeNull()
  })

  it('refuses the picture when the page could not say how wide its viewport is', () => {
    // A default of 1 would be right on some machines and would mis-place every
    // mask on a Retina display, silently. Refusing is the only honest answer.
    expect(() => bitmapShape({ width: 100, height: 50 }, 100 * 50 * 4, { width: 0, height: 0 })).toThrow(
      /could not be masked/,
    )
  })

  it('refuses a scale that could not be real', () => {
    // A viewport reported mid-resize, or a number somebody made up. Sixteen
    // device pixels to a CSS pixel is not a display, it is a mistake.
    expect(() => bitmapShape({ width: 1600, height: 800 }, 1600 * 800 * 4, { width: 100, height: 50 })).toThrow(
      /could not be masked/,
    )
  })
})

/**
 * The PNG the mask is written through. A tightly packed RGBA buffer, encoded and
 * then read straight back out with nothing but an `inflate` — which is what
 * filter type 0 buys, and what proves the pixels made the round trip unaltered.
 */
function decodeRgbaPng(png: Buffer): { width: number; height: number; data: Buffer } {
  const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  expect(png.subarray(0, 8).equals(SIGNATURE)).toBe(true)

  let width = 0
  let height = 0
  const idat: Buffer[] = []
  let offset = 8
  while (offset < png.length) {
    const length = png.readUInt32BE(offset)
    const type = png.toString('ascii', offset + 4, offset + 8)
    const payload = png.subarray(offset + 8, offset + 8 + length)
    if (type === 'IHDR') {
      width = payload.readUInt32BE(0)
      height = payload.readUInt32BE(4)
      expect(payload[8]).toBe(8) // bit depth
      expect(payload[9]).toBe(6) // colour type 6: RGBA
    } else if (type === 'IDAT') {
      idat.push(Buffer.from(payload))
    }
    offset += 12 + length
  }

  const raster = inflateSync(Buffer.concat(idat))
  const rowBytes = width * 4
  const data = Buffer.alloc(height * rowBytes)
  for (let y = 0; y < height; y++) {
    // The filter byte in front of each scanline is "none" (0), so the pixels
    // that follow are the pixels that went in.
    expect(raster[y * (rowBytes + 1)]).toBe(0)
    raster.copy(data, y * rowBytes, y * (rowBytes + 1) + 1, y * (rowBytes + 1) + 1 + rowBytes)
  }
  return { width, height, data }
}

describe('encoding a frame as a PNG', () => {
  it('round-trips a known RGBA buffer byte for byte', () => {
    const width = 3
    const height = 2
    const data = Buffer.alloc(width * height * 4)
    for (let i = 0; i < data.length; i++) data[i] = (i * 7 + 3) & 0xff
    const decoded = decodeRgbaPng(encodeRgbaPng(data, width, height))
    expect(decoded.width).toBe(width)
    expect(decoded.height).toBe(height)
    expect(decoded.data.equals(data)).toBe(true)
  })

  it('refuses a buffer whose length disagrees with the size, rather than lying', () => {
    expect(() => encodeRgbaPng(Buffer.alloc(3 * 2 * 4 - 1), 3, 2)).toThrow(/could not be encoded/)
    expect(() => encodeRgbaPng(Buffer.alloc(0), 0, 0)).toThrow(/could not be encoded/)
  })
})

describe('masking a whole captured frame', () => {
  it('paints the secret rect out and encodes a readable PNG', () => {
    const scale = 2
    const size = { width: 40, height: 20 }
    const frame: RawFrame = {
      data: canvas(size.width, size.height, scale),
      width: size.width * scale,
      height: size.height * scale,
      scale,
    }
    const field = { x: 5, y: 4, width: 10, height: 6 }
    paintSentinel(frame.data, frame.width, field, scale)

    const { png, painted } = maskFrame(frame, [field], size)
    expect(painted).toBe(1)

    // The sentinel is gone from the raw buffer before the encode…
    let survivors = 0
    for (let i = 0; i < frame.data.length; i += 4) {
      if (frame.data[i] === SENTINEL_A && frame.data[i + 2] === SENTINEL_C) survivors++
    }
    expect(survivors).toBe(0)

    // …and the encoded PNG decodes back to that same masked buffer.
    const decoded = decodeRgbaPng(png)
    expect(decoded.width).toBe(frame.width)
    expect(decoded.height).toBe(frame.height)
    expect(decoded.data.equals(frame.data)).toBe(true)
    // A pixel inside the masked field — the field is CSS (5,4)+(10×6) at scale
    // 2, so device x∈[10,30), y∈[8,20) — is opaque mid-grey.
    const at = (12 * frame.width + 20) * 4
    expect([decoded.data[at], decoded.data[at + 1], decoded.data[at + 2], decoded.data[at + 3]]).toEqual([
      0x80, 0x80, 0x80, 0xff,
    ])
  })

  it('encodes an untouched frame when there is nothing to mask', () => {
    const frame: RawFrame = { data: canvas(8, 8, 1), width: 8, height: 8, scale: 1 }
    const { png, painted } = maskFrame(frame, [], { width: 8, height: 8 })
    expect(painted).toBe(0)
    const decoded = decodeRgbaPng(png)
    expect(decoded.data.equals(frame.data)).toBe(true)
  })
})
