import { useCallback, useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent } from 'react'
import { HootMark } from '../copilot/HootMark'
import { EMPTY_SNAPSHOT, needsYou, readSnapshot, restingLine, type HootPanelSnapshot } from '../../shared/hoot-panel-model'
import './hoot-panel.css'

/**
 * The panel that drops down from Hoot's owl in the menu bar —
 * `main/hoot-menubar.ts` owns the window, this is the page inside it.
 *
 * What a glance needs and nothing more: who is working and who is waiting on
 * you, Hoot's last few words, and a box to ask. The window itself is the
 * system's popover glass (`vibrancy: 'popover'`), so this page paints no ground
 * of its own.
 *
 * ## What it tells the main process, and why
 *
 * The main process decides when the panel opens and closes (the owl's hover and
 * click), but only the page knows three things it needs for that: whether the
 * pointer is over the panel (`hoot-panel:pointer`), whether the box is holding
 * it open with text or the keyboard (`hoot-panel:held`), and how tall the
 * content is (`hoot-panel:size`). Escape closes it (`hoot-panel:close`). The
 * keyboard is asked for only on a press in the box (`hoot-panel:focus`), so an
 * open panel never takes a keystroke the person meant for another app.
 */

interface PanelBridge {
  hootPanelSnapshot?(): Promise<unknown>
  onHootPanelSnapshot?(cb: (snapshot: unknown) => void): () => void
  onHootPanelShown?(cb: () => void): () => void
  hootPanelSay?(text: string): Promise<unknown>
  hootPanelStartHoot?(): Promise<unknown>
  hootPanelShowSession?(id: string): Promise<unknown>
  hootPanelPointer?(inside: boolean): void
  hootPanelHeld?(held: boolean): void
  hootPanelFocus?(): void
  hootPanelClose?(): void
  hootPanelSize?(height: number): void
}

function bridge(): PanelBridge {
  return (globalThis as { deck?: PanelBridge }).deck ?? {}
}

function resultOf(raw: unknown): { ok: boolean; message: string } {
  if (typeof raw !== 'object' || raw === null) return { ok: false, message: '' }
  const r = raw as Record<string, unknown>
  return { ok: r.ok === true, message: typeof r.message === 'string' ? r.message : '' }
}

/**
 * Follow the glass, not the settings file.
 *
 * The panel's window is the system's popover material, which takes its light or
 * dark from `nativeTheme` — and the main process sets that from the app's own
 * theme preference. So the words are drawn in whatever the main process says
 * the glass is (`appearance` on the snapshot), which it re-sends every time the
 * panel opens. Until the first snapshot, the page's colour scheme stands in.
 *
 * Following the stored setting was measured to fail twice in a real window: a
 * switch to light made in the main window turned the glass light under white
 * text, and a hidden panel did not hear the colour scheme change back.
 */
function useGlassTheme(appearance: 'light' | 'dark' | null): void {
  useEffect(() => {
    if (appearance !== null) {
      document.documentElement.dataset.theme = appearance
      return
    }
    const query = window.matchMedia('(prefers-color-scheme: dark)')
    document.documentElement.dataset.theme = query.matches ? 'dark' : 'light'
  }, [appearance])
}

