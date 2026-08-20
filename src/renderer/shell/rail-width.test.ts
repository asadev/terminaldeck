import { describe, expect, it } from 'vitest'
import { RAIL_MAX, RAIL_MIN, clampRail, widthAfterDrag } from './rail-width'

/**
 * The rail's seam, which is now dragged by two things.
 *
 * The arithmetic left `useSidebar` on 2026-08-21 so that the copilot's side
 * panel — which takes the rail's column while it is driving a page — could be
 * dragged by the same edge without a second copy of it. Two copies of a drag is
 * how the panel and the rail come to disagree about where the seam is, and a gap
 * between them is the exact defect this round of work is about.
 */

describe('dragging the seam', () => {
  it('follows the pointer from where the drag began', () => {
    expect(widthAfterDrag(264, 400, 430)).toBe(294)
    expect(widthAfterDrag(264, 400, 370)).toBe(234)
  })

  it('stops at both bounds rather than following past them', () => {
    expect(widthAfterDrag(264, 400, 40)).toBe(RAIL_MIN)
    expect(widthAfterDrag(264, 400, 4000)).toBe(RAIL_MAX)
  })

  it('clamps a width from anywhere else the same way', () => {
    expect(clampRail(0)).toBe(RAIL_MIN)
    expect(clampRail(10_000)).toBe(RAIL_MAX)
    expect(clampRail(300)).toBe(300)
  })
})
