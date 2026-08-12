import { describe, expect, it } from 'vitest'
import {
  MIN_PANE_RATIO,
  clampRatio,
  closePane,
  closePanesForSession,
  computeRects,
  createLayout,
  deserialiseLayout,
  emptyLayout,
  findPane,
  focusPane,
  focusSession,
  focusedPane,
  focusedSessionId,
  listPanes,
  moveFocus,
  paneCount,
  panesForSession,
  resizeSplit,
  serialiseLayout,
  sessionIds,
  setPaneSession,
  splitPane,
  type FocusDirection,
  type PaneLayout,
  type PaneNode,
} from './pane-tree'

/**
 * Every pane id below is passed in explicitly. The generated ids are random by
 * design, so tests that assert on structure supply their own and the one test
 * that cares about generation checks uniqueness instead.
 */

function ids(layout: PaneLayout): string[] {
  return listPanes(layout).map((p) => p.id)
}

/** Panes in visual order, named by the session each one shows. */
function order(layout: PaneLayout): (string | null)[] {
  return listPanes(layout).map((p) => p.sessionId)
}

/**
 * A 2×2 grid, built the way a user would: split left/right, then split each
 * column top/bottom.
 *
 *   ┌─────────┬─────────┐
 *   │   nw    │   ne    │
 *   ├─────────┼─────────┤
 *   │   sw    │   se    │
 *   └─────────┴─────────┘
 */
function quadLayout(): PaneLayout {
  let layout = createLayout('nw', 'nw')
  layout = splitPane(layout, 'nw', 'horizontal', {
    sessionId: 'ne',
    paneId: 'ne',
    splitId: 'root-split',
  })
  layout = splitPane(layout, 'nw', 'vertical', {
    sessionId: 'sw',
    paneId: 'sw',
    splitId: 'west-split',
  })
  layout = splitPane(layout, 'ne', 'vertical', {
    sessionId: 'se',
    paneId: 'se',
    splitId: 'east-split',
  })
  return focusPane(layout, 'nw')
}

/** One tall pane on the left, two stacked on the right. */
function threePaneLayout(): PaneLayout {
  let layout = createLayout('a', 'a')
  layout = splitPane(layout, 'a', 'horizontal', { sessionId: 'b', paneId: 'b', splitId: 's1' })
  layout = splitPane(layout, 'b', 'vertical', { sessionId: 'c', paneId: 'c', splitId: 's2' })
  return layout
}

/**
 * Structural invariants that must hold after any sequence of operations.
 * Faults are collected and asserted once — this runs inside a hot loop, and a
 * per-node `expect` call is orders of magnitude slower than the check itself.
 */
function assertWellFormed(layout: PaneLayout): void {
  const faults: string[] = []
  const seen = new Set<string>()

  const walk = (node: PaneNode): void => {
    if (seen.has(node.id)) faults.push(`duplicate id ${node.id}`)
    seen.add(node.id)
    if (node.type === 'leaf') return
    if (node.children.length !== 2) faults.push(`split ${node.id} has ${node.children.length} children`)
    if (node.ratio < MIN_PANE_RATIO || node.ratio > 1 - MIN_PANE_RATIO) {
      faults.push(`split ${node.id} ratio ${node.ratio} outside the clamp`)
    }
    walk(node.children[0])
    walk(node.children[1])
  }

  if (layout.root) walk(layout.root)

  const paneIds = ids(layout)
  if (layout.focusedPaneId === null) {
    if (paneIds.length > 0) faults.push('panes exist but nothing is focused')
  } else if (!paneIds.includes(layout.focusedPaneId)) {
    faults.push(`focus ${layout.focusedPaneId} names no pane`)
  }

  expect(faults).toEqual([])
}

describe('createLayout / emptyLayout', () => {
  it('starts empty with nothing focused', () => {
    const layout = emptyLayout()
    expect(layout.root).toBeNull()
    expect(layout.focusedPaneId).toBeNull()
    expect(paneCount(layout)).toBe(0)
    expect(focusedPane(layout)).toBeNull()
    expect(focusedSessionId(layout)).toBeNull()
  })

  it('starts a single focused pane', () => {
    const layout = createLayout('s1', 'p1')
    expect(layout.root).toEqual({ type: 'leaf', id: 'p1', sessionId: 's1' })
    expect(layout.focusedPaneId).toBe('p1')
    expect(paneCount(layout)).toBe(1)
    expect(focusedSessionId(layout)).toBe('s1')
  })

  it('allows a pane with no session yet', () => {
    expect(createLayout().root).toMatchObject({ type: 'leaf', sessionId: null })
  })
})

