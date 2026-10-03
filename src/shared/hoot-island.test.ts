import { describe, expect, it } from 'vitest'
import {
  barRow,
  easeInOut,
  easeOut,
  EXPANDED,
  expandedShape,
  expandedWidth,
  grownness,
  islandCentre,
  islandPath,
  islandWindow,
  mixShape,
  onShape,
  placeIsland,
  REST,
  restBox,
  restShape,
  SHADOW,
  TIMING,
  within,
  type IslandGeometry,
} from './hoot-island'

/** His Mac mini: a 1920-wide display, a 30-point menu bar, no notch. */
const MINI: IslandGeometry = { barHeight: 30, displayWidth: 1920, notch: null }
/** A 14-inch MacBook Pro: 1512 wide, a 200-point notch 32 tall in the middle. */
const MACBOOK: IslandGeometry = { barHeight: 32, displayWidth: 1512, notch: { left: 656, width: 200, height: 32 } }

describe('the resting pill', () => {
  it('without a notch: as tall as the menu bar and as wide as owl and words need', () => {
    const shape = restShape(MINI, { textWidth: 30, attention: false })
    expect(shape.height).toBe(30)
    expect(shape.width).toBe(REST.padLeft + REST.owl + REST.gap + 30 + REST.padRight)
    expect(shape.radius).toBeLessThanOrEqual(shape.height / 2)
    expect(shape.shoulder).toBeGreaterThan(0)
  })

  it('makes room for the attention dot, and keeps between a floor and a ceiling', () => {
    const quiet = restShape(MINI, { textWidth: 60, attention: false })
    const loud = restShape(MINI, { textWidth: 60, attention: true })
    expect(loud.width - quiet.width).toBe(REST.dot + REST.dotGap)
    expect(restShape(MINI, { textWidth: 0, attention: false }).width).toBe(REST.minWidth)
    expect(restShape(MINI, { textWidth: 900, attention: false }).width).toBe(REST.maxWidth)
  })

  it('has room for the counts line at a glance', () => {
    // "4 open · 2 working · 1 waiting" is about 175 points in the pill's type.
    const shape = restShape(MINI, { textWidth: 175, attention: true })
    expect(shape.width).toBe(REST.padLeft + REST.owl + REST.gap + REST.dot + REST.dotGap + 175 + REST.padRight)
  })

  it('with a notch: wraps it, the same ear each side, so nothing hides behind the camera', () => {
    const shape = restShape(MACBOOK, { textWidth: 30, attention: false })
    expect(shape.height).toBe(32)
    const ear = (shape.width - 200) / 2
    expect(Number.isInteger(ear)).toBe(true)
    expect(ear).toBeGreaterThanOrEqual(REST.owl + REST.earPad * 2)
    expect(ear).toBeGreaterThanOrEqual(30 + REST.earPad * 2)
  })

  it('a longer line widens both ears around the notch — but never as wide as the grown panel', () => {
    const short = restShape(MACBOOK, { textWidth: 30, attention: false })
    const long = restShape(MACBOOK, { textWidth: 130, attention: true })
    expect(long.width).toBeGreaterThan(short.width)
    expect((long.width - 200) / 2).toBe(130 + REST.dot + REST.dotGap + REST.earPad * 2)
    const huge = restShape(MACBOOK, { textWidth: 600, attention: true })
    expect(huge.width).toBeLessThan(expandedWidth(MACBOOK))
  })

  it('shares the counts between the ears, so the owl’s side is not a long empty stretch', () => {
    // "4 open" by the owl (about 45 points), "2 working · 1 waiting" (about 125) on the right.
    const shared = restShape(MACBOOK, { textWidth: 125, attention: true, leftWidth: 45 })
    const alone = restShape(MACBOOK, { textWidth: 175, attention: true })
    expect(shared.width).toBeLessThan(alone.width)
    expect((shared.width - 200) / 2).toBe(Math.max(REST.owl + REST.gap + 45, REST.dot + REST.dotGap + 125) + REST.earPad * 2)
  })

  it('takes its row height from the notch where there is one, and keeps it sane', () => {
    expect(barRow(MACBOOK)).toBe(32)
    expect(barRow({ ...MINI, barHeight: 0 })).toBe(REST.minHeight)
    expect(barRow({ ...MINI, barHeight: 90 })).toBe(REST.maxHeight)
  })
})

describe('the grown panel', () => {
  it('about a third of the screen across and short, with round bottom corners', () => {
    const shape = expandedShape(MINI, 100)
    expect(shape.width).toBe(640)
    expect(shape.height).toBe(130)
    expect(shape.radius).toBe(EXPANDED.radius)
    expect(shape.shoulder).toBe(EXPANDED.shoulder)
  })

  it('never narrower than its floor, never wider than the screen allows, never taller than its ceiling', () => {
    expect(expandedShape(MACBOOK, 100).width).toBe(EXPANDED.minWidth)
    expect(expandedShape({ ...MINI, displayWidth: 3840 }, 100).width).toBe(EXPANDED.maxWidth)
    expect(expandedShape({ ...MINI, displayWidth: 500 }, 100).width).toBeLessThanOrEqual(500 - EXPANDED.edge * 2)
    expect(expandedShape(MINI, 4000).height).toBe(EXPANDED.maxHeight)
    expect(expandedShape(MINI, 0).height).toBe(30 + EXPANDED.minBody)
  })
})

