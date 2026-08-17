import { describe, expect, it } from 'vitest'
import {
  clipRect,
  hasArea,
  outlineBands,
  outsideOf,
  ringStyle,
  padRect,
  rectOf,
  sameEdges,
  sameRect,
  unionRect,
  type Rect,
} from './geometry'

const rect = (x: number, y: number, width: number, height: number): Rect => ({
  x,
  y,
  width,
  height,
})

describe('clipping decides which borders are real', () => {
  const pane = rect(100, 100, 400, 300)

  it('keeps all four edges for a region wholly inside', () => {
    const clipped = clipRect(rect(150, 150, 100, 50), pane)
    expect(clipped?.edges).toEqual({ top: true, right: true, bottom: true, left: true })
    expect(clipped?.rect).toEqual(rect(150, 150, 100, 50))
  })

  /*
   * The defect this whole mechanism exists for.
   *
   * A nineteen-line terminal region scrolled one row above the top of the pane
   * still has eighteen visible lines. xterm's own decoration renderer answers
   * this by hiding the decoration outright once the marker line leaves the
   * viewport, which loses all eighteen. This keeps them, and drops only the
   * border that would otherwise be drawn across the top of the *viewport* while
   * claiming to be the top of the passage.
   */
  it('drops the top border when the region is scrolled off the top', () => {
    const clipped = clipRect(rect(150, 40, 100, 200), pane)
    expect(clipped?.edges.top).toBe(false)
    expect(clipped?.edges.bottom).toBe(true)
    expect(clipped?.rect.y).toBe(100)
    expect(clipped?.rect.height).toBe(140)
  })

  it('drops the bottom border when the region runs past the foot', () => {
    const clipped = clipRect(rect(150, 350, 100, 200), pane)
    expect(clipped?.edges.bottom).toBe(false)
    expect(clipped?.edges.top).toBe(true)
  })

  /*
   * Not clamped to the edge. A box pinned to the top of a pane is a box
   * asserting the passage is at the top of the pane, and during a tour that is
   * a confident lie about where the evidence is.
   */
  it('returns null rather than a sliver when the region is entirely above', () => {
    expect(clipRect(rect(150, -500, 100, 200), pane)).toBeNull()
  })

  it('returns null for a region entirely to the right', () => {
    expect(clipRect(rect(900, 150, 100, 50), pane)).toBeNull()
  })

  it('treats a region flush with the container edge as having its own edge', () => {
    const clipped = clipRect(rect(100, 100, 400, 300), pane)
    expect(clipped?.edges).toEqual({ top: true, right: true, bottom: true, left: true })
  })
})

describe('padding grows outward', () => {
  it('adds the pad on every side', () => {
    expect(padRect(rect(10, 20, 30, 40), 3)).toEqual(rect(7, 17, 36, 46))
  })

  it('is the identity at zero, which is what a browser page gets', () => {
    expect(padRect(rect(10, 20, 30, 40), 0)).toEqual(rect(10, 20, 30, 40))
  })
})

describe('a browser page keeps every pixel of itself', () => {
  /*
   * The rule this asserts is physics, not style: a `WebContentsView` is
   * composited above the whole renderer, so any overlay pixel inside its
   * rectangle is not drawn at all. A ring that took even one pixel of the page
   * would have a gap in it and nothing on screen would say why.
   *
   * The ring is a 1px border on a box grown by 1px, which is exactly
   * `outlineBands(rect, 1)`. If someone changes it to a border *inside* the
   * box — the obvious simplification — this fails.
   */
  const page = rect(400, 120, 800, 600)

  it('draws its ring entirely outside the page', () => {
    expect(outsideOf(outlineBands(page, 1), page)).toBe(true)
    expect(outsideOf(outlineBands(page, 3), page)).toBe(true)
  })

  it('would fail for a ring drawn inside the page', () => {
    const inside = [rect(page.x, page.y, page.width, 1)]
    expect(outsideOf(inside, page)).toBe(false)
  })

  it('the four bands meet at the corners with no gap', () => {
    const [top, bottom, left, right] = outlineBands(page, 2)
    expect(top.width).toBe(page.width + 4)
    expect(bottom.y).toBe(page.y + page.height)
    expect(left.height).toBe(page.height)
    expect(right.x).toBe(page.x + page.width)
  })
})

