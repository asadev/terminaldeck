import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from 'react'
import {
  addAnnotation,
  composeHandoff,
  describeElement,
  removeAnnotation,
  type AnnotatedElement,
  type Annotation,
  type AnnotateWhere,
  type AnnotationRound,
} from '../../shared/annotate'
import type { NormRect } from '../../shared/device-tree'
import { SendToAgent } from '../browser/SendToAgent'
import type { AgentTarget } from '../browser/useAgentTarget'
import '../browser/BrowserWorkspace.css'
import { drawMarkedPicture, inkOf } from './marked-picture'
import './annotate.css'

/**
 * Annotate: the frozen screen, the numbered markers on it, one note, and Send.
 *
 * One note for the whole round, in the box at the foot of the card — the same
 * box, with the same words, in the browser and on a device. 0.16.0 also put a
 * note box under every marker; Asad, reviewing it: *keep only one box*. He
 * points at several things and says what he wants about them together, by
 * number, so the markers are the list and the box is the sentence.
 *
 * ## One surface, two places
 *
 * The browser and the Simulators page both open this, and nothing in it knows
 * which one it is in. What differs is handed in:
 *
 *  - `frame` — the picture that was frozen. In the browser, the photograph the
 *    main process took at the instant of the first click; on a device, the
 *    engine's full-resolution screenshot taken when Annotate was turned on.
 *  - `pick` — what is under a point. The browser asks the real page, still
 *    loaded beneath the photograph; a device looks in the accessibility tree
 *    read at the same moment as the picture.
 *  - `hover`, optionally — an instant answer to the same question for the
 *    outline that follows the pointer. A device has its tree in hand and can
 *    afford one per mouse move; the browser would be an IPC round trip per
 *    pixel, so it passes none and the outline is simply absent there.
 *
 * Everything else — the numbered markers, the list, editing and deleting, the
 * one message and the one picture that go to the session — is this file and
 * `@shared/annotate`, once. Asad asked for exactly that: the same mode, the same
 * look, the same handoff in both places.
 *
 * ## What freezing means
 *
 * SimView, the tool he pointed at, freezes the frame the moment Annotate is on
 * and resumes the live stream when it is off. The same here: the picture does
 * not change while it is being pointed at, so a marker can never drift off the
 * thing it was put on, and the file the agent opens is the picture the person
 * was looking at — not a later one.
 */

export interface Pick {
  rect: NormRect
  element: AnnotatedElement | null
}

interface Props {
  frame: { image: string; width: number; height: number }
  where: AnnotateWhere
  pick(x: number, y: number): Promise<Pick | null>
  hover?(x: number, y: number): NormRect | null
  /** The browser's first click, already captured. Devices start empty. */
  initial?: Pick
  agent: AgentTarget
  /** Keep the marked picture and remember the round. Null when it could not be saved. */
  save(png: string, round: AnnotationRound): Promise<{ path: string; width: number; height: number } | null>
  /** The round reached a session. */
  onSent?(roundId: string, sentTo: { sessionId: string; label: string }): void
  /** Leave Annotate. Called after a send and on Done. */
  onClose(): void
  /** "screen" on a device, "page" in the browser — the one word the empty line needs. */
  noun: 'screen' | 'page'
  /**
   * One line for the panel when the picture came without its elements — a
   * device whose tree could not be read. Notes still work, by position.
   */
  notice?: string
  /**
   * `beside`: the picture fitted on the left and the notes on the right — a
   * phone, which is narrow. `over`: the picture at its own size filling the
   * surface and the notes floating over its right edge — a web page, which is
   * the width of the pane and must not be shrunk out from under its markers.
   */
  layout?: 'beside' | 'over'
  style?: CSSProperties
}

/** A box around a point, for a click that landed on nothing with a name. */
function boxAround(x: number, y: number): NormRect {
  const size = 0.04
  return {
    x: Math.min(Math.max(x - size / 2, 0), 1 - size),
    y: Math.min(Math.max(y - size / 2, 0), 1 - size),
    width: size,
    height: size,
  }
}

function pct(rect: NormRect): CSSProperties {
  return {
    left: `${rect.x * 100}%`,
    top: `${rect.y * 100}%`,
    width: `${Math.max(rect.width * 100, 0.5)}%`,
    height: `${Math.max(rect.height * 100, 0.5)}%`,
  }
}

