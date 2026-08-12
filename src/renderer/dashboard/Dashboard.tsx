import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { GridStack, type GridItemHTMLElement, type GridStackNode } from 'gridstack'
import 'gridstack/dist/gridstack.css'
import { Modal } from '../components/Modal'
import {
  addWidget,
  applyPlacements,
  canAddWidget,
  countWidgets,
  DASHBOARD_COLUMNS,
  defaultLayout,
  moveWidget,
  parseLayout,
  readingOrder,
  removeWidget,
  resizeWidget,
  serialiseLayout,
  WIDGET_SPECS,
  type DashboardLayout,
  type WidgetType,
} from './layout'
import { getWidgetDefinition, listWidgetDefinitions, type WidgetContext } from './widgets'
import './Dashboard.css'

/**
 * The project dashboard: a gridstack grid of widgets, arranged by dragging and
 * resizing, persisted per project.
 *
 * Division of labour, and the reason this file is thin: `layout.ts` owns the
 * grid maths and is fully tested without a DOM; gridstack owns pixels and
 * pointer events; this component only keeps the two in agreement. Anything
 * here that looks like layout logic belongs in the model instead.
 */

/** Row height in pixels. Widget default sizes in `layout.ts` are tuned to it. */
const CELL_HEIGHT = 56
const GRID_MARGIN = 8
const SAVE_DEBOUNCE_MS = 500

/**
 * Persistence contract, declared locally rather than imported from the shared
 * bridge type so this component can be tested and reused without the preload
 * layer — and so wiring it up is one line in the orchestrator.
 */
export interface DashboardBridge {
  loadDashboard(projectPath: string): Promise<unknown>
  saveDashboard(projectPath: string, layout: unknown): Promise<unknown>
}

export interface DashboardProps {
  /** Absolute path of the project this dashboard belongs to. */
  projectPath: string
  /** Passed through to every widget. */
  context?: Omit<WidgetContext, 'projectPath'>
  /** Defaults to the preload bridge; pass one in tests or for a memory dashboard. */
  bridge?: DashboardBridge
}

/**
 * Resolve the preload bridge at call time. The dashboard must not hard-fail
 * when the main process hasn't registered its channels yet — it degrades to an
 * in-memory arrangement instead of throwing on mount.
 */
function windowBridge(): DashboardBridge | null {
  const api = (globalThis as unknown as { deck?: Record<string, unknown> }).deck
  const load = api?.loadDashboard
  const save = api?.saveDashboard
  if (typeof load !== 'function' || typeof save !== 'function') return null
  return {
    loadDashboard: (path) => (load as (p: string) => Promise<unknown>)(path),
    saveDashboard: (path, layout) =>
      (save as (p: string, l: unknown) => Promise<unknown>)(path, layout),
  }
}

