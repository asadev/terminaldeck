import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { ControlPicker } from './ControlPicker'
import { ControlSection } from './ControlSection'
import {
  controlName,
  FOLDED_CONTROLS,
  optionsFor,
  PRIMARY_CONTROLS,
  reachOf,
  type ControlId,
  type ControlsReading,
} from './catalog'
import type { ProviderId } from '@shared/types'
import './AgentControls.css'

/**
 * The agent's controls, living inside the composer.
 *
 * Everything here goes to the agent the same way a typed message does — as
 * keystrokes into the session's PTY. There is no second channel, so a control
 * exists only where a person sitting at that terminal could have done the same
 * thing:
 *
 *   Model       `/model <alias>`
 *   Effort      `/effort <level>`
 *   Fast mode   `/fast on|off`
 *   Permission  shift+tab, one press at a time, footer re-read after each
 *
 * The values are read back from the session's own screen, its transcript or the
 * CLI's settings file — never assumed. When nothing could be read the control
 * says so rather than guessing: a row of confident defaults that were never
 * verified would be worse than no row at all.
 *
 * Three of the four resolve on any machine. Fast mode structurally cannot until
 * the session mentions it — see `unreadLabel` in `catalog.ts` for why — so it
 * says "Not reported" and its panel explains the difference, instead of showing
 * the same "Unknown" that everywhere else here means "something failed".
 *
 * ## Why two of them are hidden
 *
 * This was a strip of four pickers and two lines of prose under the chat box,
 * and it read as clutter rather than as control — the complaint that started
 * this redesign was, exactly, "a lot of options under the chat box". So the two
 * that a session actually reaches for stay on the box and the two that get set
 * once hide behind one labelled button. `PRIMARY_CONTROLS` and
 * `FOLDED_CONTROLS` in `catalog.ts` are that decision, written down where a
 * test can check nothing fell out of both lists.
 *
 * Hiding is not dropping: everything the strip could say is still said, and the
 * panel is where the descriptions finally have room to be sentences.
 */

export interface AgentControlsBridge {
  readAgentControls(request: { sessionId?: string; cwd?: string }): Promise<unknown>
  applyAgentControl(request: {
    sessionId: string
    cwd?: string
    control: ControlId
    value: string
  }): Promise<unknown>
}

interface Props {
  /** Absent until a session is focused; the controls then explain themselves. */
  sessionId?: string
  cwd?: string | null
  /**
   * What is running in the session. `shell` withdraws every picker.
   *
   * Model, effort, fast mode and permission mode are an agent CLI's vocabulary.
   * A `/bin/zsh -l` has none of them — but the reader behind these values falls
   * back to the CLI's settings file when it cannot read the session's screen,
   * so a plain shell was confidently reporting `Model  Opus 5` and a permission
   * mode of `Unknown`, neither of which is a fact about the terminal on screen.
   * The provider is the one thing that settles it, and the session record has
   * carried it since the day it was created.
   */
  provider?: ProviderId
  /**
   * A read-only block to show at the foot of the panel. `ChatView` passes the
   * usage strip, which used to be a third row under the composer.
   *
   * It lives here rather than in `ChatComposer` so the box has one fold and not
   * two: "what this session may do" and "what it has cost" are the same kind of
   * thing to a reader — reference, wanted occasionally, never while typing.
   */
  extra?: ReactNode
}

interface ApplyResult {
  ok: boolean
  message: string
  reading: ControlsReading['model']
}

/**
 * How long the session has to stop printing before the controls re-read.
 *
 * Not a poll — a quiet-period after an event. Every value here is scraped off
 * the session's own screen, so it cannot change without the pty producing
 * output, and `session:data` says exactly when that happens. What it does *not*
 * say is when the CLI has finished repainting: reading in the middle of a
 * streaming reply gets a half-drawn footer. So the read waits out a pause,
 * which during a long answer means one read when it ends rather than one every
 * four seconds all the way through it.
 */
const SETTLE_MS = 400

/**
 * How long a successful change stays on screen.
 *
 * A confirmation is worth showing and not worth keeping: the tick in the menu
 * and the value on the button both say the same thing permanently, so leaving
 * "Set model to Sonnet 5" under the text box adds a line to the very surface
 * this redesign exists to quieten. Failures do *not* expire — an error that
 * cleans up after itself is an error nobody read.
 */
const CONFIRM_MS = 4000

/**
 * The pty output channel, read off `window.deck` as loosely as the rest.
 *
 * Optional: a build without it falls back to the read this does on mount,
 * which is still the truth, just not a live one.
 */
