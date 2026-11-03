import { describe, expect, it } from 'vitest'
import {
  addWidget,
  applyPlacements,
  canAddWidget,
  countWidgets,
  createLayout,
  DASHBOARD_COLUMNS,
  DASHBOARD_VERSION,
  defaultLayout,
  findFreeSlot,
  hasWidgetType,
  isRetiredWidget,
  layoutRows,
  MAX_ROW,
  MAX_WIDGET_ROWS,
  MAX_WIDGETS,
  moveWidget,
  overlaps,
  parseLayout,
  readingOrder,
  removeWidget,
  resizeWidget,
  serialiseLayout,
  specFor,
  WIDGET_SPECS,
  WIDGET_TYPES,
  widgetById,
  type DashboardLayout,
  type Rect,
  type WidgetType,
} from './layout'

const PROJECT = '/Users/asad/Projects/terminaldeck'

/** Build a layout from explicit rectangles, bypassing the placement search. */
function seed(rects: Array<[string, WidgetType, number, number, number, number]>): DashboardLayout {
  return {
    ...createLayout(PROJECT),
    widgets: rects.map(([id, type, x, y, w, h]) => ({ id, type, x, y, w, h })),
  }
}

/** Compact geometry, so an assertion reads as the picture it describes. */
function rects(layout: DashboardLayout): Record<string, string> {
  const out: Record<string, string> = {}
  for (const widget of layout.widgets) out[widget.id] = `${widget.x},${widget.y} ${widget.w}x${widget.h}`
  return out
}

function everyPair(layout: DashboardLayout, visit: (a: Rect, b: Rect) => void): void {
  for (let i = 0; i < layout.widgets.length; i += 1) {
    for (let j = i + 1; j < layout.widgets.length; j += 1) visit(layout.widgets[i], layout.widgets[j])
  }
}

function expectSound(layout: DashboardLayout): void {
  everyPair(layout, (a, b) => {
    if (overlaps(a, b)) throw new Error(`overlap: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`)
  })
  for (const widget of layout.widgets) {
    expect(widget.x).toBeGreaterThanOrEqual(0)
    expect(widget.y).toBeGreaterThanOrEqual(0)
    expect(widget.x + widget.w).toBeLessThanOrEqual(layout.columns)
    expect(widget.w).toBeGreaterThanOrEqual(WIDGET_SPECS[widget.type].minW)
    expect(widget.h).toBeGreaterThanOrEqual(WIDGET_SPECS[widget.type].minH)
  }
}

describe('specs', () => {
  it('every advertised type has a spec that fits the grid', () => {
    for (const type of WIDGET_TYPES) {
      const spec = specFor(type)
      expect(spec).toBeDefined()
      if (!spec) continue
      expect(spec.minW).toBeLessThanOrEqual(spec.w)
      expect(spec.minH).toBeLessThanOrEqual(spec.h)
      // A default wider than the grid could never be placed as advertised.
      expect(spec.w).toBeLessThanOrEqual(DASHBOARD_COLUMNS)
    }
  })

  it('does not resolve inherited object properties as specs', () => {
    expect(specFor('constructor' as WidgetType)).toBeUndefined()
    expect(specFor('toString' as WidgetType)).toBeUndefined()
  })
})

describe('overlaps', () => {
  const base: Rect = { x: 2, y: 2, w: 3, h: 3 }

  it('is false when rectangles only share an edge', () => {
    expect(overlaps(base, { x: 5, y: 2, w: 2, h: 2 })).toBe(false)
    expect(overlaps(base, { x: 2, y: 5, w: 2, h: 2 })).toBe(false)
    expect(overlaps(base, { x: 0, y: 2, w: 2, h: 2 })).toBe(false)
  })

  it('is true for a one-cell bite and for containment', () => {
    expect(overlaps(base, { x: 4, y: 4, w: 2, h: 2 })).toBe(true)
    expect(overlaps(base, { x: 3, y: 3, w: 1, h: 1 })).toBe(true)
    expect(overlaps(base, { x: 0, y: 0, w: 12, h: 12 })).toBe(true)
  })

  it('is symmetric', () => {
    const other: Rect = { x: 3, y: 1, w: 4, h: 4 }
    expect(overlaps(base, other)).toBe(overlaps(other, base))
  })
})

