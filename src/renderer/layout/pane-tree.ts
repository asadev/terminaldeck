/* ============================================================================
   Pane tree — the model behind split panes.

   A binary tree: every interior node splits its area between exactly two
   children, every leaf is a pane that shows one session. Two children rather
   than N because a binary tree makes "close this pane" unambiguous — the
   sibling simply takes the parent's place — where an N-ary node has to decide
   how to redistribute the freed space among the survivors.

   Everything here is pure. Each operation returns a new layout, and returns
   the *same reference* when nothing changed, so React can skip re-rendering
   on a no-op (an arrow key at the edge of the grid, a drag that hit the clamp).
   ============================================================================ */

/**
 * How a split arranges its two children.
 * `horizontal` lays them out along the horizontal axis — first child on the
 * left. `vertical` stacks them — first child on top. The names describe the
 * axis the children run along, not the orientation of the divider between them.
 */
export type SplitDirection = 'horizontal' | 'vertical'

export type FocusDirection = 'left' | 'right' | 'up' | 'down'

export interface PaneLeaf {
  readonly type: 'leaf'
  readonly id: string
  /** The session rendered here, or null for a pane waiting to be filled. */
  readonly sessionId: string | null
}

export interface PaneSplit {
  readonly type: 'split'
  readonly id: string
  readonly direction: SplitDirection
  /** Share of the split's axis taken by the first child, between 0 and 1. */
  readonly ratio: number
  readonly children: readonly [PaneNode, PaneNode]
}

export type PaneNode = PaneLeaf | PaneSplit

export interface PaneLayout {
  /** Null once the last pane is closed. */
  readonly root: PaneNode | null
  /** Always names a leaf that exists in `root`, or null when there are none. */
  readonly focusedPaneId: string | null
}

/** A pane narrower than this is unusable, so drags and restores clamp to it. */
export const MIN_PANE_RATIO = 0.08

export const SERIALISED_VERSION = 1

/** Guards against a corrupt or hand-edited layout blowing the stack on restore. */
const MAX_DEPTH = 64

/** Floating-point slack for geometry comparisons on unit-square rects. */
const EPSILON = 1e-6

const UNIT_RECT: Rect = { x: 0, y: 0, width: 1, height: 1 }

// ------------------------------------------------------------------- ids --

let idCounter = 0

/**
 * Counter for readability, random suffix for safety: a restored layout carries
 * ids minted by a previous run, and a fresh counter would hand out collisions.
 */
function mintId(prefix: string): string {
  idCounter += 1
  return `${prefix}${idCounter.toString(36)}-${Math.random().toString(36).slice(2, 8)}`
}

// -------------------------------------------------------------- creation --

export function emptyLayout(): PaneLayout {
  return { root: null, focusedPaneId: null }
}

/** A layout of a single pane, focused. */
export function createLayout(sessionId: string | null = null, paneId?: string): PaneLayout {
  const leaf: PaneLeaf = { type: 'leaf', id: paneId ?? mintId('pane-'), sessionId }
  return { root: leaf, focusedPaneId: leaf.id }
}

// ------------------------------------------------------------- inspection --

export function isLeaf(node: PaneNode): node is PaneLeaf {
  return node.type === 'leaf'
}

/** Every pane, in visual order: left before right, top before bottom. */
export function listPanes(layout: PaneLayout): PaneLeaf[] {
  const out: PaneLeaf[] = []
  if (layout.root) collectLeaves(layout.root, out)
  return out
}

function collectLeaves(node: PaneNode, out: PaneLeaf[]): void {
  if (node.type === 'leaf') {
    out.push(node)
    return
  }
  collectLeaves(node.children[0], out)
  collectLeaves(node.children[1], out)
}

export function paneCount(layout: PaneLayout): number {
  return listPanes(layout).length
}

export function findPane(layout: PaneLayout, paneId: string): PaneLeaf | null {
  return listPanes(layout).find((p) => p.id === paneId) ?? null
}