interface SessionDataEvents {
  onSessionData?: (cb: (id: string, data: string) => void) => () => void
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asReading(value: unknown): ControlsReading['model'] {
  if (!isRecord(value)) return { value: null, label: null, source: null }
  return {
    value: typeof value.value === 'string' ? value.value : null,
    label: typeof value.label === 'string' ? value.label : null,
    source:
      value.source === 'screen' || value.source === 'transcript' || value.source === 'settings' || value.source === 'env'
        ? value.source
        : null,
    unavailableReason: typeof value.unavailableReason === 'string' ? value.unavailableReason : undefined,
  }
}

function asReadings(value: unknown): ControlsReading | null {
  if (!isRecord(value)) return null
  return {
    model: asReading(value.model),
    effort: asReading(value.effort),
    fast: asReading(value.fast),
    permission: asReading(value.permission),
    live: value.live === true,
  }
}

function asApplyResult(value: unknown): ApplyResult {
  if (!isRecord(value)) return { ok: false, message: 'No answer from the session.', reading: asReading(null) }
  return {
    ok: value.ok === true,
    message: typeof value.message === 'string' ? value.message : '',
    reading: asReading(value.reading),
  }
}

/**
 * The preload bridge, if there is one.
 *
 * `globalThis` rather than `window` because `ChatView` is rendered to a string
 * in its own tests, where there is no `window` at all — reading it during
 * render threw and took the whole view down with it.
 */
function deckBridge(): Partial<AgentControlsBridge> | undefined {
  return (globalThis as unknown as { deck?: Partial<AgentControlsBridge> }).deck
}

export function AgentControls({ sessionId, cwd, provider, extra }: Props) {
  const shell = provider === 'shell'
  const [readings, setReadings] = useState<ControlsReading | null>(null)
  const [busy, setBusy] = useState<ControlId | null>(null)
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null)
  const [open, setOpen] = useState(false)
  const alive = useRef(true)
  const rootRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  const bridge = deckBridge()
  // Derived, not state: an effect that flips this would render one frame of
  // working controls before admitting the bridge is missing, and would never run
  // at all when the view is rendered to a string.
  const wired = typeof bridge?.readAgentControls === 'function' && !shell
  const usable = wired && sessionId !== undefined

  const refresh = useCallback(async (): Promise<void> => {
    if (!sessionId || typeof bridge?.readAgentControls !== 'function') return
    try {
      const answer = await bridge.readAgentControls({ sessionId, cwd: cwd ?? undefined })
      if (!alive.current) return
      const parsed = asReadings(answer)
      if (parsed) setReadings(parsed)
    } catch {
      // A read that fails leaves the previous values alone; they are still the
      // last thing that was genuinely read, and blanking them would be a
      // regression in honesty, not an improvement.
    }
  }, [bridge, sessionId, cwd])

  useEffect(() => {
    if (!wired) return
    void refresh()
  }, [wired, refresh])

  /**
   * Re-read when the session prints something, not on a clock.
   *
   * The permission footer changes when the user presses shift+tab in the
   * terminal view, and the model changes when they type `/model` there. Chat
   * mode is a different view of the same session, so this cannot trust what it
   * last set — but neither of those can happen without the pty echoing it, and
   * `session:data` carries that. The old 4-second re-read asked 21,600 times a
   * day for a value that changes a handful of times; this asks once per pause in
   * the output, and none at all while the session is idle.
   */
  useEffect(() => {
    if (!wired || !sessionId) return
    const deck = (globalThis as unknown as { deck?: SessionDataEvents }).deck
    if (typeof deck?.onSessionData !== 'function') return

    let settle: ReturnType<typeof setTimeout> | null = null
    const off = deck.onSessionData((id) => {
      if (id !== sessionId) return
      if (settle !== null) clearTimeout(settle)
      settle = setTimeout(() => {
        settle = null
        void refresh()
      }, SETTLE_MS)
    })

    return () => {
      if (settle !== null) clearTimeout(settle)
      off()
    }
  }, [wired, sessionId, refresh])

  // A confirmation expires; a failure does not. See CONFIRM_MS.
  useEffect(() => {
    if (notice === null || !notice.ok) return
    const timer = setTimeout(() => setNotice(null), CONFIRM_MS)
    return () => clearTimeout(timer)
  }, [notice])

