import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent,
  type PointerEvent as ReactPointerEvent,
} from 'react'
import { HootMark } from '../copilot/HootMark'
import { EMPTY_SNAPSHOT, needsYou, readSnapshot, type HootPanelSnapshot } from '../../shared/hoot-panel-model'
import {
  barRow,
  clampExpanded,
  EASE_CLOSE,
  EASE_OPEN,
  edgeShape,
  expandedShape,
  islandPath,
  restBox,
  restShape,
  TIMING,
  transition,
  type IslandShape,
} from '../../shared/hoot-island'
import './hoot-panel.css'

/**
 * Hoot's island: the page inside the window `main/hoot-menubar.ts` hangs from
 * the top centre of the screen.
 *
 * One shape, drawn here, that is a small pill at rest — around the notch on a
 * MacBook that has one — and grows into a wide, short panel when the pointer
 * rests on it, then settles back. Its outline is a single path
 * (`islandPath`) clipped out of one surface, so the pill *becomes* the panel and
 * the panel is one piece from the top edge of the screen down: no band, no
 * divider, no second material. The numbers are `shared/hoot-island.ts`.
 *
 * At rest it says the state of things at a glance — "4 open · 2 working · 1
 * waiting". Grown, the conversation with Hoot is the panel: one text surface
 * from the top edge of the screen down to "Ask Hoot…" across the bottom. The
 * "Hoot" tab and the sessions — small chips, a press away, or a quiet "No
 * sessions running" in the same place so he always knows where to look — float
 * over the top of that text on solid pills of their own; the conversation
 * starts just under them and scrolls on behind them. Asad, 2026-10-04: *"text
 * should still go behind those pill buttons, and those pill buttons should be on
 * the top of that. So it is overall one text and pill buttons are overlaying
 * over the text."* It wears the app's theme, light or dark, with the app's own
 * surface colours.
 *
 * ## The window never changes; the shape does, on the browser's own clock
 *
 * The window is fixed — big enough for the largest panel a drag can make, and
 * centred at the top of the screen — and nothing here asks it to move. The
 * morph is CSS transitions on the outline (`clip-path`), the shadow
 * (`transform`, `opacity`) and the words (`opacity`): nothing is laid out again
 * while it moves, and no script of this app runs on any frame of it. The
 * panel's contents are laid out once, at the grown size, and revealed by the
 * outline, so text never squeezes. Timings are `TIMING`.
 *
 * ## What it tells the main process, and why
 *
 * The window lets clicks through except on the shape. A clipped element is only
 * hit inside its clip, so whether the pointer is on the shape is simply whether
 * the event landed in it (`hoot-panel:pointer`). It also says whether it must
 * stay grown — text in the box, the keyboard in it, a corner being dragged
 * (`hoot-panel:held`); how big the resting pill is, so the invisible catcher can
 * sit over it (`hoot-panel:size`); the size he let go of a corner at
 * (`hoot-panel:resize`); a press on the pill (`hoot-panel:focus`); a
 * right-click (`hoot-panel:menu`); and Escape (`hoot-panel:close`). The keyboard
 * is asked for only on a press, so a grown island never takes a keystroke meant
 * for another app.
 */

interface PanelBridge {
  hootPanelSnapshot?(): Promise<unknown>
  onHootPanelSnapshot?(cb: (snapshot: unknown) => void): () => void
  hootPanelSay?(text: string): Promise<unknown>
  hootPanelStartHoot?(): Promise<unknown>
  hootPanelShowSession?(id: string): Promise<unknown>
  hootPanelPointer?(inside: boolean): void
  hootPanelHeld?(held: boolean): void
  hootPanelFocus?(): void
  hootPanelClose?(): void
  hootPanelSize?(box: { width: number; height: number }): void
  hootPanelResize?(size: { width: number; height: number }): void
  hootPanelMenu?(): void
}

function bridge(): PanelBridge {
  return (globalThis as { deck?: PanelBridge }).deck ?? {}
}