describe('splitPane', () => {
  it('puts the new pane after the existing one and focuses it', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'horizontal', {
      sessionId: 'b',
      paneId: 'b',
      splitId: 's',
    })
    expect(layout.root).toEqual({
      type: 'split',
      id: 's',
      direction: 'horizontal',
      ratio: 0.5,
      children: [
        { type: 'leaf', id: 'a', sessionId: 'a' },
        { type: 'leaf', id: 'b', sessionId: 'b' },
      ],
    })
    expect(layout.focusedPaneId).toBe('b')
  })

  it('can put the new pane first', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'vertical', {
      sessionId: 'b',
      paneId: 'b',
      insertFirst: true,
    })
    expect(order(layout)).toEqual(['b', 'a'])
  })

  it('can leave focus on the pane that was split', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'horizontal', {
      paneId: 'b',
      keepFocus: true,
    })
    expect(layout.focusedPaneId).toBe('a')
  })

  it('keeps the existing pane node identical so its terminal never remounts', () => {
    const before = createLayout('a', 'a')
    const after = splitPane(before, 'a', 'horizontal', { paneId: 'b' })
    const root = after.root
    if (root?.type !== 'split') throw new Error('expected a split')
    expect(root.children[0]).toBe(before.root)
  })

  it('clamps an extreme ratio', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'horizontal', { ratio: 0.99, paneId: 'b' })
    const root = layout.root
    if (root?.type !== 'split') throw new Error('expected a split')
    expect(root.ratio).toBe(1 - MIN_PANE_RATIO)
  })

  it('splits a nested pane without disturbing its siblings', () => {
    const layout = splitPane(threePaneLayout(), 'c', 'horizontal', {
      sessionId: 'd',
      paneId: 'd',
      splitId: 's3',
    })
    expect(order(layout)).toEqual(['a', 'b', 'c', 'd'])
    assertWellFormed(layout)
  })

  it('ignores an unknown pane id', () => {
    const before = createLayout('a', 'a')
    expect(splitPane(before, 'nope', 'horizontal')).toBe(before)
  })

  it('ignores a split id — only panes split', () => {
    const before = threePaneLayout()
    expect(splitPane(before, 's1', 'horizontal')).toBe(before)
  })

  it('ignores a split on an empty layout', () => {
    const before = emptyLayout()
    expect(splitPane(before, 'anything', 'vertical')).toBe(before)
  })

  it('mints unique ids when none are supplied', () => {
    let layout = createLayout('a')
    for (let i = 0; i < 60; i++) {
      const target = listPanes(layout)[i % paneCount(layout)].id
      layout = splitPane(layout, target, i % 2 === 0 ? 'horizontal' : 'vertical')
    }
    expect(new Set(ids(layout)).size).toBe(paneCount(layout))
    expect(paneCount(layout)).toBe(61)
    assertWellFormed(layout)
  })
})

