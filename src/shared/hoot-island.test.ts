import { describe, expect, it } from 'vitest'
import {
  barRow,
  EXPANDED,
  expandedShape,
  grownness,
  islandCentre,
  placeIsland,
  REST,
  restShape,
  SHADOW,
  SPRING_CLOSE,
  SPRING_OPEN,
  springSettled,
  springStep,
  unionBox,
  windowBox,
  type IslandGeometry,
  type Spring,
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

  it('with a notch: wraps it, the same ear each side, so nothing hides behind the camera', () => {
    const shape = restShape(MACBOOK, { textWidth: 30, attention: false })
    expect(shape.height).toBe(32)
    const ear = (shape.width - 200) / 2
    expect(Number.isInteger(ear)).toBe(true)
    // The left ear carries the owl, the right one the words; each fits its own.
    expect(ear).toBeGreaterThanOrEqual(REST.owl + REST.earPad * 2)
    expect(ear).toBeGreaterThanOrEqual(30 + REST.earPad * 2)
  })

  it('a longer line widens both ears around the notch', () => {
    const short = restShape(MACBOOK, { textWidth: 30, attention: false })
    const long = restShape(MACBOOK, { textWidth: 130, attention: true })
    expect(long.width).toBeGreaterThan(short.width)
    expect((long.width - 200) / 2).toBe(130 + REST.dot + REST.dotGap + REST.earPad * 2)
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

  it('is always wider than the pill it grows out of', () => {
    const wide = restShape(MACBOOK, { textWidth: 200, attention: true })
    expect(expandedShape(MACBOOK, 100, wide).width).toBeGreaterThan(wide.width)
  })
})

describe('the window around the shape', () => {
  it('at rest holds the pill and its shoulders and nothing else', () => {
    const shape = restShape(MINI, { textWidth: 30, attention: false })
    expect(windowBox(shape, false)).toEqual({ width: shape.width + shape.shoulder * 2, height: shape.height })
  })

  it('grown, leaves room for the shadow beside and below — never above, the top is the screen edge', () => {
    const shape = expandedShape(MINI, 100)
    const box = windowBox(shape, true)
    expect(box.width).toBe(shape.width + shape.shoulder * 2 + SHADOW.side * 2)
    expect(box.height).toBe(shape.height + SHADOW.bottom)
  })

  it('while moving, holds both ends of the move', () => {
    expect(unionBox({ width: 90, height: 30 }, { width: 700, height: 170 })).toEqual({ width: 700, height: 170 })
  })

  it('is centred on the notch, or the middle of the display, with its top on the top edge', () => {
    const mini = { x: 0, y: 0, width: 1920, height: 1080 }
    expect(islandCentre(mini, null)).toBe(960)
    expect(placeIsland(mini, 960, { width: 86, height: 30 })).toEqual({ x: 917, y: 0, width: 86, height: 30 })
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

describe('the morph', () => {
  const run = (from: number, to: number, config = SPRING_OPEN, frames = 120): number[] => {
    let spring: Spring = { value: from, velocity: 0 }
    const seen: number[] = []
    for (let i = 0; i < frames; i += 1) {
      spring = springStep(spring, to, 1 / 60, config)
      seen.push(spring.value)
    }
    return seen
  }

  it('grows quickly, with a little give at the end, and comes to rest on the target', () => {
    const seen = run(30, 130)
    const peak = Math.max(...seen)
    expect(peak).toBeGreaterThan(130)
    expect(peak).toBeLessThan(140)
    expect(seen.at(-1)).toBeCloseTo(130, 1)
    // Most of the way there inside a quarter of a second.
    expect(seen[14]).toBeGreaterThan(110)
  })

  it('settles back without dipping under its resting size', () => {
    const seen = run(130, 30, SPRING_CLOSE)
    expect(Math.min(...seen)).toBeGreaterThan(29)
    expect(seen.at(-1)).toBeCloseTo(30, 1)
  })

  it('a long, missed frame is taken in small steps, not one wild one', () => {
    const one = springStep({ value: 30, velocity: 0 }, 130, 0.5, SPRING_OPEN)
    expect(Number.isFinite(one.value)).toBe(true)
    expect(Math.abs(one.value - 130)).toBeLessThan(100)
  })

  it('knows when to stop, and how far along a shape is', () => {
    expect(springSettled({ value: 129.8, velocity: 1 }, 130)).toBe(true)
    expect(springSettled({ value: 125, velocity: 0 }, 130)).toBe(false)
    expect(grownness(30, 30, 130)).toBe(0)
    expect(grownness(80, 30, 130)).toBe(0.5)
    expect(grownness(140, 30, 130)).toBe(1)
  })
})
