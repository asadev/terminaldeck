import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import type { SessionStatus } from '@shared/types'
import { StatusDot } from '../components/StatusDot'
import './SwarmGrid.css'

/**
 * Narrowest cell that still shows a usable terminal. At 13px JetBrains Mono a
 * character is roughly 7.8px, so 320px is about 40 columns — enough to read a
 * prompt and see what an agent is doing, which is what swarm mode is for.
 */
export const SWARM_MIN_CELL_WIDTH = 320

/**
 * Column count for a swarm of `count` sessions in a container `containerWidth`
 * wide, where `containerWidth` is the content box — what is left after the
 * grid's own padding, and what `ResizeObserver` reports.
 *
 * A square-ish grid keeps cells as large as possible, so ceil(sqrt(n)) is the
 * starting point. Width then overrides it: on a narrow window three columns of
 * 200px show three unreadable slivers, and one tall column of readable
 * terminals is worth more than a tidy grid.
 *
 * `gap` is the gutter between columns. c columns spend (c-1) gutters, so the
 * cells share `containerWidth - (c - 1) * gap` — ignoring that hands out
 * columns the cells cannot actually afford: at 960px with a 6px gutter, three
 * columns leave 316px each, under a minimum that exists precisely to keep a
 * terminal readable.
 */
export function swarmColumns(
  count: number,
  containerWidth: number,
  minCellWidth: number = SWARM_MIN_CELL_WIDTH,
  gap: number = 0,
): number {
  if (count <= 1) return 1

  const square = Math.ceil(Math.sqrt(count))
  // Width is unknown before the first measure — assume it is not the binding
  // constraint rather than collapsing to one column and reflowing.
  if (!Number.isFinite(containerWidth) || containerWidth <= 0) return square

  const gutter = Number.isFinite(gap) && gap > 0 ? gap : 0
  // c cells fit when c * minCellWidth + (c - 1) * gutter <= containerWidth.
  const fits = Math.floor((containerWidth + gutter) / Math.max(1, minCellWidth + gutter))
  return Math.max(1, Math.min(square, fits, count))
}

export function swarmRows(count: number, columns: number): number {
  if (count <= 0 || columns <= 0) return 0
  return Math.ceil(count / columns)
}

/**
 * Whether a focus request is worth passing on to the host.
 *
 * One click on a cell fires three of them — the pointer-down capture, the
 * focus capture, then the header button's click — and a cell that already has
 * focus fires them all over again on every click and every tab into it.
 * Without this the host is told to focus the session it is already showing,
 * indefinitely, and any work it does on focus (refitting a terminal, clearing
 * an unread badge, pushing history) is repeated each time.
 */
export function shouldRequestFocus(activeSessionId: string | null, sessionId: string): boolean {
  return sessionId !== activeSessionId
}

interface GridMetrics {
  /** Content-box width: the space the columns actually divide up. */
  readonly width: number
  /** Gutter between columns, read from the stylesheet rather than assumed. */
  readonly gap: number
}

function cssPx(value: string): number {
  const parsed = Number.parseFloat(value)
  return Number.isFinite(parsed) ? parsed : 0
}

/**
 * The content box, which is what `ResizeObserver` reports. `getBoundingClientRect`
 * is the border box, so measuring with it counts the grid's own padding as
 * space for cells — enough, at a boundary, to lay out one more column on the
 * first frame and then take it away on the second, refitting every terminal.
 */
function readMetrics(host: HTMLElement, borderBoxWidth: number): GridMetrics {
  const style = getComputedStyle(host)
  const width = borderBoxWidth - cssPx(style.paddingLeft) - cssPx(style.paddingRight)
  return { width: Math.max(0, width), gap: cssPx(style.columnGap) }
}

/** The minimum a session must expose to appear in the swarm. */
export interface SwarmSession {
  id: string
  title: string
  status: SessionStatus
}

export interface SwarmCellArgs {
  session: SwarmSession
  focused: boolean
}