describe('findFreeSlot', () => {
  it('puts the first widget at the origin', () => {
    expect(findFreeSlot(createLayout(PROJECT), 6, 6)).toEqual({ x: 0, y: 0 })
  })

  it('fills a hole beside an existing widget before starting a new row', () => {
    const layout = seed([['a', 'git', 0, 0, 6, 6]])
    expect(findFreeSlot(layout, 6, 6)).toEqual({ x: 6, y: 0 })
  })

  it('drops to the next row when the first cannot take the width', () => {
    const layout = seed([['a', 'git', 0, 0, 8, 4]])
    // 4 columns are free to the right, so a 6-wide widget cannot sit there.
    expect(findFreeSlot(layout, 6, 4)).toEqual({ x: 0, y: 4 })
    // A 4-wide one can.
    expect(findFreeSlot(layout, 4, 4)).toEqual({ x: 8, y: 0 })
  })

  it('finds a hole punched in the middle of a full row', () => {
    const layout = seed([
      ['a', 'git', 0, 0, 4, 3],
      ['b', 'cost', 8, 0, 4, 3],
    ])
    expect(findFreeSlot(layout, 4, 3)).toEqual({ x: 4, y: 0 })
  })

  it('never places above fromY', () => {
    const layout = seed([['a', 'git', 0, 4, 6, 4]])
    expect(findFreeSlot(layout, 6, 2, { fromY: 2 })).toEqual({ x: 0, y: 2 })
    expect(findFreeSlot(layout, 6, 2, { fromY: 5 })).toEqual({ x: 6, y: 5 })
  })

  it('ignores the widget being moved', () => {
    const layout = seed([['a', 'git', 0, 0, 12, 4]])
    expect(findFreeSlot(layout, 12, 4, { ignoreId: 'a' })).toEqual({ x: 0, y: 0 })
    expect(findFreeSlot(layout, 12, 4)).toEqual({ x: 0, y: 4 })
  })

  it('clamps a width larger than the grid instead of never finding a slot', () => {
    const slot = findFreeSlot(createLayout(PROJECT), 99, 3)
    expect(slot).toEqual({ x: 0, y: 0 })
  })

  it('terminates and returns a free slot on a staircase of widgets', () => {
    // Staggered widths leave holes of every size — the shape that traps a
    // naive "scan until the bottom of the tallest column" search.
    const layout = seed(
      Array.from({ length: 8 }, (_, i): [string, WidgetType, number, number, number, number] => [
        `w${i}`,
        'github',
        i % 6,
        i,
        Math.max(1, 6 - (i % 5)),
        2,
      ]),
    )
    for (let w = 1; w <= DASHBOARD_COLUMNS; w += 1) {
      const slot = findFreeSlot(layout, w, 3)
      expect(slot.x + w).toBeLessThanOrEqual(DASHBOARD_COLUMNS)
      for (const widget of layout.widgets) {
        expect(overlaps(widget, { ...slot, w, h: 3 })).toBe(false)
      }
    }
  })
})

describe('defaultLayout', () => {
  it('is a sound arrangement of the widgets that have a live data source', () => {
    const layout = defaultLayout(PROJECT)
    expectSound(layout)
    expect(layout.widgets.map((w) => w.type)).toEqual(['cost', 'git'])
    // Level with each other. Usage was a row taller for one round, when it
    // carried a dollar figure and the four lines needed to qualify it; with the
    // money gone the seventh row held 133px of nothing. See WIDGET_SPECS.
    expect(rects(layout)).toEqual({
      'cost-default': '0,0 6x6',
      'git-default': '6,0 6x6',
    })
  })

  /**
   * The Overview page opens with a live board of every running session, so a
   * Sessions tile in the starter layout is a count of the thing listed in full
   * three inches above it. It is retired rather than deleted — a tile already
   * in somebody's saved arrangement keeps rendering — but nothing seeds it and
   * the picker no longer offers it.
   */
  it('does not seed the tile the session board replaced', () => {
    expect(defaultLayout(PROJECT).widgets.map((w) => w.type)).not.toContain('sessions')
    expect(isRetiredWidget('sessions')).toBe(true)
    expect(isRetiredWidget('cost')).toBe(false)
  })

  it('still places a retired widget a saved layout already holds', () => {
    // Dropping it on read would be data loss on someone's arrangement.
    const restored = parseLayout(
      { widgets: [{ id: 'kept', type: 'sessions', x: 0, y: 0, w: 6, h: 6 }] },
      PROJECT,
    )
    expect(restored.widgets.map((w) => w.id)).toEqual(['kept'])
  })

  it('carries the caller-supplied project path', () => {
    expect(defaultLayout('/tmp/other').projectPath).toBe('/tmp/other')
  })
})

