/**
 * Pure layout model for the per-project dashboard.
 *
 * Every exported transition is pure: it never mutates its arguments, never
 * touches the DOM, and returns plain JSON-serialisable data. gridstack is a
 * rendering detail bolted on top — the grid maths lives here so it can be
 * tested without a browser, and so a broken layout file can be repaired long
 * before any DOM exists to be confused by it.
 *
 * Transitions return the *same* object when nothing would change, so a React
 * consumer can lean on reference equality to skip a re-render.
 *
 * Coordinates are grid cells, not pixels: `x` counts columns from the left,
 * `y` counts rows from the top, both zero-based, and a widget occupies the
 * half-open rectangle `[x, x+w) × [y, y+h)`. Columns are bounded — `x + w` may
 * never exceed `columns` — and rows only loosely so: a widget's own height and
 * any row a caller names are capped (see `MAX_WIDGET_ROWS`/`MAX_ROW`), because
 * placement walks rows and unbounded rows means an unbounded walk. Rows the
 * model works out for itself are left alone, so a deep dashboard still stacks.
 */

/** Bumped only when a saved layout needs migrating; `parseLayout` handles older files. */
export const DASHBOARD_VERSION = 1

/**
 * Column count of the rendered grid. This is a property of the app's CSS and
 * the widget size table below, not of any saved file — see `parseLayout`.
 */
export const DASHBOARD_COLUMNS = 12

/** Guard against a hand-edited file claiming an absurd grid. */
const MAX_COLUMNS = 48

/**
 * Ceiling on a single widget's height, in rows.
 *
 * Rows are unbounded downwards as a *coordinate*, but a widget's own height is
 * not: `findFreeSlot` scans row by row down to the lowest occupied row, so a
 * height taken verbatim from an untrusted file turns that scan into a loop of
 * that many iterations. A layout carrying `h: 1e15` is not a tall dashboard,
 * it is a hang on project open. 64 rows is ~3600px — already several screens.
 */
export const MAX_WIDGET_ROWS = 64

/**
 * Ceiling on a row a *caller* may name. Rows the model computes for itself are
 * not clamped — a genuinely deep dashboard still stacks past this — but a `y`
 * arriving from a file, an IPC payload or a grid engine is bounded, for the
 * same reason as the height above.
 */
export const MAX_ROW = 1024

/**
 * Cap on widgets in one parsed layout, matching the main-process store's own
 * write cap. The store checks it on save; a file written by anything else has
 * to be capped on read, because placement is quadratic in the widget count.
 */
export const MAX_WIDGETS = 200

/**
 * Hard budget on cells `findFreeSlot` will test before falling back to the row
 * below everything. The fallback is always free, so spending the budget costs
 * a tidier position, never a correct one.
 */
const SCAN_BUDGET = 20_000

export type WidgetType = 'sessions' | 'cost' | 'git' | 'readiness' | 'github'

/** Order the widget picker offers them in. */
export const WIDGET_TYPES: readonly WidgetType[] = [
  'sessions',
  'cost',
  'git',
  'readiness',
  'github',
]

export interface WidgetSpec {
  type: WidgetType
  /** Size a freshly added widget gets, in columns × rows. */
  w: number
  h: number
  /** Floor for a user resize. Below this the widget's content stops being readable. */
  minW: number
  minH: number
  /** Whether more than one instance on the same dashboard is meaningful. */
  allowMultiple: boolean
}

/**
 * Sizes are tuned for a 12-column grid at 56px rows: a half-width widget is
 * 6 columns, and 6 rows is roughly the height at which a list of sessions
 * stops being a teaser and starts being useful.
 */
export const WIDGET_SPECS: Readonly<Record<WidgetType, WidgetSpec>> = {
  sessions: { type: 'sessions', w: 6, h: 6, minW: 3, minH: 3, allowMultiple: false },
  cost: { type: 'cost', w: 6, h: 6, minW: 3, minH: 3, allowMultiple: false },
  git: { type: 'git', w: 6, h: 6, minW: 3, minH: 3, allowMultiple: false },
  readiness: { type: 'readiness', w: 8, h: 7, minW: 4, minH: 4, allowMultiple: false },
  // The only repeatable one: a project can watch more than one GitHub view.
  github: { type: 'github', w: 6, h: 6, minW: 3, minH: 3, allowMultiple: true },
}

export interface Rect {
  x: number
  y: number
  w: number
  h: number
}

