import { describe, expect, it } from 'vitest'
import {
  centreOn,
  displayAt,
  fitInto,
  placeNew,
  placeRestored,
  placementFile,
  reachableOn,
  readPlacements,
  type DisplayInfo,
} from './popout-placement'

/**
 * Two monitors side by side, the desk Asad described: the built-in screen on
 * the left with the menu bar, a bigger one to its right.
 */
const LAPTOP: DisplayInfo = {
  id: 1,
  bounds: { x: 0, y: 0, width: 1512, height: 982 },
  workArea: { x: 0, y: 38, width: 1512, height: 944 },
  label: 'Built-in Retina Display',
}
const MONITOR: DisplayInfo = {
  id: 7,
  bounds: { x: 1512, y: -200, width: 2560, height: 1440 },
  workArea: { x: 1512, y: -200, width: 2560, height: 1415 },
  label: 'DELL U2723QE',
}

describe('where a remembered window comes back', () => {
  const onMonitor = { bounds: { x: 2000, y: 100, width: 1100, height: 700 }, displayId: 7 }

  it('goes back exactly where it was when the monitor is still there', () => {
    const placed = placeRestored(onMonitor, [LAPTOP, MONITOR], LAPTOP)
    expect(placed.outcome).toBe('same-display')
    expect(placed.display.id).toBe(7)
    expect(placed.bounds).toEqual(onMonitor.bounds)
  })

  it('falls back onto the main screen when that monitor has gone, at a size that fits', () => {
    const placed = placeRestored(onMonitor, [LAPTOP], LAPTOP)
    expect(placed.outcome).toBe('fallback-primary')
    expect(placed.display.id).toBe(1)
    // Wholly inside the laptop's work area, so its title bar can be reached.
    const b = placed.bounds
    expect(b.x).toBeGreaterThanOrEqual(LAPTOP.workArea.x)
    expect(b.y).toBeGreaterThanOrEqual(LAPTOP.workArea.y)
    expect(b.x + b.width).toBeLessThanOrEqual(LAPTOP.workArea.x + LAPTOP.workArea.width)
    expect(b.y + b.height).toBeLessThanOrEqual(LAPTOP.workArea.y + LAPTOP.workArea.height)
    expect(reachableOn(b, LAPTOP)).toBe(true)
  })

  it('trusts where the window is over a display id that changed on reconnect', () => {
    const renumbered: DisplayInfo = { ...MONITOR, id: 99 }
    const placed = placeRestored(onMonitor, [LAPTOP, renumbered], LAPTOP)
    expect(placed.outcome).toBe('moved-display')
    expect(placed.display.id).toBe(99)
    expect(placed.bounds).toEqual(onMonitor.bounds)
  })

  it('brings a window whose title bar is off the top of every screen back where it can be grabbed', () => {
    const lost = { bounds: { x: 300, y: -900, width: 800, height: 600 }, displayId: 1 }
    const placed = placeRestored(lost, [LAPTOP], LAPTOP)
    expect(placed.outcome).toBe('fallback-primary')
    expect(reachableOn(placed.bounds, LAPTOP)).toBe(true)
  })

  it('shrinks a window from a bigger screen to fit a smaller one rather than hanging off it', () => {
    const huge = { bounds: { x: 1600, y: 0, width: 2400, height: 1300 }, displayId: 7 }
    const placed = placeRestored(huge, [LAPTOP], LAPTOP)
    expect(placed.bounds.width).toBeLessThanOrEqual(LAPTOP.workArea.width)
    expect(placed.bounds.height).toBeLessThanOrEqual(LAPTOP.workArea.height)
  })
})

describe('where a new window opens', () => {
  it('lands under the pointer when a tab is let go on the other monitor', () => {
    const placed = placeNew({ at: { x: 3000, y: 400 }, main: null, displays: [LAPTOP, MONITOR], primary: LAPTOP, open: 0 })
    expect(placed.display.id).toBe(7)
    expect(placed.bounds.y).toBe(386)
    expect(placed.bounds.x + placed.bounds.width / 2).toBe(3000)
  })

  it('is centred on a display a tool named', () => {
    const placed = placeNew({ display: MONITOR, main: null, displays: [LAPTOP, MONITOR], primary: LAPTOP, open: 0 })
    expect(placed.display.id).toBe(7)
    expect(placed.bounds).toEqual(centreOn({ width: 960, height: 640 }, MONITOR.workArea))
  })

  it('steps down from the main window, and a second steps further, so neither hides the other', () => {
    const main = { x: 100, y: 100, width: 1400, height: 860 }
    const first = placeNew({ main, displays: [LAPTOP], primary: LAPTOP, open: 0 }).bounds
    const second = placeNew({ main, displays: [LAPTOP], primary: LAPTOP, open: 1 }).bounds
    expect(first.x).toBeGreaterThan(main.x)
    expect(second.x).toBeGreaterThan(first.x)
    expect(second.y).toBeGreaterThan(first.y)
  })

  it('stays on screen when let go right at the edge', () => {
    const placed = placeNew({ at: { x: 5, y: 970 }, main: null, displays: [LAPTOP], primary: LAPTOP, open: 0 })
    expect(placed.bounds.x).toBeGreaterThanOrEqual(0)
    expect(placed.bounds.y + placed.bounds.height).toBeLessThanOrEqual(982)
  })
})

describe('the remembered file', () => {
  it('reads back what it wrote', () => {
    const rows = [{ key: 'tab-1', bounds: { x: 2000, y: 100, width: 900, height: 600 }, displayId: 7, fullScreen: false }]
    expect(readPlacements(JSON.parse(JSON.stringify(placementFile(rows))))).toEqual(rows)
  })

  it('drops a broken row and keeps the rest', () => {
    const read = readPlacements({
      v: 1,
      windows: [
        { key: 'good', bounds: { x: 0, y: 0, width: 800, height: 600 }, displayId: 1 },
        { key: 'no-size', bounds: { x: 0, y: 0, width: 0, height: 600 } },
        { bounds: { x: 0, y: 0, width: 800, height: 600 } },
        'nonsense',
      ],
    })
    expect(read.map((row) => row.key)).toEqual(['good'])
  })

  it('reads nothing from a file of another shape', () => {
    expect(readPlacements(null)).toEqual([])
    expect(readPlacements({ v: 2, windows: [] })).toEqual([])
    expect(readPlacements('[]')).toEqual([])
  })
})

describe('the small helpers', () => {
  it('finds the display under a point, and none between displays', () => {
    expect(displayAt({ x: 10, y: 10 }, [LAPTOP, MONITOR])?.id).toBe(1)
    expect(displayAt({ x: 2000, y: 0 }, [LAPTOP, MONITOR])?.id).toBe(7)
    expect(displayAt({ x: -50, y: 10 }, [LAPTOP, MONITOR])).toBeNull()
  })

  it('fits a rectangle inside an area, size first', () => {
    expect(fitInto({ x: -100, y: -100, width: 5000, height: 5000 }, LAPTOP.workArea)).toEqual(LAPTOP.workArea)
  })
})