describe('addWidget', () => {
  it('appends into the first free slot', () => {
    let layout = createLayout(PROJECT)
    layout = addWidget(layout, { type: 'sessions', id: 's' })
    layout = addWidget(layout, { type: 'cost', id: 'c' })
    expect(rects(layout)).toEqual({ s: '0,0 6x6', c: '6,0 6x6' })
    expectSound(layout)
  })

  it('honours an explicit position when the space is free', () => {
    const layout = addWidget(createLayout(PROJECT), { type: 'git', id: 'g', x: 3, y: 4 })
    expect(rects(layout)).toEqual({ g: '3,4 6x6' })
  })

  it('slides a colliding explicit position down, never up', () => {
    const layout = addWidget(seed([['a', 'git', 0, 0, 12, 4]]), {
      type: 'cost',
      id: 'c',
      x: 0,
      y: 2,
    })
    expect(widgetById(layout, 'c')?.y).toBe(4)
    expectSound(layout)
  })

  it('clamps an explicit x so the widget cannot hang off the right edge', () => {
    const layout = addWidget(createLayout(PROJECT), { type: 'git', id: 'g', x: 11, y: 0 })
    expect(rects(layout)).toEqual({ g: '6,0 6x6' })
  })

  it('floors size at the spec minimum and caps width at the column count', () => {
    const layout = addWidget(createLayout(PROJECT), { type: 'readiness', id: 'k', w: 1, h: 1 })
    expect(rects(layout)).toEqual({
      k: `0,0 ${WIDGET_SPECS.readiness.minW}x${WIDGET_SPECS.readiness.minH}`,
    })
    const wide = addWidget(createLayout(PROJECT), { type: 'readiness', id: 'k', w: 99, h: 3 })
    expect(widgetById(wide, 'k')?.w).toBe(DASHBOARD_COLUMNS)
  })

  it('is a no-op for a duplicate id, and returns the same object', () => {
    const layout = addWidget(createLayout(PROJECT), { type: 'git', id: 'g' })
    expect(addWidget(layout, { type: 'cost', id: 'g' })).toBe(layout)
  })

  it('refuses a second instance of a single-instance widget', () => {
    const layout = addWidget(createLayout(PROJECT), { type: 'cost', id: 'c1' })
    expect(addWidget(layout, { type: 'cost', id: 'c2' })).toBe(layout)
    expect(canAddWidget(layout, 'cost')).toBe(false)
  })

  it('allows repeats of the type that declares them', () => {
    let layout = addWidget(createLayout(PROJECT), { type: 'github', id: 'g1' })
    layout = addWidget(layout, { type: 'github', id: 'g2' })
    expect(countWidgets(layout)).toBe(2)
    expect(canAddWidget(layout, 'github')).toBe(true)
    expectSound(layout)
  })

  it('ignores a type with no spec', () => {
    const layout = createLayout(PROJECT)
    expect(addWidget(layout, { type: 'nope' as WidgetType })).toBe(layout)
    expect(addWidget(layout, { type: 'constructor' as WidgetType })).toBe(layout)
  })

  it('survives non-finite coordinates', () => {
    const layout = addWidget(createLayout(PROJECT), {
      type: 'git',
      id: 'g',
      x: Number.NaN,
      y: Number.POSITIVE_INFINITY,
      w: Number.NaN,
      h: Number.NaN,
    })
    expectSound(layout)
    expect(rects(layout)).toEqual({ g: '0,0 6x6' })
  })
})

describe('removeWidget', () => {
  it('drops the widget and leaves the rest untouched', () => {
    const layout = removeWidget(defaultLayout(PROJECT), 'cost-default')
    expect(layout.widgets.map((w) => w.id)).toEqual(['git-default'])
  })

  it('returns the same object for an unknown id', () => {
    const layout = defaultLayout(PROJECT)
    expect(removeWidget(layout, 'nope')).toBe(layout)
  })
})

