import {
  useCallback,
  useState,
  type CSSProperties,
  type KeyboardEvent,
  type PointerEvent,
  type ReactNode,
} from 'react'
import {
  MIN_PANE_RATIO,
  clampRatio,
  focusPane,
  primaryPane,
  resizeSplit,
  type PaneLayout,
  type PaneNode,
  type PaneSplit,
} from './pane-tree'
import './SplitView.css'

/** Smallest pane along the split axis before a drag stops following the pointer. */
const DEFAULT_MIN_PANE_PX = 140

/** How far one arrow key nudges a divider. */
const KEY_STEP = 0.02

export interface DividerRatioArgs {
  /** Length of the split along its own axis, in px. */
  size: number
  /** Pointer position from the start of that axis, in px. */
  offset: number
  /** The divider's own track, which the two panes do not get to share. */
  dividerPx: number
  minPanePx: number
  /** Returned when the split is too small to place a divider inside. */
  fallback: number
}

/**
 * Ratio for a pointer dragging a divider.
 *
 * The two panes divide `size - dividerPx`, not `size`, and the pointer sits
 * mid-divider rather than on the first pane's edge. Mapping the pointer
 * straight onto the full width instead makes the divider jump away from the
 * cursor the moment a drag starts, by more the further it is from centre.
 */
export function dividerRatio({
  size,
  offset,
  dividerPx,
  minPanePx,
  fallback,
}: DividerRatioArgs): number {
  const bar = Number.isFinite(dividerPx) && dividerPx > 0 ? dividerPx : 0
  const free = size - bar
  // Below this there is no room to put the divider anywhere meaningful, and
  // dividing by it would hand clampRatio a non-finite ratio, which reads as
  // "corrupt" and snaps the split back to the middle.
  if (!Number.isFinite(free) || free <= 0 || !Number.isFinite(offset)) return fallback

  const firstPaneWidth = offset - bar / 2
  return clampRatio(firstPaneWidth / free, Math.max(MIN_PANE_RATIO, minPanePx / free))
}

export interface PaneRenderArgs {
  paneId: string
  /** Null while a pane is waiting to be filled — render a placeholder. */
  tabId: string | null
  focused: boolean
  /**
   * The window's own pane — the first one in visual order — rather than one of
   * the panes opened beside it.
   *
   * The two are deliberately not symmetrical, and the asymmetry is the request:
   *
   *   > *"The first view, main view, can be on the left side with the overall
   *   > same background, everything. The other one — the new split view,
   *   > secondary view — it can be only inside a box, and the other one will not
   *   > be inside a box."*
   *
   * The primary keeps the window's ground and its edges; every other pane is a
   * bounded card sitting on it. With three panes the rule does not stop making
   * sense, it simply reads as one host and two guests, which is what the
   * arrangement is: you split a window you were already working in.
   *
   * The caller takes it further than the container. The host's name, folder and
   * account stay in the *window's* toolbar, exactly where they sat before the
   * split, and only the guests draw a bar of their own — which is what makes
   * the box mean something. Asad, 2026-08-17: *"If we make both exactly the
   * same placement — if the name and the account come down — then there is no
   * reason to keep one of them in a box, because all the sizes, everything, is
   * the same."* See `App.tsx`'s `renderPane` and `PaneBar`.
   *
   * Decided here rather than by the caller because it is a fact about the tree
   * — `primaryPane` reads `listPanes`, which is left-before-right,
   * top-before-bottom — and a caller that had to work it out would be a second
   * copy of the same traversal that could disagree with this one.
   */
  primary: boolean
}

export interface SplitViewProps {
  layout: PaneLayout
  onLayoutChange(next: PaneLayout): void
  /**
   * Renders the contents of one pane. A render-prop rather than an import so
   * this file never depends on TerminalView — the caller decides what a pane
   * holds, and the terminal keeps its own mounting rules.
   */
  renderPane(args: PaneRenderArgs): ReactNode
  /** Shown when the last pane has been closed. */
  empty?: ReactNode
  minPanePx?: number
}

/**
 * Renders a pane tree as nested CSS grids. Each split is a three-track grid —
 * first child, divider, second child — so the divider occupies real space
 * instead of floating over a pane and stealing its clicks.
 */
export function SplitView({
  layout,
  onLayoutChange,
  renderPane,
  empty = null,
  minPanePx = DEFAULT_MIN_PANE_PX,
}: SplitViewProps) {
  const focusPaneById = useCallback(
    (paneId: string) => {
      const next = focusPane(layout, paneId)
      // focusPane hands back the same layout when nothing moved, so an
      // already-focused pane never triggers a re-render of every terminal.
      if (next !== layout) onLayoutChange(next)
    },
    [layout, onLayoutChange],
  )

  const resize = useCallback(
    (splitId: string, ratio: number) => {
      const next = resizeSplit(layout, splitId, ratio)
      if (next !== layout) onLayoutChange(next)
    },
    [layout, onLayoutChange],
  )

  if (!layout.root) return <div className="split-view split-view-empty">{empty}</div>

  // Visual order, so "primary" is the pane at the top-left however the tree
  // happens to be nested — the one the eye reads first, which is the one the
  // window is about. Asked of `pane-tree` rather than worked out here, because
  // `App.tsx` has to reach the same answer to know whose name belongs in the
  // window's toolbar; see `primaryPane`.
  const primaryPaneId = primaryPane(layout)?.id ?? null

  return (
    <div className="split-view">
      <SplitNode
        node={layout.root}
        focusedPaneId={layout.focusedPaneId}
        primaryPaneId={primaryPaneId}
        renderPane={renderPane}
        onFocusPane={focusPaneById}
        onResize={resize}
        minPanePx={minPanePx}
      />
    </div>
  )
}

