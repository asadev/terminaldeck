import { useCallback, useEffect, useRef, useState } from 'react'
import type { ControlId, ControlReading, ControlsReading } from '../chat/controls/catalog'

/**
 * One session's model, effort and fast mode, read from the session and written
 * back to it — the state behind {@link SessionControls}.
 *
 * ## Why this is a hook and not part of the component
 *
 * Because the component is rendered in two places at once. The window's own bar
 * carries the controls for the session the window is looking at, and every pane
 * of a split carries its own set for its own session — and those are different
 * sessions, with different models, different efforts and different reasons for
 * being un-typeable at any given moment. Keeping the state here means each
 * mounted cluster owns exactly one session's answers and cannot be handed
 * another pane's, which is the confusion that started this whole redesign:
 * *"it can be a problem, it can be a confusion — which one it is showing right
 * now."*
 *
 * ## Why this is not shared with the chat composer's copy
 *
 * `chat/controls/AgentControls.tsx` runs the same conversation with the same
 * bridge, and folding the two together was tried first. It cannot be done
 * without weakening pins that exist for good reasons: `AgentControls.test.tsx`
 * asserts against that file's **source text** — that it names the provider on
 * both bridge calls, and that it writes `answer.reading` rather than the value
 * that was clicked — and `wiring.test.ts` asserts that the same file renders
 * `<ControlPicker` and `<ControlSection` and builds its panel from
 * `MENU_CONTROLS.map`. Every one of those checks is guarding a bug that has
 * actually shipped here, and all of them go silent the moment the lines they
 * read move into a hook. So the composer keeps its copy, this is the chrome's,
 * and the part that would really hurt to duplicate — what the options *are*,
 * what each is called, what a value means and where it was read from — is not
 * duplicated at all: both import `chat/controls/catalog.ts`.
 *
 * Everything below goes to the agent as keystrokes into its pty, because that
 * is the only channel this app has. See `src/main/agent-controls.ts` for the
 * protocol that makes that safe.
 */

/**
 * Whether a command could be typed at the session this instant, and why not.
 *
 * Mirrors `ControlGate` in `src/main/agent-controls.ts`. Duplicated as a shape
 * rather than imported because main-process types do not cross the bridge —
 * what arrives here is `unknown` off an IPC channel, and is parsed as such.
 */
export interface ControlGate {
  canType: boolean
  reason: string | null
}

export interface SessionReadings extends ControlsReading {
  gate: ControlGate
}

export interface SessionControlsState {
  /** The last values genuinely read, or null before the first read lands. */
  readings: SessionReadings | null
  /** Which control is mid-change, so its own chip can say so. */
  busy: ControlId | null
  /** What the session said about the last change. Cleared on success, kept on failure. */
  notice: { ok: boolean; text: string } | null
  dismissNotice(): void
  /** True when there is a bridge, a session, and a CLI this build can drive. */
  wired: boolean
  pick(control: ControlId, value: string): void
}

/**
 * The bridge, as loosely as the rest of the renderer reads it.
 *
 * Optional everywhere: a build without these methods gets controls that say
 * they are not wired rather than controls that throw on first click.
 */
interface Bridge {
  readAgentControls?(request: { sessionId?: string; cwd?: string; provider?: string }): Promise<unknown>
  applyAgentControl?(request: {
    sessionId: string
    cwd?: string
    control: ControlId
    value: string
    provider?: string
  }): Promise<unknown>
  onSessionData?(cb: (id: string, data: string) => void): () => void
}

/**
 * How long the session has to stop printing before the controls re-read.
 *
 * The same quiet period the composer's copy uses, for the same reason: every
 * value here is scraped off the session's own screen, so it cannot change
 * without the pty producing output, and reading in the middle of a streaming
 * reply gets a half-drawn footer. During a long answer this is one read when it
 * ends rather than one every four seconds all the way through it.
 */
const SETTLE_MS = 400

/**
 * How long a successful confirmation stays on screen.
 *
 * A confirmation is worth showing and not worth keeping — the value on the chip
 * says the same thing permanently. A failure does not expire: an error that
 * cleans up after itself is an error nobody read.
 */
