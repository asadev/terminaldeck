import { useCallback, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type KeyboardEvent } from 'react'
import { HootMark } from '../copilot/HootMark'
import { BRAND } from '../../shared/brand'
import { EMPTY_SNAPSHOT, needsYou, readSnapshot, restingLine, type HootPanelSnapshot } from '../../shared/hoot-panel-model'
import {
  barRow,
  expandedShape,
  grownness,
  restShape,
  SPRING_CLOSE,
  SPRING_OPEN,
  springSettled,
  springStep,
  unionBox,
  windowBox,
  type IslandShape,
  type Spring,
} from '../../shared/hoot-island'
import './hoot-panel.css'

/**
 * Hoot's island: the page inside the window `main/hoot-menubar.ts` hangs from
 * the top centre of the screen.
 *
 * One black shape, drawn here, that is a small pill at rest — around the notch
 * on a MacBook that has one — and grows into a wide, short panel when the
 * pointer rests on it, then settles back. Both are the same element animated by
 * a spring, never two surfaces, so there is no seam, gap or second material:
 * the pill *becomes* the panel. The numbers are `shared/hoot-island.ts`.
 *
 * The grown panel reads left to right: Hoot — its latest words and a box to
 * ask; the sessions that need you or are working, a press away; and Hoot's own
 * state with the quick actions. White and grey on black, the orange owl the one
 * colour, the way a notch app looks.
 *
 * ## What it tells the main process, and why
 *
 * The main process decides when it grows and settles, and places the window;
 * only the page knows four things it needs for that: whether the pointer is over
 * the shape (`hoot-panel:pointer`), whether the box is holding it open with text
 * or the keyboard (`hoot-panel:held`), the window size the shape needs this
 * instant (`hoot-panel:size`), and a press on it (`hoot-panel:focus`). A
 * right-click asks for the background menu (`hoot-panel:menu`); Escape settles
 * it (`hoot-panel:close`). The keyboard is asked for only on a press, so a grown
 * island never takes a keystroke meant for another app.
 *
 * ## The morph
 *
 * Width, height, the bottom corners' radius and the shoulders each follow a
 * spring on animation frames — quick with a little give when it grows, quick
 * without overshoot when it settles. Before growing it asks for the bigger
 * window and waits until it has it, so the shape is never clipped; after
 * settling it gives the room back. Under reduced motion it simply changes.
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

/** 0 below `from`, 1 above `to`, a smooth ramp between. */
function ramp(value: number, from: number, to: number): number {
  const t = Math.min(1, Math.max(0, (value - from) / (to - from)))
  return t * t * (3 - 2 * t)
}

interface Motion {
  w: Spring
  h: Spring
  r: Spring
  s: Spring
  frame: number | null
  last: number
  started: boolean
}

const still = (value: number): Spring => ({ value, velocity: 0 })

/** The status words beside a session, in the grown panel's list. */
function what(status: string): string {
  if (status === 'input') return 'needs you'
  if (status === 'working') return 'working'
  if (status === 'completed') return 'finished'
  return 'idle'
}