describe('a cut edge is drawn as a cut, not as a missing border', () => {
  /*
   * Suppressing the border colour alone was not enough, and the gap was only
   * visible on screen at 4x: the ring's 3px glow still wrapped the cut side and
   * the corners under it stayed round, so a passage scrolled off the top of a
   * pane read as a closed box whose top border had failed to paint.
   */
  const whole = { top: true, right: true, bottom: true, left: true }

  it('leaves an uncut ring alone', () => {
    expect(ringStyle(whole, 7, 3)).toEqual({ clipPath: undefined, borderRadius: '7px 7px 7px 7px' })
  })

  it('trims the glow flush to a cut top and squares the two corners on it', () => {
    const style = ringStyle({ ...whole, top: false }, 7, 3)
    expect(style.clipPath).toBe('inset(0px -3px -3px -3px)')
    expect(style.borderRadius).toBe('0px 0px 7px 7px')
  })

  it('handles two cut sides at once', () => {
    const style = ringStyle({ top: false, right: true, bottom: false, left: true }, 7, 3)
    expect(style.clipPath).toBe('inset(0px -3px 0px -3px)')
    expect(style.borderRadius).toBe('0px 0px 0px 0px')
  })

  /*
   * A browser page's hole has square corners already — a rounded hole would
   * claim the native view has rounded corners, and since HTML cannot paint
   * inside that rectangle the rounding would simply never appear.
   */
  it('keeps a page ring square', () => {
    expect(ringStyle(whole, 0, 3).borderRadius).toBe('0px')
  })
})

describe('sameRect tolerates sub-pixel noise and nothing more', () => {
  /*
   * The tolerance is why this feature does not set React state sixty times a
   * second while nothing moves. `getBoundingClientRect()` reports at 1/64 px and
   * a real xterm row measured 22.5078125 against a computed 22.5152.
   */
  it('ignores a sixteenth of a pixel', () => {
    expect(sameRect(rect(10, 22.5078125, 30, 40), rect(10, 22.5152, 30, 40))).toBe(true)
  })

  it('notices a whole pixel', () => {
    expect(sameRect(rect(10, 20, 30, 40), rect(10, 21, 30, 40))).toBe(false)
  })

  it('handles nulls without pretending they match a rectangle', () => {
    expect(sameRect(null, null)).toBe(true)
    expect(sameRect(null, rect(0, 0, 1, 1))).toBe(false)
  })
})

describe('the small helpers', () => {
  it('unions only rectangles with area', () => {
    expect(unionRect([rect(0, 0, 0, 0), rect(10, 10, 5, 5)])).toEqual(rect(10, 10, 5, 5))
    expect(unionRect([])).toBeNull()
    expect(unionRect([rect(0, 0, 10, 10), rect(20, 5, 10, 10)])).toEqual(rect(0, 0, 30, 15))
  })

  it('knows an empty rectangle from a real one', () => {
    expect(hasArea(rect(0, 0, 0, 10))).toBe(false)
    expect(hasArea(rect(0, 0, 1, 1))).toBe(true)
  })

  it('compares edge sets', () => {
    const all = { top: true, right: true, bottom: true, left: true }
    expect(sameEdges(all, { ...all })).toBe(true)
    expect(sameEdges(all, { ...all, top: false })).toBe(false)
  })

  it('reads a DOM box into the same shape', () => {
    const element = { getBoundingClientRect: () => ({ left: 4, top: 8, width: 16, height: 32 }) }
    expect(rectOf(element)).toEqual(rect(4, 8, 16, 32))
  })
})