function resultOf(raw: unknown): { ok: boolean; message: string } {
  if (typeof raw !== 'object' || raw === null) return { ok: false, message: '' }
  const r = raw as Record<string, unknown>
  return { ok: r.ok === true, message: typeof r.message === 'string' ? r.message : '' }
}

type Phase = 'open' | 'close' | 'reshape'

/** Each part's transition for a phase. Every phase names the same properties, so a change of phase never cancels one mid-way. */
function transitions(phase: Phase): Record<'shape' | 'shadow' | 'rest' | 'ears' | 'full', string> {
  if (phase === 'open') {
    const t = TIMING.open
    return {
      shape: transition('clip-path', t.shape, EASE_OPEN),
      shadow: `${transition('transform', t.shape, EASE_OPEN)}, ${transition('opacity', t.shape, EASE_OPEN)}`,
      rest: transition('opacity', t.rest, 'linear'),
      ears: transition('transform', t.shape, EASE_OPEN),
      full: transition('opacity', t.full, 'linear'),
    }
  }
  if (phase === 'close') {
    const t = TIMING.close
    return {
      shape: transition('clip-path', t.shape, EASE_CLOSE),
      shadow: `${transition('transform', t.shape, EASE_CLOSE)}, ${transition('opacity', t.shape, EASE_CLOSE)}`,
      rest: transition('opacity', t.rest, 'linear'),
      ears: transition('transform', t.shape, EASE_CLOSE),
      full: transition('opacity', t.full, 'linear'),
    }
  }
  const t = TIMING.reshape
  return {
    shape: transition('clip-path', t.shape, EASE_CLOSE),
    shadow: `${transition('transform', t.shape, EASE_CLOSE)}, ${transition('opacity', t.shape, EASE_CLOSE)}`,
    rest: transition('opacity', t.rest, 'linear'),
    ears: transition('transform', t.shape, EASE_CLOSE),
    full: transition('opacity', t.rest, 'linear'),
  }
}

/** The status words beside a session's dot, for a screen reader. */
function what(status: string): string {
  if (status === 'input') return 'needs you'
  if (status === 'working') return 'working'
  if (status === 'completed') return 'finished'
  return 'idle'
}

/** How long without a move before the next one counts as the pointer arriving afresh. */
const FRESH_MS = 120

/** A drag on one of the grown panel's bottom corners. */
interface Drag {
  side: 'left' | 'right'
  pointer: number
  x: number
  y: number
  width: number
  height: number
}

