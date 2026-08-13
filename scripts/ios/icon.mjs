#!/usr/bin/env node
/**
 * The iOS app icon, rasterised from the same vector artwork as the desktop one.
 *
 *   node scripts/ios/icon.mjs
 *
 * Writes `ios/TerminalDeck/Assets.xcassets/AppIcon.appiconset/icon-1024.png`.
 *
 * ## Why this file exists at all
 *
 * `build/art/icon.mjs` already describes the mark — a rounded-square tile, a
 * card with a blue spine, a second card behind it, a chevron — and rasterises
 * it from signed distance fields at whatever size is asked for. This does not
 * redraw any of that. It imports `render` and asks for one size. The artwork
 * has exactly one definition and it is not here.
 *
 * What differs is the frame, and it differs for two reasons that are both
 * Apple's rules rather than taste:
 *
 * 1. **iOS masks the icon itself.** The macOS composition draws its own rounded
 *    tile inset inside a transparent 1024 square, because macOS ships icons
 *    with their shape baked in. iOS does the opposite: it wants a full-bleed
 *    square and applies the squircle mask at display time. Handing iOS the
 *    macOS art gives you a rounded tile inside a rounded mask — a dark ring
 *    around a smaller icon.
 *
 * 2. **No alpha channel.** App Store Connect rejects an app icon that carries
 *    one at all (ITMS-90717), even where every pixel is opaque. The shared
 *    `png()` helper emits truecolour *with* alpha, so this file has its own
 *    twenty-line encoder that emits truecolour without it. That is the only
 *    duplication here, and it is duplicated because the shared one is correct
 *    for its own callers.
 *
 * ## How the frame is chosen
 *
 * Both problems are solved by one move: render the whole 1024 canvas larger
 * than the output and take a square out of the middle of the tile, so the
 * tile's own rounding and the transparency outside it are cropped away and
 * every output pixel is opaque tile.
 *
 * How large a square fits inside the tile is arithmetic, not preference. The
 * tile is a superellipse of exponent 5 with half-width a = 412 about (512,512),
 * so a square of half-width h centred on it has its corner inside the tile
 * while 2*(h/412)^5 < 1, i.e. h < 358.7. The tile also carries an inner rim —
 * a lit edge 7 units wide just inside its boundary — and a crop that catches
 * the rim draws a bright diagonal across each corner. h = 348 sits about 16
 * units inside the boundary, clear of the 7-unit rim with room to spare, and
 * is what CROP_HALF_WIDTH is. `assertOpaque` below then checks the result
 * rather than trusting this paragraph: if the crop ever strays outside the
 * tile, some pixel is not opaque and the script fails instead of shipping a
 * transparent corner.
 *
 * The 1024 is the App Store marketing icon and the only size committed. Every
 * size the phone actually draws is derived from it by `actool` at build time
 * (see AppIcon.appiconset/Contents.json). That is a departure from the desktop
 * icon, which rasterises each size natively so that the 16px one can use a
 * simplified composition — but the smallest icon iOS asks for is 40px, well
 * above the 32px threshold where `build/art/icon.mjs` switches compositions, so
 * there is no size in the iOS set that wants different art.
 */

import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { deflateSync, crc32 } from 'node:zlib'

import { render } from '../../build/art/icon.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = dirname(dirname(HERE))
const ICONSET = join(REPO, 'ios', 'TerminalDeck', 'Assets.xcassets', 'AppIcon.appiconset')

/** The design canvas `build/art/icon.mjs` describes everything on. */
const U = 1024
/** Half-width, in design units, of the square taken out of the tile. See above. */
const CROP_HALF_WIDTH = 348
/** The App Store marketing icon, and the source every other size is derived from. */
const OUT = 1024

/* --------------------------------------------------------------------- PNG */

function chunk(type, data) {
  const head = Buffer.alloc(8)
  head.writeUInt32BE(data.length, 0)
  head.write(type, 4, 'ascii')
  const body = Buffer.concat([head.subarray(4), data])
  const tail = Buffer.alloc(4)
  tail.writeUInt32BE(crc32(body) >>> 0, 0)
  return Buffer.concat([head, data, tail])
}

/** Truecolour, 8 bits, **no alpha channel** — colour type 2. See the header. */
function pngRGB(size, rgb) {
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(size, 0)
  ihdr.writeUInt32BE(size, 4)
  ihdr[8] = 8
  ihdr[9] = 2
  const stride = size * 3
  const raw = Buffer.alloc(size * (stride + 1))
  for (let j = 0; j < size; j++) {
    raw[j * (stride + 1)] = 0 // filter: none
    rgb.copy(raw, j * (stride + 1) + 1, j * stride, (j + 1) * stride)
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

/* -------------------------------------------------------------------- crop */

/**
 * The crop is only legitimate if every pixel in it is opaque tile. A single
 * transparent pixel means the square has reached outside the superellipse and
 * the icon would ship with a see-through corner, so this throws rather than
 * silently flattening it against black.
 */
function assertOpaque(rgba, size, offset, out) {
  for (let j = 0; j < out; j++) {
    for (let i = 0; i < out; i++) {
      const a = rgba[((j + offset) * size + (i + offset)) * 4 + 3]
      if (a !== 255) {
        throw new Error(
          `crop is not fully inside the tile: pixel (${i},${j}) has alpha ${a}. ` +
            `Lower CROP_HALF_WIDTH (currently ${CROP_HALF_WIDTH}).`,
        )
      }
    }
  }
}

function main() {
  // Render the full canvas at whatever size makes the crop come out at OUT
  // pixels. Every pixel is still rasterised from the distance fields at its
  // final resolution — nothing here is an upscale of a smaller bitmap.
  const zoom = U / (2 * CROP_HALF_WIDTH)
  const size = Math.round(OUT * zoom)
  const offset = Math.round((size - OUT) / 2)

  const rgba = render(size, false)
  assertOpaque(rgba, size, offset, OUT)

  const rgb = Buffer.alloc(OUT * OUT * 3)
  for (let j = 0; j < OUT; j++) {
    for (let i = 0; i < OUT; i++) {
      const src = ((j + offset) * size + (i + offset)) * 4
      const dst = (j * OUT + i) * 3
      rgb[dst] = rgba[src]
      rgb[dst + 1] = rgba[src + 1]
      rgb[dst + 2] = rgba[src + 2]
    }
  }

  mkdirSync(ICONSET, { recursive: true })
  writeFileSync(join(ICONSET, 'icon-1024.png'), pngRGB(OUT, rgb))
  process.stdout.write(
    `  icon-1024.png          ${OUT}px, no alpha ` +
      `(rendered at ${size}px, cropped ${offset}..${offset + OUT})\n`,
  )
}

main()