export function focusedPane(layout: PaneLayout): PaneLeaf | null {
  return layout.focusedPaneId ? findPane(layout, layout.focusedPaneId) : null
}

export function focusedSessionId(layout: PaneLayout): string | null {
  return focusedPane(layout)?.sessionId ?? null
}

/** Every pane showing this session — a session may be open in more than one. */
export function panesForSession(layout: PaneLayout, sessionId: string): PaneLeaf[] {
  return listPanes(layout).filter((p) => p.sessionId === sessionId)
}

export function sessionIds(layout: PaneLayout): string[] {
  const seen = new Set<string>()
  for (const pane of listPanes(layout)) if (pane.sessionId) seen.add(pane.sessionId)
  return [...seen]
}

// --------------------------------------------------------------- editing --

export function clampRatio(ratio: number, min: number = MIN_PANE_RATIO): number {
  if (!Number.isFinite(ratio)) return 0.5
  const floor = Math.min(Math.max(min, 0), 0.5)
  return Math.min(Math.max(ratio, floor), 1 - floor)
}

/**
 * Rebuild the tree with `id`'s node replaced by `make(node)`.
 * Returns null when the id is not in the tree, so callers can hand back the
 * original layout untouched.
 */
function mapNode(
  node: PaneNode,
  id: string,
  make: (found: PaneNode) => PaneNode,
): PaneNode | null {
  if (node.id === id) return make(node)
  if (node.type === 'leaf') return null

  const first = mapNode(node.children[0], id, make)
  if (first) return { ...node, children: [first, node.children[1]] }

  const second = mapNode(node.children[1], id, make)
  if (second) return { ...node, children: [node.children[0], second] }

  return null
}

interface ParentRef {
  readonly parent: PaneSplit
  readonly index: 0 | 1
}

function findParent(node: PaneNode, childId: string): ParentRef | null {
  if (node.type === 'leaf') return null
  if (node.children[0].id === childId) return { parent: node, index: 0 }
  if (node.children[1].id === childId) return { parent: node, index: 1 }
  return findParent(node.children[0], childId) ?? findParent(node.children[1], childId)
}

/** Every id in the subtree — splits as well as panes; the two share a namespace. */
function collectIds(node: PaneNode, out: Set<string>): void {
  out.add(node.id)
  if (node.type === 'leaf') return
  collectIds(node.children[0], out)
  collectIds(node.children[1], out)
}

/** Depth of the node named `id`, the root being 0. -1 when it is not in the tree. */
function depthOf(node: PaneNode, id: string, depth = 0): number {
  if (node.id === id) return depth
  if (node.type === 'leaf') return -1
  const first = depthOf(node.children[0], id, depth + 1)
  return first >= 0 ? first : depthOf(node.children[1], id, depth + 1)
}

/**
 * `wanted` when it is free, a fresh id when it is not.
 *
 * Callers pass explicit ids so tests can name panes, but an id that is already
 * in the tree cannot simply be honoured: two nodes sharing an id make
 * `findPane` and `findParent` answer for the first one only — closing a pane
 * would take out its twin — and `deserialiseLayout` rejects such a tree
 * outright, so the whole layout is thrown away at the next start.
 */
function claimId(taken: Set<string>, wanted: string | undefined, prefix: string): string {
  let id = wanted !== undefined && wanted.length > 0 && !taken.has(wanted) ? wanted : mintId(prefix)
  // The counter in `mintId` only ever climbs, so this settles immediately; the
  // bound is here so a pathological id set can never spin.
  for (let attempt = 0; taken.has(id) && attempt < 64; attempt += 1) id = mintId(prefix)
  taken.add(id)
  return id
}

export interface SplitOptions {
  /** Session for the pane being created. */
  sessionId?: string | null
  /** Share for the first child. Defaults to an even split. */
  ratio?: number
  /** Put the new pane left of / above the existing one instead of after it. */
  insertFirst?: boolean
  /** Leave focus on the pane that was split. */
  keepFocus?: boolean
  /** Id for the new pane. Ignored, and a fresh one minted, if it is taken. */
  paneId?: string
  /** Id for the split. Ignored, and a fresh one minted, if it is taken. */
  splitId?: string
}