describe('splitPane id and depth safety', () => {
  // Regression: an explicit id that was already in the tree used to be honoured
  // verbatim, and the result could not be closed or restored correctly.
  it('mints a fresh id rather than duplicating a pane id that is taken', () => {
    let layout = createLayout('a', 'dup')
    layout = splitPane(layout, 'dup', 'horizontal', { sessionId: 'b', paneId: 'dup' })

    const paneIds = ids(layout)
    expect(paneIds).toHaveLength(2)
    expect(new Set(paneIds).size).toBe(2)
    expect(paneIds[0]).toBe('dup')
    expect(order(layout)).toEqual(['a', 'b'])
    assertWellFormed(layout)
  })

  it('refuses an empty id, which the parser will not accept either', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'horizontal', { paneId: '', splitId: '' })
    expect(ids(layout).every((id) => id.length > 0)).toBe(true)
    expect(deserialiseLayout(serialiseLayout(layout))).toEqual(layout)
  })

  it('does not let a split id collide with an existing node', () => {
    let layout = createLayout('a', 'a')
    layout = splitPane(layout, 'a', 'horizontal', { paneId: 'b', splitId: 's' })
    layout = splitPane(layout, 'b', 'vertical', { paneId: 'c', splitId: 's' })
    assertWellFormed(layout)
    expect(deserialiseLayout(serialiseLayout(layout))).toEqual(layout)
  })

  it('does not let one call take the same id for its pane and its split', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'horizontal', {
      paneId: 'same',
      splitId: 'same',
    })
    assertWellFormed(layout)
  })

  it('keeps a duplicated id from costing the user the whole layout on restart', () => {
    let layout = createLayout('a', 'dup')
    layout = splitPane(layout, 'dup', 'horizontal', { sessionId: 'b', paneId: 'dup' })
    // deserialiseLayout rejects duplicate ids outright, so building one meant
    // the stored layout came back null and was replaced by a fresh one.
    expect(deserialiseLayout(serialiseLayout(layout))).toEqual(layout)
  })

  it('closes the pane that was asked for, not its twin', () => {
    let layout = createLayout('a', 'dup')
    layout = splitPane(layout, 'dup', 'horizontal', { sessionId: 'b', paneId: 'dup' })
    expect(order(closePane(layout, 'dup'))).toEqual(['b'])
    expect(order(closePane(layout, ids(layout)[1]))).toEqual(['a'])
  })

  it('stops splitting before the tree gets too deep to restore', () => {
    let layout = createLayout('s0')
    for (let i = 0; i < 200; i += 1) {
      const deepest = listPanes(layout)[listPanes(layout).length - 1]
      layout = splitPane(layout, deepest.id, 'horizontal', { sessionId: `s${i + 1}` })
    }
    assertWellFormed(layout)
    // Whatever it stopped at, the layout must still survive a restart.
    expect(deserialiseLayout(serialiseLayout(layout))).toEqual(layout)
    // A spine 64 splits deep is the deepest the parser accepts, so 65 panes.
    expect(paneCount(layout)).toBe(65)
  })
})

describe('closePane', () => {
  it('promotes the sibling to the parent slot', () => {
    const layout = closePane(threePaneLayout(), 'a')
    expect(order(layout)).toEqual(['b', 'c'])
    const root = layout.root
    if (root?.type !== 'split') throw new Error('expected a split')
    expect(root.id).toBe('s2')
    assertWellFormed(layout)
  })

  it('promotes a whole subtree, not just a leaf', () => {
    // Closing the lone left pane hands the entire right column to the root.
    const layout = closePane(quadLayout(), 'nw')
    expect(order(layout)).toEqual(['sw', 'ne', 'se'])
    assertWellFormed(layout)
  })

  it('empties the layout when the last pane closes', () => {
    const layout = closePane(createLayout('a', 'a'), 'a')
    expect(layout.root).toBeNull()
    expect(layout.focusedPaneId).toBeNull()
    expect(paneCount(layout)).toBe(0)
  })

  it('survives closing every pane one at a time', () => {
    let layout = quadLayout()
    for (const paneId of ['ne', 'sw', 'nw', 'se']) {
      layout = closePane(layout, paneId)
      assertWellFormed(layout)
    }
    expect(layout).toEqual(emptyLayout())
  })

  it('survives closing every pane from the front', () => {
    let layout = quadLayout()
    while (paneCount(layout) > 0) {
      layout = closePane(layout, listPanes(layout)[0].id)
      assertWellFormed(layout)
    }
    expect(layout.root).toBeNull()
  })

  it('leaves focus alone when another pane closes', () => {
    const layout = closePane(focusPane(threePaneLayout(), 'a'), 'c')
    expect(layout.focusedPaneId).toBe('a')
  })

  it('moves focus to the sibling edge nearest the closed pane', () => {
    // 'nw' sat above 'sw'; closing it should focus 'sw', not the far column.
    expect(closePane(quadLayout(), 'nw').focusedPaneId).toBe('sw')
  })

  it('picks the last leaf of the sibling when the second child closes', () => {
    // Left column is a stack (nw over sw); closing the right column's 'ne'
    // should land on 'sw' — the leaf nearest where 'ne' was, reading back.
    const layout = focusPane(quadLayout(), 'ne')
    const closed = closePane(closePane(layout, 'se'), 'ne')
    expect(closed.focusedPaneId).toBe('sw')
  })

  it('ignores an unknown pane id', () => {
    const before = threePaneLayout()
    expect(closePane(before, 'nope')).toBe(before)
  })

  it('ignores a split id', () => {
    const before = threePaneLayout()
    expect(closePane(before, 's1')).toBe(before)
  })

  it('ignores an empty layout', () => {
    const before = emptyLayout()
    expect(closePane(before, 'a')).toBe(before)
  })
})

