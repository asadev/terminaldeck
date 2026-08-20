import { describe, expect, it } from 'vitest'
import { foldedActions, groupFor, type FoldableButton, type Placed } from './toolbar-overflow'
import type { Box } from './popup-anchor'

/**
 * The overflow's two decisions, on plain rectangles.
 *
 * Both of them are the kind of thing that reads as obviously right and is
 * obviously wrong once there are two browser panels open, or once a control is
 * pressed while the panel is narrow. Neither needs a DOM to state.
 */

function box(x: number, y: number, width: number, height: number): Box {
  return { x, y, width, height }
}

function group(rect: Box): Placed {
  return { getBoundingClientRect: () => rect }
}

function button(label: string, width: number, disabled = false): FoldableButton {
  return {
    disabled,
    getBoundingClientRect: () => box(0, 0, width, 24),
    getAttribute: (name) => (name === 'title' ? label : null),
  }
}

describe('which action group a menu belongs to', () => {
  it('picks the group the anchor sits inside, not the first one on the page', () => {
    // A split shows two browser panels, each with its own bar. The menu is
    // portalled to `<body>`, so document order says nothing about which ⋯ was
    // pressed.
    const left = group(box(0, 40, 240, 24))
    const right = group(box(700, 40, 240, 24))
    expect(groupFor([left, right], box(880, 40, 24, 24))).toBe(right)
    expect(groupFor([left, right], box(180, 40, 24, 24))).toBe(left)
  })

  it('is null when the anchor is inside none of them', () => {
    expect(groupFor([group(box(0, 40, 240, 24))], box(900, 400, 24, 24))).toBeNull()
  })
})

describe('which actions folded', () => {
  it('offers the ones with no width, in bar order', () => {
    const record = button('Record', 0)
    const shot = button('Shot', 0)
    const folded = foldedActions([button('Inspect', 24), record, shot])
    expect(folded.map((action) => action.label)).toEqual(['Record', 'Shot'])
    expect(folded[0]?.button).toBe(record)
  })

  it('leaves a control that is still on the bar out of the menu', () => {
    // While a recording runs its button stays on the bar — the stylesheet keeps
    // a pressed control there — and one control in two places at once is the
    // duplication he objected to by name.
    expect(foldedActions([button('Stop (8)', 24)])).toEqual([])
  })

  it('carries the button’s own disabled state onto the row', () => {
    // Draw is disabled on a build whose preload never wired it. A row that
    // looked pressable and did nothing would be worse than no row.
    expect(foldedActions([button('Draw', 0, true)])[0]?.disabled).toBe(true)
  })

  it('skips a button with no name rather than offering a blank row', () => {
    const nameless: FoldableButton = {
      disabled: false,
      getBoundingClientRect: () => box(0, 0, 0, 24),
      getAttribute: () => null,
    }
    expect(foldedActions([nameless])).toEqual([])
  })
})