export interface SwarmGridProps {
  sessions: readonly SwarmSession[]
  activeSessionId: string | null
  onFocusSession(id: string): void
  /** Render-prop for the cell body, so this file never imports TerminalView. */
  renderCell(args: SwarmCellArgs): ReactNode
  /** Adds a "+" affordance to the leftover grid slots when provided. */
  onNewSession?(): void
  /** Shown when there is nothing running. */
  empty?: ReactNode
  minCellWidth?: number
}

/**
 * Every running session on screen at once. Unlike the split view there is no
 * tree here — the grid is derived from the session list, so opening or closing
 * a session reflows it without any layout state to keep in sync.
 */
export function SwarmGrid({
  sessions,
  activeSessionId,
  onFocusSession,
  renderCell,
  onNewSession,
  empty = null,
  minCellWidth = SWARM_MIN_CELL_WIDTH,
}: SwarmGridProps) {
  const hostRef = useRef<HTMLDivElement>(null)
  const [metrics, setMetrics] = useState<GridMetrics>({ width: 0, gap: 0 })

  useEffect(() => {
    const host = hostRef.current
    if (!host || typeof ResizeObserver === 'undefined') return

    const apply = (next: GridMetrics) => {
      // Sub-pixel churn cannot change a column count, and every state change
      // here refits every terminal in the grid.
      setMetrics((prev) =>
        prev.gap === next.gap && Math.abs(prev.width - next.width) < 1 ? prev : next,
      )
    }

    // contentRect is already the content box, so it needs no padding correction.
    const observer = new ResizeObserver((entries) => {
      const entry = entries[0]
      if (!entry) return
      apply({ width: entry.contentRect.width, gap: cssPx(getComputedStyle(host).columnGap) })
    })
    observer.observe(host)
    apply(readMetrics(host, host.getBoundingClientRect().width))

    return () => observer.disconnect()
  }, [])

  const requestFocus = (sessionId: string) => {
    if (shouldRequestFocus(activeSessionId, sessionId)) onFocusSession(sessionId)
  }

  if (sessions.length === 0) {
    return (
      <div ref={hostRef} className="swarm-grid swarm-grid-empty">
        {empty}
      </div>
    )
  }

  const columns = swarmColumns(sessions.length, metrics.width, minCellWidth, metrics.gap)
  const rows = swarmRows(sessions.length, columns)
  const style: CSSProperties = {
    gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))`,
    gridTemplateRows: `repeat(${rows}, minmax(0, 1fr))`,
  }
  const spare = columns * rows - sessions.length

  return (
    <div ref={hostRef} className="swarm-grid" style={style} data-columns={columns}>
      {sessions.map((session) => {
        const focused = session.id === activeSessionId
        return (
          <section
            key={session.id}
            className="swarm-cell"
            data-focused={focused}
            data-session-id={session.id}
            // Capture phase, because clicking straight into a terminal is the
            // most natural way to say "work in this one".
            onPointerDownCapture={() => requestFocus(session.id)}
            onFocusCapture={() => requestFocus(session.id)}
          >
            <button
              type="button"
              className="swarm-cell-head"
              // The head, not the whole cell, is the button — a cell-sized
              // button would eat every keystroke meant for the terminal.
              aria-current={focused ? 'true' : undefined}
              title={session.title}
              onClick={() => requestFocus(session.id)}
            >
              <StatusDot status={session.status} />
              <span className="swarm-cell-title">{session.title}</span>
            </button>
            <div className="swarm-cell-body">{renderCell({ session, focused })}</div>
          </section>
        )
      })}

      {Array.from({ length: spare }, (_, i) => (
        <div key={`spare-${i}`} className="swarm-spare">
          {onNewSession && (
            <button
              type="button"
              className="swarm-spare-add"
              title="New session"
              aria-label="New session"
              onClick={onNewSession}
            >
              <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
                <path
                  d="M8 3.5v9M3.5 8h9"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="1.5"
                  strokeLinecap="round"
                />
              </svg>
            </button>
          )}
        </div>
      ))}
    </div>
  )
}