describe('closePanesForSession', () => {
  it('closes every pane showing a dead session', () => {
    let layout = threePaneLayout()
    layout = setPaneSession(layout, 'c', 'b')
    expect(panesForSession(layout, 'b')).toHaveLength(2)

    layout = closePanesForSession(layout, 'b')
    expect(order(layout)).toEqual(['a'])
    assertWellFormed(layout)
  })

  it('empties the layout when the session filled it', () => {
    let layout = createLayout('a', 'a')
    layout = splitPane(layout, 'a', 'horizontal', { sessionId: 'a', paneId: 'a2' })
    expect(closePanesForSession(layout, 'a')).toEqual(emptyLayout())
  })

  it('does nothing for a session that is not open', () => {
    const before = threePaneLayout()
    expect(closePanesForSession(before, 'zzz')).toBe(before)
  })
})

describe('resizeSplit', () => {
  it('moves the divider', () => {
    const layout = resizeSplit(threePaneLayout(), 's1', 0.7)
    const root = layout.root
    if (root?.type !== 'split') throw new Error('expected a split')
    expect(root.ratio).toBe(0.7)
  })

  it('clamps at both ends so a pane never collapses to nothing', () => {
    expect(clampRatio(-4)).toBe(MIN_PANE_RATIO)
    expect(clampRatio(4)).toBe(1 - MIN_PANE_RATIO)
    expect(clampRatio(Number.NaN)).toBe(0.5)
    expect(clampRatio(0.5, 0.3)).toBe(0.5)
    expect(clampRatio(0.1, 0.3)).toBe(0.3)
    // A pixel floor bigger than half the container cannot pin both sides.
    expect(clampRatio(0.9, 0.8)).toBe(0.5)
  })

  it('resizes a nested split without touching the outer one', () => {
    const layout = resizeSplit(threePaneLayout(), 's2', 0.25)
    const root = layout.root
    if (root?.type !== 'split') throw new Error('expected a split')
    expect(root.ratio).toBe(0.5)
    expect(computeRects(layout.root).map((r) => Number(r.height.toFixed(3)))).toEqual([1, 0.25, 0.75])
  })

  it('returns the same layout when the ratio does not move', () => {
    const before = threePaneLayout()
    expect(resizeSplit(before, 's1', 0.5)).toBe(before)
  })

  it('ignores unknown ids, leaf ids and empty layouts', () => {
    const before = threePaneLayout()
    expect(resizeSplit(before, 'nope', 0.3)).toBe(before)
    expect(resizeSplit(before, 'a', 0.3)).toBe(before)
    expect(resizeSplit(emptyLayout(), 's1', 0.3)).toEqual(emptyLayout())
  })
})

describe('focusPane / focusSession / setPaneSession', () => {
  it('focuses an existing pane', () => {
    expect(focusPane(threePaneLayout(), 'a').focusedPaneId).toBe('a')
  })

  it('returns the same layout when already focused or unknown', () => {
    const before = focusPane(threePaneLayout(), 'a')
    expect(focusPane(before, 'a')).toBe(before)
    expect(focusPane(before, 'nope')).toBe(before)
    expect(focusPane(before, 's1')).toBe(before)
  })

  it('focuses the first pane showing a session', () => {
    const layout = focusSession(threePaneLayout(), 'a')
    expect(layout.focusedPaneId).toBe('a')
    expect(focusSession(layout, 'ghost')).toBe(layout)
  })

  it('repoints a pane at another session without moving it', () => {
    const layout = setPaneSession(threePaneLayout(), 'b', 'other')
    expect(order(layout)).toEqual(['a', 'other', 'c'])
    expect(sessionIds(layout)).toEqual(['a', 'other', 'c'])
  })

  it('returns the same layout when the session is unchanged or the pane unknown', () => {
    const before = threePaneLayout()
    expect(setPaneSession(before, 'b', 'b')).toBe(before)
    expect(setPaneSession(before, 'nope', 'x')).toBe(before)
    expect(setPaneSession(emptyLayout(), 'a', 'x')).toEqual(emptyLayout())
  })

  it('can empty a pane', () => {
    expect(order(setPaneSession(threePaneLayout(), 'b', null))).toEqual(['a', null, 'c'])
  })

  it('reports each session once even when open twice', () => {
    const layout = setPaneSession(threePaneLayout(), 'c', 'a')
    expect(sessionIds(layout)).toEqual(['a', 'b'])
  })
})