describe('moveWidget', () => {
  it('moves into free space', () => {
    const layout = moveWidget(seed([['a', 'git', 0, 0, 6, 4]]), 'a', 6, 2)
    expect(rects(layout)).toEqual({ a: '6,2 6x4' })
  })

  it('clamps x to the right wall and y to the top', () => {
    const layout = seed([['a', 'git', 0, 4, 6, 4]])
    expect(rects(moveWidget(layout, 'a', 99, -5))).toEqual({ a: '6,0 6x4' })
  })

  it('resolves a collision downwards instead of stacking widgets', () => {
    const layout = seed([
      ['a', 'git', 0, 0, 12, 4],
      ['b', 'cost', 6, 4, 6, 4],
    ])
    // Row 0 is full width, so there is nowhere at the requested row to land.
    const moved = moveWidget(layout, 'b', 0, 0)
    expectSound(moved)
    expect(widgetById(moved, 'b')).toMatchObject({ x: 0, y: 4 })
  })

  it('settles a widget into the first free hole when its own spot is taken', () => {
    const layout = seed([
      ['a', 'git', 0, 0, 6, 4],
      ['b', 'cost', 0, 4, 6, 4],
    ])
    // Asked for a spot that overlaps 'a'; the hole beside 'a' is the answer.
    expect(rects(moveWidget(layout, 'b', 2, 0))).toEqual({ a: '0,0 6x4', b: '6,0 6x4' })
  })

  it('lets a widget move back onto the cells it currently occupies', () => {
    const layout = seed([['a', 'git', 3, 3, 6, 4]])
    // Overlapping its own old rectangle must not count as a collision.
    expect(rects(moveWidget(layout, 'a', 4, 3))).toEqual({ a: '4,3 6x4' })
  })

  it('returns the same object when nothing moves, or the id is unknown', () => {
    const layout = seed([['a', 'git', 2, 2, 6, 4]])
    expect(moveWidget(layout, 'a', 2, 2)).toBe(layout)
    expect(moveWidget(layout, 'ghost', 0, 0)).toBe(layout)
  })
})

describe('resizeWidget', () => {
  it('grows a widget in place', () => {
    const layout = resizeWidget(seed([['a', 'git', 0, 0, 6, 4]]), 'a', 8, 6)
    expect(rects(layout)).toEqual({ a: '0,0 8x6' })
  })

  it('clamps width to the wall without sliding the widget sideways', () => {
    const layout = resizeWidget(seed([['a', 'git', 8, 0, 4, 4]]), 'a', 12, 4)
    expect(rects(layout)).toEqual({ a: '8,0 4x4' })
  })

  it('floors at the spec minimum', () => {
    const layout = resizeWidget(seed([['a', 'readiness', 0, 0, 8, 7]]), 'a', 1, 1)
    expect(rects(layout)).toEqual({
      a: `0,0 ${WIDGET_SPECS.readiness.minW}x${WIDGET_SPECS.readiness.minH}`,
    })
  })

  it('refuses a size that would swallow a neighbour', () => {
    const layout = seed([
      ['a', 'git', 0, 0, 6, 4],
      ['b', 'cost', 6, 0, 6, 4],
    ])
    expect(resizeWidget(layout, 'a', 12, 4)).toBe(layout)
    // Growing downwards is still fine — nothing is below.
    expect(rects(resizeWidget(layout, 'a', 6, 8))).toMatchObject({ a: '0,0 6x8' })
  })

  it('returns the same object for a no-op or an unknown id', () => {
    const layout = seed([['a', 'git', 0, 0, 6, 4]])
    expect(resizeWidget(layout, 'a', 6, 4)).toBe(layout)
    expect(resizeWidget(layout, 'ghost', 6, 4)).toBe(layout)
  })
})