export function HootPanel() {
  const [deck] = useState(bridge)
  const [snap, setSnap] = useState<HootPanelSnapshot>(EMPTY_SNAPSHOT)
  useGlassTheme(snap.appearance)
  const [draft, setDraft] = useState('')
  const [focused, setFocused] = useState(false)
  const [sending, setSending] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const [arrival, setArrival] = useState(0)
  const root = useRef<HTMLDivElement>(null)
  const log = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLInputElement>(null)

  useEffect(() => {
    document.documentElement.classList.add('hoot-panel-page')
    return () => document.documentElement.classList.remove('hoot-panel-page')
  }, [])

  useEffect(() => {
    let live = true
    const take = (raw: unknown): void => {
      if (live) setSnap(readSnapshot(raw))
    }
    const off = deck.onHootPanelSnapshot?.(take)
    // Each time it opens: the arrival animation again, from the top.
    const offShown = deck.onHootPanelShown?.(() => setArrival((n) => n + 1))
    void deck.hootPanelSnapshot?.().then(take).catch(() => undefined)
    return () => {
      live = false
      off?.()
      offShown?.()
    }
  }, [deck])

  /*
   * Escape closes it, wherever the keyboard is in the page — on the window, not
   * on the panel's own box, because a panel opened from the owl has the
   * keyboard on its page and nothing inside it focused yet. Measured in a real
   * window: with the listener on the box, Escape on a freshly opened panel did
   * nothing at all.
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

  // Text in the box, or the keyboard in it, keeps the panel open.
  const held = focused || draft.trim() !== ''
  useEffect(() => {
    deck.hootPanelHeld?.(held)
  }, [deck, held])

  // The newest message in view.
  useEffect(() => {
    const box = log.current
    if (box) box.scrollTop = box.scrollHeight
  }, [snap.messages, arrival])

  // How tall the content is, so the window fits it.
  useLayoutEffect(() => {
    const el = root.current
    if (!el) return
    const report = (): void => deck.hootPanelSize?.(Math.ceil(el.getBoundingClientRect().height))
    report()
    const observer = new ResizeObserver(report)
    observer.observe(el)
    return () => observer.disconnect()
  }, [deck])

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

  const name = snap.assistant
  const running = snap.hoot.status === 'running'
  const line = restingLine(snap.sessions)
  const waiting = needsYou(snap.sessions)

  return (
    <div
      ref={root}
      className="hoot-panel"
      onPointerEnter={() => deck.hootPanelPointer?.(true)}
      onPointerLeave={() => deck.hootPanelPointer?.(false)}
    >
      {/* Keyed on each opening, so the arrival plays again from the top. */}
      <div className="hoot-panel-in" key={arrival}>
      <header className="hoot-panel-head">
        <HootMark size={22} />
        <span className="hoot-panel-name">{name}</span>
        {line ? (
          <span className="hoot-panel-line" data-attention={line.attention || undefined}>
            {line.attention ? <span className="hoot-panel-dot" aria-hidden="true" /> : null}
            {line.text}
          </span>
        ) : null}
      </header>

      {waiting.length > 0 ? (
        <ul className="hoot-panel-waiting" aria-label="Waiting on you">
          {waiting.slice(0, 4).map((session) => (
            <li key={session.id}>
              <button type="button" className="hoot-panel-session" onClick={() => void deck.hootPanelShowSession?.(session.id)}>
                <span className="hoot-panel-dot" aria-hidden="true" />
                <span className="hoot-panel-session-name">{session.label}</span>
                <span className="hoot-panel-session-what">needs you</span>
              </button>
            </li>
          ))}
        </ul>
      ) : null}

      {running ? (
        <>
          <div className="hoot-panel-log" ref={log}>
            {snap.messages.length === 0 ? (
              <p className="hoot-panel-quiet">Ask {name} anything about your sessions.</p>
            ) : (
              snap.messages.slice(-6).map((message) => (
                <p key={message.id} className="hoot-panel-msg" data-role={message.role}>
                  {message.text}
                </p>
              ))
            )}
          </div>
          <input
            ref={input}
            className="hoot-panel-input"
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
        <div className="hoot-panel-off">
          <p className="hoot-panel-quiet">
            {snap.hoot.status === 'starting' ? `${name} is starting…` : snap.hoot.problem ?? `${name} isn’t running.`}
          </p>
          {snap.hoot.status === 'stopped' ? (
            <button
              type="button"
              className="btn-primary hoot-panel-start"
              onClick={() => {
                setProblem(null)
                void deck
                  .hootPanelStartHoot?.()
                  .then((raw) => {
                    const result = resultOf(raw)
                    if (!result.ok) setProblem(result.message || `${name} could not start.`)
                  })
                  .catch(() => setProblem(`${name} could not start.`))
              }}
            >
              Start {name}
            </button>
          ) : null}
        </div>
      )}
      {problem ? (
        <p className="hoot-panel-problem" role="status">
          {problem}
        </p>
      ) : null}
      </div>
    </div>
  )
}
