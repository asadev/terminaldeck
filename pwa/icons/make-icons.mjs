#!/usr/bin/env node
/**
 * Home-screen icons for the phone client.
 *
 *   node pwa/icons/make-icons.mjs
 *
 * Original artwork, generated rather than drawn, for the same reason as
 * `build/art/icon.mjs`: every size is rasterised from the description at its
 * native resolution instead of being a downscale of a bigger bitmap, and at
 * 180px that is the difference between a crisp chevron and a smudge. The PNG
 * encoder is imported from that file rather than restated.
 *
 * The mark is the desktop icon's chevron alone. At home-screen size the card,
 * the spine and the back card are all under two pixels wide, so what is left is
 * the prompt itself — which is the part someone actually recognises.
 *
 * A maskable copy is produced as well. Android crops icons to whatever shape
 * the launcher uses, and an icon without a maskable variant gets its corners
 * cut off or, worse, gets a white plate drawn behind it.
 */

import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { png } from '../../build/art/icon.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))

/** From src/renderer/styles/tokens.css, dark theme. */
const TILE_TOP = [0x26, 0x2b, 0x33]
const TILE_BOTTOM = [0x0f, 0x11, 0x14]
const CHEVRON = [0x52, 0x9c, 0xca]
const CURSOR = [0xd4, 0xd4, 0xd4]

const mix = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v)

/** Coverage from a signed distance, one pixel of feathering. */
const cover = (distance, feather) => clamp01(0.5 - distance / feather)

/** Distance from a point to a line segment, all in unit coordinates. */
function segmentDistance(px, py, ax, ay, bx, by) {
  const vx = bx - ax
  const vy = by - ay
  const wx = px - ax
  const wy = py - ay
  const t = clamp01((wx * vx + wy * vy) / (vx * vx + vy * vy))
  const dx = wx - vx * t
  const dy = wy - vy * t
  return Math.sqrt(dx * dx + dy * dy)
}

/** Signed distance to a rounded rectangle centred on (cx, cy). */
function roundedRectDistance(px, py, cx, cy, halfW, halfH, radius) {
  const dx = Math.abs(px - cx) - (halfW - radius)
  const dy = Math.abs(py - cy) - (halfH - radius)
  const outside = Math.hypot(Math.max(dx, 0), Math.max(dy, 0))
  return outside + Math.min(Math.max(dx, dy), 0) - radius
}

/**
 * @param {number} size pixels
 * @param {boolean} maskable full-bleed, with the art inside the 80% safe zone
 */
function render(size, maskable) {
  const rgba = new Uint8ClampedArray(size * size * 4)
  const feather = 1 / size

  // A maskable icon is cropped by the launcher, so the art shrinks into the
  // circle every mask is guaranteed to keep, and the tile fills the square.
  const scale = maskable ? 0.62 : 1
  const tileHalf = maskable ? 0.5 : 0.44
  const tileRadius = maskable ? 0 : 0.1

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const px = (x + 0.5) / size
      const py = (y + 0.5) / size

      const tile = cover(roundedRectDistance(px, py, 0.5, 0.5, tileHalf, tileHalf, tileRadius), feather)
      let [r, g, b] = mix(TILE_TOP, TILE_BOTTOM, py)
      let a = tile

      // The chevron: two strokes meeting at a point, like a shell prompt.
      const cx = (v) => 0.5 + (v - 0.5) * scale
      const stroke = 0.052 * scale
      const chevron = Math.min(
        segmentDistance(px, py, cx(0.36), cx(0.33), cx(0.55), cx(0.5)),
        segmentDistance(px, py, cx(0.55), cx(0.5), cx(0.36), cx(0.67)),
      )
      const onChevron = cover(chevron - stroke, feather) * tile
      ;[r, g, b] = mix([r, g, b], CHEVRON, onChevron)
      a = Math.max(a, onChevron * tile)

      // The cursor block after it.
      const bar = roundedRectDistance(px, py, cx(0.68), cx(0.62), 0.075 * scale, 0.026 * scale, 0.02 * scale)
      const onBar = cover(bar, feather) * tile
      ;[r, g, b] = mix([r, g, b], CURSOR, onBar)

      const at = (y * size + x) * 4
      rgba[at] = r
      rgba[at + 1] = g
      rgba[at + 2] = b
      rgba[at + 3] = a * 255
    }
  }
  return rgba
}

const OUTPUT = [
  ['icon-180.png', 180, false],
  ['icon-192.png', 192, false],
  ['icon-512.png', 512, false],
  ['icon-maskable-512.png', 512, true],
]

for (const [name, size, maskable] of OUTPUT) {
  writeFileSync(join(HERE, name), png(size, render(size, maskable)))
  process.stdout.write(`  ${name.padEnd(24)} ${size}px${maskable ? ' (maskable)' : ''}\n`)
}