/**
 * Turn one pane into two. The existing pane keeps its identity and session —
 * only the new pane is new — so a terminal never remounts because its
 * neighbour appeared.
 */
export function splitPane(
  layout: PaneLayout,
  targetPaneId: string,
  direction: SplitDirection,
  options: SplitOptions = {},
): PaneLayout {
  if (!layout.root) return layout
  if (!findPane(layout, targetPaneId)) return layout

  // Refuse to nest deeper than the parser will accept. A deeper tree still
  // renders, but `deserialiseLayout` rejects it, so the reward for one more
  // split is losing the entire layout at the next start.
  if (depthOf(layout.root, targetPaneId) + 1 > MAX_DEPTH) return layout

  const taken = new Set<string>()
  collectIds(layout.root, taken)

  const created: PaneLeaf = {
    type: 'leaf',
    id: claimId(taken, options.paneId, 'pane-'),
    sessionId: options.sessionId ?? null,
  }
  const splitId = claimId(taken, options.splitId, 'split-')
  const ratio = clampRatio(options.ratio ?? 0.5)

  const root = mapNode(layout.root, targetPaneId, (existing) => {
    const children: readonly [PaneNode, PaneNode] = options.insertFirst
      ? [created, existing]
      : [existing, created]
    return { type: 'split', id: splitId, direction, ratio, children }
  })
  if (!root) return layout

  return { root, focusedPaneId: options.keepFocus ? layout.focusedPaneId : created.id }
}

/**
 * Remove a pane; its sibling subtree takes over the space they shared.
 * Closing the only pane leaves an empty layout rather than refusing — the
 * caller decides whether that means "show the empty state" or "close the tab".
 */
export function closePane(layout: PaneLayout, paneId: string): PaneLayout {
  const root = layout.root
  if (!root) return layout
  if (!findPane(layout, paneId)) return layout

  if (root.type === 'leaf') return emptyLayout()

  const ref = findParent(root, paneId)
  if (!ref) return layout

  const sibling = ref.parent.children[ref.index === 0 ? 1 : 0]
  const nextRoot =
    ref.parent.id === root.id ? sibling : mapNode(root, ref.parent.id, () => sibling)
  if (!nextRoot) return layout

  return { root: nextRoot, focusedPaneId: focusAfterClose(layout, paneId, sibling, ref.index) }
}

/**
 * Only one leaf ever disappears, so any other focused pane simply survives.
 * When the focused pane is the one closing, focus lands where it was rather
 * than on an arbitrary survivor: the sibling's edge nearest the hole it fills.
 */
function focusAfterClose(
  layout: PaneLayout,
  closedPaneId: string,
  sibling: PaneNode,
  closedIndex: 0 | 1,
): string {
  if (layout.focusedPaneId && layout.focusedPaneId !== closedPaneId) return layout.focusedPaneId

  const leaves: PaneLeaf[] = []
  collectLeaves(sibling, leaves)
  return (closedIndex === 0 ? leaves[0] : leaves[leaves.length - 1]).id
}

/** Close every pane showing this session — used when its process exits. */
export function closePanesForSession(layout: PaneLayout, sessionId: string): PaneLayout {
  let next = layout
  for (;;) {
    const pane = panesForSession(next, sessionId)[0]
    if (!pane) return next
    next = closePane(next, pane.id)
  }
}

/** Point a pane at a different session, keeping the geometry. */
export function setPaneSession(
  layout: PaneLayout,
  paneId: string,
  sessionId: string | null,
): PaneLayout {
  if (!layout.root) return layout
  const pane = findPane(layout, paneId)
  if (!pane || pane.sessionId === sessionId) return layout

  const root = mapNode(layout.root, paneId, (found) =>
    found.type === 'leaf' ? { ...found, sessionId } : found,
  )
  return root ? { ...layout, root } : layout
}

