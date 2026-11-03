import { describe, expect, it } from 'vitest'
import {
  arrowHead,
  beginMark,
  extendMark,
  headLength,
  isDrawn,
  markPaths,
  onFrame,
  paintMarks,
  strokeWidth,
  undoMark,
  type Mark,
  type MarkContext,
} from './marks'

/**
 * The draw tool's model, held down where it can be held down.
 *
 * There is no DOM in this project's test run, so the canvas cannot be exercised
 * — which is exactly why `paintMarks` takes a structural context. The recorder
 * below is that context, and it is the only thing standing between "the marks
 * are drawn" and "the marks are drawn in a colour nobody can see on a red
 * button", which is the failure mode this feature actually has.
 */

type Call =
  | { op: 'style'; value: unknown }
  | { op: 'width'; value: number }
  | { op: 'begin' }
  | { op: 'move'; x: number; y: number }
  | { op: 'line'; x: number; y: number }
  | { op: 'stroke' }

function recorder(): { ctx: MarkContext; calls: Call[] } {
  const calls: Call[] = []
  const ctx: MarkContext = {
    lineCap: '',
    lineJoin: '',
    set lineWidth(value: number) {
      calls.push({ op: 'width', value })
    },
    get lineWidth() {
      return 0
    },
    set strokeStyle(value: unknown) {
      calls.push({ op: 'style', value })
    },
    get strokeStyle() {
      return ''
    },
    beginPath: () => calls.push({ op: 'begin' }),
    moveTo: (x, y) => calls.push({ op: 'move', x, y }),
    lineTo: (x, y) => calls.push({ op: 'line', x, y }),
    stroke: () => calls.push({ op: 'stroke' }),
  }
  return { ctx, calls }
}

const RED = 'rgb(189, 58, 44)'

/** Every colour the painter set, in order. */
function styles(calls: Call[]): unknown[] {
  return calls.filter((call): call is Extract<Call, { op: 'style' }> => call.op === 'style').map((c) => c.value)
}

describe('a mark being drawn', () => {
  it('starts as two points at the pointer, so a shape exists before the first move', () => {
    const mark = beginMark('rect', { x: 0.2, y: 0.3 })
    expect(mark.points).toEqual([
      { x: 0.2, y: 0.3 },
      { x: 0.2, y: 0.3 },
    ])
  })

  it('keeps a rectangle and an arrow at exactly two points however far the drag goes', () => {
    let rect = beginMark('rect', { x: 0.1, y: 0.1 })
    for (const step of [0.2, 0.3, 0.4, 0.5]) rect = extendMark(rect, { x: step, y: step })
    expect(rect.points).toEqual([
      { x: 0.1, y: 0.1 },
      { x: 0.5, y: 0.5 },
    ])
  })

  it('grows a freehand stroke, but drops samples too close to matter', () => {
    let free = beginMark('free', { x: 0.1, y: 0.1 })
    // A pointermove fires every frame; a slow hand produces hundreds of points a
    // third of a pixel apart, and keeping them all would repaint a thousand-node
    // path on every frame for a line that looks identical.
    for (let i = 0; i < 50; i++) free = extendMark(free, { x: 0.1 + i * 0.00001, y: 0.1 })
    expect(free.points).toHaveLength(2)

    free = extendMark(free, { x: 0.2, y: 0.1 })
    expect(free.points).toHaveLength(3)
  })

  it('clamps a drag that left the canvas back onto the frame', () => {
    // Pointer capture keeps the events coming after the pointer leaves the
    // element, which is how a mark ends up at x = 1.4 and paints nowhere.
    expect(onFrame({ x: 1.4, y: -0.2 })).toEqual({ x: 1, y: 0 })
    expect(extendMark(beginMark('arrow', { x: 0.5, y: 0.5 }), { x: 2, y: 2 }).points[1]).toEqual({
      x: 1,
      y: 1,
    })
  })
})

describe('what counts as a mark at all', () => {
  it('throws away a click that the trackpad turned into a one-pixel drag', () => {
    // Otherwise the picture collects invisible specks and Undo has to be pressed
    // once per speck with nothing disappearing from the screen — a control that
    // appears not to work.
    expect(isDrawn(extendMark(beginMark('rect', { x: 0.5, y: 0.5 }), { x: 0.501, y: 0.5 }))).toBe(false)
  })

  it('keeps a real drag', () => {
    expect(isDrawn(extendMark(beginMark('rect', { x: 0.2, y: 0.2 }), { x: 0.6, y: 0.5 }))).toBe(true)
  })

  it('judges freehand on the path travelled, not on where it ended', () => {
    // A circle ends where it started. End-to-end distance would discard the one
    // gesture this whole tool exists for.
    let circle = beginMark('free', { x: 0.5, y: 0.5 })
    for (const point of [
      { x: 0.56, y: 0.5 },
      { x: 0.56, y: 0.56 },
      { x: 0.5, y: 0.56 },
      { x: 0.5, y: 0.5 },
    ]) {
      circle = extendMark(circle, point)
    }
    expect(circle.points[0]).toEqual(circle.points[circle.points.length - 1])
    expect(isDrawn(circle)).toBe(true)
  })
})

