#!/usr/bin/env node
/**
 * Terminal Deck disk-image background — original artwork, generated from scratch.
 *
 *   node build/art/dmg-background.mjs
 *
 * Writes build/background.png (600x400), build/background@2x.png (1200x800)
 * and, via tiffutil, build/background.tiff — the multi-resolution file Finder
 * wants so the image is not soft on a Retina display.
 *
 * This file exists because electron-builder does not let you have no
 * background: `dmg.background: null` falls through to a stock image that ships
 * inside the npm package. Rather than distribute someone else's placeholder in
 * our release, we draw our own.
 *
 * The geometry deliberately matches `dmg.window` and `dmg.contents` in
 * electron-builder.yml. Change one and change the other.
 *
 * Known limitation: Finder draws icon labels in the viewer's system
 * appearance, so on a light background the labels are crisp in light mode and
 * white-on-light in dark mode. There is no image that is right in both. Light
 * is the side chosen here — it is what macOS's own installer windows look
 * like, and it matches the app's light theme.
 */

import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { png } from './icon.mjs'

const BUILD = dirname(dirname(fileURLToPath(import.meta.url)))

/** Window size, and the icon centres, exactly as electron-builder.yml has them. */
const W = 600
const H = 400
const SLOT_Y = 180
const SLOT_X = [155, 445]

const hex = (s) => [
  parseInt(s.slice(1, 3), 16),
  parseInt(s.slice(3, 5), 16),
  parseInt(s.slice(5, 7), 16),
]

const TOP = hex('#fbfbfa')
const BOTTOM = hex('#ececea')
const SLOT = hex('#dcdcd7')
const ARROW = hex('#b4b4ae')

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v)

function roundRect(x, y, cx, cy, hw, hh, r) {
  const qx = Math.abs(x - cx) - (hw - r)
  const qy = Math.abs(y - cy) - (hh - r)
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r
}

function capsule(x, y, ax, ay, bx, by, halfT) {
  const pax = x - ax
  const pay = y - ay
  const bax = bx - ax
  const bay = by - ay
  const h = clamp01((pax * bax + pay * bay) / (bax * bax + bay * bay))
  return Math.hypot(pax - bax * h, pay - bay * h) - halfT
}

/** Outline of a shape: everything within `w` of its edge. */
const outline = (sdf, w) => (x, y) => Math.abs(sdf(x, y)) - w / 2

function shapes() {
  const slots = SLOT_X.map(
    (cx) => (x, y) => roundRect(x, y, cx, SLOT_Y + 22, 84, 96, 20),
  )
  // Drag hint: shaft plus two head strokes, sitting in the gap between the
  // slots and on the same baseline as the icons.
  const arrow = (x, y) => {
    const shaft = capsule(x, y, 272, SLOT_Y, 324, SLOT_Y, 1.6)
    const up = capsule(x, y, 313, SLOT_Y - 11, 325, SLOT_Y, 1.6)
    const down = capsule(x, y, 313, SLOT_Y + 11, 325, SLOT_Y, 1.6)
    return Math.min(shaft, Math.min(up, down))
  }
  return [
    ...slots.map((s) => ({ sdf: outline(s, 1.4), color: SLOT, alpha: 1 })),
    { sdf: arrow, color: ARROW, alpha: 1 },
  ]
}

function render(scale) {
  const w = W * scale
  const h = H * scale
  const px = new Uint8Array(w * h * 4)
  const stack = shapes()

  for (let j = 0; j < h; j++) {
    const y = (j + 0.5) / scale
    const t = clamp01(y / H)
    for (let i = 0; i < w; i++) {
      const x = (i + 0.5) / scale
      let r = TOP[0] + (BOTTOM[0] - TOP[0]) * t
      let g = TOP[1] + (BOTTOM[1] - TOP[1]) * t
      let b = TOP[2] + (BOTTOM[2] - TOP[2]) * t

      for (const s of stack) {
        const cov = clamp01(0.5 - s.sdf(x, y) * scale) * s.alpha
        if (cov <= 0) continue
        r = s.color[0] * cov + r * (1 - cov)
        g = s.color[1] * cov + g * (1 - cov)
        b = s.color[2] * cov + b * (1 - cov)
      }

      const o = (j * w + i) * 4
      px[o] = Math.round(r)
      px[o + 1] = Math.round(g)
      px[o + 2] = Math.round(b)
      px[o + 3] = 255
    }
  }

  return { w, h, px }
}

for (const [scale, name] of [
  [1, 'background.png'],
  [2, 'background@2x.png'],
]) {
  const { w, h, px } = render(scale)
  writeFileSync(join(BUILD, name), png(w, px, h))
  process.stdout.write(`  ${name.padEnd(22)} ${w}x${h}\n`)
}

// Finder picks the 2x representation off a multi-page TIFF; two loose PNGs
// would leave it upscaling the 1x one on every Retina display.
execFileSync('/usr/bin/tiffutil', [
  '-cathidpicheck',
  join(BUILD, 'background.png'),
  join(BUILD, 'background@2x.png'),
  '-out',
  join(BUILD, 'background.tiff'),
])
process.stdout.write('  background.tiff        600x400 + 1200x800\n')
