import { describe, expect, it } from 'vitest'
import {
  barRow,
  clampExpanded,
  defaultExpanded,
  EASE_CLOSE,
  EASE_OPEN,
  edgeShape,
  EXPANDED,
  expandedLimits,
  expandedShape,
  islandCentre,
  islandPath,
  islandWindow,
  mixShape,
  placeIsland,
  REST,
  restBox,
  restShape,
  SHADOW,
  TIMING,
  transition,
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

  it('a longer line widens both ears around the notch — but never wider than the window holds', () => {
    const short = restShape(MACBOOK, { textWidth: 30, attention: false })
    const long = restShape(MACBOOK, { textWidth: 130, attention: true })
    expect(long.width).toBeGreaterThan(short.width)
    expect((long.width - 200) / 2).toBe(130 + REST.dot + REST.dotGap + REST.earPad * 2)
    const huge = restShape(MACBOOK, { textWidth: 600, attention: true })
    expect(huge.width).toBeLessThan(expandedLimits(MACBOOK).maxWidth)
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

describe('the grown panel — his to resize', () => {
  it('opens about a third of the screen across and short, with round bottom corners, until he resizes it', () => {
    const shape = expandedShape(MINI, null)
    expect(shape).toEqual({ width: 640, height: EXPANDED.defaultHeight, radius: EXPANDED.radius, shoulder: EXPANDED.shoulder })
    expect(defaultExpanded(MACBOOK).width).toBe(EXPANDED.defaultMinWidth)
  })

  it('opens at the size he left it at', () => {
    expect(expandedShape(MINI, { width: 820, height: 360 })).toMatchObject({ width: 820, height: 360 })
  })

  it('is held between a size that still holds a conversation and the largest the window was made for', () => {
    const limits = expandedLimits(MINI)
    expect(clampExpanded(MINI, { width: 100, height: 40 })).toEqual({ width: limits.minWidth, height: limits.minHeight })
    expect(clampExpanded(MINI, { width: 5000, height: 5000 })).toEqual({ width: EXPANDED.maxWidth, height: EXPANDED.maxHeight })
    // A remembered size from a bigger screen fits a smaller one.
    expect(clampExpanded({ ...MINI, displayWidth: 800 }, { width: 960, height: 300 }).width).toBeLessThanOrEqual(800 - EXPANDED.edge * 2)
  })
})

describe('the one window', () => {
  it('holds the largest panel a drag can make, its shoulders and its shadow — whatever the shape is doing', () => {
    const box = islandWindow(MINI)
    const largest = expandedShape(MINI, { width: 99999, height: 99999 })
    expect(box.width).toBe(largest.width + largest.shoulder * 2 + SHADOW.side * 2)
    expect(box.height).toBe(largest.height + SHADOW.bottom)
  })

  it('depends on the display alone — not on the words, the counts, his size or whether it is grown', () => {
    expect(islandWindow(MINI)).toEqual(islandWindow({ ...MINI }))
    expect(islandWindow(MINI).width).toBe(EXPANDED.maxWidth + EXPANDED.shoulder * 2 + SHADOW.side * 2)
  })

  it('is centred on the notch, or the middle of the display, with its top on the top edge', () => {
    const mini = { x: 0, y: 0, width: 1920, height: 1080 }
    expect(islandCentre(mini, null)).toBe(960)
    const frame = placeIsland(mini, 960, islandWindow(MINI))
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

  it('knows the box the resting pill covers, for the catcher', () => {
    expect(restBox({ width: 100, height: 30, radius: 12, shoulder: 6 })).toEqual({ width: 112, height: 30 })
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
      const shape = mixShape(restShape(MINI, { textWidth: 30, attention: false }), expandedShape(MINI, null), t)
      const xs = [...islandPath(shape, 500).matchAll(/(-?[\d.]+) (-?[\d.]+)(?= [ALZ]| Z|$)/g)].map((m) => Number(m[1]))
      expect((Math.min(...xs) + Math.max(...xs)) / 2).toBeCloseTo(500, 1)
    }
  })

  it('is the same commands whatever its size, so the browser can move one outline into another', () => {
    const shape = (s: string): string => s.replace(/-?[\d.]+/g, '#')
    const a = islandPath(restShape(MINI, { textWidth: 30, attention: false }), 500)
    const b = islandPath(expandedShape(MINI, null), 500)
    expect(shape(a)).toBe(shape(b))
    expect(shape(islandPath(edgeShape(expandedShape(MINI, null)), 500))).toBe(shape(b))
  })

  it('keeps its corners inside a shape too small for them', () => {
    const path = islandPath({ width: 10, height: 4, radius: 22, shoulder: 10 }, 50)
    expect(path).not.toContain('NaN')
    expect(path).toContain('A 4 4')
  })

})

describe('the morph', () => {
  it('grows in 220 ms and settles in 240 — quick both ways', () => {
    expect(TIMING.open.shape).toEqual([0, 220])
    expect(TIMING.close.shape[1]).toBe(240)
  })

  it('fades the panel’s words in only once the shape is most of the way grown', () => {
    expect(TIMING.open.full[0]).toBeGreaterThanOrEqual(TIMING.open.shape[1] / 2)
    expect(TIMING.open.full[1]).toBe(TIMING.open.shape[1])
  })

  it('fades the words out before the shape has gone far, and the pill’s back as it lands', () => {
    expect(TIMING.close.full[1]).toBeLessThanOrEqual(TIMING.close.shape[0] + 40)
    expect(TIMING.close.rest[1]).toBe(TIMING.close.shape[1])
  })

  it('eases without ever passing its target, so nothing overshoots and jerks back', () => {
    for (const ease of [EASE_OPEN, EASE_CLOSE]) {
      const [x1, y1, x2, y2] = ease.match(/[\d.]+/g)?.map(Number) ?? []
      for (const v of [x1, y1, x2, y2]) expect(v).toBeGreaterThanOrEqual(0)
      for (const v of [y1, y2]) expect(v).toBeLessThanOrEqual(1)
    }
  })

  it('writes each part’s timing as a CSS transition', () => {
    expect(transition('clip-path', [40, 240], EASE_CLOSE)).toBe(`clip-path 200ms ${EASE_CLOSE} 40ms`)
  })

  it('mixes two shapes, the way a transition between their outlines passes through them', () => {
    const a = { width: 100, height: 30, radius: 12, shoulder: 6 }
    const b = { width: 600, height: 130, radius: 22, shoulder: 10 }
    expect(mixShape(a, b, 0.5)).toEqual({ width: 350, height: 80, radius: 17, shoulder: 8 })
    expect(edgeShape(a)).toEqual({ width: 102, height: 31, radius: 13, shoulder: 6 })
  })
})