describe('computeRects', () => {
  it('gives a single pane the whole area', () => {
    expect(computeRects(createLayout('a', 'a').root)).toEqual([
      { paneId: 'a', sessionId: 'a', x: 0, y: 0, width: 1, height: 1 },
    ])
  })

  it('divides a horizontal split along x', () => {
    const layout = resizeSplit(
      splitPane(createLayout('a', 'a'), 'a', 'horizontal', { paneId: 'b', splitId: 's' }),
      's',
      0.3,
    )
    expect(computeRects(layout.root)).toEqual([
      { paneId: 'a', sessionId: 'a', x: 0, y: 0, width: 0.3, height: 1 },
      { paneId: 'b', sessionId: null, x: 0.3, y: 0, width: 0.7, height: 1 },
    ])
  })

  it('divides a vertical split along y', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'vertical', { paneId: 'b' })
    expect(computeRects(layout.root).map((r) => [r.y, r.height])).toEqual([
      [0, 0.5],
      [0.5, 0.5],
    ])
  })

  it('nests correctly', () => {
    expect(computeRects(quadLayout().root)).toEqual([
      { paneId: 'nw', sessionId: 'nw', x: 0, y: 0, width: 0.5, height: 0.5 },
      { paneId: 'sw', sessionId: 'sw', x: 0, y: 0.5, width: 0.5, height: 0.5 },
      { paneId: 'ne', sessionId: 'ne', x: 0.5, y: 0, width: 0.5, height: 0.5 },
      { paneId: 'se', sessionId: 'se', x: 0.5, y: 0.5, width: 0.5, height: 0.5 },
    ])
  })

  it('honours custom bounds', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'horizontal', { paneId: 'b' })
    expect(computeRects(layout.root, { x: 10, y: 20, width: 200, height: 100 })).toEqual([
      { paneId: 'a', sessionId: 'a', x: 10, y: 20, width: 100, height: 100 },
      { paneId: 'b', sessionId: null, x: 110, y: 20, width: 100, height: 100 },
    ])
  })

  it('returns nothing for an empty layout', () => {
    expect(computeRects(null)).toEqual([])
  })
})