describe('undo', () => {
  it('removes the last mark and nothing else', () => {
    const marks: Mark[] = [
      { kind: 'rect', points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] },
      { kind: 'arrow', points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] },
    ]
    expect(undoMark(marks)).toEqual([marks[0]])
    expect(undoMark([])).toEqual([])
  })
})

describe('the shapes, in frame pixels', () => {
  it('closes a rectangle back onto its first corner', () => {
    const [path] = markPaths(
      { kind: 'rect', points: [{ x: 0.25, y: 0.5 }, { x: 0.75, y: 1 }] },
      400,
      200,
    )
    expect(path).toEqual([
      { x: 100, y: 100 },
      { x: 300, y: 100 },
      { x: 300, y: 200 },
      { x: 100, y: 200 },
      { x: 100, y: 100 },
    ])
  })

  it('draws an arrow as a shaft and one unbroken head through the tip', () => {
    // Two separate barbs would cross at the point and leave a notch exactly
    // where the eye is being sent.
    const paths = markPaths({ kind: 'arrow', points: [{ x: 0, y: 0 }, { x: 0.5, y: 0 }] }, 400, 400)
    expect(paths).toHaveLength(2)
    expect(paths[0]).toEqual([
      { x: 0, y: 0 },
      { x: 200, y: 0 },
    ])
    const [left, tip, right] = paths[1]
    expect(tip).toEqual({ x: 200, y: 0 })
    // Barbs behind the tip, one above the shaft and one below it.
    expect(left.x).toBeLessThan(tip.x)
    expect(right.x).toBeLessThan(tip.x)
    expect(Math.sign(left.y - tip.y)).toBe(-Math.sign(right.y - tip.y))
  })

  it('keeps a short arrow from being all head', () => {
    expect(headLength(30, 2000)).toBeCloseTo(9.6, 5)
    // …and a long one from growing a head the size of what it points at.
    expect(headLength(1500, 2000)).toBeCloseTo(70, 5)
  })

  it('points the head along the shaft whichever way it was drawn', () => {
    const back = arrowHead({ x: 300, y: 0 }, { x: 100, y: 0 }, 400)
    // Drawn right-to-left, the barbs trail to the right of the tip.
    expect(back[0].x).toBeGreaterThan(100)
    expect(back[1].x).toBeGreaterThan(100)
  })
})

describe('painting', () => {
  it('draws a halo under every mark, so red is legible on a red button', () => {
    const { ctx, calls } = recorder()
    paintMarks(ctx, [{ kind: 'rect', points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] }], 1000, 800, RED)

    const order = styles(calls)
    expect(order).toHaveLength(2)
    expect(String(order[0])).toContain('255, 255, 255')
    expect(order[1]).toBe(RED)
  })

  it('haloes each mark just before its own colour, not all haloes first', () => {
    // Scribbling over the same spot is normal. One pass of haloes followed by one
    // pass of colour would let a later halo erase an earlier line where they
    // cross.
    const { ctx, calls } = recorder()
    const mark: Mark = { kind: 'free', points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] }
    paintMarks(ctx, [mark, mark], 1000, 800, RED)
    expect(styles(calls).map((value) => (value === RED ? 'red' : 'halo'))).toEqual([
      'halo',
      'red',
      'halo',
      'red',
    ])
  })

  it('draws the halo wider than the line it is under', () => {
    const { ctx, calls } = recorder()
    paintMarks(ctx, [{ kind: 'free', points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] }], 1000, 800, RED)
    const widths = calls.filter((c): c is Extract<Call, { op: 'width' }> => c.op === 'width')
    expect(widths[0].value).toBeGreaterThan(widths[1].value)
  })

  it('scales the stroke with the frame, so the saved PNG is not a hairline', () => {
    // The same marks are painted onto a canvas the size of the page on screen
    // and onto a capture at the display's own resolution.
    expect(strokeWidth(1000)).toBe(2)
    expect(strokeWidth(2000)).toBe(4)
    expect(strokeWidth(100)).toBe(2)
  })

  it('paints nothing at all when there are no marks', () => {
    const { ctx, calls } = recorder()
    paintMarks(ctx, [], 1000, 800, RED)
    expect(calls.filter((call) => call.op === 'stroke')).toHaveLength(0)
  })
})
