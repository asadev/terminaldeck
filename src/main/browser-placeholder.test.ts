import { inflateSync } from 'node:zlib'
import { beforeEach, describe, expect, it } from 'vitest'
import {
  crc32,
  forgetPlaceholders,
  MAX_PLACEHOLDER_SIDE,
  placeholderPng,
} from './browser-placeholder'

/**
 * The placeholder, decoded rather than looked at.
 *
 * There is no image decoder in this repository and Node has none, so "does
 * Chromium render this" cannot be asserted here. What *can* be asserted is
 * everything a decoder would check before it rendered anything: the signature,
 * the chunk CRCs, the IHDR fields, the transparency chunk, and — by inflating
 * the IDAT and reading the raster back — that the pixels really are the
 * dimensions the page will be told they are. A PNG that passes all of that is a
 * PNG.
 *
 * The one thing this cannot catch is a decoder that dislikes greyscale plus
 * `tRNS`, which is why that choice is argued from the spec in
 * `browser-placeholder.ts` rather than from taste.
 */

/** Walk the chunks, checking every CRC on the way. */
function chunks(png: Buffer): { type: string; data: Buffer }[] {
  expect([...png.subarray(0, 8)]).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  const out: { type: string; data: Buffer }[] = []
  let at = 8
  while (at < png.length) {
    const length = png.readUInt32BE(at)
    const type = png.subarray(at + 4, at + 8).toString('ascii')
    const data = png.subarray(at + 8, at + 8 + length)
    const stated = png.readUInt32BE(at + 8 + length)
    expect(crc32(png.subarray(at + 4, at + 8 + length)), `${type} CRC`).toBe(stated)
    out.push({ type, data })
    at += 12 + length
  }
  return out
}

describe('the image a cheaply-answered request is given', () => {
  beforeEach(() => forgetPlaceholders())

  it('is a valid PNG of exactly the size the page expects', () => {
    const made = placeholderPng(1200, 800)
    expect(made.width).toBe(1200)
    expect(made.height).toBe(800)
    expect(made.clamped).toBe(false)

    const parts = chunks(made.png)
    expect(parts.map((part) => part.type)).toEqual(['IHDR', 'tRNS', 'IDAT', 'IEND'])

    const ihdr = parts[0].data
    expect(ihdr.readUInt32BE(0)).toBe(1200)
    expect(ihdr.readUInt32BE(4)).toBe(800)
    expect(ihdr[8]).toBe(8) // eight bits per sample
    expect(ihdr[9]).toBe(0) // greyscale
    expect(ihdr[12]).toBe(0) // not interlaced
  })

  it('is fully transparent, and says so in the one chunk that can', () => {
    // Grey level 0 declared transparent, and every pixel in the raster is 0.
    const parts = chunks(placeholderPng(64, 48).png)
    const trns = parts.find((part) => part.type === 'tRNS')!
    expect(trns.data.readUInt16BE(0)).toBe(0)

    const raster = inflateSync(parts.find((part) => part.type === 'IDAT')!.data)
    // One filter byte per scanline, then one byte per pixel.
    expect(raster.length).toBe(48 * (64 + 1))
    for (let y = 0; y < 48; y += 1) {
      expect(raster[y * 65], `filter byte on row ${y}`).toBe(0)
    }
    expect(raster.every((byte) => byte === 0)).toBe(true)
  })

  /*
   * The reason the whole file exists rather than a one-line data URL: a 1×1 is
   * what breaks `naturalWidth`-gated lazy-loading, so it is only ever the
   * answer when nothing states a size — and it must still be a real image when
   * it is.
   */
  it('is a real one-pixel image when nothing states a size', () => {
    const made = placeholderPng(1, 1)
    expect(made.width).toBe(1)
    expect(made.height).toBe(1)
    const parts = chunks(made.png)
    expect(parts[0].data.readUInt32BE(0)).toBe(1)
    expect(inflateSync(parts.find((part) => part.type === 'IDAT')!.data).length).toBe(2)
  })

  it('stays small however large the picture the page thinks it received', () => {
    // An all-zero raster deflates to nothing much, which is the property that
    // makes "hand the page a 1920×1080 image" cost no bandwidth at all.
    const made = placeholderPng(1920, 1080)
    expect(made.png.length).toBeLessThan(8_000)
  })

  it('clamps a size a website made up, and reports that it did', () => {
    // `width` is an author-supplied attribute and nothing validates it, so
    // without this a single `<img width="200000">` sizes a Buffer.alloc in the
    // main process.
    const made = placeholderPng(200_000, 3)
    expect(made.width).toBe(MAX_PLACEHOLDER_SIDE)
    expect(made.clamped).toBe(true)
    expect(chunks(made.png)[0].data.readUInt32BE(0)).toBe(MAX_PLACEHOLDER_SIDE)
  })

  /*
   * A number that is not a size collapses to 1, including `Infinity` — which is
   * not "unboundedly large" but "the page said something that is not a
   * measurement". `readSizeHint` refuses non-finite numbers one layer up, so
   * the real path never reaches here with one; both layers agree that the
   * answer is the 1×1 fallback rather than a made-up 4096.
   */
  it.each([
    [0, 1],
    [-40, 1],
    [Number.NaN, 1],
    [Number.POSITIVE_INFINITY, 1],
    [12.7, 12],
    [MAX_PLACEHOLDER_SIDE + 1, MAX_PLACEHOLDER_SIDE],
  ])('turns a size of %s into %i', (given, expected) => {
    expect(placeholderPng(given, given).width).toBe(expected)
  })

  it('builds one image per distinct size and hands the same bytes back', () => {
    const first = placeholderPng(300, 200)
    const second = placeholderPng(300, 200)
    expect(second.png).toBe(first.png)
    expect(placeholderPng(200, 300).png).not.toBe(first.png)
  })

  it('computes the CRC every PNG decoder checks', () => {
    // The known value for "IEND", which every PNG on disk ends with. A wrong
    // polynomial produces a file that looks right and decodes to nothing.
    expect(crc32(Buffer.from('IEND', 'ascii'))).toBe(0xae426082)
  })
})