  // Escape closes the panel from anywhere inside it, and a click outside
  // dismisses. Both are needed: a panel that only closes on Escape traps the
  // pointer, and one that only closes on click ignores the keyboard. Registered
  // only while it is open, so a shut panel costs the composer nothing.
  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        setOpen(false)
      }
    }
    const onDown = (event: MouseEvent): void => {
      const host = rootRef.current
      if (host && event.target instanceof Node && !host.contains(event.target)) setOpen(false)
    }
    document.addEventListener('keydown', onKey, true)
    document.addEventListener('mousedown', onDown)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      document.removeEventListener('mousedown', onDown)
    }
  }, [open])

  const pick = useCallback(
    async (control: ControlId, value: string): Promise<void> => {
      if (!sessionId || typeof bridge?.applyAgentControl !== 'function') return
      setBusy(control)
      setNotice(null)
      try {
        const answer = asApplyResult(await bridge.applyAgentControl({ sessionId, cwd: cwd ?? undefined, control, value }))
        if (!alive.current) return
        setNotice({ ok: answer.ok, text: answer.message })
        setReadings((was) => (was ? { ...was, [control]: answer.reading } : was))
      } catch (error) {
        if (alive.current) setNotice({ ok: false, text: error instanceof Error ? error.message : 'The change failed.' })
      } finally {
        if (alive.current) setBusy(null)
        void refresh()
      }
    },
    [bridge, sessionId, cwd, refresh],
  )

  /**
   * Why nothing can be changed, or null when it can.
   *
   * The second sentence is deliberately not "open a session": the caller
   * resolves the session by project folder, so that state is reached both with
   * none open and with two open in the same folder — and telling someone
   * staring at a running session to open one is its own small lie.
   */
  const unusable =
    shell
      ? 'This session is a shell, not an agent. Model, effort, fast mode and permission modes belong to an agent CLI — there is nothing here to set them on.'
      : wired
        ? sessionId === undefined
          ? 'These type into a running session, and there is no single live session for this folder to type into.'
          : null
        : 'Model, effort and permission controls are not wired into this build.'

  // Fast mode is the one control an account can be barred from, and the CLI is
  // the only thing that knows. Once it has said so, the reason is shown in place
  // of the options rather than leaving a button that argues with the CLI every
  // time it is pressed.
  const blockedReason = (control: ControlId): string | null =>
    control === 'fast' ? (readings?.fast.unavailableReason ?? null) : null

  return (
    <div className="agent-controls" ref={rootRef}>
      {notice ? (
        <p className={notice.ok ? 'ac-notice' : 'ac-notice ac-notice-bad'} role="status">
          {notice.text}
        </p>
      ) : usable && readings && !readings.live ? (
        <p className="ac-notice ac-notice-bad" role="status">
          This session is not running, so nothing can be changed in it.
        </p>
      ) : null}

      <div className="ac-row">
        {usable
          ? PRIMARY_CONTROLS.map((id) => (
              <ControlPicker
                key={id}
                control={id}
                name={controlName(id)}
                reading={readings?.[id]}
                options={optionsFor(id)}
                reach={reachOf(id)}
                busy={busy === id}
                disabled={busy !== null && busy !== id}
                blocked={blockedReason(id)}
                onPick={(value) => void pick(id, value)}
              />
            ))
          : null}

        {/* One affordance for everything folded away, and it says so on hover
            rather than making the word "More" carry the whole explanation. */}
        <button
          type="button"
          className="cc-chip ac-more"
          aria-haspopup="dialog"
          aria-expanded={open}
          title={
            shell
              ? 'What this session can and cannot be told to do'
              : 'Effort, fast mode, and what this session has cost'
          }
          onClick={() => setOpen((was) => !was)}
        >
          More
          <svg className="ac-caret" width="9" height="9" viewBox="0 0 12 12" aria-hidden="true">
            <path d="M2.5 4.5 6 8l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
          </svg>
        </button>
      </div>

      {open ? (
        <div className="ac-sheet scroll-fade" role="dialog" aria-label="More session options">
          {unusable ? (
            <p className="ac-sheet-note">{unusable}</p>
          ) : (
            FOLDED_CONTROLS.map((id) => (
              <ControlSection
                key={id}
                control={id}
                reading={readings?.[id]}
                options={optionsFor(id)}
                reach={reachOf(id)}
                busy={busy === id}
                disabled={busy !== null && busy !== id}
                blocked={blockedReason(id)}
                onPick={(value) => void pick(id, value)}
              />
            ))
          )}

          {extra ? (
            <section className="ac-section">
              <h4 className="ac-section-name">This session</h4>
              <p className="ac-section-desc">What it has cost so far, and how full the context window is.</p>
              {extra}
            </section>
          ) : null}

          {unusable ? null : (
            <p className="ac-sheet-foot">Every change here is typed into the session, exactly as you would type it.</p>
          )}
        </div>
      ) : null}
    </div>
  )
}