let seq = 0
function newId(prefix: string): string {
  seq += 1
  const random =
    typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
      ? crypto.randomUUID()
      : `${Date.now().toString(36)}-${seq}`
  return `${prefix}-${random}`
}

/** The short name of where this is, for the head of the panel. */
function shortWhere(where: AnnotateWhere): string {
  if (where.kind === 'browser') {
    try {
      return where.url ? new URL(where.url).host : where.name
    } catch {
      return where.name
    }
  }
  return where.app ? `${where.name} · ${where.app}` : where.name
}

export function AnnotateSurface({
  frame,
  where,
  pick,
  hover,
  initial,
  agent,
  save,
  onSent,
  onClose,
  noun,
  notice = '',
  layout = 'beside',
  style,
}: Props) {
  const roundId = useMemo(() => newId('round'), [])
  const createdAt = useMemo(() => Date.now(), [])
  const [annotations, setAnnotations] = useState<Annotation[]>(() =>
    initial ? addAnnotation([], { id: newId('a'), rect: initial.rect, element: initial.element }) : [],
  )
  const [focused, setFocused] = useState<string>(() => annotations[0]?.id ?? '')
  // Bumped each time a marker lands, so the note box takes the caret: click,
  // then type, is the whole of it.
  const [focusKey, setFocusKey] = useState(() => (initial ? 1 : 0))
  const [hoverRect, setHoverRect] = useState<NormRect | null>(null)
  const [picking, setPicking] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const stageRef = useRef<HTMLDivElement | null>(null)
  const pictureRef = useRef<HTMLDivElement | null>(null)
  const inkRef = useRef<HTMLSpanElement | null>(null)
  const [size, setSize] = useState<{ width: number; height: number } | null>(null)

  /*
   * The picture at the largest size that fits, worked out rather than left to
   * CSS. `aspect-ratio` with both a height and a max-width resolves one and
   * ignores the other, and a marker placed in percentages of a box that is not
   * the picture's own shape lands beside the thing it marks.
   */
  useLayoutEffect(() => {
    const stage = stageRef.current
    if (!stage || frame.width === 0 || frame.height === 0) return
    const fit = (): void => {
      const box = stage.getBoundingClientRect()
      const scale = Math.min(box.width / frame.width, box.height / frame.height)
      if (!Number.isFinite(scale) || scale <= 0) return
      setSize({ width: Math.floor(frame.width * scale), height: Math.floor(frame.height * scale) })
    }
    fit()
    if (typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(fit)
    observer.observe(stage)
    return () => observer.disconnect()
  }, [frame.width, frame.height])


  const pointOf = (event: { clientX: number; clientY: number }): { x: number; y: number } | null => {
    const node = pictureRef.current
    if (!node) return null
    const box = node.getBoundingClientRect()
    if (box.width === 0 || box.height === 0) return null
    return {
      x: Math.min(Math.max((event.clientX - box.left) / box.width, 0), 1),
      y: Math.min(Math.max((event.clientY - box.top) / box.height, 0), 1),
    }
  }

  const addAt = useCallback(
    async (x: number, y: number): Promise<void> => {
      if (picking) return
      setPicking(true)
      setConfirming(false)
      try {
        const found = await pick(x, y).catch(() => null)
        const id = newId('a')
        setAnnotations((prev) =>
          addAnnotation(prev, {
            id,
            rect: found?.rect ?? boxAround(x, y),
            element: found?.element ?? null,
          }),
        )
        setFocused(id)
        setFocusKey((key) => key + 1)
      } finally {
        setPicking(false)
      }
    },
    [pick, picking],
  )

  const leave = (): void => {
    if (annotations.length > 0 && !confirming) {
      setConfirming(true)
      return
    }
    onClose()
  }

  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if (event.key !== 'Escape') return
      // Stopped here: the browser workspace and the page both bind Escape, and
      // one press must do one thing.
      event.stopPropagation()
      if (confirming) setConfirming(false)
      else leave()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  })

  const round: AnnotationRound = {
    id: roundId,
    createdAt,
    where,
    frame: { width: frame.width, height: frame.height },
    annotations,
    note: '',
  }

  const prepare = async (typed: string): Promise<{ path: string } | null> => {
    const drawn = await drawMarkedPicture(frame.image, annotations, inkOf(inkRef.current))
    if (!drawn) return null
    const kept = await save(drawn.png, { ...round, note: typed, frame: { width: drawn.width, height: drawn.height } })
    return kept ? { path: kept.path } : null
  }

  return (
    <div className="an" data-layout={layout} style={style} role="dialog" aria-label="Annotate">
      {/* Never shown. It wears the accent so the picture can be drawn in it. */}
      <span className="an-ink" ref={inkRef} aria-hidden="true" />
      <div className="an-stage" ref={stageRef}>
        <div
          className="an-picture"
          ref={pictureRef}
          data-picking={picking || undefined}
          style={size ? { width: size.width, height: size.height } : { visibility: 'hidden' }}
          onClick={(event) => {
            const at = pointOf(event)
            if (at) void addAt(at.x, at.y)
          }}
          onMouseMove={(event) => {
            if (!hover) return
            const at = pointOf(event)
            setHoverRect(at ? hover(at.x, at.y) : null)
          }}
          onMouseLeave={() => setHoverRect(null)}
        >
          <img src={frame.image} alt={`The frozen ${noun}`} draggable={false} />
          {hoverRect && <span className="an-hover" style={pct(hoverRect)} aria-hidden="true" />}
          {annotations.map((entry) => (
            <span
              key={entry.id}
              className="an-mark"
              data-on={entry.id === focused || undefined}
              style={pct(entry.rect)}
              onClick={(event) => {
                // A click on a marker is choosing it, not putting a second one
                // on the same spot.
                event.stopPropagation()
                setFocused(entry.id)
              }}
            >
              <b className="an-badge">{entry.n}</b>
            </span>
          ))}
        </div>
      </div>

      <aside className="an-panel" aria-label="Markers and note">
        <header className="an-head">
          <span className="an-title">Annotate</span>
          <span className="an-where" title={shortWhere(where)}>
            {shortWhere(where)}
          </span>
          <button type="button" className="an-done" onClick={leave}>
            Done
          </button>
        </header>

        {confirming && (
          <div className="an-confirm" role="alert">
            <span>
              Discard {annotations.length} marker{annotations.length === 1 ? '' : 's'}?
            </span>
            <button type="button" className="an-text-button" onClick={() => setConfirming(false)}>
              Keep
            </button>
            <button type="button" className="bw-danger" onClick={onClose}>
              Discard
            </button>
          </div>
        )}

        {notice !== '' && <p className="an-notice">{notice}</p>}

        {annotations.length === 0 ? (
          <p className="an-empty">Click anything on the {noun} to mark it.</p>
        ) : (
          <ol className="an-list">
            {annotations.map((entry) => (
              <li key={entry.id} className="an-row" data-on={entry.id === focused || undefined}>
                <b className="an-badge" aria-hidden="true">
                  {entry.n}
                </b>
                <span className="an-element" title={describeElement(entry.element)}>
                  {describeElement(entry.element)}
                </span>
                <button
                  type="button"
                  className="an-remove"
                  aria-label={`Delete marker ${entry.n}`}
                  title="Delete"
                  onClick={() => {
                    setAnnotations((prev) => removeAnnotation(prev, entry.id))
                    if (focused === entry.id) setFocused('')
                  }}
                >
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                    <path d="M5 7h14M10 7V5h4v2M7 7l1 12h8l1-12" />
                  </svg>
                </button>
              </li>
            ))}
          </ol>
        )}

        <div className="an-send">
          <SendToAgent
            agent={agent}
            prepare={prepare}
            needsText
            multiline
            focusKey={focusKey}
            notReady={annotations.length === 0 ? `Mark something on the ${noun} first.` : ''}
            compose={(typed, handed) => composeHandoff({ ...round, note: typed }, handed)}
            placeholder="What should change?"
            action="Send"
            onSent={() => {
              const target = agent.target
              if (target) onSent?.(roundId, { sessionId: target.id, label: target.label })
              onClose()
            }}
          />
        </div>
      </aside>
    </div>
  )
}
