/**
 * Reading a PNG that arrived from the renderer as a `data:` URL.
 *
 * ## Why the renderer is the one holding the pixels
 *
 * A marked-up screenshot is a photograph of a page with lines drawn over it, and
 * the lines are drawn on a `<canvas>` because that is the only place in this app
 * that can draw. Electron's main process has `nativeImage`, which can resize and
 * re-encode a bitmap and cannot put a single stroke on one. So the composite is
 * made in the renderer and comes back here as a string, and this module is the
 * door it comes through.
 *
 * That door has to be a real one. The string is built by our own code today, but
 * it is a string from a renderer that has a whole untrusted website composited
 * into the same window, and it ends up as bytes in the user's Pictures folder.
 * So it is checked rather than trusted: the right media type, base64 that
 * decodes, a real PNG signature, a size a screenshot could plausibly be, and a
 * width and a height read out of the file's own header rather than taken on the
 * renderer's word.
 *
 * Pure, and in its own file, because every one of those checks is a rule that
 * should fail a test rather than fail in the Pictures folder — and because
 * `browser-view.ts` is already the module that owns four other things.
 */

/** The only media type this accepts, spelled exactly as `toDataURL` emits it. */
const PNG_URL_PREFIX = 'data:image/png;base64,'

/**
 * The eight bytes every PNG begins with.
 *
 * Checked even though the media type already claimed PNG, because the media type
 * is part of the string being validated — it asserts nothing. These bytes are
 * the file saying what it is.
 */
const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

/**
 * The largest composite this will write, in bytes.
 *
 * A full-window Retina capture with a few strokes on it encodes to two or three
 * megabytes; 64 covers a 6K display and a very busy scribble with room to spare,
 * and it is still small enough that a renderer bug looping on this channel fills
 * a disk slowly enough to be noticed.
 */
const MAX_BYTES = 64 * 1024 * 1024

export interface PngImage {
  bytes: Buffer
  width: number
  height: number
}

/**
 * The size in a PNG's `IHDR`, or null if this is not a PNG that has one.
 *
 * `IHDR` is mandatory and must be the first chunk, so its position is fixed: the
 * 8-byte signature, a 4-byte length, the 4-byte type `IHDR`, then width and
 * height as big-endian 32-bit integers. Reading it here rather than believing
 * the renderer's numbers means the size reported to the user, written into the
 * agent's prompt, and shown in the popup is the size of the file that is
 * actually on disk.
 */
export function readPngSize(bytes: Buffer): { width: number; height: number } | null {
  if (bytes.length < 24) return null
  for (let i = 0; i < PNG_SIGNATURE.length; i++) {
    if (bytes[i] !== PNG_SIGNATURE[i]) return null
  }
  if (bytes.toString('latin1', 12, 16) !== 'IHDR') return null
  const width = bytes.readUInt32BE(16)
  const height = bytes.readUInt32BE(20)
  if (width === 0 || height === 0) return null
  return { width, height }
}

/**
 * A `data:image/png;base64,…` URL as bytes and a size, or null.
 *
 * Null for every kind of wrong, deliberately without saying which: the caller
 * turns it into one sentence for the user, and the distinction between "not
 * base64" and "not a PNG" is of no use to anyone at that end. What the caller
 * must never do is write the bytes anyway.
 */
export function decodePngDataUrl(value: unknown): PngImage | null {
  if (typeof value !== 'string' || !value.startsWith(PNG_URL_PREFIX)) return null

  const encoded = value.slice(PNG_URL_PREFIX.length)
  // Base64 is 4 characters per 3 bytes, so this bounds the decode itself rather
  // than only its result — the point is not to materialise 400MB and then
  // reject it.
  if (encoded.length === 0 || encoded.length > Math.ceil(MAX_BYTES / 3) * 4) return null
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) return null

  const bytes = Buffer.from(encoded, 'base64')
  if (bytes.length === 0 || bytes.length > MAX_BYTES) return null

  const size = readPngSize(bytes)
  if (!size) return null
  return { bytes, width: size.width, height: size.height }
}

/**
 * The filename a marked capture gets, from the plain one it would have had.
 *
 * Same folder and same stem as an ordinary screenshot — it is one, with lines on
 * it — with `-marked` before the extension so the two are told apart in a
 * folder listing and in the one-line context an agent receives. Derived from
 * `screenshotName` rather than reimplemented, so the host-safety and the
 * timestamp rules cannot drift into two versions.
 */
export function markedName(screenshotFileName: string): string {
  return screenshotFileName.endsWith('.png')
    ? `${screenshotFileName.slice(0, -'.png'.length)}-marked.png`
    : `${screenshotFileName}-marked.png`
}