describe('applyPlacements', () => {
  const layout = seed([
    ['a', 'git', 0, 0, 6, 4],
    ['b', 'cost', 6, 0, 6, 4],
  ])

  it('takes the grid engine at its word for a whole batch', () => {
    const next = applyPlacements(layout, [
      { id: 'a', x: 6, y: 0, w: 6, h: 4 },
      { id: 'b', x: 0, y: 0, w: 6, h: 4 },
    ])
    expect(rects(next)).toEqual({ a: '6,0 6x4', b: '0,0 6x4' })
    expectSound(next)
  })

  it('applies a swap that would be a collision if done one widget at a time', () => {
    // Applied sequentially with collision resolution, 'a' would be pushed to a
    // free row and the engine's own answer would be lost.
    const next = applyPlacements(layout, [
      { id: 'a', y: 4 },
      { id: 'b', y: 4, x: 0 },
    ])
    expect(rects(next)).toEqual({ a: '0,4 6x4', b: '0,4 6x4' })
  })

  it('keeps fields the placement leaves out', () => {
    const next = applyPlacements(layout, [{ id: 'a', y: 9 }])
    expect(rects(next)).toEqual({ a: '0,9 6x4', b: '6,0 6x4' })
  })

  it('ignores unknown ids and empty batches', () => {
    expect(applyPlacements(layout, [])).toBe(layout)
    expect(applyPlacements(layout, [{ id: 'ghost', x: 3 }])).toBe(layout)
  })

  it('returns the same object when the geometry is unchanged', () => {
    expect(applyPlacements(layout, [{ id: 'a', x: 0, y: 0, w: 6, h: 4 }])).toBe(layout)
  })

  it('clamps values that could not have come from a sane engine', () => {
    const next = applyPlacements(layout, [{ id: 'a', x: -3, y: -3, w: 99, h: 0 }])
    expect(rects(next)).toMatchObject({ a: `0,0 ${DASHBOARD_COLUMNS}x${WIDGET_SPECS.git.minH}` })
  })

  it('does not re-solve collisions, and a slipped-through overlap is repaired on read', () => {
    // Deliberate: this is the one transition that trusts its caller, because
    // the caller is the grid engine reporting a batch it has already packed.
    const overlapping = applyPlacements(layout, [{ id: 'a', w: 12 }])
    expect(overlaps(overlapping.widgets[0], overlapping.widgets[1])).toBe(true)
    // The next load is where that gets fixed, so it can never become permanent.
    const reloaded = parseLayout(serialiseLayout(overlapping), PROJECT)
    everyPair(reloaded, (a, b) => expect(overlaps(a, b)).toBe(false))
  })

  it('lets the last placement for an id win', () => {
    const next = applyPlacements(layout, [
      { id: 'a', y: 4 },
      { id: 'a', y: 8 },
    ])
    expect(widgetById(next, 'a')?.y).toBe(8)
  })
})

describe('serialiseLayout', () => {
  it('emits only the persisted fields', () => {
    const layout = defaultLayout(PROJECT)
    const extra = {
      ...layout,
      widgets: layout.widgets.map((w) => ({ ...w, el: { nodeType: 1 }, subscription: () => {} })),
    }
    const json = serialiseLayout(extra as DashboardLayout)
    expect(Object.keys(json)).toEqual(['version', 'projectPath', 'columns', 'widgets'])
    for (const widget of json.widgets) {
      expect(Object.keys(widget)).toEqual(['id', 'type', 'x', 'y', 'w', 'h'])
    }
  })

  it('survives JSON, which is the only thing that reaches disk', () => {
    const layout = defaultLayout(PROJECT)
    const round = JSON.parse(JSON.stringify(serialiseLayout(layout))) as unknown
    expect(parseLayout(round, PROJECT)).toEqual(layout)
  })

  it('always stamps the current version', () => {
    const layout = { ...defaultLayout(PROJECT), version: 0 }
    expect(serialiseLayout(layout).version).toBe(DASHBOARD_VERSION)
  })
})

