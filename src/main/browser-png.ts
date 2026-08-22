import { deflateSync } from 'node:zlib'

/**
 * Painting secrets out of a captured frame, and writing the result as a PNG,
 * with no Electron anywhere in the file.
 *
 * ## Why this lives on its own now
 *
 * The masking used to sit in `browser-driver.ts` and finish through
 * `nativeImage.createFromBitmap(...).toPNG()` — an Electron call, on an Electron
 * `NativeImage`, in the one module the headless server most needs to run. Route
 * B gives that server a real headless Chromium of its own and drives it over
 * CDP, so the driver had to stop importing Electron; the two things it did with
 * `nativeImage` were *lay grey rectangles over a raw buffer* and *turn that
 * buffer into a PNG*, and neither of those needs a browser to be running. Both
 * are arithmetic over a `Buffer`, and both are here.
 *
 * The encode is the discipline `browser-placeholder.ts` already uses — a PNG
 * assembled by hand out of `node:zlib`'s `deflateSync`, because that is the one
 * image primitive both runtimes share. Under Electron a captured frame arrives
 * as `NativeImage.toBitmap()` (see `browser-driven-electron.ts`, which converts
 * it to the `RawFrame` this file speaks); under headless Chromium it arrives as
 * `Page.captureScreenshot` decoded to RGBA. Either way what reaches here is a
 * flat RGBA buffer and a size, and the masking and the encoding are identical.
 *
 * ## The one property this file exists to keep true
 *
 * A password must be gone from the pixels *before* the PNG exists. So the mask
 * is painted in place on the raw buffer and only then is the buffer encoded —
 * there is never a moment at which an unmasked PNG is in a buffer anything else
 * can read. And when the arithmetic that places a mask cannot be trusted — a
 * buffer that is not the shape it claims, a viewport a page would not report —
 * {@link bitmapShape} throws rather than degrading, because a screenshot that
 * never appears is a bug report and one that appears with a password in it is
 * not noticed at all.
 */

/* ------------------------------------------------------------- the frame -- */

/**
 * A captured page frame, transport-neutral.
 *
 * `data` is tightly packed RGBA — one byte each of red, green, blue and alpha,
 * row by row, `width * height * 4` bytes and no padding. `width`/`height` are
 * **device** pixels, the true resolution of the buffer; `scale` is how many of
 * those there are per CSS pixel, carried for a caller that wants to log it. The
 * masking does not trust `scale`: it re-derives the ratio from the viewport the
 * page reported, because a page can lie about its device pixel ratio and a
 * buffer cannot lie about its own length. See {@link bitmapShape}.
 */
export interface RawFrame {
  /** Tightly packed RGBA, `width * height * 4` bytes. */
  data: Buffer
  /** Device pixels. */
  width: number
  /** Device pixels. */
  height: number
  /** Device pixels per CSS pixel. Informational; the mask re-derives its own. */
  scale: number
}

/* --------------------------------------------------------------- the PNG -- */

/**
 * CRC-32, hand-rolled — the same fourteen lines `browser-placeholder.ts` keeps,
 * and for the same reason: `zlib.crc32` is a recent Node addition and this
 * cannot be wrong about which Node the Electron of the day bundles. Every PNG
 * chunk carries a CRC and a decoder may reject a chunk whose CRC is wrong, so
 * this is the difference between an image and a broken-image icon.
 */
const POLYNOMIAL = 0xedb88320

const CRC_TABLE = ((): Uint32Array => {
  const table = new Uint32Array(256)
  for (let n = 0; n < 256; n += 1) {
    let c = n
    for (let k = 0; k < 8; k += 1) c = c & 1 ? POLYNOMIAL ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }
  return table
})()

function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff
  for (let i = 0; i < bytes.length; i += 1) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

/** One PNG chunk: length, type, payload, CRC over type+payload. */
function chunk(type: string, payload: Uint8Array): Buffer {
  const head = Buffer.alloc(8)
  head.writeUInt32BE(payload.length, 0)
  head.write(type, 4, 'ascii')
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4, 8), payload])), 0)
  return Buffer.concat([head, payload, crc])
}