/** Move a divider. `ratio` is the first child's share of the split's axis. */
export function resizeSplit(layout: PaneLayout, splitId: string, ratio: number): PaneLayout {
  if (!layout.root) return layout

  const next = clampRatio(ratio)
  let changed = false
  const root = mapNode(layout.root, splitId, (found) => {
    if (found.type !== 'split') return found
    if (Math.abs(found.ratio - next) < EPSILON) return found
    changed = true
    return { ...found, ratio: next }
  })

  return root && changed ? { ...layout, root } : layout
}

// ----------------------------------------------------------------- focus --

export function focusPane(layout: PaneLayout, paneId: string): PaneLayout {
  if (layout.focusedPaneId === paneId) return layout
  if (!findPane(layout, paneId)) return layout
  return { ...layout, focusedPaneId: paneId }
}

/** Focus the first pane showing a session, if any. */
export function focusSession(layout: PaneLayout, sessionId: string): PaneLayout {
  const pane = panesForSession(layout, sessionId)[0]
  return pane ? focusPane(layout, pane.id) : layout
}

export interface Rect {
  readonly x: number
  readonly y: number
  readonly width: number
  readonly height: number
}

export interface PaneRect extends Rect {
  readonly paneId: string
  readonly sessionId: string | null
}

/**
 * Where each pane sits inside `bounds` (the unit square by default). Divider
 * thickness is ignored — this exists to answer "what is to the right of this
 * pane", and a couple of pixels of gutter never changes that answer.
 */
export function computeRects(root: PaneNode | null, bounds: Rect = UNIT_RECT): PaneRect[] {
  const out: PaneRect[] = []
  if (root) layoutNode(root, bounds, out)
  return out
}

function layoutNode(node: PaneNode, rect: Rect, out: PaneRect[]): void {
  if (node.type === 'leaf') {
    out.push({ paneId: node.id, sessionId: node.sessionId, ...rect })
    return
  }
  if (node.direction === 'horizontal') {
    const first = rect.width * node.ratio
    layoutNode(node.children[0], { ...rect, width: first }, out)
    layoutNode(
      node.children[1],
      { x: rect.x + first, y: rect.y, width: rect.width - first, height: rect.height },
      out,
    )
    return
  }
  const first = rect.height * node.ratio
  layoutNode(node.children[0], { ...rect, height: first }, out)
  layoutNode(
    node.children[1],
    { x: rect.x, y: rect.y + first, width: rect.width, height: rect.height - first },
    out,
  )
}

/**
 * Move focus geometrically rather than by walking the tree. A tree walk has to
 * guess which leaf to land on when it descends into a perpendicular split;
 * comparing rectangles just answers it — of the neighbours that share an edge,
 * the closest one lined up with this pane's centre wins, which is what the eye
 * expects across arbitrary nesting.
 */
export function moveFocus(layout: PaneLayout, direction: FocusDirection): PaneLayout {
  if (!layout.root) return layout

  const rects = computeRects(layout.root)
  const from = rects.find((r) => r.paneId === layout.focusedPaneId)
  // Nothing focused yet: land somewhere rather than swallowing the keypress.
  if (!from) return { ...layout, focusedPaneId: rects[0].paneId }

  const target = nearestInDirection(from, rects, direction)
  return target ? { ...layout, focusedPaneId: target.paneId } : layout
}

interface Candidate {
  readonly rect: PaneRect
  /** Distance along the direction of travel. */
  readonly gap: number
  /** How far the candidate's centre sits off the current pane's centre line. */
  readonly drift: number
  /** How much of the shared edge the two panes have in common. */
  readonly overlap: number
}