describe('the one window', () => {
  it('holds the grown panel, its shoulders and its shadow — whatever the shape is doing', () => {
    const box = islandWindow(MINI)
    const tallest = expandedShape(MINI, 4000)
    expect(box.width).toBe(tallest.width + tallest.shoulder * 2 + SHADOW.side * 2)
    expect(box.height).toBe(tallest.height + SHADOW.bottom)
    expect(box.width).toBeGreaterThan(restBox(restShape(MINI, { textWidth: 900, attention: true })).width)
  })

  it('depends on the display alone — not on the words, the counts or whether it is grown', () => {
    expect(islandWindow(MINI)).toEqual(islandWindow({ ...MINI }))
    expect(islandWindow(MACBOOK).width).toBe(EXPANDED.minWidth + EXPANDED.shoulder * 2 + SHADOW.side * 2)
  })

  it('is centred on the notch, or the middle of the display, with its top on the top edge', () => {
    const mini = { x: 0, y: 0, width: 1920, height: 1080 }
    expect(islandCentre(mini, null)).toBe(960)
    const box = islandWindow(MINI)
    const frame = placeIsland(mini, 960, box)
    expect(frame.y).toBe(0)
    expect(frame.x + frame.width / 2).toBe(960)
    const side = { x: -1512, y: -200, width: 1512, height: 982 }
    expect(islandCentre(side, MACBOOK.notch)).toBe(-1512 + 756)
    expect(placeIsland(side, -756, { width: 300, height: 32 }).y).toBe(-200)
  })

  it('stays on its display', () => {
    const mini = { x: 0, y: 0, width: 1920, height: 1080 }
    expect(placeIsland(mini, 10, { width: 200, height: 30 }).x).toBe(0)
    expect(placeIsland(mini, 1910, { width: 200, height: 30 }).x).toBe(1720)
    expect(placeIsland(mini, 960, { width: 4000, height: 30 }).width).toBe(1920)
  })
})

describe('the outline', () => {
  it('is one closed path, centred, hanging from the top edge, with outward shoulders and round bottom corners', () => {
    const shape = { width: 100, height: 30, radius: 12, shoulder: 6 }
    const path = islandPath(shape, 400)
    expect(path.startsWith('M 344 0')).toBe(true)
    expect(path).toContain('A 6 6 0 0 1 350 6')
    expect(path).toContain('A 12 12 0 0 0 362 30')
    expect(path).toContain('A 6 6 0 0 1 456 0')
    expect(path.endsWith('Z')).toBe(true)
    expect(path.match(/M /g)).toHaveLength(1)
  })

  it('is symmetric about its centre, so the centre never wanders while the shape moves', () => {
    for (const t of [0, 0.25, 0.5, 0.75, 1]) {
      const shape = mixShape(restShape(MINI, { textWidth: 30, attention: false }), expandedShape(MINI, 100), t)
      const xs = [...islandPath(shape, 500).matchAll(/(-?[\d.]+) (-?[\d.]+)(?= [ALZ]| Z|$)/g)].map((m) => Number(m[1]))
      expect((Math.min(...xs) + Math.max(...xs)) / 2).toBeCloseTo(500, 1)
    }
  })

  it('keeps its corners inside a shape too small for them', () => {
    const path = islandPath({ width: 10, height: 4, radius: 22, shoulder: 10 }, 50)
    expect(path).not.toContain('NaN')
    expect(path).toContain('A 4 4')
  })

  it('knows a point on it from a point beside it — the shoulders count, the margin does not', () => {
    const shape = { width: 100, height: 30, radius: 12, shoulder: 6 }
    expect(onShape(shape, 400, { x: 400, y: 10 })).toBe(true)
    expect(onShape(shape, 400, { x: 455, y: 2 })).toBe(true)
    expect(onShape(shape, 400, { x: 470, y: 10 })).toBe(false)
    expect(onShape(shape, 400, { x: 400, y: 40 })).toBe(false)
  })
})

describe('the morph', () => {
  it('grows in 380 ms and settles in 450, slow and smooth', () => {
    expect(TIMING.open.shape).toEqual([0, 380])
    expect(TIMING.close.shape[1]).toBe(450)
  })

  it('fades the panel’s words in only once the shape is most of the way grown', () => {
    expect(easeOut(within(TIMING.open.full[0], TIMING.open.shape))).toBeGreaterThan(0.85)
  })

  it('fades the words out before the shape starts to shrink', () => {
    expect(TIMING.close.full[1]).toBeLessThanOrEqual(TIMING.close.shape[0])
  })

  it('eases without ever passing its target, so nothing overshoots and jerks back', () => {
    const samples = Array.from({ length: 101 }, (_, i) => i / 100)
    for (const ease of [easeOut, easeInOut]) {
      const values = samples.map(ease)
      expect(Math.max(...values)).toBeLessThanOrEqual(1)
      expect(Math.min(...values)).toBeGreaterThanOrEqual(0)
      for (let i = 1; i < values.length; i += 1) expect(values[i]).toBeGreaterThanOrEqual(values[i - 1])
    }
    expect(easeOut(1)).toBe(1)
    expect(easeInOut(0.5)).toBeCloseTo(0.5, 5)
  })

  it('mixes two shapes, and knows how far along a shape is', () => {
    const a = { width: 100, height: 30, radius: 12, shoulder: 6 }
    const b = { width: 600, height: 130, radius: 22, shoulder: 10 }
    expect(mixShape(a, b, 0.5)).toEqual({ width: 350, height: 80, radius: 17, shoulder: 8 })
    expect(grownness(30, 30, 130)).toBe(0)
    expect(grownness(80, 30, 130)).toBe(0.5)
    expect(grownness(140, 30, 130)).toBe(1)
    expect(within(50, [0, 100])).toBe(0.5)
    expect(within(500, [0, 100])).toBe(1)
  })
})