const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

/**
 * Encode a tightly packed RGBA buffer as a PNG.
 *
 * Colour type 6 (truecolour with alpha), 8 bits a channel, one "none" filter
 * byte per scanline — the simplest raster a spec-compliant decoder must read,
 * which is what makes it round-trippable with nothing more than an `inflate`.
 *
 * Throws when the buffer is not `width * height * 4` bytes, rather than emitting
 * a PNG whose dimensions and pixels disagree. This is the same direction
 * {@link bitmapShape} takes and for the same reason: a picture that is refused
 * is noticed, and a picture that is silently wrong is not.
 */
export function encodeRgbaPng(data: Buffer, width: number, height: number): Buffer {
  if (width <= 0 || height <= 0 || data.length !== width * height * 4) {
    throw new Error('the screenshot could not be encoded, so it was not written')
  }

  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 6 // colour type 6: truecolour with alpha
  ihdr[10] = 0 // deflate, the only compression PNG has
  ihdr[11] = 0 // adaptive filtering, the only filter method PNG has
  ihdr[12] = 0 // not interlaced

  /*
   * One filter byte (0, "none") in front of each scanline's pixels. A decoder
   * reading a filter-0 raster copies the bytes straight through, so what comes
   * back out of `inflate` is exactly this layout — which is what the round-trip
   * test relies on.
   */
  const rowBytes = width * 4
  const raster = Buffer.alloc(height * (rowBytes + 1))
  for (let y = 0; y < height; y += 1) {
    const src = y * rowBytes
    const dst = y * (rowBytes + 1) + 1
    data.copy(raster, dst, src, src + rowBytes)
  }
  const idat = deflateSync(raster)

  return Buffer.concat([
    SIGNATURE,
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

/* ------------------------------------------------------------- the mask -- */

export interface BitmapShape {
  pixelWidth: number
  pixelHeight: number
  /**
   * Device pixels per **CSS** pixel — the number that puts a mask on the
   * password field rather than a hundred pixels above it.
   *
   * This was wrong once, and the picture is what caught it. The first version
   * derived the scale from the buffer's own length against the frame's device
   * size, which is self-consistent and answers a different question: those two
   * are both in device pixels, so the ratio is always 1 and the rectangles —
   * which come from `getBoundingClientRect` and are in CSS pixels — were used
   * unscaled. On a Retina page the mask landed at half the offset and half the
   * size: a grey bar above the form, and a perfectly legible password box below
   * it, in an image that *looked* redacted.
   */
  scale: number
  /** What the image is scaled against. Reported so a caller can log it. */
  viewport: { width: number; height: number }
}

/**
 * How big the raw buffer actually is, in device pixels, and how it maps onto
 * the CSS pixels a rectangle is stated in.
 *
 * The device size is derived from the buffer's own length rather than trusted
 * from a device pixel ratio read out of the page, because the page can lie about
 * `devicePixelRatio` and the buffer cannot lie about how long it is. A mismatch
 * throws rather than falling back: emitting the unmasked image is the single
 * outcome this whole path exists to prevent, so refusing the picture is the safe
 * direction.
 *
 * Null when the image is empty, which is a caller's problem rather than a
 * masking failure.
 */
export function bitmapShape(
  size: { width: number; height: number },
  bytes: number,
  viewport: { width: number; height: number },
): BitmapShape | null {
  const pixels = bytes / 4
  if (size.width <= 0 || size.height <= 0 || pixels <= 0) return null

  /*
   * How many bytes the buffer really holds, against the size the frame claims.
   *
   * These are both device measurements, so the ratio is normally 1 — but it is
   * checked rather than assumed, because a buffer that is not width×height×4 is
   * one this arithmetic cannot index safely, and indexing it wrongly writes
   * grey pixels somewhere other than over the password.
   */
  const buffered = Math.sqrt(pixels / (size.width * size.height))
  if (!Number.isFinite(buffered) || buffered <= 0) return null
  const pixelWidth = Math.round(size.width * buffered)
  const pixelHeight = Math.round(size.height * buffered)
  if (pixelWidth * pixelHeight * 4 !== bytes) {
    throw new Error('the screenshot could not be masked, so it was not written')
  }

  /*
   * And the number that matters: device pixels per CSS pixel.
   *
   * Refused rather than guessed when the page could not report its viewport. A
   * default of 1 would be right on some machines and would silently mis-place
   * every mask on a Retina display, which is the failure this whole function
   * exists to prevent. The clamp catches a viewport that is absurd relative to
   * the image — a page mid-resize, or a lying number — for the same reason.
   */
  if (!Number.isFinite(viewport.width) || viewport.width <= 0) {
    throw new Error('the screenshot could not be masked, so it was not written')
  }
  const scale = pixelWidth / viewport.width
  if (!Number.isFinite(scale) || scale < 0.25 || scale > 8) {
    throw new Error('the screenshot could not be masked, so it was not written')
  }
  return { pixelWidth, pixelHeight, scale, viewport }
}

/**
 * Paint over the rectangles, in place, and say how many landed.
 *
 * Pure over a buffer so it can be driven from a test with a sentinel colour and
 * no browser — which matters, because "the password was still in the PNG" is not
 * a defect anybody would notice by looking.
 */
export function paintMasks(
  bitmap: Buffer,
  shape: BitmapShape,
  rects: ReadonlyArray<{ x: number; y: number; width: number; height: number }>,
): number {
  let painted = 0
  for (const rect of rects) {
    const left = Math.max(0, Math.floor(rect.x * shape.scale))
    const top = Math.max(0, Math.floor(rect.y * shape.scale))
    const right = Math.min(shape.pixelWidth, Math.ceil((rect.x + rect.width) * shape.scale))
    const bottom = Math.min(shape.pixelHeight, Math.ceil((rect.y + rect.height) * shape.scale))
    if (right <= left || bottom <= top) continue
    painted++
    for (let y = top; y < bottom; y++) {
      const rowStart = (y * shape.pixelWidth + left) * 4
      const rowEnd = (y * shape.pixelWidth + right) * 4
      // Opaque mid-grey. Grey is symmetric across the channels, so this is the
      // same three bytes whether the buffer is RGB- or BGR-ordered; the fourth,
      // set below, is the alpha. Not black: a black rectangle on a dark page is
      // invisible, and the point of the mask is that a person looking at the
      // picture can see that something was hidden there.
      bitmap.fill(0x80, rowStart, rowEnd)
      for (let i = rowStart + 3; i < rowEnd; i += 4) bitmap[i] = 0xff
    }
  }
  return painted
}

/**
 * Paint every secret rectangle out of a frame and hand back the PNG.
 *
 * The whole point of the file, composed: derive the shape, paint the masks on
 * the raw buffer, then — and only then — encode. When there is nothing to mask
 * the frame is encoded untouched, which is still an encode through this file's
 * one door rather than the runtime's, so the server and the desktop write the
 * same bytes for the same pixels.
 */
export function maskFrame(
  frame: RawFrame,
  rects: ReadonlyArray<{ x: number; y: number; width: number; height: number }>,
  viewport: { width: number; height: number },
): { png: Buffer; painted: number } {
  if (rects.length === 0) {
    return { png: encodeRgbaPng(frame.data, frame.width, frame.height), painted: 0 }
  }
  const shape = bitmapShape({ width: frame.width, height: frame.height }, frame.data.length, viewport)
  if (shape === null) {
    return { png: encodeRgbaPng(frame.data, frame.width, frame.height), painted: 0 }
  }
  const painted = paintMasks(frame.data, shape, rects)
  return { png: encodeRgbaPng(frame.data, shape.pixelWidth, shape.pixelHeight), painted }
}
