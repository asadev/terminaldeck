import { deflateSync } from 'node:zlib'

/**
 * The image a request is answered with when it is answered cheaply.
 *
 * ## Why this file exists at all, in one number: 16,498
 *
 * That is how many floor plans were lost out of a real property scrape, and
 * nothing blocked the crawler. The tooling blocked **images** — the ordinary,
 * sensible, every-scraping-guide optimisation — so the pages went faster and
 * every lazy-loading gallery on them never fired. A lazy-loader watches its own
 * images: an `IntersectionObserver` that swaps `data-src` into `src` once the
 * one above it has settled, a carousel that requests page two once page one has
 * decoded, a `<picture>` that only resolves the next candidate after the
 * current one loads. Block the image and the observer never advances, so the
 * real image URLs are never written into the DOM at all. The scrape did not
 * fail; it succeeded at reading a page that never finished revealing itself.
 *
 * So the primitive is not block-or-allow. It is **answer the request cheaply**:
 * the request is intercepted, a valid image is handed back out of this process,
 * and no byte crosses the network. The page believes the image loaded, the
 * observer advances, the next URL appears — and the crawl gets the URLs it came
 * for while spending nothing on the pixels.
 *
 * ## Why not a 1×1, which is what everybody uses
 *
 * Because a 1×1 loses the same data for a new reason, and it does it silently.
 *
 * A great deal of real lazy-loading code gates on the size of what arrived:
 *
 *     img.onload = () => { if (img.naturalWidth > 1) revealNext() }
 *     if (!img.complete || img.naturalWidth === 0) return
 *     const ratio = img.naturalHeight / img.naturalWidth   // → 1, every card square
 *
 * Responsive layout does too. A `<picture>` or a `srcset` picks its candidate
 * from the intrinsic width of what it got; a masonry grid measures the first
 * image to lay out the column; `aspect-ratio: auto` collapses a card to nothing
 * when the image inside it is one pixel square. Each of those turns a page that
 * would have revealed a hundred URLs into a page that reveals none, and each of
 * them looks exactly like a page that simply had no images.
 *
 * So a fulfilled image carries the **expected dimensions** wherever the page
 * itself states them — the `width`/`height` attributes, the laid-out CSS box, or
 * a `srcset` width descriptor — and falls back to 1×1 only when nothing on the
 * page says a size. `browser-network.ts` does the asking and counts how many of
 * each it managed, so a run that fell back to 1×1 for everything is a fact in
 * the result rather than a mystery in the output.
 *
 * ## Why 8-bit greyscale with a tRNS chunk, rather than RGBA
 *
 * Memory. Fully transparent RGBA at 1920×1080 is 8.3 MB of zeroes to allocate
 * and deflate for one placeholder, and a page can ask for a hundred. Colour
 * type 0 at 8 bits is one byte per pixel — 2 MB for the same picture — and one
 * `tRNS` chunk naming grey level 0 as transparent makes every one of those
 * pixels fully transparent. It is ordinary PNG, in the spec since 1996, and
 * libpng — which is what Chromium decodes with — has always read it.
 *
 * Deflate does the rest: an all-zero raster compresses to a couple of kilobytes
 * whatever its dimensions, so the bytes handed to the page are small even when
 * the picture it thinks it received is large.
 */

/* ------------------------------------------------------------- the bounds -- */

/**
 * The largest placeholder that will ever be built, per side.
 *
 * A page states its own sizes and a page can state a nonsense one — `width` is
 * an author-supplied attribute and nothing validates it. Without a cap, one
 * `<img width="200000">` is a 200,000-byte-wide raster allocated inside the
 * main process on the strength of a number a website chose.
 *
 * 4096 is comfortably past any real image on any real page and bounds the
 * worst case at 16 MB of scratch before deflate. A clamped placeholder is
 * reported as clamped — see {@link placeholderPng} — because an image that came
 * back smaller than the page asked for is a thing the caller may need to know.
 */
export const MAX_PLACEHOLDER_SIDE = 4096

/**
 * How many built placeholders are kept.
 *
 * A page's images cluster on a handful of sizes — a grid of cards is one size
 * repeated forty times — so the cache hit rate is high and the cost of a miss
 * is a deflate. Bounded because the key is a size the *page* chooses, and an
 * unbounded map keyed on attacker input is a leak with a nice name.
 */
const CACHE_LIMIT = 64

const cache = new Map<string, Buffer>()

/* --------------------------------------------------------------- the PNG -- */

/**
 * CRC-32, hand-rolled.
 *
 * `zlib.crc32` exists in Node 22.2 and would do, and this is fourteen lines
 * that cannot be wrong about which Node the Electron of the day bundles. Every
 * PNG chunk carries one and a decoder is entitled to reject a chunk whose CRC
 * does not match, so getting it right is the difference between an image and a
 * broken-image icon.
 */
/** The PNG/zlib CRC polynomial, reversed, as every implementation writes it. */
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

export function crc32(bytes: Uint8Array): number {
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

export interface Placeholder {
  /** The PNG itself. */
  png: Buffer
  /** What the page will read as `naturalWidth` / `naturalHeight`. */
  width: number
  height: number
  /** True when the page asked for something larger than {@link MAX_PLACEHOLDER_SIDE}. */
  clamped: boolean
}

/**
 * A fully transparent PNG of the given size.
 *
 * Sizes are clamped rather than refused: a page that states a nonsense width
 * still needs its request answered, and answering it with the largest thing
 * this will build is closer to what the page asked for than a 1×1 is. Whether
 * that happened is on the result.
 */
export function placeholderPng(width: number, height: number): Placeholder {
  const w = clampSide(width)
  const h = clampSide(height)
  const clamped = w !== Math.trunc(width) || h !== Math.trunc(height)
  const key = `${w}x${h}`
  const hit = cache.get(key)
  if (hit) return { png: hit, width: w, height: h, clamped }

  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(w, 0)
  ihdr.writeUInt32BE(h, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 0 // colour type 0: greyscale
  ihdr[10] = 0 // deflate, the only compression PNG has
  ihdr[11] = 0 // adaptive filtering, the only filter method PNG has
  ihdr[12] = 0 // not interlaced

  // Grey level 0 — every pixel in the raster — is fully transparent.
  const trns = Buffer.alloc(2)
  trns.writeUInt16BE(0, 0)

  /*
   * One filter byte per scanline, then the pixels. Both are zero: filter type 0
   * is "none", and grey 0 is the transparent level. `Buffer.alloc` zeroes, so
   * the raster is built by asking for it and nothing else.
   */
  const raster = Buffer.alloc(h * (w + 1))
  // Level 9 because this is compressed once per distinct size and then cached,
  // and the result is handed to a page over and over.
  const idat = deflateSync(raster, { level: 9 })

  const png = Buffer.concat([
    SIGNATURE,
    chunk('IHDR', ihdr),
    chunk('tRNS', trns),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ])
  remember(key, png)
  return { png, width: w, height: h, clamped }
}

function clampSide(value: number): number {
  if (!Number.isFinite(value)) return 1
  const whole = Math.trunc(value)
  if (whole < 1) return 1
  return whole > MAX_PLACEHOLDER_SIDE ? MAX_PLACEHOLDER_SIDE : whole
}

function remember(key: string, png: Buffer): void {
  if (cache.size >= CACHE_LIMIT) {
    const oldest = cache.keys().next()
    if (!oldest.done) cache.delete(oldest.value)
  }
  cache.set(key, png)
}

/** Test seam: the cache is a performance detail and must not be shared state. */
export function forgetPlaceholders(): void {
  cache.clear()
}
