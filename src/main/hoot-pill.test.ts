import { describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({ BrowserWindow: class {}, nativeImage: {} }))

const { PILL_HEIGHT, PILL_MAX_WIDTH, PILL_MIN_WIDTH, PILL_PAINT_SOURCE, widthsBetween } = await import('./hoot-pill')

describe('how the pill grows', () => {
  it('passes through widths that only grow, easing in to the new one, and ends exactly on it', () => {
    const widths = widthsBetween(68, 150, 5)
    expect(widths).toHaveLength(5)
    expect(widths.at(-1)).toBe(150)
    expect(widths).toEqual([...widths].sort((a, b) => a - b))
    // Eased out: the first step is the biggest.
    expect(widths[0] - 68).toBeGreaterThan(widths[4] - widths[3])
  })

  it('settles the same way in the other direction, and takes one step when asked for one', () => {
    expect(widthsBetween(150, 68, 5).at(-1)).toBe(68)
    expect(widthsBetween(68, 150, 1)).toEqual([150])
    expect(widthsBetween(90, 90, 5)).toEqual([90])
  })
})

describe('the painter', () => {
  it('is plain source the page can run, sized to a status item and kept between a dot and a banner', () => {
    expect(PILL_HEIGHT).toBe(22)
    expect(PILL_MIN_WIDTH).toBeGreaterThan(PILL_HEIGHT * 2)
    expect(PILL_MAX_WIDTH).toBeLessThanOrEqual(200)
    // It must parse as one expression, or `executeJavaScript` throws on every paint.
    expect(() => new Function(`return (${PILL_PAINT_SOURCE})`)).not.toThrow()
  })
})