describe('moveFocus', () => {
  /** Focus `from`, move, and report the session now focused. */
  function step(layout: PaneLayout, from: string, direction: FocusDirection): string | null {
    return focusedSessionId(moveFocus(focusPane(layout, from), direction))
  }

  it('moves across a horizontal split', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'horizontal', {
      sessionId: 'b',
      paneId: 'b',
    })
    expect(step(layout, 'a', 'right')).toBe('b')
    expect(step(layout, 'b', 'left')).toBe('a')
  })

  it('does not move along the axis a horizontal split does not span', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'horizontal', { paneId: 'b' })
    const focused = focusPane(layout, 'a')
    expect(moveFocus(focused, 'up')).toBe(focused)
    expect(moveFocus(focused, 'down')).toBe(focused)
  })

  it('moves across a vertical split', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'vertical', {
      sessionId: 'b',
      paneId: 'b',
    })
    expect(step(layout, 'a', 'down')).toBe('b')
    expect(step(layout, 'b', 'up')).toBe('a')
    const focused = focusPane(layout, 'a')
    expect(moveFocus(focused, 'left')).toBe(focused)
    expect(moveFocus(focused, 'right')).toBe(focused)
  })

  it('stops at the edges of the grid', () => {
    const layout = quadLayout()
    const nw = focusPane(layout, 'nw')
    expect(moveFocus(nw, 'left')).toBe(nw)
    expect(moveFocus(nw, 'up')).toBe(nw)
    const se = focusPane(layout, 'se')
    expect(moveFocus(se, 'right')).toBe(se)
    expect(moveFocus(se, 'down')).toBe(se)
  })

  it('walks every direction of a 2×2 grid', () => {
    const layout = quadLayout()
    expect(step(layout, 'nw', 'right')).toBe('ne')
    expect(step(layout, 'nw', 'down')).toBe('sw')
    expect(step(layout, 'ne', 'left')).toBe('nw')
    expect(step(layout, 'ne', 'down')).toBe('se')
    expect(step(layout, 'sw', 'right')).toBe('se')
    expect(step(layout, 'sw', 'up')).toBe('nw')
    expect(step(layout, 'se', 'left')).toBe('sw')
    expect(step(layout, 'se', 'up')).toBe('ne')
  })

  it('steps one column at a time rather than jumping to the far edge', () => {
    let layout = createLayout('a', 'a')
    layout = splitPane(layout, 'a', 'horizontal', { sessionId: 'b', paneId: 'b' })
    layout = splitPane(layout, 'b', 'horizontal', { sessionId: 'c', paneId: 'c' })
    expect(step(layout, 'a', 'right')).toBe('b')
    expect(step(layout, 'c', 'left')).toBe('b')
  })

  it('crosses from a tall pane into a stack, preferring the top on a tie', () => {
    // 'a' spans the full height, so 'b' and 'c' are equally close to its
    // centre line. The tie resolves upward, so the same key always lands here.
    const layout = threePaneLayout()
    expect(step(layout, 'a', 'right')).toBe('b')
  })

  it('crosses out of a stack back to the pane beside it', () => {
    const layout = threePaneLayout()
    expect(step(layout, 'b', 'left')).toBe('a')
    expect(step(layout, 'c', 'left')).toBe('a')
    expect(step(layout, 'b', 'down')).toBe('c')
    expect(step(layout, 'c', 'up')).toBe('b')
  })

  it('follows the divider when the stack is uneven', () => {
    // Shrink the top-right pane to 20%: 'a' centre (0.5) now sits inside 'c'.
    const layout = resizeSplit(threePaneLayout(), 's2', 0.2)
    expect(step(layout, 'a', 'right')).toBe('c')
  })

  it('picks whichever of three stacked neighbours straddles the centre line', () => {
    let layout = createLayout('a', 'a')
    layout = splitPane(layout, 'a', 'horizontal', { sessionId: 'b', paneId: 'b', splitId: 's1' })
    layout = splitPane(layout, 'b', 'vertical', { sessionId: 'c', paneId: 'c', splitId: 's2' })
    layout = splitPane(layout, 'c', 'vertical', { sessionId: 'd', paneId: 'd', splitId: 's3' })

    // 'a' spans the full height, so its centre line (y 0.5) decides. Evenly
    // split, the right column is b 0–0.5, c 0.5–0.75, d 0.75–1 — 'c' is the
    // one whose centre sits closest to 0.5.
    expect(step(layout, 'a', 'right')).toBe('c')

    // Give 'b' nine tenths of the column and it swallows the centre line.
    expect(step(resizeSplit(layout, 's2', 0.9), 'a', 'right')).toBe('b')

    // Squeeze both dividers to the top and 'd' owns everything below 0.19.
    const bottomHeavy = resizeSplit(resizeSplit(layout, 's2', 0.1), 's3', 0.1)
    expect(step(bottomHeavy, 'a', 'right')).toBe('d')
  })

  it('reaches a neighbour that shares no edge at all', () => {
    // 'sw' is squeezed into the bottom 10%, so moving right from it finds a
    // pane it does not overlap. It should still move rather than dead-end.
    const layout = resizeSplit(resizeSplit(quadLayout(), 'west-split', 0.9), 'east-split', 0.1)
    expect(step(layout, 'sw', 'up')).toBe('nw')
    expect(step(layout, 'sw', 'right')).not.toBeNull()
  })

  it('lands somewhere when nothing is focused yet', () => {
    const layout: PaneLayout = { ...threePaneLayout(), focusedPaneId: null }
    expect(moveFocus(layout, 'right').focusedPaneId).toBe('a')
    expect(moveFocus(layout, 'up').focusedPaneId).toBe('a')
  })

  it('ignores an empty layout', () => {
    const before = emptyLayout()
    expect(moveFocus(before, 'left')).toBe(before)
  })

  it('never leaves focus on a pane that does not exist', () => {
    const directions: FocusDirection[] = ['left', 'right', 'up', 'down']
    let layout = quadLayout()
    for (const direction of directions) {
      layout = moveFocus(layout, direction)
      assertWellFormed(layout)
    }
  })
})