const CONFIRM_MS = 4000

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asReading(value: unknown): ControlReading {
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

/**
 * The gate, defaulting **shut** when the answer is missing or malformed.
 *
 * Closed is the safe direction and it is also the honest one: a build whose
 * main process does not report a gate has not established that typing is safe,
 * and an open default would draw live-looking pickers over exactly the states
 * — a draft in the composer, a dialog waiting on an answer — that the gate
 * exists to keep this app's fingers out of.
 */
function asGate(value: unknown): ControlGate {
  if (!isRecord(value)) return { canType: false, reason: null }
  return {
    canType: value.canType === true,
    reason: typeof value.reason === 'string' ? value.reason : null,
  }
}

function asReadings(value: unknown): SessionReadings | null {
  if (!isRecord(value)) return null
  return {
    model: asReading(value.model),
    effort: asReading(value.effort),
    fast: asReading(value.fast),
    permission: asReading(value.permission),
    live: value.live === true,
    gate: asGate(value.gate),
  }
}

function asApplyResult(value: unknown): { ok: boolean; message: string; reading: ControlReading } {
  if (!isRecord(value)) return { ok: false, message: 'No answer from the session.', reading: asReading(null) }
  return {
    ok: value.ok === true,
    message: typeof value.message === 'string' ? value.message : '',
    reading: asReading(value.reading),
  }
}

/**
 * `globalThis` rather than `window`, because the shell's components are rendered
 * to a string in their own tests, where there is no `window` at all — reading it
 * during render throws and takes the whole bar down with it.
 */
function deckBridge(): Bridge | undefined {
  return (globalThis as unknown as { deck?: Bridge }).deck
}

export function useSessionControls(
  sessionId: string | undefined,
  cwd: string | null | undefined,
  provider: string | undefined,
): SessionControlsState {
  const [readings, setReadings] = useState<SessionReadings | null>(null)
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
  // Derived, not state: an effect that flipped this would render one frame of
  // working controls before admitting the bridge is missing, and would never
  // run at all when the bar is rendered to a string.
  const wired = typeof bridge?.readAgentControls === 'function' && sessionId !== undefined

  const refresh = useCallback(async (): Promise<void> => {
    if (!sessionId || typeof bridge?.readAgentControls !== 'function') return
    try {
      const answer = await bridge.readAgentControls({ sessionId, cwd: cwd ?? undefined, provider })
      if (!alive.current) return
      const parsed = asReadings(answer)
      if (parsed) setReadings(parsed)
    } catch {
      // A read that fails leaves the previous values alone: they are still the
      // last thing genuinely read, and blanking them would be a regression in
      // honesty rather than an improvement.
    }
  }, [bridge, sessionId, cwd, provider])

  useEffect(() => {
    if (!wired) return
    void refresh()
  }, [wired, refresh])

  /*
   * Re-read when the session prints something, not on a clock.
   *
   * Everything on these chips changes only when the pty produces output — the
   * model line, the effort confirmation, the footer, and the composer state the
   * gate is read from. `session:data` says exactly when that happens, so this
   * asks once per pause in the output and not at all while the session is idle.
   * It matters more here than it did in the composer: this cluster is mounted
   * for every pane of a split at once, so a four-second poll would have been
   * three of them.
   */
  useEffect(() => {
    if (!wired || !sessionId) return
    const deck = deckBridge()
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

  const pick = useCallback(
    (control: ControlId, value: string): void => {
      const apply = bridge?.applyAgentControl
      // Bound to a local before the closure, not read off `bridge` inside it:
      // the narrowing a `typeof` check buys is re-widened the moment the
      // property is read again inside a nested function.
      if (!sessionId || typeof apply !== 'function') return
      setBusy(control)
      setNotice(null)
      void (async () => {
        try {
          const answer = asApplyResult(
            await apply({ sessionId, cwd: cwd ?? undefined, control, value, provider }),
          )
          if (!alive.current) return
          setNotice({ ok: answer.ok, text: answer.message })
          /*
           * The reading comes from the answer, and the answer's reading is one
           * the main process re-read off the session after the change settled —
           * never the value that was clicked. A picker that ticks the row you
           * pressed is showing your intention, and this app has shipped that bug
           * once already.
           */
          setReadings((was) => (was ? { ...was, [control]: answer.reading } : was))
        } catch (error) {
          if (alive.current) {
            setNotice({ ok: false, text: error instanceof Error ? error.message : 'The change failed.' })
          }
        } finally {
          if (alive.current) setBusy(null)
          void refresh()
        }
      })()
    },
    [bridge, sessionId, cwd, provider, refresh],
  )

  const dismissNotice = useCallback(() => setNotice(null), [])

  return { readings, busy, notice, dismissNotice, wired, pick }
}
