import { useCallback, useEffect, useRef, useState } from 'react'
import { ControlPicker } from './ControlPicker'
import { optionsFor, reachOf, type ControlId, type ControlsReading } from './catalog'
import './AgentControls.css'

/**
 * The control row under the chat composer.
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
 * says "Unknown", which is the point: a row of confident defaults that were
 * never verified would be worse than no row at all.
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
  /** Absent until a session is focused; the row then explains itself. */
  sessionId?: string
  cwd?: string | null
}

interface ApplyResult {
  ok: boolean
  message: string
  reading: ControlsReading['model']
}

/**
 * How long the session has to stop printing before the row re-reads.
 *
 * Not a poll — a quiet-period after an event. Every value on this row is
 * scraped off the session's own screen, so it cannot change without the pty
 * producing output, and `session:data` says exactly when that happens. What it
 * does *not* say is when the CLI has finished repainting: reading in the middle
 * of a streaming reply gets a half-drawn footer. So the read waits out a pause,
 * which during a long answer means one read when it ends rather than one every
 * four seconds all the way through it.
 */
const SETTLE_MS = 400

/**
 * The pty output channel, read off `window.deck` as loosely as the rest.
 *
 * Optional: a build without it falls back to the read this row does on mount,
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

const LABELS: Array<{ id: ControlId; name: string }> = [
  { id: 'model', name: 'Model' },
  { id: 'effort', name: 'Effort' },
  { id: 'fast', name: 'Fast' },
  { id: 'permission', name: 'Permission' },
]

export function AgentControls({ sessionId, cwd }: Props) {
  const [readings, setReadings] = useState<ControlsReading | null>(null)
  const [busy, setBusy] = useState<ControlId | null>(null)
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null)
  const alive = useRef(true)

  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  const bridge = deckBridge()
  // Derived, not state: an effect that flips this would render one frame of a
  // working row before admitting the bridge is missing, and would never run at
  // all when the view is rendered to a string.
  const wired = typeof bridge?.readAgentControls === 'function'

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
   * mode is a different view of the same session, so the row cannot trust what
   * it last set — but neither of those can happen without the pty echoing it,
   * and `session:data` carries that. The old 4-second re-read asked 21,600
   * times a day for a value that changes a handful of times; this asks once per
   * pause in the output, and none at all while the session is idle.
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

  if (!wired) {
    return (
      <div className="agent-controls agent-controls-idle">
        <span className="ac-idle">Model, effort and permission controls are not wired into this build.</span>
      </div>
    )
  }

  if (!sessionId) {
    // Not "open a session": the caller resolves the session by project folder,
    // so this state is reached both with none open and with two open in the
    // same folder — and telling someone staring at a running session to open
    // one is its own small lie.
    return (
      <div className="agent-controls agent-controls-idle">
        <span className="ac-idle">
          These type into a running session, and there is no single live session for this folder to type into.
        </span>
      </div>
    )
  }

  return (
    <div className="agent-controls">
      <div className="ac-row">
        {LABELS.map(({ id, name }) => {
          const reading = readings?.[id]
          // Fast mode is the one control an account can be barred from, and the
          // CLI is the only thing that knows. Once it has said so, the reason is
          // shown in place of the menu rather than leaving a button that argues
          // with the CLI every time it is pressed.
          const blocked = id === 'fast' && reading?.unavailableReason ? reading.unavailableReason : null
          return (
            <ControlPicker
              key={id}
              name={name}
              reading={reading}
              options={optionsFor(id)}
              reach={reachOf(id)}
              busy={busy === id}
              disabled={busy !== null && busy !== id}
              blocked={blocked}
              onPick={(value) => void pick(id, value)}
            />
          )
        })}
      </div>

      {notice ? (
        <p className={notice.ok ? 'ac-notice' : 'ac-notice ac-notice-bad'} role="status">
          {notice.text}
        </p>
      ) : readings && !readings.live ? (
        <p className="ac-notice ac-notice-bad" role="status">
          This session is not running, so nothing can be changed in it.
        </p>
      ) : (
        <p className="ac-notice ac-notice-quiet">
          {readings?.permission.label
            ? `Typed into the session, like you would yourself · ${readings.permission.label.toLowerCase()} permissions`
            : 'Typed into the session, like you would yourself'}
        </p>
      )}
    </div>
  )
}