describe('serialiseLayout / deserialiseLayout', () => {
  it('round-trips structure and focus', () => {
    const layout = resizeSplit(focusPane(quadLayout(), 'se'), 'root-split', 0.35)
    const restored = deserialiseLayout(serialiseLayout(layout))
    expect(restored).toEqual(layout)
  })

  it('round-trips an empty layout', () => {
    expect(deserialiseLayout(serialiseLayout(emptyLayout()))).toEqual(emptyLayout())
  })

  it('rejects anything it cannot trust', () => {
    expect(deserialiseLayout('')).toBeNull()
    expect(deserialiseLayout('not json')).toBeNull()
    expect(deserialiseLayout('[]')).toBeNull()
    expect(deserialiseLayout('42')).toBeNull()
    expect(deserialiseLayout('null')).toBeNull()
    expect(deserialiseLayout(JSON.stringify({ version: 99, root: null }))).toBeNull()
  })

  it('rejects duplicate ids, which would make closing a pane ambiguous', () => {
    const twin: PaneNode = {
      type: 'split',
      id: 's',
      direction: 'horizontal',
      ratio: 0.5,
      children: [
        { type: 'leaf', id: 'dup', sessionId: 'a' },
        { type: 'leaf', id: 'dup', sessionId: 'b' },
      ],
    }
    expect(
      deserialiseLayout(JSON.stringify({ version: 1, root: twin, focusedPaneId: 'dup' })),
    ).toBeNull()
  })

  it('rejects malformed nodes', () => {
    const bad = (root: unknown): string =>
      JSON.stringify({ version: 1, root, focusedPaneId: null })

    expect(deserialiseLayout(bad({ type: 'leaf' }))).toBeNull()
    expect(deserialiseLayout(bad({ type: 'leaf', id: '', sessionId: null }))).toBeNull()
    expect(deserialiseLayout(bad({ type: 'leaf', id: 'a', sessionId: 7 }))).toBeNull()
    expect(deserialiseLayout(bad({ type: 'wat', id: 'a' }))).toBeNull()
    expect(
      deserialiseLayout(
        bad({ type: 'split', id: 's', direction: 'sideways', ratio: 0.5, children: [] }),
      ),
    ).toBeNull()
    expect(
      deserialiseLayout(
        bad({
          type: 'split',
          id: 's',
          direction: 'horizontal',
          ratio: 'half',
          children: [
            { type: 'leaf', id: 'a', sessionId: null },
            { type: 'leaf', id: 'b', sessionId: null },
          ],
        }),
      ),
    ).toBeNull()
    // A split must have exactly two children — one or three is a broken tree.
    expect(
      deserialiseLayout(
        bad({
          type: 'split',
          id: 's',
          direction: 'horizontal',
          ratio: 0.5,
          children: [{ type: 'leaf', id: 'a', sessionId: null }],
        }),
      ),
    ).toBeNull()
  })

  it('rejects a focus id of the wrong type', () => {
    const layout = serialiseLayout(createLayout('a', 'a')).replace('"a"}', '7}')
    expect(deserialiseLayout(layout)).toBeNull()
  })

  it('rejects a tree too deep to be real, rather than blowing the stack', () => {
    let root: PaneNode = { type: 'leaf', id: 'leaf-0', sessionId: null }
    for (let i = 1; i <= 80; i++) {
      root = {
        type: 'split',
        id: `split-${i}`,
        direction: 'horizontal',
        ratio: 0.5,
        children: [root, { type: 'leaf', id: `leaf-${i}`, sessionId: null }],
      }
    }
    expect(
      deserialiseLayout(JSON.stringify({ version: 1, root, focusedPaneId: 'leaf-0' })),
    ).toBeNull()
  })

  it('clamps a stored ratio that would collapse a pane', () => {
    const root: PaneNode = {
      type: 'split',
      id: 's',
      direction: 'horizontal',
      ratio: 0.999,
      children: [
        { type: 'leaf', id: 'a', sessionId: null },
        { type: 'leaf', id: 'b', sessionId: null },
      ],
    }
    const restored = deserialiseLayout(JSON.stringify({ version: 1, root, focusedPaneId: 'a' }))
    expect(restored?.root).toMatchObject({ ratio: 1 - MIN_PANE_RATIO })
  })

  it('repairs a focus id that no longer names a pane', () => {
    const layout = quadLayout()
    const text = JSON.stringify({
      version: 1,
      root: layout.root,
      focusedPaneId: 'deleted-in-a-previous-run',
    })
    expect(deserialiseLayout(text)?.focusedPaneId).toBe('nw')
  })

  it('repairs a focus id pointing at a split rather than a pane', () => {
    const layout = quadLayout()
    const text = JSON.stringify({ version: 1, root: layout.root, focusedPaneId: 'root-split' })
    expect(deserialiseLayout(text)?.focusedPaneId).toBe('nw')
  })

  it('survives a restored layout being edited further', () => {
    const restored = deserialiseLayout(serialiseLayout(quadLayout()))
    if (!restored) throw new Error('expected a layout')
    const layout = splitPane(restored, 'se', 'horizontal', { sessionId: 'new' })
    expect(paneCount(layout)).toBe(5)
    assertWellFormed(layout)
  })
})