export function HootPanel() {
  const [deck] = useState(bridge)
  const [snap, setSnap] = useState<HootPanelSnapshot>(EMPTY_SNAPSHOT)
  const [draft, setDraft] = useState('')
  const [focused, setFocused] = useState(false)
  const [sending, setSending] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const [confirmStop, setConfirmStop] = useState(false)
  // The first real snapshot, and the pill's words measured for the words it now
  // says: nothing is drawn or sized before both, so the first frame anybody
  // sees is the right shape, not a default growing into it.
  const [ready, setReady] = useState(false)
  const [measure, setMeasure] = useState<{ text: string; width: number } | null>(null)
  const [fullHeight, setFullHeight] = useState(140)

  const shapeEl = useRef<HTMLDivElement>(null)
  const bodyEl = useRef<HTMLDivElement>(null)
  const leftShoulder = useRef<HTMLSpanElement>(null)
  const rightShoulder = useRef<HTMLSpanElement>(null)
  const restEl = useRef<HTMLDivElement>(null)
  const fullEl = useRef<HTMLDivElement>(null)
  const measureEl = useRef<HTMLSpanElement>(null)
  const log = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const motion = useRef<Motion | null>(null)

  useEffect(() => {
    const root = document.documentElement
    root.classList.add('hoot-panel-page')
    // The island is black on every screen, so its words always take the dark theme's ink.
    root.dataset.theme = 'dark'
    return () => root.classList.remove('hoot-panel-page')
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

  // How wide the pill's words are, measured in the pill's own type.
  useLayoutEffect(() => {
    const el = measureEl.current
    if (el) setMeasure({ text: snap.label.text, width: Math.ceil(el.getBoundingClientRect().width) })
  }, [snap.label.text])

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
  const rest = restShape(geometry, { textWidth: measure?.width ?? 0, attention: snap.label.attention })
  const grown = expandedShape(geometry, fullHeight - row, rest)
  const target: IslandShape = snap.expanded ? grown : rest
  const notch = geometry.notch

  /** Draw one state of the shape. */
  const paint = useCallback(
    (w: number, h: number, r: number, s: number): void => {
      const shape = shapeEl.current
      const body = bodyEl.current
      if (!shape || !body) return
      const radius = Math.max(0, Math.min(r, h / 2, w / 2))
      const shoulder = Math.max(0, s)
      shape.style.width = `${w + shoulder * 2}px`
      shape.style.height = `${h}px`
      body.style.left = `${shoulder}px`
      body.style.width = `${w}px`
      body.style.height = `${h}px`
      body.style.borderRadius = `0 0 ${radius}px ${radius}px`
      for (const el of [leftShoulder.current, rightShoulder.current]) {
        if (!el) continue
        el.style.width = `${shoulder}px`
        el.style.height = `${shoulder}px`
      }
      const p = grownness(h, rest.height, grown.height)
      shape.style.filter = p > 0.01 ? `drop-shadow(0 10px 22px rgba(0, 0, 0, ${(0.5 * p).toFixed(3)}))` : 'none'
      if (restEl.current) restEl.current.style.opacity = String(1 - ramp(p, 0, 0.35))
      if (fullEl.current) {
        const shownFull = ramp(p, 0.45, 1)
        fullEl.current.style.opacity = String(shownFull)
        fullEl.current.style.visibility = shownFull > 0.01 ? 'visible' : 'hidden'
      }
    },
    [rest.height, grown.height],
  )

  /*
   * Move the shape to the target: ask for room, wait for it, spring there, give
   * the room back. The first draw jumps — there is nothing to grow from.
   */
  useLayoutEffect(() => {
    // The words are measured in a layout effect of their own, which re-renders
    // before anything is painted; until then there is nothing true to draw.
    if (!measured) return
    const finalBox = windowBox(target, snap.expanded)
    const m = motion.current
    if (m === null) {
      motion.current = {
        w: still(target.width),
        h: still(target.height),
        r: still(target.radius),
        s: still(target.shoulder),
        frame: null,
        last: 0,
        started: true,
      }
      paint(target.width, target.height, target.radius, target.shoulder)
      deck.hootPanelSize?.(finalBox)
      return
    }
    if (m.frame !== null) cancelAnimationFrame(m.frame)
    m.frame = null
    const fromShadow = m.h.value > rest.height + 1
    const current: IslandShape = { width: m.w.value, height: m.h.value, radius: m.r.value, shoulder: m.s.value }
    const room = unionBox(windowBox(current, fromShadow || snap.expanded), windowBox(target, fromShadow || snap.expanded))
    deck.hootPanelSize?.(room)
    const config = target.height >= m.h.value ? SPRING_OPEN : SPRING_CLOSE

    const finish = (): void => {
      m.w = still(target.width)
      m.h = still(target.height)
      m.r = still(target.radius)
      m.s = still(target.shoulder)
      m.frame = null
      paint(target.width, target.height, target.radius, target.shoulder)
      deck.hootPanelSize?.(finalBox)
    }

    const step = (time: number): void => {
      const seconds = m.last === 0 ? 1 / 60 : (time - m.last) / 1000
      m.last = time
      m.w = springStep(m.w, target.width, seconds, config)
      m.h = springStep(m.h, target.height, seconds, config)
      m.r = springStep(m.r, target.radius, seconds, config)
      m.s = springStep(m.s, target.shoulder, seconds, config)
      if (
        springSettled(m.w, target.width) &&
        springSettled(m.h, target.height) &&
        springSettled(m.r, target.radius) &&
        springSettled(m.s, target.shoulder)
      ) {
        finish()
        return
      }
      paint(m.w.value, m.h.value, m.r.value, m.s.value)
      m.frame = requestAnimationFrame(step)
    }

    const begin = (): void => {
      if (reducedMotion()) {
        finish()
        return
      }
      m.last = 0
      m.frame = requestAnimationFrame(step)
    }

    // Wait for the window to have room — it is resized by the main process a
    // moment after the ask — or give up waiting after a few frames.
    const fits = (): boolean => window.innerWidth >= room.width - 1 && window.innerHeight >= room.height - 1
    if (fits()) {
      begin()
      return
    }
    let done = false
    const go = (): void => {
      if (done) return
      done = true
      window.removeEventListener('resize', check)
      window.clearTimeout(timer)
      begin()
    }
    const check = (): void => {
      if (fits()) go()
    }
    window.addEventListener('resize', check)
    const timer = window.setTimeout(go, 80)
    return () => {
      done = true
      window.removeEventListener('resize', check)
      window.clearTimeout(timer)
      if (m.frame !== null) cancelAnimationFrame(m.frame)
      m.frame = null
    }
    // The target's numbers are what matter, not the object's identity.
  }, [target.width, target.height, target.radius, target.shoulder, snap.expanded, paint, deck, measured])

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
  const listed = [...waiting, ...working].slice(0, 3)
  const ears: CSSProperties | undefined = notch ? { width: `calc(50% - ${notch.width / 2}px)` } : undefined
  // Beside a notch, the header's two halves stay out from under the camera.
  const half: CSSProperties | undefined = notch ? { maxWidth: `calc(50% - ${notch.width / 2 + 12}px)` } : undefined

  const pillWords = (
    <>
      {snap.label.attention ? <span className="hoot-island-dot" aria-hidden="true" /> : null}
      <span className="hoot-island-label">{snap.label.text}</span>
    </>
  )

  return (
    <div className="hoot-island">
      <div
        ref={shapeEl}
        className="hoot-island-shape"
        data-expanded={snap.expanded || undefined}
        onPointerEnter={() => deck.hootPanelPointer?.(true)}
        onPointerLeave={() => deck.hootPanelPointer?.(false)}
        onMouseDown={() => {
          // A press on the resting pill grows it, pinned, with the keyboard.
          if (!snap.expanded) deck.hootPanelFocus?.()
        }}
        onContextMenu={(event) => {
          event.preventDefault()
          deck.hootPanelMenu?.()
        }}
      >
        <span ref={leftShoulder} className="hoot-island-shoulder" data-side="left" aria-hidden="true" />
        <span ref={rightShoulder} className="hoot-island-shoulder" data-side="right" aria-hidden="true" />
        <div ref={bodyEl} className="hoot-island-body">
          {/* At rest: the owl and the short line — either side of the notch, where there is one. */}
          <div ref={restEl} className="hoot-island-rest" style={{ height: row }} aria-label={`${name}: ${snap.label.text}`}>
            {notch ? (
              <>
                <span className="hoot-island-ear" data-side="left" style={ears}>
                  <HootMark size={18} />
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
              <span className="hoot-island-half" data-side="right" style={half}>
                <button
                  type="button"
                  className="hoot-island-icon"
                  aria-label={`${name} Settings`}
                  title={`${name} Settings`}
                  onClick={() => void deck.hootPanelOpenApp?.('hoot-settings')}
                >
                  <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
                    <circle cx="8" cy="8" r="2.2" fill="none" stroke="currentColor" strokeWidth="1.4" />
                    <path
                      d="M8 1.6v1.8M8 12.6v1.8M1.6 8h1.8M12.6 8h1.8M3.5 3.5l1.3 1.3M11.2 11.2l1.3 1.3M3.5 12.5l1.3-1.3M11.2 4.8l1.3-1.3"
                      stroke="currentColor"
                      strokeWidth="1.4"
                      strokeLinecap="round"
                    />
                  </svg>
                </button>
              </span>
            </header>

            <div className="hoot-island-sections">
              <section className="hoot-island-section" data-part="hoot" aria-label={name}>
                {running ? (
                  <>
                    <div className="hoot-island-log" ref={log}>
                      {snap.messages.length === 0 ? (
                        <p className="hoot-island-quiet">Ask {name} anything about your sessions.</p>
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
                ) : (
                  <div className="hoot-island-off">
                    <p className="hoot-island-quiet">
                      {status === 'starting' ? `${name} is starting…` : snap.hoot.problem ?? `${name} isn’t running.`}
                    </p>
                    {status === 'stopped' ? (
                      <button type="button" className="btn-primary hoot-island-start" onClick={startHoot}>
                        Start {name}
                      </button>
                    ) : null}
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
                  <p className="hoot-island-quiet">Nothing needs you.</p>
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

              <section className="hoot-island-section" data-part="actions" aria-label="Quick actions">
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
        {snap.label.text}
      </span>
    </div>
  )
}