describe('parseLayout', () => {
  it('round-trips any layout the model can produce', () => {
    let layout = defaultLayout(PROJECT)
    layout = addWidget(layout, { type: 'github', id: 'gh1' })
    layout = addWidget(layout, { type: 'github', id: 'gh2' })
    layout = moveWidget(layout, 'git-default', 6, 12)
    layout = resizeWidget(layout, 'sessions-default', 8, 7)
    expect(parseLayout(serialiseLayout(layout), PROJECT)).toEqual(layout)
  })

  it('falls back to the default set when there is nothing to read', () => {
    for (const raw of [null, undefined, 0, 'nope', [], { version: 1 }]) {
      expect(parseLayout(raw, PROJECT)).toEqual(defaultLayout(PROJECT))
    }
  })

  it('keeps an empty dashboard empty rather than resurrecting the defaults', () => {
    const cleared = parseLayout({ version: 1, projectPath: PROJECT, widgets: [] }, PROJECT)
    expect(countWidgets(cleared)).toBe(0)
  })

  it('ignores the project path stored in the file', () => {
    const raw = serialiseLayout(defaultLayout('/somewhere/else'))
    expect(parseLayout(raw, PROJECT).projectPath).toBe(PROJECT)
  })

  it('drops entries that are not widgets', () => {
    const layout = parseLayout(
      {
        widgets: [
          null,
          'git',
          42,
          { type: 'not-a-widget', x: 0, y: 0 },
          { x: 0, y: 0, w: 4, h: 4 },
          { id: 'ok', type: 'git', x: 0, y: 0, w: 6, h: 6 },
        ],
      },
      PROJECT,
    )
    expect(layout.widgets.map((w) => w.id)).toEqual(['ok'])
  })

  it('re-ids duplicates instead of colliding React keys', () => {
    const layout = parseLayout(
      {
        widgets: [
          { id: 'same', type: 'github', x: 0, y: 0, w: 6, h: 6 },
          { id: 'same', type: 'github', x: 6, y: 0, w: 6, h: 6 },
        ],
      },
      PROJECT,
    )
    expect(countWidgets(layout)).toBe(2)
    expect(new Set(layout.widgets.map((w) => w.id)).size).toBe(2)
    expect(layout.widgets[0].id).toBe('same')
  })

  it('generates an id for an entry that has none', () => {
    const layout = parseLayout({ widgets: [{ type: 'cost', x: 0, y: 0, w: 6, h: 6 }] }, PROJECT)
    expect(layout.widgets[0].id).toMatch(/^cost-/)
  })

  it('repairs overlaps, letting the first widget listed keep its cells', () => {
    const layout = parseLayout(
      {
        widgets: [
          { id: 'a', type: 'git', x: 0, y: 0, w: 6, h: 6 },
          { id: 'b', type: 'cost', x: 0, y: 0, w: 6, h: 6 },
          { id: 'c', type: 'readiness', x: 3, y: 3, w: 6, h: 6 },
        ],
      },
      PROJECT,
    )
    expectSound(layout)
    expect(widgetById(layout, 'a')).toMatchObject({ x: 0, y: 0 })
    expect(widgetById(layout, 'b')).toMatchObject({ x: 6, y: 0 })
  })

  it('pulls widgets from a wider grid back inside this one', () => {
    const layout = parseLayout(
      {
        columns: 24,
        widgets: [
          { id: 'a', type: 'git', x: 18, y: 0, w: 6, h: 6 },
          { id: 'b', type: 'cost', x: 12, y: 0, w: 6, h: 6 },
        ],
      },
      PROJECT,
    )
    expect(layout.columns).toBe(DASHBOARD_COLUMNS)
    expectSound(layout)
  })

  it('repairs junk coordinates', () => {
    const layout = parseLayout(
      {
        widgets: [
          { id: 'a', type: 'git', x: -5, y: -5, w: 0, h: 0 },
          { id: 'b', type: 'cost', x: '3', y: null, w: Number.NaN, h: Number.POSITIVE_INFINITY },
        ],
      },
      PROJECT,
    )
    expectSound(layout)
    for (const widget of layout.widgets) {
      expect(Number.isInteger(widget.x)).toBe(true)
      expect(Number.isInteger(widget.y)).toBe(true)
      expect(Number.isInteger(widget.w)).toBe(true)
      expect(Number.isInteger(widget.h)).toBe(true)
    }
  })

  it('keeps a duplicated single-instance widget rather than deleting one on read', () => {
    const layout = parseLayout(
      {
        widgets: [
          { id: 'c1', type: 'cost', x: 0, y: 0, w: 6, h: 6 },
          { id: 'c2', type: 'cost', x: 6, y: 0, w: 6, h: 6 },
        ],
      },
      PROJECT,
    )
    expect(countWidgets(layout)).toBe(2)
    expect(canAddWidget(layout, 'cost')).toBe(false)
  })

  it('reads a file with no version, from before the field existed', () => {
    const layout = parseLayout({ widgets: [{ id: 'a', type: 'git', x: 0, y: 0, w: 6, h: 6 }] }, PROJECT)
    expect(layout.version).toBe(DASHBOARD_VERSION)
    expect(countWidgets(layout)).toBe(1)
  })
})

