import { describe, expect, it } from 'vitest'
import { measureSlots, sameBoxes, slotStyle, SLOT_ATTR, type SlotElement, type SlotHost } from './pane-slots'

/**
 * A terminal that cannot be moved into a pane, drawn over the pane anyway.
 *
 * The arithmetic is the whole feature and it is the half a browser cannot be
 * asked about here: jsdom answers every `getBoundingClientRect` with zeroes, so
 * a test written against a rendered tree would pass while measuring nothing.
 * `measureSlots` therefore takes the smallest structural interface it can and
 * these fixtures supply real numbers.
 */

function slot(id: string, box: { top: number; left: number; width: number; height: number }): SlotElement {
  return {
    getAttribute: (name) => (name === SLOT_ATTR ? id : null),
    getBoundingClientRect: () => box,
  }
}

function host(
  origin: { top: number; left: number; width: number; height: number },
  slots: readonly SlotElement[],
): SlotHost {
  return {
    getBoundingClientRect: () => origin,
    querySelectorAll: () => slots,
  }
}

describe('where a pane hole is', () => {
  it('answers in the pane area own coordinates, not the window', () => {
    /*
     * The pane area sits below the tab strip and to the right of the sidebar, and
     * the terminals are absolutely positioned *inside* it. Handed viewport
     * numbers a pane would be drawn one sidebar-width to the right and one strip
     * down — and would drift every time either changed.
     */
    const boxes = measureSlots(
      host({ top: 80, left: 264, width: 1000, height: 600 }, [
        slot('local:1', { top: 108, left: 264, width: 500, height: 572 }),
        slot('srv:office a', { top: 108, left: 764, width: 500, height: 572 }),
      ]),
    )
    expect(boxes['local:1']).toEqual({ top: 28, left: 0, width: 500, height: 572 })
    expect(boxes['srv:office a']).toEqual({ top: 28, left: 500, width: 500, height: 572 })
  })

  it('leaves out a hole with no area rather than recording a corner', () => {
    /*
     * A slot measured before layout has run has no width. Recording it as 0x0
     * would put the terminal in the top-left corner of the pane area for a frame
     * — a real terminal, visibly in the wrong place — where leaving it out draws
     * it where it already was.
     */
    const boxes = measureSlots(
      host({ top: 0, left: 0, width: 800, height: 600 }, [
        slot('not-laid-out', { top: 0, left: 0, width: 0, height: 0 }),
      ]),
    )
    expect(boxes).toEqual({})
  })

  it('ignores a slot that names nothing', () => {
    const boxes = measureSlots(
      host({ top: 0, left: 0, width: 800, height: 600 }, [
        { getAttribute: () => '', getBoundingClientRect: () => ({ top: 0, left: 0, width: 10, height: 10 }) },
      ]),
    )
    expect(boxes).toEqual({})
  })

  it('says there is nothing to measure without a pane area', () => {
    expect(measureSlots(null)).toEqual({})
  })
})

describe('re-measuring while a divider is dragged', () => {
  /*
   * The observers fire on every frame of a drag. Rebuilding the state each time
   * would re-render the whole window sixty times a second for a rectangle that
   * has not moved, and re-rendering the window is re-rendering every terminal in
   * it.
   */
  it('calls sub-pixel jitter the same picture', () => {
    const a = { p: { top: 10, left: 0, width: 500.02, height: 400 } }
    const b = { p: { top: 10, left: 0, width: 500.04, height: 400 } }
    expect(sameBoxes(a, b)).toBe(true)
  })

  it('calls a real move a different picture', () => {
    const a = { p: { top: 10, left: 0, width: 500, height: 400 } }
    const b = { p: { top: 10, left: 0, width: 520, height: 400 } }
    expect(sameBoxes(a, b)).toBe(false)
  })

  it('notices a pane appearing or going', () => {
    const one = { p: { top: 0, left: 0, width: 10, height: 10 } }
    const two = { ...one, q: { top: 0, left: 10, width: 10, height: 10 } }
    expect(sameBoxes(one, two)).toBe(false)
    expect(sameBoxes(two, one)).toBe(false)
  })

  it('notices a pane being renamed even when the count holds', () => {
    const one = { p: { top: 0, left: 0, width: 10, height: 10 } }
    const other = { q: { top: 0, left: 0, width: 10, height: 10 } }
    expect(sameBoxes(one, other)).toBe(false)
  })
})

describe('standing in the hole', () => {
  it('releases the four sides before setting them', () => {
    /*
     * The stylesheet places these panes with `inset: 0` — "fill the pane area",
     * which is the unsplit window. A `top` and a `left` alone would leave `right`
     * and `bottom` pinned to the far edges, so the pane would be stretched rather
     * than moved: two terminals, both as wide as the window, overlapping.
     */
    const style = slotStyle({ top: 28, left: 500, width: 500, height: 572 })
    expect(style).toEqual({
      inset: 'auto',
      top: '28px',
      left: '500px',
      width: '500px',
      height: '572px',
    })
  })

  it('says nothing at all when no pane is holding it', () => {
    // Which leaves the stylesheet's `inset: 0`, and that is the unsplit window.
    expect(slotStyle(undefined)).toBeUndefined()
  })
})