interface NodeProps {
  node: PaneNode
  focusedPaneId: string | null
  primaryPaneId: string | null
  renderPane(args: PaneRenderArgs): ReactNode
  onFocusPane(paneId: string): void
  onResize(splitId: string, ratio: number): void
  minPanePx: number
}

function SplitNode(props: NodeProps) {
  const { node, focusedPaneId, primaryPaneId, renderPane, onFocusPane } = props

  if (node.type === 'leaf') {
    const focused = node.id === focusedPaneId
    const primary = node.id === primaryPaneId
    return (
      <div
        className="pane-leaf"
        data-pane-id={node.id}
        data-focused={focused}
        // Read by the stylesheet, which is where the whole difference lives:
        // the primary pane is flush with the window and every other one is a
        // card inset into it. An attribute rather than a second class name so
        // both states are addressable — `[data-primary='false']` is what the
        // box is drawn on, and a class would leave that case as a `:not()`.
        data-primary={primary}
        // Capture phase: a click landing inside a terminal still counts as
        // reaching for that pane, and xterm stops the event before it bubbles.
        onPointerDownCapture={() => onFocusPane(node.id)}
        onFocusCapture={() => onFocusPane(node.id)}
      >
        <div className="pane-leaf-body">
          {renderPane({ paneId: node.id, tabId: node.tabId, focused, primary })}
        </div>
      </div>
    )
  }

  const horizontal = node.direction === 'horizontal'
  const tracks = `${node.ratio}fr var(--pane-divider) ${1 - node.ratio}fr`
  const style: CSSProperties = horizontal
    ? { gridTemplateColumns: tracks }
    : { gridTemplateRows: tracks }

  return (
    <div className="pane-split" data-direction={node.direction} style={style}>
      <SplitNode {...props} node={node.children[0]} />
      <Divider split={node} onResize={props.onResize} minPanePx={props.minPanePx} />
      <SplitNode {...props} node={node.children[1]} />
    </div>
  )
}

interface DividerProps {
  split: PaneSplit
  onResize(splitId: string, ratio: number): void
  minPanePx: number
}

function Divider({ split, onResize, minPanePx }: DividerProps) {
  const [dragging, setDragging] = useState(false)
  const horizontal = split.direction === 'horizontal'

  const ratioAt = useCallback(
    (bar: HTMLElement, grid: HTMLElement, clientX: number, clientY: number): number => {
      const rect = grid.getBoundingClientRect()
      const barRect = bar.getBoundingClientRect()
      // A pixel floor on top of the ratio floor: on a small window 8% is a
      // sliver, and a pane too narrow to read is the same as a closed one.
      return dividerRatio({
        size: horizontal ? rect.width : rect.height,
        offset: horizontal ? clientX - rect.left : clientY - rect.top,
        dividerPx: horizontal ? barRect.width : barRect.height,
        minPanePx,
        fallback: split.ratio,
      })
    },
    [horizontal, minPanePx, split.ratio],
  )

  const onPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return
    event.preventDefault()
    // Capture keeps the drag alive over the terminals either side, which would
    // otherwise swallow the pointer the moment it left the divider.
    event.currentTarget.setPointerCapture(event.pointerId)
    setDragging(true)
  }

  const onPointerMove = (event: PointerEvent<HTMLDivElement>) => {
    if (!dragging) return
    // pointermove fires on plain hover too. If the button came up somewhere we
    // never heard about — capture lost to another element, a release outside
    // the window — the divider would otherwise follow the bare cursor forever.
    if (event.buttons === 0) {
      setDragging(false)
      return
    }
    const grid = event.currentTarget.parentElement
    if (!grid) return
    onResize(split.id, ratioAt(event.currentTarget, grid, event.clientX, event.clientY))
  }

  const endDrag = (event: PointerEvent<HTMLDivElement>) => {
    if (!dragging) return
    setDragging(false)
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
  }

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const back = horizontal ? 'ArrowLeft' : 'ArrowUp'
    const forward = horizontal ? 'ArrowRight' : 'ArrowDown'

    if (event.key === back) onResize(split.id, split.ratio - KEY_STEP)
    else if (event.key === forward) onResize(split.id, split.ratio + KEY_STEP)
    else if (event.key === 'Home') onResize(split.id, 0)
    else if (event.key === 'End') onResize(split.id, 1)
    else if (event.key === 'Enter' || event.key === ' ') onResize(split.id, 0.5)
    else return

    event.preventDefault()
  }

  const percent = Math.round(split.ratio * 100)

  return (
    <div
      className="pane-divider"
      role="separator"
      // A side-by-side split is parted by a vertical bar, and vice versa.
      aria-orientation={horizontal ? 'vertical' : 'horizontal'}
      aria-label="Resize panes"
      aria-valuenow={percent}
      aria-valuemin={Math.round(MIN_PANE_RATIO * 100)}
      aria-valuemax={100 - Math.round(MIN_PANE_RATIO * 100)}
      aria-valuetext={`${percent}%`}
      tabIndex={0}
      data-dragging={dragging}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={endDrag}
      onPointerCancel={endDrag}
      // The browser can take the capture away without a pointerup — the node
      // being moved, another element grabbing it — and a drag left switched on
      // resizes on the next hover.
      onLostPointerCapture={() => setDragging(false)}
      onKeyDown={onKeyDown}
      onDoubleClick={() => onResize(split.id, 0.5)}
    />
  )
}