describe('selectors', () => {
  it('reports the first row below every widget', () => {
    expect(layoutRows(createLayout(PROJECT))).toBe(0)
    // The starter layout is one row of two half-width tiles, both six rows
    // deep, and that is what the page's height is.
    expect(layoutRows(defaultLayout(PROJECT))).toBe(6)
  })

  it('orders widgets the way they are read, not the way they were added', () => {
    const layout = seed([
      ['bottom', 'git', 0, 6, 6, 6],
      ['right', 'cost', 6, 0, 6, 6],
      ['left', 'sessions', 0, 0, 6, 6],
    ])
    expect(readingOrder(layout).map((w) => w.id)).toEqual(['left', 'right', 'bottom'])
    // …and does not disturb the stored order, which is React's key order.
    expect(layout.widgets.map((w) => w.id)).toEqual(['bottom', 'right', 'left'])
  })

  it('answers type questions', () => {
    const layout = defaultLayout(PROJECT)
    expect(hasWidgetType(layout, 'cost')).toBe(true)
    expect(hasWidgetType(layout, 'readiness')).toBe(false)
    expect(canAddWidget(layout, 'readiness')).toBe(true)
    expect(canAddWidget(layout, 'nope' as WidgetType)).toBe(false)
  })
})

/**
 * Regression: placement walks rows, so an unbounded row or height in the data
 * is an unbounded walk. Every one of these hung — some for seconds, some
 * forever — before heights, caller-supplied rows and the widget count were
 * capped and the scan given a budget.
 *
 * Each has a wall-clock assertion. That is deliberate: the bug is not a wrong
 * answer, it is an answer that never arrives, and only elapsed time catches it.
 */