export function HootPanel() {
  const [deck] = useState(bridge)
  const [snap, setSnap] = useState<HootPanelSnapshot>(EMPTY_SNAPSHOT)
  const [draft, setDraft] = useState('')
  const [focused, setFocused] = useState(false)
  const [sending, setSending] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  // The first real snapshot, and the pill's words measured for the words it now
  // says: nothing is drawn before both, so the first frame anybody sees is the
  // right shape, not a default growing into it.
  const [ready, setReady] = useState(false)
  const [measure, setMeasure] = useState<{ text: string; width: number; left: number } | null>(null)
  const [centre, setCentre] = useState(() => window.innerWidth / 2)
  /** The size while a corner is held, and the size let go at until the main process has kept it. */
  const [dragSize, setDragSize] = useState<{ width: number; height: number } | null>(null)
  const [keptSize, setKeptSize] = useState<{ width: number; height: number } | null>(null)

  const groundEl = useRef<HTMLDivElement>(null)
  const restEl = useRef<HTMLDivElement>(null)
  const measureEl = useRef<HTMLSpanElement>(null)
  const measureLeftEl = useRef<HTMLSpanElement>(null)
  const log = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const drag = useRef<Drag | null>(null)
  const pointerAt = useRef<{ inside: boolean; at: number } | null>(null)
  const wasExpanded = useRef<boolean | null>(null)
  const lastWords = useRef<string | null>(null)

  useEffect(() => {
    document.documentElement.classList.add('hoot-panel-page')
    return () => document.documentElement.classList.remove('hoot-panel-page')
  }, [])

  // The app's theme, as the main process says it is right now — sent with every
  // snapshot, and again whenever it changes.
  useEffect(() => {
    document.documentElement.dataset.theme = snap.appearance
  }, [snap.appearance])

  // The window's middle is the island's middle. It changes only with the display.
  useEffect(() => {
    const onResize = (): void => setCentre(window.innerWidth / 2)
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [])

  useEffect(() => {
    let live = true
    const take = (raw: unknown): void => {
      if (!live) return
      setSnap(readSnapshot(raw))
      setReady(true)
    }
    const off = deck.onHootPanelSnapshot?.(take)
    void deck.hootPanelSnapshot?.().then(take).catch(() => undefined)
    return () => {
      live = false
      off?.()
    }
  }, [deck])

  /*
   * Escape settles it, wherever the keyboard is in the page — on the window, not
   * on the box, because an island grown by a click has the keyboard on its page
   * and nothing inside it focused yet.
   */
  useEffect(() => {
    const onKey = (event: globalThis.KeyboardEvent): void => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      input.current?.blur()
      deck.hootPanelClose?.()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [deck])

  // Text in the box, the keyboard in it, or a corner in his hand keeps it grown.
  const held = focused || draft.trim() !== '' || dragSize !== null
  useEffect(() => {
    deck.hootPanelHeld?.(held)
  }, [deck, held])

  // The newest message in view.
  useEffect(() => {
    const box = log.current
    if (box) box.scrollTop = box.scrollHeight
  }, [snap.messages, snap.expanded])

  /*
   * Beside a notch the counts are shared between the two ears — "4 open" by the
   * owl, "2 working · 1 waiting" on the other side — so neither ear is a long
   * empty stretch. A moment, with no counts in it, keeps to the right.
   */
  const geometry = snap.geometry
  const notch = geometry.notch
  const parts = snap.label.text.split(' · ')
  const leftWords = notch !== null && parts.length > 1 ? parts[0] : ''
  const rightWords = leftWords === '' ? snap.label.text : parts.slice(1).join(' · ')

  // How wide the pill's words are, measured in the pill's own type.
  useLayoutEffect(() => {
    const el = measureEl.current
    const beside = measureLeftEl.current
    if (!el) return
    setMeasure({
      text: snap.label.text,
      width: Math.ceil(el.getBoundingClientRect().width),
      left: leftWords !== '' && beside ? Math.ceil(beside.getBoundingClientRect().width) : 0,
    })
  }, [snap.label.text, leftWords, rightWords])

  // The size the main process has kept is the size let go at: the hand-off is over.
  useEffect(() => {
    if (keptSize !== null && snap.size !== null && snap.size.width === keptSize.width && snap.size.height === keptSize.height) {
      setKeptSize(null)
    }
  }, [snap.size, keptSize])

  const row = barRow(geometry)
  // Drawn once there is a first measurement. When the words change, the render
  // before the new ones are measured keeps the last width, so the outline moves
  // from the old width to the new one rather than jumping.
  const measured = ready && measure !== null
  const rest = restShape(geometry, {
    textWidth: measure?.width ?? 0,
    attention: snap.label.attention,
    leftWidth: measure?.left ?? 0,
  })
  const grown = expandedShape(geometry, dragSize ?? keptSize ?? snap.size)
  const target: IslandShape = snap.expanded ? grown : rest

  // Which way it is moving: growing, settling, or changing shape where it is.
  const previous = wasExpanded.current
  const phase: Phase = previous === null || previous === snap.expanded ? 'reshape' : snap.expanded ? 'open' : 'close'
  useEffect(() => {
    wasExpanded.current = snap.expanded
  }, [snap.expanded])
  const moving = transitions(phase)

  // Tell the main process how big the resting pill is, so the catcher fits it.
  useEffect(() => {
    if (measured) deck.hootPanelSize?.(restBox(rest))
  }, [deck, measured, rest.width, rest.height, rest.shoulder])

  /*
   * New words on the resting pill fade in where the pill is reshaping to say
   * them, rather than appearing whole before the outline has made room.
   */
  useLayoutEffect(() => {
    const words = snap.label.text
    const before = lastWords.current
    lastWords.current = words
    const el = restEl.current
    if (before === null || before === words || snap.expanded || !measured || el === null) return
    el.style.transition = 'none'
    el.style.opacity = '0'
    void el.offsetWidth
    el.style.transition = transitions('reshape').rest
    el.style.opacity = '1'
  }, [snap.label.text, snap.expanded, measured])

  /*
   * Where the pointer is: on the shape when the event landed inside the clipped
   * surface, which the browser only hits inside its clip. Said when it changes,
   * and on the first move after a pause — the window may have only just started
   * hearing the pointer, so "still outside" has to be said once too. Not while
   * a corner is being dragged: the pointer is his, wherever it goes.
   */
  useEffect(() => {
    const tell = (inside: boolean): void => {
      const now = performance.now()
      const last = pointerAt.current
      if (last !== null && last.inside === inside && now - last.at < FRESH_MS) {
        last.at = now
        return
      }
      pointerAt.current = { inside, at: now }
      deck.hootPanelPointer?.(inside)
    }
    const onMove = (event: MouseEvent): void => {
      if (drag.current !== null) return
      const ground = groundEl.current
      tell(ground !== null && event.target instanceof Node && ground.contains(event.target))
    }
    const onLeave = (): void => {
      if (drag.current !== null) return
      pointerAt.current = null
      deck.hootPanelPointer?.(false)
    }
    window.addEventListener('mousemove', onMove)
    document.documentElement.addEventListener('mouseleave', onLeave)
    return () => {
      window.removeEventListener('mousemove', onMove)
      document.documentElement.removeEventListener('mouseleave', onLeave)
    }
  }, [deck])

  /* -- resizing by the bottom corners -- */

  const startDrag = (side: Drag['side']) => (event: ReactPointerEvent<HTMLSpanElement>) => {
    if (event.button !== 0) return
    event.preventDefault()
    event.stopPropagation()
    event.currentTarget.setPointerCapture(event.pointerId)
    drag.current = { side, pointer: event.pointerId, x: event.screenX, y: event.screenY, width: grown.width, height: grown.height }
    setDragSize({ width: grown.width, height: grown.height })
  }

  const moveDrag = (event: ReactPointerEvent<HTMLSpanElement>): void => {
    const d = drag.current
    if (d === null || d.pointer !== event.pointerId) return
    // Centred, so a corner moved out by a point widens it by two.
    const dx = (event.screenX - d.x) * (d.side === 'right' ? 1 : -1)
    setDragSize(clampExpanded(geometry, { width: d.width + dx * 2, height: d.height + (event.screenY - d.y) }))
  }

  const endDrag = (event: ReactPointerEvent<HTMLSpanElement>): void => {
    const d = drag.current
    if (d === null || d.pointer !== event.pointerId) return
    drag.current = null
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId)
    const size = dragSize ?? { width: d.width, height: d.height }
    setKeptSize(size)
    setDragSize(null)
    deck.hootPanelResize?.(size)
    // Where the pointer is now decides whether it stays.
    const ground = groundEl.current
    const target = document.elementFromPoint(event.clientX, event.clientY)
    deck.hootPanelPointer?.(ground !== null && target !== null && ground.contains(target))
  }

  const name = snap.assistant

  const send = useCallback(async () => {
    const text = draft.trim()
    if (text === '' || sending) return
    setSending(true)
    setProblem(null)
    const result = resultOf(await deck.hootPanelSay?.(text).catch(() => null))
    setSending(false)
    if (result.ok) setDraft('')
    else setProblem(result.message || 'That message did not go through.')
  }, [deck, draft, sending])

  const onKey = (event: KeyboardEvent<HTMLInputElement>): void => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      void send()
    }
  }

  const startHoot = (): void => {
    setProblem(null)
    void deck
      .hootPanelStartHoot?.()
      .then((raw) => {
        const result = resultOf(raw)
        if (!result.ok) setProblem(result.message || `${name} could not start.`)
      })
      .catch(() => setProblem(`${name} could not start.`))
  }

  const status = snap.hoot.status
  const running = status === 'running'
  // Every open session, the ones waiting on him first, then the ones working.
  const rank = (s: string): number => (s === 'input' ? 0 : s === 'working' ? 1 : 2)
  const open = snap.sessions.filter((session) => session.status !== 'exited').sort((a, b) => rank(a.status) - rank(b.status))
  const waiting = needsYou(snap.sessions).length
  const clip = (shape: IslandShape): string | undefined => (measured ? `path('${islandPath(shape, centre)}')` : undefined)
  const scale = `scale(${(rest.width / grown.width).toFixed(4)}, ${(rest.height / grown.height).toFixed(4)})`
  // Beside a notch, the top row keeps out from under the camera: the tab to its
  // left, the sessions to its right.
  const beside: CSSProperties | undefined = notch ? { maxWidth: `calc(50% - ${notch.width / 2 + 14}px)` } : undefined

  // Always there, in the same place: the sessions, or a quiet word that there are none.
  const chips = (
    <div className="hoot-island-chips" role="list" aria-label="Open sessions">
      {open.length === 0 ? (
        <span className="hoot-island-chip" role="listitem" data-quiet="">
          No sessions running
        </span>
      ) : (
        open.map((session) => (
          <button
            key={session.id}
            type="button"
            role="listitem"
            className="hoot-island-chip"
            title={`${session.label}: ${what(session.status)}`}
            onClick={() => void deck.hootPanelShowSession?.(session.id)}
          >
            <span className="hoot-island-status" data-status={session.status} aria-hidden="true" />
            <span className="hoot-island-chip-name">{session.label}</span>
            <span className="hoot-island-visually-hidden">, {what(session.status)}</span>
          </button>
        ))
      )}
    </div>
  )

  return (
    <div
      className="hoot-island"
      data-ready={measured || undefined}
      data-expanded={snap.expanded || undefined}
      data-dragging={dragSize !== null || undefined}
    >
      {/* The soft shadow: the grown panel's shape, scaled to the shape it is now. */}
      <div
        className="hoot-island-shadow"
        style={{
          left: centre - grown.width / 2,
          width: grown.width,
          height: grown.height,
          borderBottomLeftRadius: grown.radius,
          borderBottomRightRadius: grown.radius,
          transform: snap.expanded ? 'none' : scale,
          opacity: snap.expanded ? 1 : 0,
          transition: moving.shadow,
        }}
        aria-hidden="true"
      />
      {/* A hairline one point outside the outline, so the shape keeps its edge on a bar of its own colour. */}
      <div className="hoot-island-edge" style={{ clipPath: clip(edgeShape(target)), transition: moving.shape }} aria-hidden="true" />
      <div
        ref={groundEl}
        className="hoot-island-ground"
        style={{ clipPath: clip(target), transition: moving.shape }}
        onMouseDown={() => {
          // A press on the resting pill grows it, pinned, with the keyboard.
          if (!snap.expanded) deck.hootPanelFocus?.()
        }}
        onContextMenu={(event) => {
          event.preventDefault()
          deck.hootPanelMenu?.()
        }}
      >
        {/* At rest: the owl and the counts — either side of the notch, where there is one. */}
        <div
          ref={restEl}
          className="hoot-island-rest"
          style={{ height: row, opacity: snap.expanded ? 0 : 1, transition: moving.rest }}
          aria-label={`${name}: ${snap.label.text}`}
        >
          {notch ? (
            measured ? (
              <>
                <span
                  className="hoot-island-ear"
                  data-side="left"
                  style={{ left: centre, transform: `translateX(${-rest.width / 2 + 10}px)`, transition: moving.ears }}
                >
                  <HootMark size={18} />
                  {leftWords !== '' ? <span className="hoot-island-label">{leftWords}</span> : null}
                </span>
                <span
                  className="hoot-island-ear"
                  data-side="right"
                  style={{ right: `calc(100% - ${centre}px)`, transform: `translateX(${rest.width / 2 - 12}px)`, transition: moving.ears }}
                >
                  {snap.label.attention ? <span className="hoot-island-dot" aria-hidden="true" /> : null}
                  <span className="hoot-island-label">{rightWords}</span>
                </span>
              </>
            ) : null
          ) : (
            <span className="hoot-island-pill" style={{ left: centre }}>
              <HootMark size={18} />
              {snap.label.attention ? <span className="hoot-island-dot" aria-hidden="true" /> : null}
              <span className="hoot-island-label">{rightWords}</span>
            </span>
          )}
        </div>

        {/*
          Grown: one surface — the tab and the sessions along the top, the
          conversation filling the rest. At rest it is still drawn, transparent
          and out of reach (`inert`), so the first time it grows there is
          nothing to paint for the first time in the middle of the move.
        */}
        <div
          className="hoot-island-full"
          inert={!snap.expanded}
          style={{
            left: centre - grown.width / 2,
            width: grown.width,
            height: grown.height,
            opacity: snap.expanded ? 1 : 0,
            transition: moving.full,
          }}
        >
          {/*
            The conversation: one text surface from the very top edge down to
            the box. It starts just under the pills, so nothing is hidden at
            rest, and scrolls on up behind them.
          */}
          <div className="hoot-island-chat">
            {running ? (
              <div className="hoot-island-log" ref={log} style={{ paddingTop: row + 8 }}>
                {snap.messages.length === 0 ? (
                  <p className="hoot-island-quiet">Ask {name} anything about your sessions.</p>
                ) : (
                  snap.messages.slice(-12).map((message) => (
                    <p key={message.id} className="hoot-island-msg" data-role={message.role}>
                      {message.text}
                    </p>
                  ))
                )}
              </div>
            ) : (
              <div className="hoot-island-off" style={{ paddingTop: row }}>
                {status === 'starting' ? (
                  <p className="hoot-island-quiet">{name} is starting…</p>
                ) : (
                  // Offered only when Hoot is truly not running — never over a Hoot that is.
                  <>
                    <p className="hoot-island-quiet">{snap.hoot.problem ?? `${name} isn’t running.`}</p>
                    <button type="button" className="btn-primary hoot-island-start" onClick={startHoot}>
                      Start {name}
                    </button>
                  </>
                )}
              </div>
            )}
          </div>

          {problem ? (
            <p className="hoot-island-problem" role="status">
              {problem}
            </p>
          ) : null}
          {running ? (
            <div className="hoot-island-ask">
              <input
                ref={input}
                className="hoot-island-input"
                value={draft}
                placeholder={`Ask ${name}…`}
                aria-label={`Ask ${name}`}
                disabled={sending}
                // The keyboard is asked for here, on a press in the box, and nowhere else.
                onMouseDown={() => deck.hootPanelFocus?.()}
                onFocus={() => setFocused(true)}
                onBlur={() => setFocused(false)}
                onChange={(event) => setDraft(event.target.value)}
                onKeyDown={onKey}
              />
            </div>
          ) : null}

          {/*
            The pills, floating over the text. Nothing else is up here — no
            band, no fade: between and around the pills the passing text shows.
          */}
          <header className="hoot-island-head" style={{ height: row }}>
            <span className="hoot-island-side" style={notch ? beside : undefined}>
              <span className="hoot-island-tab">
                <HootMark size={14} />
                {name}
                {waiting > 0 ? <span className="hoot-island-dot" aria-label={`${waiting} waiting on you`} /> : null}
              </span>
              {notch ? null : chips}
            </span>
            {notch ? (
              <span className="hoot-island-side" data-side="right" style={beside}>
                {chips}
              </span>
            ) : null}
          </header>

          {(['left', 'right'] as const).map((side) => (
            <span
              key={side}
              className="hoot-island-grip"
              data-side={side}
              role="separator"
              aria-label={`Resize ${name}`}
              onPointerDown={startDrag(side)}
              onPointerMove={moveDrag}
              onPointerUp={endDrag}
              onPointerCancel={endDrag}
            />
          ))}
        </div>
      </div>
      {/* The pill's words, laid out off-screen in the pill's own type, to be measured. */}
      <span ref={measureEl} className="hoot-island-label hoot-island-measure" aria-hidden="true">
        {rightWords}
      </span>
      <span ref={measureLeftEl} className="hoot-island-label hoot-island-measure" aria-hidden="true">
        {leftWords}
      </span>
    </div>
  )
}