describe('invariants under random editing', () => {
  /** Deterministic PRNG so a failure is reproducible. */
  function mulberry32(seed: number): () => number {
    let a = seed
    return () => {
      a |= 0
      a = (a + 0x6d2b79f5) | 0
      let t = Math.imul(a ^ (a >>> 15), 1 | a)
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296
    }
  }

  const directions: FocusDirection[] = ['left', 'right', 'up', 'down']

  it('stays well formed across 400 random operations', () => {
    for (let seed = 1; seed <= 6; seed++) {
      const rand = mulberry32(seed)
      let layout = createLayout('s0')
      let sessionCounter = 0

      for (let step = 0; step < 400; step++) {
        const panes = listPanes(layout)
        const roll = rand()

        if (panes.length === 0) {
          layout = createLayout(`s${(sessionCounter += 1)}`)
        } else if (roll < 0.45) {
          const target = panes[Math.floor(rand() * panes.length)]
          layout = splitPane(layout, target.id, rand() < 0.5 ? 'horizontal' : 'vertical', {
            sessionId: `s${(sessionCounter += 1)}`,
          })
        } else if (roll < 0.7) {
          layout = closePane(layout, panes[Math.floor(rand() * panes.length)].id)
        } else if (roll < 0.85) {
          layout = moveFocus(layout, directions[Math.floor(rand() * 4)])
        } else {
          // Resizing needs a split id, and every layout with 2+ panes has one.
          const root = layout.root
          if (root && root.type === 'split') layout = resizeSplit(layout, root.id, rand())
        }

        assertWellFormed(layout)
        // Rects must always tile the unit square exactly, with no overlap.
        const rects = computeRects(layout.root)
        const area = rects.reduce((sum, r) => sum + r.width * r.height, 0)
        if (rects.length > 0) expect(area).toBeCloseTo(1, 9)
        expect(rects).toHaveLength(paneCount(layout))

        // And a round trip must never change the layout. Sampled rather than
        // checked every step — the deep compare dominates the run otherwise.
        if (step % 25 === 0) expect(deserialiseLayout(serialiseLayout(layout))).toEqual(layout)
      }
    }
  })
})

describe('findPane / listPanes ordering', () => {
  it('finds a pane by id and reports null otherwise', () => {
    const layout = threePaneLayout()
    expect(findPane(layout, 'b')).toEqual({ type: 'leaf', id: 'b', sessionId: 'b' })
    expect(findPane(layout, 'nope')).toBeNull()
    expect(findPane(layout, 's1')).toBeNull()
  })

  it('lists panes left to right, top to bottom', () => {
    expect(ids(quadLayout())).toEqual(['nw', 'sw', 'ne', 'se'])
  })
})
