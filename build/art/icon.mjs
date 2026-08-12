#!/usr/bin/env node
/**
 * Terminal Deck application icon — original artwork, generated from scratch.
 *
 *   node build/art/icon.mjs
 *
 * Writes build/icon.iconset/*.png and build/icon.png. It does not produce the
 * .icns itself — `npm run art` pipes the iconset through `iconutil -c icns`
 * and then regenerates the disk-image background.
 *
 * Why generated rather than drawn in an editor: every size is rasterised
 * directly from the vector description at its native resolution, so nothing is
 * ever a downscale of a bigger bitmap, and the small sizes can use their own
 * simplified composition. Nothing here is imported, traced or derived from any
 * other product's artwork — the shapes are a rounded-square tile, a card, a
 * band and a chevron, and the colours come from src/renderer/styles/tokens.css.
 *
 * No dependencies: signed-distance fields for the geometry, node:zlib for PNG.
 *
 * The mark is the app itself seen from far away — a workspace card with the
 * sidebar down its left edge, a second card stacked behind it (the deck), and
 * the shell prompt on the front card. At 16px the chevron and the back card
 * are gone; a light card with a blue spine is all that is left, which is
 * still a silhouette you can pick out of a Dock.
 */

import { deflateSync, crc32 } from 'node:zlib'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const BUILD = dirname(HERE)

/** Everything is described on a 1024x1024 canvas and scaled at render time. */
const U = 1024

/* ------------------------------------------------------------------ colour */

const hex = (s) => [
  parseInt(s.slice(1, 3), 16),
  parseInt(s.slice(3, 5), 16),
  parseInt(s.slice(5, 7), 16),
]

const COLOR = {
  tileTop: hex('#262b33'),
  tileBottom: hex('#0f1114'),
  cardTop: hex('#f6f7f9'),
  cardBottom: hex('#dfe3e9'),
  spineTop: hex('#3b8fee'),
  spineBottom: hex('#2371d6'),
  backCard: hex('#4e5a6c'),
  chevron: hex('#1b1f26'),
}

const lerp = (a, b, t) => a + (b - a) * t
const mix = (a, b, t) => [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)]
const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v)

/** Vertical gradient between two design-space y positions. */
const vgrad = (top, bottom, y0, y1) => (_x, y) => mix(top, bottom, clamp01((y - y0) / (y1 - y0)))
const flat = (c) => () => c

/* -------------------------------------------------------------------- SDFs */

/**
 * Superellipse — the continuous-corner shape macOS uses for app tiles. A plain
 * rounded rectangle has a visible seam where the arc meets the straight edge;
 * this does not. Distance is estimated as f / |grad f|, which is accurate
 * close to the boundary, and that is the only place it is used.
 */
function superellipse(x, y, cx, cy, a, n) {
  const ax = Math.abs((x - cx) / a)
  const ay = Math.abs((y - cy) / a)
  const f = ax ** n + ay ** n - 1
  const gx = (n / a) * ax ** (n - 1)
  const gy = (n / a) * ay ** (n - 1)
  const g = Math.hypot(gx, gy)
  return g > 1e-9 ? f / g : -a
}

function roundRect(x, y, cx, cy, hw, hh, r) {
  const qx = Math.abs(x - cx) - (hw - r)
  const qy = Math.abs(y - cy) - (hh - r)
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r
}

/** Thick line segment with round caps — every stroke in the mark is one of these. */
function capsule(x, y, ax, ay, bx, by, halfT) {
  const pax = x - ax
  const pay = y - ay
  const bax = bx - ax
  const bay = by - ay
  const h = clamp01((pax * bax + pay * bay) / (bax * bax + bay * bay))
  return Math.hypot(pax - bax * h, pay - bay * h) - halfT
}

const isect = (a, b) => Math.max(a, b)
const union = (a, b) => Math.min(a, b)

/* ---------------------------------------------------------------- geometry */

const TILE = { cx: 512, cy: 512, a: 412, n: 5 }

const FULL = {
  back: { cx: 592, cy: 430, hw: 214, hh: 158, r: 48 },
  card: { cx: 484, cy: 552, hw: 262, hh: 196, r: 58 },
  /** Dark seam punched around the front card so the two read as two cards
   *  rather than one card with a misaligned shadow. */
  gap: 18,
  spineRight: 370,
  chevron: { apex: [608, 552], top: [509, 453], bottom: [509, 651], halfT: 28 },
}

const SMALL = {
  card: { cx: 512, cy: 512, hw: 280, hh: 210, r: 62 },
  spineRight: 397,
}