export interface DashboardWidget extends Rect {
  id: string
  type: WidgetType
}

export interface DashboardLayout {
  version: number
  /** Absolute path of the project this dashboard belongs to. */
  projectPath: string
  columns: number
  /**
   * Placement order is *insertion* order, never visual order. It is also the
   * order React renders the grid items in, and re-sorting it on every change
   * would make React move live DOM nodes underneath gridstack, which holds
   * references to them. Use `readingOrder` when visual order is what you want.
   */
  widgets: DashboardWidget[]
}

export interface WidgetDraft {
  type: WidgetType
  /** Supplied by tests and replays; generated when absent. */
  id?: string
  /** Explicit placement. Omit either and a free slot is found instead. */
  x?: number
  y?: number
  w?: number
  h?: number
}

/** One widget's new geometry, as reported by the grid after a drag or resize. */
export interface WidgetPlacement {
  id: string
  x?: number
  y?: number
  w?: number
  h?: number
}

export interface FreeSlotOptions {
  /** Treat this widget as absent — it is the one being moved. */
  ignoreId?: string
  /** Never place above this row. */
  fromY?: number
}

// ---------------------------------------------------------------- helpers --

let idCounter = 0

/**
 * Widget id. The only impure export here, and every transition accepts an
 * explicit id so tests never depend on it. Avoids `crypto.randomUUID` so this
 * module stays importable from the main process, whose lib has no DOM.
 */
export function makeWidgetId(type: WidgetType): string {
  idCounter += 1
  const rand = Math.random().toString(36).slice(2, 8)
  return `${type}-${idCounter.toString(36)}${rand}`
}

function toInt(value: unknown, fallback: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback
  return Math.trunc(value)
}

function clampInt(value: unknown, min: number, max: number, fallback = min): number {
  // `max < min` happens when a widget's minimum width exceeds the space left
  // to its right. The minimum wins — a widget narrower than its own floor
  // renders broken, whereas one hanging a column over the edge only looks odd.
  if (max < min) return min
  return Math.min(max, Math.max(min, toInt(value, fallback)))
}

/** A widget height from an untrusted source: at least `minH`, never absurd. */
function clampHeight(value: unknown, minH: number, fallback: number): number {
  return clampInt(value, minH, MAX_WIDGET_ROWS, fallback)
}

/** A row index from an untrusted source. */
function clampRow(value: unknown, fallback: number): number {
  return clampInt(value, 0, MAX_ROW, fallback)
}

export function specFor(type: WidgetType): WidgetSpec | undefined {
  return Object.prototype.hasOwnProperty.call(WIDGET_SPECS, type) ? WIDGET_SPECS[type] : undefined
}

function isWidgetType(value: unknown): value is WidgetType {
  return typeof value === 'string' && (WIDGET_TYPES as readonly string[]).includes(value)
}

