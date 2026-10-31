import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
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

/* ----------------------------------------------------- the hole has a size -- */

/**
 * The stylesheet has to give the hole a rectangle, or none of the above runs.
 *
 * This is the assertion the arithmetic tests above could never make, and the
 * bug it closes shipped past every one of them. `.pane-remote-slot` is an empty
 * `<div>`: it has no content, so its height comes entirely from CSS. It carried
 * `flex: 1; min-height: 0`, and its only parent — `.pane-cell-body` — is
 * `position: relative; flex: 1; min-height: 0` with no `display` of its own,
 * which is to say a **block** container. `flex: 1` on the child of a block box
 * does nothing at all, so every slot in the window measured `width × 0`.
 *
 * `measureSlots` above drops a zero box on purpose, so the result was `{}`;
 * `pageOnScreen()` in `App.tsx` requires an entry there while the window is
 * split; and `.bw[data-visible='false']` is `display: none`. Splitting the
 * window therefore emptied both panes — measured in a real window on
 * 2026-08-23 as two slots of 584×0 and 568×0 inside bodies of 584×804 and
 * 568×754, with both pages hidden and nothing on screen.
 *
 * Read as text rather than rendered because jsdom has no layout engine — the
 * same reason the fixtures above supply their own numbers. Either arrangement
 * is accepted: fill the positioning parent, or make the parent a flex column.
 * What is refused is the third state, which is what shipped: a slot that asks
 * for flex growth from a parent that does not lay its children out that way.
 */
describe('the stylesheet behind the hole', () => {
  const sheet = readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), '..', 'shell', 'shell.css'),
    'utf8',
  )

  /** One rule body out of the sheet, by selector. */
  const ruleFor = (selector: string): string => {
    const at = sheet.indexOf(`\n${selector} {`)
    expect(at, `${selector} is not in shell.css`).toBeGreaterThan(-1)
    const open = sheet.indexOf('{', at)
    const close = sheet.indexOf('}', open)
    return sheet.slice(open + 1, close)
  }

  it('gives the slot a height that does not depend on the parent being flex', () => {
    const slotRule = ruleFor('.pane-remote-slot')
    const bodyRule = ruleFor('.pane-cell-body')

    const fillsItsParent =
      /position:\s*absolute/.test(slotRule) && /inset:\s*0/.test(slotRule)
    const parentIsAColumn =
      /display:\s*flex/.test(bodyRule) && /flex-direction:\s*column/.test(bodyRule)

    expect(
      fillsItsParent || parentIsAColumn,
      'an empty .pane-remote-slot is 0px tall unless it fills .pane-cell-body or that body is a flex column',
    ).toBe(true)
  })

  it('does not leave the slot asking a block parent to grow it', () => {
    const slotRule = ruleFor('.pane-remote-slot')
    const bodyRule = ruleFor('.pane-cell-body')
    if (/display:\s*flex/.test(bodyRule)) return
    expect(slotRule, '.pane-cell-body is not a flex container, so flex: 1 sizes nothing').not.toMatch(
      /(^|[\s;])flex:\s*1/,
    )
  })
})