function nearestInDirection(
  from: PaneRect,
  all: readonly PaneRect[],
  direction: FocusDirection,
): PaneRect | null {
  const alongX = direction === 'left' || direction === 'right'
  const forward = direction === 'right' || direction === 'down'

  const fromStart = alongX ? from.x : from.y
  const fromEnd = fromStart + (alongX ? from.width : from.height)
  const crossStart = alongX ? from.y : from.x
  const crossEnd = crossStart + (alongX ? from.height : from.width)
  const crossCentre = (crossStart + crossEnd) / 2

  const candidates: Candidate[] = []
  for (const rect of all) {
    if (rect.paneId === from.paneId) continue

    const start = alongX ? rect.x : rect.y
    const end = start + (alongX ? rect.width : rect.height)
    const gap = forward ? start - fromEnd : fromStart - end
    if (gap < -EPSILON) continue // behind us, or overlapping — not that way

    const otherCrossStart = alongX ? rect.y : rect.x
    const otherCrossEnd = otherCrossStart + (alongX ? rect.height : rect.width)
    candidates.push({
      rect,
      gap,
      drift: Math.abs((otherCrossStart + otherCrossEnd) / 2 - crossCentre),
      overlap: Math.min(crossEnd, otherCrossEnd) - Math.max(crossStart, otherCrossStart),
    })
  }
  if (candidates.length === 0) return null

  // Prefer panes that actually share an edge with this one; fall back to the
  // rest only when nothing lines up (possible with deeply uneven splits).
  const aligned = candidates.filter((c) => c.overlap > EPSILON)
  const pool = aligned.length > 0 ? aligned : candidates

  // Ties (two equal neighbours straddling the centre line) resolve to the
  // first in visual order — top or left — so the same keypress always lands
  // in the same place.
  pool.sort((a, b) => (Math.abs(a.gap - b.gap) > EPSILON ? a.gap - b.gap : a.drift - b.drift))
  return pool[0].rect
}

// --------------------------------------------------------- serialisation --

interface SerialisedLayout {
  readonly version: number
  readonly root: PaneNode | null
  readonly focusedPaneId: string | null
}

export function serialiseLayout(layout: PaneLayout): string {
  const payload: SerialisedLayout = {
    version: SERIALISED_VERSION,
    root: layout.root,
    focusedPaneId: layout.focusedPaneId,
  }
  return JSON.stringify(payload)
}

/**
 * Returns null for anything it cannot trust, so a corrupt stored layout falls
 * back to a fresh one instead of rendering a broken grid. Duplicate ids are a
 * hard reject: they would make "close this pane" ambiguous.
 */
export function deserialiseLayout(text: string): PaneLayout | null {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return null
  }
  if (!isRecord(parsed)) return null
  if (parsed.version !== SERIALISED_VERSION) return null
  if (parsed.focusedPaneId !== null && typeof parsed.focusedPaneId !== 'string') return null

  if (parsed.root === null || parsed.root === undefined) return emptyLayout()

  const seen = new Set<string>()
  const root = parseNode(parsed.root, seen, 0)
  if (!root) return null

  const leaves: PaneLeaf[] = []
  collectLeaves(root, leaves)

  // A stale focus id is harmless where a broken tree is not, so repair it.
  const focused = leaves.find((l) => l.id === parsed.focusedPaneId)?.id ?? leaves[0].id
  return { root, focusedPaneId: focused }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function parseNode(value: unknown, seen: Set<string>, depth: number): PaneNode | null {
  if (depth > MAX_DEPTH) return null
  if (!isRecord(value)) return null
  if (typeof value.id !== 'string' || value.id.length === 0) return null
  if (seen.has(value.id)) return null
  seen.add(value.id)

  if (value.type === 'leaf') {
    const sessionId = value.sessionId
    if (sessionId !== null && typeof sessionId !== 'string') return null
    return { type: 'leaf', id: value.id, sessionId }
  }

  if (value.type !== 'split') return null
  if (value.direction !== 'horizontal' && value.direction !== 'vertical') return null
  if (typeof value.ratio !== 'number' || !Number.isFinite(value.ratio)) return null
  if (!Array.isArray(value.children) || value.children.length !== 2) return null

  const first = parseNode(value.children[0], seen, depth + 1)
  if (!first) return null
  const second = parseNode(value.children[1], seen, depth + 1)
  if (!second) return null

  return {
    type: 'split',
    id: value.id,
    direction: value.direction,
    ratio: clampRatio(value.ratio),
    children: [first, second],
  }
}