export function Dashboard({ projectPath, context, bridge }: DashboardProps) {
  const [layout, setLayout] = useState<DashboardLayout>(() => defaultLayout(projectPath))
  const [loaded, setLoaded] = useState(false)
  const [picking, setPicking] = useState(false)

  const resolvedBridge = useMemo(() => bridge ?? windowBridge(), [bridge])

  const rootRef = useRef<HTMLDivElement>(null)
  const gridRef = useRef<GridStack | null>(null)
  /**
   * Live DOM node per widget id.
   *
   * Entries are never dropped when React detaches a node, only after gridstack
   * has been told the widget is gone — gridstack finds its node through the
   * element, so losing the reference first would strand the node in its engine
   * and the tile would keep occupying cells nothing renders into.
   */
  const elements = useRef(new Map<string, HTMLDivElement>())
  /** Ids gridstack currently manages, which is not the same as ids React renders. */
  const managed = useRef(new Set<string>())

  /* ------------------------------------------------------------ persistence -- */

  // Load whenever the project changes. `stale` guards against a slow load for
  // project A landing after the user has already switched to project B.
  useEffect(() => {
    let stale = false
    setLoaded(false)
    setLayout(defaultLayout(projectPath))

    if (!resolvedBridge) {
      setLoaded(true)
      return
    }

    void resolvedBridge
      .loadDashboard(projectPath)
      .then((raw) => {
        if (stale) return
        // The store hands back whatever was on disk, including null on first
        // run — repair and migration are the model's job, not the store's.
        setLayout(parseLayout(raw, projectPath))
        // Saving is armed here and nowhere else: only a read that actually came
        // back means the arrangement on screen is the one on disk.
        setLoaded(true)
      })
      .catch((err: unknown) => {
        // `loaded` deliberately stays false. Arming saves after a failed read
        // would let the placeholder default layout be written over the file
        // half a second later and destroy the user's arrangement.
        console.error('[dashboard] load failed — persistence stays off:', err)
      })

    return () => {
      stale = true
    }
  }, [projectPath, resolvedBridge])

  const saveTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  /** The edit the debounce timer is still holding, so teardown can flush it. */
  const pendingSave = useRef<{ projectPath: string; layout: DashboardLayout } | null>(null)

  useEffect(() => {
    if (!loaded || !resolvedBridge) {
      pendingSave.current = null
      return
    }
    pendingSave.current = { projectPath, layout }
    clearTimeout(saveTimer.current)
    saveTimer.current = setTimeout(() => {
      const pending = pendingSave.current
      pendingSave.current = null
      if (!pending) return
      void resolvedBridge
        .saveDashboard(pending.projectPath, serialiseLayout(pending.layout))
        .catch((err: unknown) => console.error('[dashboard] save failed:', err))
    }, SAVE_DEBOUNCE_MS)
    return () => clearTimeout(saveTimer.current)
  }, [layout, loaded, projectPath, resolvedBridge])

  // Flush on unmount and on a project switch — the effect above kills its own
  // timer on teardown, so without this the last drag before leaving is lost.
  // Declared after it so this cleanup runs second, once the timer is dead.
  useEffect(() => {
    return () => {
      const pending = pendingSave.current
      pendingSave.current = null
      if (!pending || !resolvedBridge) return
      void resolvedBridge
        .saveDashboard(pending.projectPath, serialiseLayout(pending.layout))
        .catch((err: unknown) => console.error('[dashboard] final save failed:', err))
    }
  }, [projectPath, resolvedBridge])

  /* -------------------------------------------------------------- gridstack -- */

  // Init once. The grid outlives every layout change; only its nodes come and go.
  useEffect(() => {
    const root = rootRef.current
    if (!root) return

    const grid = GridStack.init(
      {
        column: DASHBOARD_COLUMNS,
        cellHeight: CELL_HEIGHT,
        margin: GRID_MARGIN,
        // Widgets settle upwards into gaps, so deleting one closes the hole it
        // leaves instead of stranding the rest of the dashboard below it.
        float: false,
        animate: true,
        // Children are added explicitly with known coordinates; letting
        // gridstack auto-adopt whatever React had already painted would race
        // the first sync and place tiles at wherever the DOM order implied.
        auto: false,
        // Drag from the header only. The bodies are lists and buttons, and a
        // grab anywhere would swallow every click meant for their content.
        handle: '.widget-drag-handle',
        acceptWidgets: false,
      },
      root,
    )
    gridRef.current = grid

    // gridstack is authoritative for geometry: it packs, pushes and clamps in
    // ways the model does not try to predict. Every change it reports — from a
    // drag, a resize, or its own compaction while widgets are being added —
    // is absorbed verbatim. `applyPlacements` returns the same object when
    // nothing actually moved, so an echo of our own edit is a no-op render.
    grid.on('change', (_event: Event, nodes: GridStackNode[]) => {
      if (!nodes?.length) return
      setLayout((current) =>
        applyPlacements(
          current,
          nodes.flatMap((node) =>
            typeof node.id === 'string' ? [{ id: node.id, x: node.x, y: node.y, w: node.w, h: node.h }] : [],
          ),
        ),
      )
    })

    return () => {
      // `false`: React owns these DOM nodes and will unmount them itself.
      // Letting gridstack rip them out first leaves React writing into a tree
      // that no longer exists.
      grid.destroy(false)
      gridRef.current = null
      // Only the gridstack-side bookkeeping is dropped. `elements` deliberately
      // survives: StrictMode tears this effect down and runs it again without
      // unmounting the tiles, so React never re-fires their ref callbacks — and
      // a cleared map would leave the second grid with nothing to adopt and
      // every widget stacked, undraggable, at the origin.
      managed.current.clear()
    }
  }, [])

  // Reconcile gridstack's nodes with the model after every render that changed
  // the widget set or their geometry.
  useEffect(() => {
    const grid = gridRef.current
    if (!grid) return

    const live = new Set(layout.widgets.map((widget) => widget.id))

    // One batch, so intermediate compaction never renders and gridstack emits a
    // single change event at the end rather than one per widget.
    grid.batchUpdate()
    try {
      for (const id of [...managed.current]) {
        if (live.has(id)) continue
        const el = elements.current.get(id)
        // `false, false`: React unmounts the node itself, and the repacking
        // this causes is reported once when the batch commits.
        if (el) grid.removeWidget(el, false, false)
        managed.current.delete(id)
      }

      // Prune the element map separately from the grid bookkeeping — the two
      // go out of step whenever the grid is torn down and rebuilt underneath
      // tiles that never unmounted.
      for (const id of [...elements.current.keys()]) {
        if (!live.has(id)) elements.current.delete(id)
      }

      // Visual order, not insertion order: adding top-left tiles first means
      // gridstack's upward packing has nothing to pull up, so a saved
      // arrangement lands exactly as it was left.
      for (const widget of readingOrder(layout)) {
        const el = elements.current.get(widget.id)
        if (!el) continue
        const spec = WIDGET_SPECS[widget.type]
        const geometry = { x: widget.x, y: widget.y, w: widget.w, h: widget.h }

        if (!managed.current.has(widget.id)) {
          grid.makeWidget(el, { ...geometry, id: widget.id, minW: spec.minW, minH: spec.minH })
          managed.current.add(widget.id)
          continue
        }

        // The model moved without gridstack's involvement — a keyboard nudge,
        // or a reset. Pushing it back is what keeps the two from diverging.
        // gridstack hangs its node off the element it was given; the cast is
        // only naming that, since React's ref hands back a plain HTMLDivElement.
        const node = (el as GridItemHTMLElement).gridstackNode
        if (node && (node.x !== widget.x || node.y !== widget.y || node.w !== widget.w || node.h !== widget.h)) {
          grid.update(el, geometry)
        }
      }
    } finally {
      // In a `finally` so a throw mid-sync cannot leave the grid batched and
      // frozen for the rest of the session.
      grid.batchUpdate(false)
    }
  }, [layout])

  /* ---------------------------------------------------------------- actions -- */

  const registerElement = useCallback((id: string, el: HTMLDivElement | null) => {
    // Null means React is detaching the node. The entry is kept deliberately —
    // see the `elements` ref comment; the sync effect clears it once gridstack
    // has let go.
    if (el) elements.current.set(id, el)
  }, [])

  const handleAdd = useCallback((type: WidgetType) => {
    setLayout((current) => addWidget(current, { type }))
    setPicking(false)
  }, [])

  const handleRemove = useCallback((id: string) => {
    setLayout((current) => removeWidget(current, id))
  }, [])

  const handleReset = useCallback(() => {
    setLayout(defaultLayout(projectPath))
  }, [projectPath])

  /**
   * Keyboard equivalents for drag and resize.
   *
   * Pointer dragging is unreachable for anyone who cannot hold a button down
   * while moving, and gridstack offers no keyboard path of its own, so the
   * model's own transitions are wired to Alt+arrows (move) and Alt+Shift+arrows
   * (resize) on the focused widget header.
   */
  const handleKeyDown = useCallback((event: React.KeyboardEvent, id: string) => {
    if (!event.altKey) return
    const deltas: Record<string, [number, number]> = {
      ArrowLeft: [-1, 0],
      ArrowRight: [1, 0],
      ArrowUp: [0, -1],
      ArrowDown: [0, 1],
    }
    const delta = deltas[event.key]
    if (!delta) return
    event.preventDefault()

    setLayout((current) => {
      const widget = current.widgets.find((w) => w.id === id)
      if (!widget) return current
      const [dx, dy] = delta
      return event.shiftKey
        ? resizeWidget(current, id, widget.w + dx, widget.h + dy)
        : moveWidget(current, id, widget.x + dx, widget.y + dy)
    })
  }, [])

  const widgetContext = useMemo<WidgetContext>(
    () => ({ ...context, projectPath }),
    [context, projectPath],
  )

  const available = listWidgetDefinitions()
  const empty = countWidgets(layout) === 0

  return (
    <section className="dashboard" aria-label="Project dashboard">
      <header className="dashboard-bar">
        <h2 className="dashboard-title">Overview</h2>
        <span className="dashboard-hint">Drag a widget by its header · Alt+arrows to move</span>
        <button type="button" className="dashboard-btn" onClick={() => setPicking(true)}>
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
            <path d="M12 5v14M5 12h14" strokeWidth="2" strokeLinecap="round" />
          </svg>
          Add widget
        </button>
        <button type="button" className="dashboard-btn ghost" onClick={handleReset}>
          Reset
        </button>
      </header>

      <div className="dashboard-scroll">
        {empty && (
          <div className="dashboard-empty">
            <p className="dashboard-empty-title">Nothing on this dashboard</p>
            <p className="dashboard-empty-detail">
              Add a widget to see sessions, spend, git state and the board at a glance.
            </p>
            <button type="button" className="dashboard-btn" onClick={() => setPicking(true)}>
              Add widget
            </button>
          </div>
        )}

        {/* Rendered even when empty: gridstack initialises against this node
            once, and swapping it out for the empty state would tear the grid
            down and rebuild it on every transition through zero widgets. */}
        <div ref={rootRef} className="grid-stack dashboard-grid" hidden={empty}>
          {layout.widgets.map((widget) => {
            const definition = getWidgetDefinition(widget.type)
            if (!definition) return null
            const { Component } = definition
            return (
              // No `style` and no `gs-*` attributes: gridstack writes both, and
              // React would clobber them on the next render. className is a
              // constant for the same reason — gridstack appends `ui-draggable`
              // and friends to it, and a conditional class here would wipe them.
              <div
                key={widget.id}
                ref={(el) => registerElement(widget.id, el)}
                className="grid-stack-item"
                data-widget-id={widget.id}
              >
                <div className="grid-stack-item-content widget">
                  <header
                    className="widget-head widget-drag-handle"
                    tabIndex={0}
                    role="group"
                    aria-label={`${definition.title} widget. Alt with arrow keys to move, Alt and Shift with arrow keys to resize.`}
                    onKeyDown={(event) => handleKeyDown(event, widget.id)}
                  >
                    <h3 className="widget-title">{definition.title}</h3>
                    <button
                      type="button"
                      className="widget-remove"
                      title={`Remove ${definition.title}`}
                      aria-label={`Remove ${definition.title} widget`}
                      onClick={() => handleRemove(widget.id)}
                    >
                      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                        <path d="M6 6l12 12M18 6L6 18" strokeWidth="2" strokeLinecap="round" />
                      </svg>
                    </button>
                  </header>
                  <div className="widget-body">
                    <Component context={widgetContext} />
                  </div>
                </div>
              </div>
            )
          })}
        </div>
      </div>

      <Modal
        open={picking}
        title="Add a widget"
        description="Widgets you already have are greyed out."
        onClose={() => setPicking(false)}
      >
        <ul className="widget-picker">
          {available.map((definition) => {
            const allowed = canAddWidget(layout, definition.type)
            return (
              <li key={definition.type}>
                <button
                  type="button"
                  className="widget-picker-item"
                  disabled={!allowed}
                  onClick={() => handleAdd(definition.type)}
                >
                  <span className="widget-picker-name">{definition.title}</span>
                  <span className="widget-picker-detail">{definition.description}</span>
                  {!allowed && <span className="widget-picker-tag">on the dashboard</span>}
                </button>
              </li>
            )
          })}
        </ul>
      </Modal>
    </section>
  )
}