/** Half-open rectangle intersection: sharing only an edge is not an overlap. */
export function overlaps(a: Rect, b: Rect): boolean {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

function collides(rects: readonly Rect[], rect: Rect): boolean {
  return rects.some((other) => overlaps(other, rect))
}

function sameRect(a: Rect, b: Rect): boolean {
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h
}

/** First row below everything currently placed. Zero for an empty layout. */
export function layoutRows(layout: DashboardLayout): number {
  return layout.widgets.reduce((rows, widget) => Math.max(rows, widget.y + widget.h), 0)
}

export function widgetById(layout: DashboardLayout, id: string): DashboardWidget | undefined {
  return layout.widgets.find((widget) => widget.id === id)
}

export function countWidgets(layout: DashboardLayout): number {
  return layout.widgets.length
}

export function hasWidgetType(layout: DashboardLayout, type: WidgetType): boolean {
  return layout.widgets.some((widget) => widget.type === type)
}

/** Whether the picker should still offer this type. */
export function canAddWidget(layout: DashboardLayout, type: WidgetType): boolean {
  const spec = specFor(type)
  if (!spec) return false
  return spec.allowMultiple || !hasWidgetType(layout, type)
}

/** Widgets top-to-bottom then left-to-right — visual order, for keyboard nav. */
export function readingOrder(layout: DashboardLayout): DashboardWidget[] {
  return [...layout.widgets].sort((a, b) => (a.y === b.y ? a.x - b.x : a.y - b.y))
}

// ----------------------------------------------------------- constructors --

export function createLayout(projectPath: string, columns = DASHBOARD_COLUMNS): DashboardLayout {
  return {
    version: DASHBOARD_VERSION,
    projectPath,
    columns: clampInt(columns, 1, MAX_COLUMNS, DASHBOARD_COLUMNS),
    widgets: [],
  }
}

/**
 * What a project shows before anyone has arranged anything: the three widgets
 * backed by data that exists today. Readiness and GitHub are left to the picker
 * deliberately — a default dashboard where half the tiles say "not available"
 * reads as a broken app rather than an empty one.
 *
 * This used to be a 2×2, with a board widget in the fourth slot. The board went
 * with the feature, and the hole it left is not filled with Readiness or GitHub
 * for the reason above: a tidy grid is not worth a tile that says nothing.
 */
export function defaultLayout(projectPath: string): DashboardLayout {
  const base = createLayout(projectPath)
  const seed: Array<[WidgetType, number, number]> = [
    ['sessions', 0, 0],
    ['cost', 6, 0],
    ['git', 0, 6],
  ]
  return seed.reduce(
    (layout, [type, x, y]) => addWidget(layout, { type, id: `${type}-default`, x, y }),
    base,
  )
}

// -------------------------------------------------------------- placement --

/**
 * Topmost-then-leftmost rectangle of `w × h` free cells.
 *
 * First-fit in row-major order, which is what "add a widget" should feel like:
 * it drops into the first hole big enough, and into the next empty row when
 * there is no hole.
 *
 * Termination is guaranteed rather than hoped for. Every placed widget ends at
 * or above `layoutRows`, so the band starting at that row is empty and `x = 0`
 * always fits there; the scan therefore always returns on or before its last
 * row, no matter how the existing widgets are arranged.
 *
 * Terminating is not the same as terminating *soon*, though, and the number of
 * rows to walk comes from the data: one widget with a corrupt height puts the
 * last row billions of rows down and the scan stops being a search and becomes
 * a freeze. So the walk also carries a step budget, and spending it falls
 * straight through to that provably-free last row. Heights and caller-supplied
 * rows are clamped at the transitions too — this is the second line, not the
 * first.
 */
export function findFreeSlot(
  layout: DashboardLayout,
  w: number,
  h: number,
  options: FreeSlotOptions = {},
): { x: number; y: number } {
  const width = clampInt(w, 1, layout.columns)
  const height = clampHeight(h, 1, 1)
  const others = layout.widgets.filter((widget) => widget.id !== options.ignoreId)

  const startY = clampRow(options.fromY ?? 0, 0)
  const lastRow = Math.max(
    startY,
    others.reduce((rows, widget) => Math.max(rows, widget.y + widget.h), 0),
  )

  let steps = 0
  for (let y = startY; y <= lastRow; y += 1) {
    for (let x = 0; x + width <= layout.columns; x += 1) {
      // Budget spent: stop searching for a tidy hole and take the empty band
      // below everything, which the argument above shows is always free.
      if (steps >= SCAN_BUDGET) return { x: 0, y: lastRow }
      steps += 1
      if (!collides(others, { x, y, w: width, h: height })) return { x, y }
    }
  }

  // Unreachable by the argument above; kept so a future change to the bound
  // degrades into an empty row rather than into `undefined`.
  return { x: 0, y: lastRow }
}

// ------------------------------------------------------------ transitions --

/**
 * Add a widget. Unknown types, duplicate ids, and a second instance of a
 * single-instance type are all no-ops rather than errors — the caller is a
 * click handler, and a double-click must not produce two overlapping tiles.
 *
 * An explicit `x`/`y` is honoured when the space is free and clamped into the
 * grid when it is not; a collision falls back to the first free slot at or
 * below the requested row, so an add can never bury one widget under another.
 */
export function addWidget(layout: DashboardLayout, draft: WidgetDraft): DashboardLayout {
  const spec = specFor(draft.type)
  if (!spec) return layout
  if (!spec.allowMultiple && hasWidgetType(layout, draft.type)) return layout

  const id = draft.id ?? makeWidgetId(draft.type)
  if (widgetById(layout, id)) return layout

  const w = clampInt(draft.w, spec.minW, layout.columns, spec.w)
  const h = clampHeight(draft.h, spec.minH, spec.h)

  const wantsExplicit = draft.x !== undefined && draft.y !== undefined
  const x = clampInt(draft.x, 0, layout.columns - w, 0)
  const y = clampRow(draft.y, 0)

  const placed =
    wantsExplicit && !collides(layout.widgets, { x, y, w, h })
      ? { x, y }
      : findFreeSlot(layout, w, h, { fromY: wantsExplicit ? y : 0 })

  return { ...layout, widgets: [...layout.widgets, { id, type: draft.type, ...placed, w, h }] }
}

export function removeWidget(layout: DashboardLayout, id: string): DashboardLayout {
  if (!widgetById(layout, id)) return layout
  return { ...layout, widgets: layout.widgets.filter((widget) => widget.id !== id) }
}

/**
 * Move a widget to `(x, y)`, clamped into the grid.
 *
 * A destination that overlaps another widget resolves to the first free slot
 * at or below the requested row. The model never holds two widgets on the same
 * cell: overlap here would render as one tile on top of another for however
 * long it took the grid to repack, and in a test it is silent corruption.
 * Geometry that the grid engine has *already* resolved arrives through
 * `applyPlacements` instead, which trusts it verbatim.
 */
export function moveWidget(layout: DashboardLayout, id: string, x: number, y: number): DashboardLayout {
  const widget = widgetById(layout, id)
  if (!widget) return layout

  const nextX = clampInt(x, 0, layout.columns - widget.w, 0)
  const nextY = clampRow(y, 0)
  const others = layout.widgets.filter((other) => other.id !== id)

  const target = collides(others, { x: nextX, y: nextY, w: widget.w, h: widget.h })
    ? findFreeSlot(layout, widget.w, widget.h, { ignoreId: id, fromY: nextY })
    : { x: nextX, y: nextY }

  if (target.x === widget.x && target.y === widget.y) return layout
  return {
    ...layout,
    widgets: layout.widgets.map((other) => (other.id === id ? { ...other, ...target } : other)),
  }
}

/**
 * Resize a widget in place.
 *
 * Width is clamped to the space between the widget's left edge and the right
 * wall — the widget never slides sideways to make room, because a resize that
 * also teleports the tile is disorienting when the handle is in its corner.
 * A size that would swallow a neighbour is refused outright; growing into
 * occupied space is the grid engine's business, and its answer comes back
 * through `applyPlacements`.
 */
export function resizeWidget(layout: DashboardLayout, id: string, w: number, h: number): DashboardLayout {
  const widget = widgetById(layout, id)
  if (!widget) return layout
  const spec = specFor(widget.type)
  if (!spec) return layout

  const nextW = clampInt(w, spec.minW, layout.columns - widget.x, widget.w)
  const nextH = clampHeight(h, spec.minH, widget.h)
  if (nextW === widget.w && nextH === widget.h) return layout

  const rect = { x: widget.x, y: widget.y, w: nextW, h: nextH }
  const others = layout.widgets.filter((other) => other.id !== id)
  if (collides(others, rect)) return layout

  return {
    ...layout,
    widgets: layout.widgets.map((other) => (other.id === id ? { ...other, ...rect } : other)),
  }
}

/**
 * Apply geometry the grid engine has already solved.
 *
 * Values are taken verbatim apart from a bounds clamp. Re-running collision
 * resolution here would fight the engine: it reports every node it moved in
 * one batch, and repairing them one at a time against a half-applied layout
 * produces positions the engine never chose and then hands them back on the
 * next change event, which is how a grid ends up oscillating.
 *
 * Unknown ids are ignored — a placement can outlive the widget it names when
 * a removal and a drag land in the same frame.
 */
export function applyPlacements(
  layout: DashboardLayout,
  placements: readonly WidgetPlacement[],
): DashboardLayout {
  if (placements.length === 0) return layout

  // Last write wins if the same id appears twice in one batch.
  const byId = new Map<string, WidgetPlacement>()
  for (const placement of placements) {
    if (typeof placement?.id === 'string' && placement.id) byId.set(placement.id, placement)
  }

  let changed = false
  const widgets = layout.widgets.map((widget) => {
    const placement = byId.get(widget.id)
    if (!placement) return widget
    const spec = specFor(widget.type)

    const w = clampInt(placement.w, spec?.minW ?? 1, layout.columns, widget.w)
    const h = clampHeight(placement.h, spec?.minH ?? 1, widget.h)
    const x = clampInt(placement.x, 0, layout.columns - w, widget.x)
    const y = clampRow(placement.y, widget.y)

    const next = { ...widget, x, y, w, h }
    if (sameRect(widget, next)) return widget
    changed = true
    return next
  })

  return changed ? { ...layout, widgets } : layout
}

// ------------------------------------------------------- (de)serialisation --

export interface SerialisedLayout {
  version: number
  projectPath: string
  columns: number
  widgets: Array<{ id: string; type: WidgetType; x: number; y: number; w: number; h: number }>
}

/**
 * Freeze a layout for disk. Fields are picked explicitly rather than spread so
 * a value some future consumer hangs off a widget at runtime — a cached DOM
 * node, a subscription — can never reach the file or the IPC boundary.
 */
export function serialiseLayout(layout: DashboardLayout): SerialisedLayout {
  return {
    version: DASHBOARD_VERSION,
    projectPath: layout.projectPath,
    columns: layout.columns,
    widgets: layout.widgets.map(({ id, type, x, y, w, h }) => ({ id, type, x, y, w, h })),
  }
}

/**
 * Rebuild a layout from untrusted JSON — an older version's file, a
 * hand-edited one, or an IPC payload. Nothing throws: a corrupt dashboard must
 * never be the reason a project won't open.
 *
 * Two cases are deliberately *not* the same:
 *
 *  - There is no usable layout at all (first run, unreadable file, `null`) —
 *    the caller gets `defaultLayout`.
 *  - There is a layout and it happens to contain no widgets — the caller gets
 *    an empty dashboard.
 *
 * Collapsing them is the bug where a user clears every tile, reopens the
 * project, and finds the starter set resurrected on top of their choice.
 *
 * Sizes, rows and the widget count are all capped here rather than trusted,
 * because every one of them feeds the placement scan: a file is the one input
 * that reaches this model without ever having passed through it.
 *
 * `projectPath` always comes from the caller; a path baked into the file is
 * ignored so a layout can never claim to belong to a different project. The
 * column count is likewise the app's, not the file's — it is fixed by the CSS
 * — so a file written against a wider grid has its widgets repaired into this
 * one instead of hanging off the right-hand edge.
 */
export function parseLayout(raw: unknown, projectPath: string): DashboardLayout {
  if (typeof raw !== 'object' || raw === null) return defaultLayout(projectPath)
  const source = raw as Record<string, unknown>
  if (!Array.isArray(source.widgets)) return defaultLayout(projectPath)

  let layout = createLayout(projectPath)
  const seen = new Set<string>()

  for (const entry of source.widgets) {
    // Placement is quadratic in the widget count, so an over-long list is a
    // freeze rather than a busy dashboard. The store refuses to write more than
    // this; a file from anywhere else is truncated here.
    if (layout.widgets.length >= MAX_WIDGETS) break
    if (typeof entry !== 'object' || entry === null) continue
    const candidate = entry as Record<string, unknown>
    if (!isWidgetType(candidate.type)) continue

    // Ids are keys in a Map here, never object properties, so `__proto__` is
    // harmless — but it would still collide with itself as a React key.
    const rawId = typeof candidate.id === 'string' ? candidate.id.trim() : ''
    const id = rawId && !seen.has(rawId) ? rawId : makeWidgetId(candidate.type)
    seen.add(id)

    const spec = WIDGET_SPECS[candidate.type]
    const w = clampInt(candidate.w, spec.minW, layout.columns, spec.w)
    // Sizes and rows are the two fields a file can use to wedge the placement
    // scan, so they are bounded here rather than trusted and repaired later.
    const h = clampHeight(candidate.h, spec.minH, spec.h)
    const x = clampInt(candidate.x, 0, layout.columns - w, 0)
    const y = clampRow(candidate.y, 0)

    // A file may hold overlaps that this model would never produce: an older
    // grid was wider, or someone edited it by hand. Each widget keeps its spot
    // when the spot is free and slides to the next free one below when it is
    // not, so the first widget listed wins any contested cell.
    const rect = collides(layout.widgets, { x, y, w, h })
      ? { ...findFreeSlot(layout, w, h, { fromY: y }), w, h }
      : { x, y, w, h }

    // Built directly rather than through `addWidget`: parsing must preserve
    // exactly what the file said, including a second instance of a
    // single-instance widget. Dropping one would be data loss on a read.
    layout = { ...layout, widgets: [...layout.widgets, { id, type: candidate.type, ...rect }] }
  }

  return layout
}