/** Layers, painted back to front. Each is { sdf, color, alpha }. */
function layers(simplified) {
  const tile = (x, y) => superellipse(x, y, TILE.cx, TILE.cy, TILE.a, TILE.n)
  const out = [
    { sdf: tile, color: vgrad(COLOR.tileTop, COLOR.tileBottom, 100, 924), alpha: 1 },
    // Inner rim: the thin lit edge a physical object would have. Strongest at
    // the top, gone by the bottom, so the tile reads as lit from above.
    {
      sdf: (x, y) => Math.abs(tile(x, y) + 3.5) - 3.5,
      color: flat([255, 255, 255]),
      alpha: (_x, y) => 0.14 * (1 - clamp01((y - 100) / 824)) + 0.02,
    },
  ]

  const g = simplified ? SMALL : FULL
  const card = (x, y) => roundRect(x, y, g.card.cx, g.card.cy, g.card.hw, g.card.hh, g.card.r)
  const cardTop = g.card.cy - g.card.hh
  const cardBottom = g.card.cy + g.card.hh

  if (!simplified) {
    const b = FULL.back
    const k = FULL.gap
    out.push({
      sdf: (x, y) => roundRect(x, y, b.cx, b.cy, b.hw, b.hh, b.r),
      color: flat(COLOR.backCard),
      alpha: 1,
    })
    // Filled with the tile's own gradient, so it is invisible against the tile
    // and reads as a gap only where it cuts into the card behind.
    out.push({
      sdf: (x, y) =>
        roundRect(x, y, g.card.cx, g.card.cy, g.card.hw + k, g.card.hh + k, g.card.r + k),
      color: vgrad(COLOR.tileTop, COLOR.tileBottom, 100, 924),
      alpha: 1,
    })
  }

  out.push({ sdf: card, color: vgrad(COLOR.cardTop, COLOR.cardBottom, cardTop, cardBottom), alpha: 1 })
  out.push({
    sdf: (x, y) => isect(card(x, y), x - g.spineRight),
    color: vgrad(COLOR.spineTop, COLOR.spineBottom, cardTop, cardBottom),
    alpha: 1,
  })

  if (!simplified) {
    const c = FULL.chevron
    out.push({
      sdf: (x, y) =>
        union(
          capsule(x, y, ...c.top, ...c.apex, c.halfT),
          capsule(x, y, ...c.bottom, ...c.apex, c.halfT),
        ),
      color: flat(COLOR.chevron),
      alpha: 1,
    })
  }

  return out
}

/* --------------------------------------------------------------- rasteriser */

/**
 * Analytic coverage from the distance field: at one design unit per device
 * pixel a pixel is fully covered at d = -0.5 and empty at d = +0.5. No
 * supersampling needed, and edges stay crisp at 16px where supersampling
 * would smear them.
 */
export function render(size, simplified) {
  const scale = U / size
  const stack = layers(simplified)
  const px = new Uint8Array(size * size * 4)

  for (let j = 0; j < size; j++) {
    const y = (j + 0.5) * scale
    for (let i = 0; i < size; i++) {
      const x = (i + 0.5) * scale
      let r = 0
      let g = 0
      let b = 0
      let a = 0

      for (const layer of stack) {
        const cov = clamp01(0.5 - layer.sdf(x, y) / scale)
        if (cov <= 0) continue
        const la = typeof layer.alpha === 'function' ? layer.alpha(x, y) : layer.alpha
        const sa = cov * la
        if (sa <= 0) continue
        const [sr, sg, sb] = layer.color(x, y)
        r = sr * sa + r * (1 - sa)
        g = sg * sa + g * (1 - sa)
        b = sb * sa + b * (1 - sa)
        a = sa + a * (1 - sa)
      }

      const o = (j * size + i) * 4
      px[o] = Math.round(r)
      px[o + 1] = Math.round(g)
      px[o + 2] = Math.round(b)
      px[o + 3] = Math.round(a * 255)
    }
  }

  return px
}

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

export function png(width, rgba, height = width) {
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 6 // truecolour with alpha
  // Filter byte 0 on every scanline: the images are small and smooth, and a
  // filter-free stream is one less thing that can be encoded wrong.
  const stride = width * 4
  const raw = Buffer.alloc(height * (stride + 1))
  for (let j = 0; j < height; j++) {
    raw[j * (stride + 1)] = 0
    Buffer.from(rgba.buffer, rgba.byteOffset + j * stride, stride).copy(raw, j * (stride + 1) + 1)
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

/* -------------------------------------------------------------------- main */

/** The ten entries `iconutil` expects, as (file, pixel size). */
const ICONSET = [
  ['icon_16x16.png', 16],
  ['icon_16x16@2x.png', 32],
  ['icon_32x32.png', 32],
  ['icon_32x32@2x.png', 64],
  ['icon_128x128.png', 128],
  ['icon_128x128@2x.png', 256],
  ['icon_256x256.png', 256],
  ['icon_256x256@2x.png', 512],
  ['icon_512x512.png', 512],
  ['icon_512x512@2x.png', 1024],
]

/** At 32px and below the chevron is under two pixels wide and the back card
 *  is under one — both turn to mud, so those sizes get their own composition. */
export const simplifiedAt = (size) => size <= 32

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const iconset = join(BUILD, 'icon.iconset')
  rmSync(iconset, { recursive: true, force: true })
  mkdirSync(iconset, { recursive: true })

  const cache = new Map()
  for (const [name, size] of ICONSET) {
    const key = `${size}:${simplifiedAt(size)}`
    if (!cache.has(key)) cache.set(key, png(size, render(size, simplifiedAt(size))))
    writeFileSync(join(iconset, name), cache.get(key))
    process.stdout.write(`  ${name.padEnd(22)} ${size}px\n`)
  }

  writeFileSync(join(BUILD, 'icon.png'), cache.get('1024:false'))
  process.stdout.write(`  icon.png               1024px (source for non-mac targets)\n`)
}