describe('bounded work', () => {
  /** Generous enough not to flake on a loaded machine; the bug took minutes. */
  const BUDGET_MS = 2000

  function timed(run: () => void): number {
    const started = Date.now()
    run()
    return Date.now() - started
  }

  it('caps a widget height so one tall tile cannot wedge the next placement', () => {
    const layout = addWidget(createLayout(PROJECT), { type: 'github', id: 'a', w: 12, h: 1e15 })
    expect(widgetById(layout, 'a')?.h).toBe(MAX_WIDGET_ROWS)

    const elapsed = timed(() => {
      const next = addWidget(layout, { type: 'github', id: 'b', w: 12, h: 6 })
      expect(widgetById(next, 'b')?.y).toBe(MAX_WIDGET_ROWS)
      expectSound(next)
    })
    expect(elapsed).toBeLessThan(BUDGET_MS)
  })

  it('caps a row a caller names, in every transition that takes one', () => {
    const added = addWidget(createLayout(PROJECT), { type: 'git', id: 'g', x: 0, y: 1e15 })
    expect(widgetById(added, 'g')?.y).toBe(MAX_ROW)

    const moved = moveWidget(added, 'g', 0, Number.MAX_SAFE_INTEGER)
    expect(widgetById(moved, 'g')?.y).toBe(MAX_ROW)

    const placed = applyPlacements(added, [{ id: 'g', y: 1e12, h: 1e12 }])
    expect(widgetById(placed, 'g')).toMatchObject({ y: MAX_ROW, h: MAX_WIDGET_ROWS })

    const resized = resizeWidget(added, 'g', 6, 1e9)
    expect(widgetById(resized, 'g')?.h).toBe(MAX_WIDGET_ROWS)
  })

  it('reads a layout file whose heights would otherwise never finish', () => {
    let parsed!: DashboardLayout
    const elapsed = timed(() => {
      parsed = parseLayout(
        {
          widgets: [
            { id: 'a', type: 'git', x: 0, y: 0, w: 12, h: 1e15 },
            { id: 'b', type: 'cost', x: 0, y: 0, w: 12, h: 1e15 },
            { id: 'c', type: 'readiness', x: 0, y: 1e15, w: 12, h: 6 },
          ],
        },
        PROJECT,
      )
    })
    expect(elapsed).toBeLessThan(BUDGET_MS)
    expect(countWidgets(parsed)).toBe(3)
    expectSound(parsed)
    for (const widget of parsed.widgets) {
      expect(widget.h).toBeLessThanOrEqual(MAX_WIDGET_ROWS)
      expect(widget.y).toBeLessThanOrEqual(MAX_ROW + MAX_WIDGET_ROWS)
    }
  })

  it('truncates a layout file with more widgets than the store would ever write', () => {
    // Under 512KB on disk, so the store's byte cap lets it through — placement
    // is quadratic in the count, which is what actually has to be bounded.
    const widgets = Array.from({ length: 5000 }, (_, i) => ({
      id: `w${i}`,
      type: 'github',
      x: 0,
      y: 0,
      w: 6,
      h: 6,
    }))

    let parsed!: DashboardLayout
    const elapsed = timed(() => {
      parsed = parseLayout({ widgets }, PROJECT)
    })
    expect(elapsed).toBeLessThan(BUDGET_MS)
    expect(countWidgets(parsed)).toBe(MAX_WIDGETS)
    expectSound(parsed)
  })

  it('still finds the tidy hole when the scan budget is nowhere near spent', () => {
    // The budget must not change the answer for any layout a user could make.
    const layout = seed([
      ['a', 'git', 0, 0, 4, 3],
      ['b', 'cost', 8, 0, 4, 3],
    ])
    expect(findFreeSlot(layout, 4, 3)).toEqual({ x: 4, y: 0 })
  })

  it('falls back to a free row rather than a wrong one when the budget runs out', () => {
    // Deep and dense: enough rows that the row-major walk cannot finish, so the
    // fallback is exercised. It must still be a slot nothing else occupies.
    const layout = seed(
      Array.from({ length: 190 }, (_, i): [string, WidgetType, number, number, number, number] => [
        `w${i}`,
        'github',
        (i % 2) * 6,
        i * MAX_WIDGET_ROWS,
        6,
        MAX_WIDGET_ROWS,
      ]),
    )

    let slot!: { x: number; y: number }
    const elapsed = timed(() => {
      slot = findFreeSlot(layout, 12, 6)
    })
    expect(elapsed).toBeLessThan(BUDGET_MS)
    expect(slot.x).toBe(0)
    for (const widget of layout.widgets) {
      expect(overlaps(widget, { ...slot, w: 12, h: 6 })).toBe(false)
    }
  })
})

describe('invariants under a long random session', () => {
  /** Deterministic LCG — a failing seed must reproduce exactly. */
  function rng(seed: number): () => number {
    let state = seed >>> 0
    return () => {
      state = (state * 1664525 + 1013904223) >>> 0
      return state / 0x100000000
    }
  }

  it('never lets two widgets share a cell, whatever the operation order', () => {
    for (let seed = 1; seed <= 25; seed += 1) {
      const random = rng(seed)
      const pick = <T,>(items: readonly T[]): T => items[Math.floor(random() * items.length)]
      let layout = createLayout(PROJECT)
      let nextId = 0

      for (let step = 0; step < 200; step += 1) {
        const ids = layout.widgets.map((w) => w.id)
        const op = Math.floor(random() * 4)

        if (op === 0 || ids.length === 0) {
          nextId += 1
          // 'github' is the repeatable type, so the layout can actually grow.
          layout = addWidget(layout, {
            type: random() < 0.6 ? 'github' : pick(WIDGET_TYPES),
            id: `w${nextId}`,
            w: 1 + Math.floor(random() * 13),
            h: 1 + Math.floor(random() * 8),
          })
        } else if (op === 1) {
          layout = moveWidget(
            layout,
            pick(ids),
            Math.floor(random() * 16) - 2,
            Math.floor(random() * 16) - 2,
          )
        } else if (op === 2) {
          layout = resizeWidget(
            layout,
            pick(ids),
            1 + Math.floor(random() * 14),
            1 + Math.floor(random() * 10),
          )
        } else {
          layout = removeWidget(layout, pick(ids))
        }

        expectSound(layout)
      }

      // Whatever it ended up as, it must survive a save/load cycle unchanged.
      expect(parseLayout(JSON.parse(JSON.stringify(serialiseLayout(layout))), PROJECT)).toEqual(layout)
    }
  })
})
