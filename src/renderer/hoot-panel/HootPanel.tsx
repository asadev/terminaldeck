import { useCallback, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type KeyboardEvent } from 'react'
import { HootMark } from '../copilot/HootMark'
import { BRAND } from '../../shared/brand'
import { EMPTY_SNAPSHOT, needsYou, readSnapshot, restingLine, type HootPanelSnapshot } from '../../shared/hoot-panel-model'
import {
  barRow,
  easeInOut,
  easeOut,
  expandedShape,
  grownness,
  islandPath,
  mixShape,
  onShape,
  restBox,
  restShape,
  TIMING,
  within,
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
 * (`islandPath`), so the pill *becomes* the panel: no seam, no gap, no second
 * surface. The numbers are `shared/hoot-island.ts`.
 *
 * At rest it says the state of things at a glance — "4 open · 2 working · 1
 * waiting" — and the grown panel reads left to right: Hoot, its latest words
 * and a box to ask; the sessions that need you or are working, a press away;
 * Hoot's own state and the quick actions. It wears the app's theme, light or
 * dark, with the app's own surface colours.
 *
 * ## The window never changes; the shape does
 *
 * The window is fixed — as big as the grown panel and its shadow, centred at
 * the top of the screen — and nothing here asks it to move or resize. The first
 * version did, and his recording caught the pill drawn 315 points off centre
 * for a frame while the window server caught up. Now every frame is the same
 * window with a different outline clipped out of it, centred on the window's
 * middle, which never moves.
 *
 * ## What it tells the main process, and why
 *
 * The window lets clicks through except on the shape, and only the page knows
 * where the shape is drawn this instant: it hit-tests the pointer against the
 * outline and says when the pointer arrives on it or leaves it
 * (`hoot-panel:pointer`). It also says whether the box is holding it open
 * (`hoot-panel:held`), how big the resting pill is so the invisible catcher can
 * sit over it (`hoot-panel:size`), a press on the pill (`hoot-panel:focus`), a
 * right-click (`hoot-panel:menu`), and Escape (`hoot-panel:close`). The keyboard
 * is asked for only on a press, so a grown island never takes a keystroke meant
 * for another app.
 *
 * ## The morph
 *
 * Growing takes 380 ms on a gentle ease-out, and the panel's words fade in only
 * once the shape is most of the way there, so text never squeezes; settling
 * takes 450 ms — the words fade first, then the shape eases in, then the pill's
 * words return (`TIMING`). A change of the pill's words reshapes it in 320 ms.
 * Each frame only redraws the outline and a few opacities. Under reduced
 * motion it simply changes.
 */

interface PanelBridge {
  hootPanelSnapshot?(): Promise<unknown>
  onHootPanelSnapshot?(cb: (snapshot: unknown) => void): () => void
  hootPanelSay?(text: string): Promise<unknown>
  hootPanelStartHoot?(): Promise<unknown>
  hootPanelStopHoot?(): Promise<unknown>
  hootPanelShowSession?(id: string): Promise<unknown>
  hootPanelOpenApp?(page?: 'hoot-settings'): Promise<unknown>
  hootPanelPointer?(inside: boolean): void
  hootPanelHeld?(held: boolean): void
  hootPanelFocus?(): void
  hootPanelClose?(): void
  hootPanelSize?(box: { width: number; height: number }): void
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

const reducedMotion = (): boolean => {
  try {
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches
  } catch {
    return false
  }
}

/** One morph in flight: where it started, where it is going, and how. */
interface Morph {
  kind: 'open' | 'close' | 'reshape'
  from: IslandShape
  to: IslandShape
  /** The panel's words and the pill's words, as they were when it started. */
  fullFrom: number
  restFrom: number
  /** A reshape that changed the pill's words fades the new ones in. */
  newWords: boolean
  started: number | null
}

/** Where everything is drawn right now. */
interface Drawn {
  shape: IslandShape
  full: number
  rest: number
}

/** A morph's state `at` ms in, and whether it is over. */
function morphAt(m: Morph, at: number): Drawn & { done: boolean } {
  if (m.kind === 'open') {
    const [, end] = TIMING.open.shape
    return {
      shape: mixShape(m.from, m.to, easeOut(within(at, TIMING.open.shape))),
      full: m.fullFrom + (1 - m.fullFrom) * within(at, TIMING.open.full),
      rest: m.restFrom * (1 - within(at, TIMING.open.rest)),
      done: at >= end,
    }
  }
  if (m.kind === 'close') {
    // The words fade first — for as long as they have left to fade — then the
    // shape eases in, then the pill's own words come back.
    const fade = TIMING.close.full[1] * m.fullFrom
    const shrink = TIMING.close.shape[1] - TIMING.close.shape[0]
    const end = fade + shrink
    const restSpan = TIMING.close.rest[1] - TIMING.close.rest[0]
    return {
      shape: mixShape(m.from, m.to, easeInOut(within(at, [fade, end]))),
      full: m.fullFrom * (1 - within(at, [0, Math.max(1, fade)])),
      rest: m.restFrom + (1 - m.restFrom) * within(at, [end - restSpan, end]),
      done: at >= end,
    }
  }
  const [, end] = TIMING.reshape.shape
  return {
    shape: mixShape(m.from, m.to, easeInOut(within(at, TIMING.reshape.shape))),
    full: m.fullFrom,
    rest: m.newWords ? within(at, TIMING.reshape.rest) : m.restFrom,
    done: at >= Math.max(end, m.newWords ? TIMING.reshape.rest[1] : 0),
  }
}

/** The status words beside a session, in the grown panel's list. */
function what(status: string): string {
  if (status === 'input') return 'needs you'
  if (status === 'working') return 'working'
  if (status === 'completed') return 'finished'
  return 'idle'
}

/** How long without a move before the next one counts as the pointer arriving afresh. */
const FRESH_MS = 120

export function HootPanel() {
  const [deck] = useState(bridge)
  const [snap, setSnap] = useState<HootPanelSnapshot>(EMPTY_SNAPSHOT)
  const [draft, setDraft] = useState('')
  const [focused, setFocused] = useState(false)
  const [sending, setSending] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const [confirmStop, setConfirmStop] = useState(false)
  // The first real snapshot, and the pill's words measured for the words it now
  // says: nothing is drawn before both, so the first frame anybody sees is the
  // right shape, not a default growing into it.
  const [ready, setReady] = useState(false)
  const [measure, setMeasure] = useState<{ text: string; width: number; left: number } | null>(null)
  const [fullHeight, setFullHeight] = useState(140)

  const shadowEl = useRef<HTMLDivElement>(null)
  const groundEl = useRef<HTMLDivElement>(null)
  const restEl = useRef<HTMLDivElement>(null)
  const fullEl = useRef<HTMLDivElement>(null)
  const measureEl = useRef<HTMLSpanElement>(null)
  const measureLeftEl = useRef<HTMLSpanElement>(null)
  const log = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const drawn = useRef<Drawn | null>(null)
  const morph = useRef<Morph | null>(null)
  const frame = useRef<number | null>(null)
  const lastWords = useRef<string | null>(null)
  const pointerAt = useRef<{ inside: boolean; at: number } | null>(null)

  useEffect(() => {
    document.documentElement.classList.add('hoot-panel-page')
    return () => document.documentElement.classList.remove('hoot-panel-page')
  }, [])

  // The app's theme, as the main process says it is right now — sent with every
  // snapshot, and again whenever it changes.
  useEffect(() => {
    document.documentElement.dataset.theme = snap.appearance
  }, [snap.appearance])

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

  // Text in the box, or the keyboard in it, keeps it grown.
  const held = focused || draft.trim() !== ''
  useEffect(() => {
    deck.hootPanelHeld?.(held)
  }, [deck, held])

  // "Stop" asks twice, and forgets the first press after a few seconds.
  useEffect(() => {
    if (!confirmStop) return
    const timer = window.setTimeout(() => setConfirmStop(false), 3500)
    return () => window.clearTimeout(timer)
  }, [confirmStop])

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
  const notch = snap.geometry.notch
  const parts = snap.label.text.split(' · ')
  const leftWords = notch !== null && parts.length > 1 ? parts[0] : ''
  const rightWords = leftWords === '' ? snap.label.text : parts.slice(1).join(' · ')

  // How wide the pill's words are, measured in the pill's own type.
  useLayoutEffect(() => {
    const el = measureEl.current
    const beside = measureLeftEl.current
    if (el) {
      setMeasure({
        text: snap.label.text,
        width: Math.ceil(el.getBoundingClientRect().width),
        left: leftWords !== '' && beside ? Math.ceil(beside.getBoundingClientRect().width) : 0,
      })
    }
  }, [snap.label.text, leftWords, rightWords])

  // How tall the grown panel's content is, laid out at its grown width.
  useLayoutEffect(() => {
    const el = fullEl.current
    if (!el) return
    const report = (): void => setFullHeight(Math.ceil(el.scrollHeight))
    report()
    const observer = new ResizeObserver(report)
    observer.observe(el)
    return () => observer.disconnect()
  }, [])

  const geometry = snap.geometry
  const row = barRow(geometry)
  const measured = ready && measure !== null && measure.text === snap.label.text
  const rest = restShape(geometry, {
    textWidth: measure?.width ?? 0,
    attention: snap.label.attention,
    leftWidth: measure?.left ?? 0,
  })
  const grown = expandedShape(geometry, fullHeight - row)
  const target: IslandShape = snap.expanded ? grown : rest

  /** The middle of the window, which is the middle of the island, always. */
  const centre = (): number => window.innerWidth / 2

  /** Draw one state: the outline, its shadow, and the two sets of words. */
  const paint = useCallback(
    (state: Drawn): void => {
      drawn.current = state
      const ground = groundEl.current
      const shadow = shadowEl.current
      if (!ground || !shadow) return
      const c = centre()
      ground.style.clipPath = `path('${islandPath(state.shape, c)}')`
      const p = grownness(state.shape.height, rest.height, grown.height)
      shadow.style.setProperty('--island-lift', p.toFixed(3))
      const restRow = restEl.current
      if (restRow) {
        restRow.style.opacity = state.rest.toFixed(3)
        restRow.style.width = `${Math.round(state.shape.width)}px`
        restRow.style.left = `${Math.round(c - state.shape.width / 2)}px`
      }
      const full = fullEl.current
      if (full) {
        full.style.opacity = state.full.toFixed(3)
        full.style.visibility = state.full > 0.01 ? 'visible' : 'hidden'
      }
    },
    [rest.height, grown.height],
  )

  // Tell the main process how big the resting pill is, so the catcher fits it.
  useEffect(() => {
    if (measured) deck.hootPanelSize?.(restBox(rest))
  }, [deck, measured, rest.width, rest.height, rest.shoulder])

  /*
   * Start a morph to the target whenever it changes, from wherever the shape is
   * this instant — a hover that leaves halfway through growing settles back from
   * halfway, not from the end.
   */
  useLayoutEffect(() => {
    if (!measured) return
    const words = snap.label.text
    const wordsChanged = lastWords.current !== null && lastWords.current !== words
    lastWords.current = words
    const now = drawn.current
    const final: Drawn = { shape: target, full: snap.expanded ? 1 : 0, rest: snap.expanded ? 0 : 1 }
    if (now === null || reducedMotion()) {
      if (frame.current !== null) cancelAnimationFrame(frame.current)
      frame.current = null
      morph.current = null
      paint(final)
      return
    }
    const same =
      Math.abs(now.shape.width - target.width) < 0.5 &&
      Math.abs(now.shape.height - target.height) < 0.5 &&
      Math.abs(now.full - final.full) < 0.01 &&
      Math.abs(now.rest - final.rest) < 0.01 &&
      !wordsChanged
    if (same) return
    const wasGrowing = now.full > 0.5 || now.shape.height > rest.height + 1
    const kind: Morph['kind'] = snap.expanded ? (wasGrowing && now.full >= 0.99 ? 'reshape' : 'open') : wasGrowing ? 'close' : 'reshape'
    morph.current = {
      kind,
      from: now.shape,
      to: target,
      fullFrom: now.full,
      restFrom: kind === 'reshape' && !snap.expanded && wordsChanged ? 0 : now.rest,
      newWords: kind === 'reshape' && !snap.expanded && wordsChanged,
      started: null,
    }
    const step = (time: number): void => {
      const m = morph.current
      if (m === null) return
      if (m.started === null) m.started = time
      const state = morphAt(m, time - m.started)
      paint(state)
      if (state.done) {
        morph.current = null
        frame.current = null
        return
      }
      frame.current = requestAnimationFrame(step)
    }
    if (frame.current !== null) cancelAnimationFrame(frame.current)
    frame.current = requestAnimationFrame(step)
    // The target's numbers are what matter, not the object's identity.
  }, [target.width, target.height, target.radius, target.shoulder, snap.expanded, snap.label.text, measured, paint])

  useEffect(
    () => () => {
      if (frame.current !== null) cancelAnimationFrame(frame.current)
    },
    [],
  )

  /*
   * Where the pointer is, against the outline as drawn right now. Said when it
   * changes, and on the first move after a pause — the window may have only just
   * started hearing the pointer, so "still outside" has to be said once too.
   */
  useEffect(() => {
    const tell = (inside: boolean): void => {
      const now = performance.now()
      const last = pointerAt.current
      if (last !== null && last.inside === inside && now - last.at < FRESH_MS) {
        last.at = now
        return
      }
      const changed = last === null || last.inside !== inside || now - last.at >= FRESH_MS
      pointerAt.current = { inside, at: now }
      if (changed) deck.hootPanelPointer?.(inside)
    }
    const onMove = (event: MouseEvent): void => {
      const state = drawn.current
      if (state === null) return
      tell(onShape(state.shape, centre(), { x: event.clientX, y: event.clientY }))
    }
    const onLeave = (): void => {
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

  const stopHoot = (): void => {
    if (!confirmStop) {
      setConfirmStop(true)
      return
    }
    setConfirmStop(false)
    setProblem(null)
    void deck
      .hootPanelStopHoot?.()
      .then((raw) => {
        const result = resultOf(raw)
        if (!result.ok) setProblem(result.message || `${name} could not be stopped.`)
      })
      .catch(() => setProblem(`${name} could not be stopped.`))
  }

  const status = snap.hoot.status
  const running = status === 'running'
  const line = restingLine(snap.sessions)
  const waiting = needsYou(snap.sessions)
  const working = snap.sessions.filter((session) => session.status === 'working')
  const open = snap.sessions.filter((session) => session.status !== 'exited').length
  const listed = [...waiting, ...working].slice(0, 3)
  const ears: CSSProperties | undefined = notch ? { width: `calc(50% - ${notch.width / 2}px)` } : undefined
  // Beside a notch, the header's left half stays out from under the camera.
  const half: CSSProperties | undefined = notch ? { maxWidth: `calc(50% - ${notch.width / 2 + 12}px)` } : undefined

  const pillWords = (
    <>
      {snap.label.attention ? <span className="hoot-island-dot" aria-hidden="true" /> : null}
      <span className="hoot-island-label">{rightWords}</span>
    </>
  )

  return (
    <div className="hoot-island" data-ready={measured || undefined}>
      <div ref={shadowEl} className="hoot-island-shadow">
        <div
          ref={groundEl}
          className="hoot-island-ground"
          onMouseDown={() => {
            // A press on the resting pill grows it, pinned, with the keyboard.
            if (!snap.expanded) deck.hootPanelFocus?.()
          }}
          onContextMenu={(event) => {
            event.preventDefault()
            deck.hootPanelMenu?.()
          }}
        >
          {/* At rest: the owl and the state of things — either side of the notch, where there is one. */}
          <div ref={restEl} className="hoot-island-rest" style={{ height: row }} aria-label={`${name}: ${snap.label.text}`}>
            {notch ? (
              <>
                <span className="hoot-island-ear" data-side="left" style={ears}>
                  <HootMark size={18} />
                  {leftWords !== '' ? <span className="hoot-island-label">{leftWords}</span> : null}
                </span>
                <span className="hoot-island-ear" data-side="right" style={ears}>
                  {pillWords}
                </span>
              </>
            ) : (
              <span className="hoot-island-pill">
                <HootMark size={18} />
                {pillWords}
              </span>
            )}
          </div>

          {/* Grown: the same shape, wide and short, read left to right. */}
          <div ref={fullEl} className="hoot-island-full" style={{ width: grown.width }}>
            <header className="hoot-island-head" style={{ height: row }}>
              <span className="hoot-island-half" style={half}>
                <span className="hoot-island-tab">
                  <HootMark size={14} />
                  {name}
                </span>
                {line ? (
                  <span className="hoot-island-line" data-attention={line.attention || undefined}>
                    {line.attention ? <span className="hoot-island-dot" aria-hidden="true" /> : null}
                    <span className="hoot-island-line-text">{line.text}</span>
                  </span>
                ) : null}
              </span>
            </header>

            <div className="hoot-island-sections">
              <section className="hoot-island-section" data-part="hoot" aria-label={name}>
                {running ? (
                  <>
                    <div className="hoot-island-log" ref={log}>
                      {snap.messages.length === 0 ? (
                        <p className="hoot-island-quiet">
                          {name} is running, keeping an eye on {open === 1 ? '1 session' : `${open} sessions`}. Ask it
                          anything about them.
                        </p>
                      ) : (
                        snap.messages.slice(-6).map((message) => (
                          <p key={message.id} className="hoot-island-msg" data-role={message.role}>
                            {message.text}
                          </p>
                        ))
                      )}
                    </div>
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
                  </>
                ) : status === 'starting' ? (
                  <p className="hoot-island-quiet">{name} is starting…</p>
                ) : (
                  // Offered only when Hoot is truly not running — never over a Hoot that is.
                  <div className="hoot-island-off">
                    <p className="hoot-island-quiet">{snap.hoot.problem ?? `${name} isn’t running.`}</p>
                    <button type="button" className="btn-primary hoot-island-start" onClick={startHoot}>
                      Start {name}
                    </button>
                  </div>
                )}
                {problem ? (
                  <p className="hoot-island-problem" role="status">
                    {problem}
                  </p>
                ) : null}
              </section>

              <section className="hoot-island-section" data-part="sessions" aria-label="Sessions">
                <p className="hoot-island-kicker">{waiting.length > 0 ? 'Waiting on you' : 'Sessions'}</p>
                {listed.length === 0 ? (
                  <p className="hoot-island-quiet">{open === 0 ? 'No sessions open.' : 'Nothing needs you.'}</p>
                ) : (
                  <ul className="hoot-island-list">
                    {listed.map((session) => (
                      <li key={session.id}>
                        <button
                          type="button"
                          className="hoot-island-session"
                          onClick={() => void deck.hootPanelShowSession?.(session.id)}
                        >
                          <span className="hoot-island-status" data-status={session.status} aria-hidden="true" />
                          <span className="hoot-island-session-name">{session.label}</span>
                          <span className="hoot-island-session-what">{what(session.status)}</span>
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
              </section>

              <section className="hoot-island-section" data-part="actions" aria-label={`${name} and quick actions`}>
                <p className="hoot-island-kicker">
                  <span className="hoot-island-status" data-status={running ? 'working' : 'idle'} aria-hidden="true" />
                  {running ? `${name} is on` : status === 'starting' ? 'Starting…' : `${name} is off`}
                </p>
                <button type="button" className="hoot-island-action" onClick={() => void deck.hootPanelOpenApp?.()}>
                  Open {BRAND.name}
                </button>
                {running ? (
                  <button type="button" className="hoot-island-action" data-confirm={confirmStop || undefined} onClick={stopHoot}>
                    {confirmStop ? `Stop ${name}? Press again` : `Stop ${name}`}
                  </button>
                ) : null}
              </section>
            </div>
          </div>
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
