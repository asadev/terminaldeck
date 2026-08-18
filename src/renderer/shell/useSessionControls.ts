import { useCallback, useEffect, useRef, useState } from 'react'
import {
  DEFAULT_EFFORT,
  EFFORT_OPTIONS,
  type ControlId,
  type ControlReading,
  type ControlsReading,
} from '../chat/controls/catalog'
import type { ModelRow } from '../../shared/model-catalog'

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
  /**
   * The models this session's own `/model` picker offered, or null until it has
   * been asked.
   *
   * Null and empty mean different things and the UI depends on it: null is "not
   * asked yet, use the captured list", empty is "asked and could not be told",
   * which comes with a `notice` saying why.
   */
  models: ModelRow[] | null
  /**
   * Ask the session what models it has. Types `/model`, reads the dialog and
   * presses Esc — so it is called when somebody opens the menu, never on a
   * timer.
   */
  discoverModels(): void
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
  discoverAgentModels?(request: { sessionId?: string; provider?: string }): Promise<unknown>
  onSessionData?(cb: (id: string, data: string) => void): () => void
}

/**
 * A model row off the bridge, parsed rather than trusted.
 *
 * Same rule as `asReading` above and for the same reason: what arrives here is
 * `unknown` off an IPC channel. A row missing its alias is dropped outright,
 * because an option whose id is `undefined` is a button that types `/model
 * undefined` into somebody's terminal.
 */
function asModelRows(value: unknown): ModelRow[] {
  if (!isRecord(value) || !Array.isArray(value.models)) return []
  const rows: ModelRow[] = []
  for (const entry of value.models) {
    if (!isRecord(entry)) continue
    if (typeof entry.alias !== 'string' || entry.alias === '') continue
    if (typeof entry.model !== 'string' || entry.model === '') continue
    rows.push({
      alias: entry.alias,
      name: typeof entry.name === 'string' ? entry.name : entry.model,
      model: entry.model,
      note: typeof entry.note === 'string' ? entry.note : '',
      current: entry.current === true,
      recommended: entry.recommended === true,
    })
  }
  return rows
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

/* --------------------------------------------------- the effort default -- */

/**
 * Where the app remembers the effort you last chose.
 *
 * No product-name prefix — `localStorage` is already scoped to this renderer's
 * origin, and the product name is allowed in exactly one file, which is not this
 * one. The convention and the reasoning are `session-start.ts`'s.
 */
export const EFFORT_MEMORY_KEY = 'session-controls.effort.v1'

/**
 * The effort this app will set on a session that has none.
 *
 * Asad asked for two things in one sentence — *"effort defaults to extra-high,
 * and a change sticks"* — and they are the two halves of this function. The
 * default is `DEFAULT_EFFORT`; the sticking is that a value you picked from the
 * bar replaces it, for this and every later session, on this machine.
 *
 * Reading it out of storage is what makes the second half true across a restart.
 * Claude Code does persist an effort of its own accord, in its `settings.json`,
 * and where it has, this never fires at all — the session already reports one.
 * What it cannot persist is `auto`, because `auto` *is* the cleared state: the
 * CLI answers `Cleared effort from settings`. So somebody who deliberately wants
 * the model's own default would otherwise be handed extra-high again by this app
 * on every new session, for ever, with no way to stop it. Remembering the choice
 * is the way out, and it is also just what he asked for.
 *
 * Total by construction. This string is editable by hand in devtools and can be
 * left behind by an older build, so anything that is not one of the ids the CLI
 * accepts falls back to the default rather than being typed at a prompt.
 */
export function preferredEffort(store: Pick<Storage, 'getItem'> | null): string | null {
  let stored: string | null = null
  try {
    stored = store?.getItem(EFFORT_MEMORY_KEY) ?? null
  } catch {
    // Storage can be unavailable or blocked outright. The default still applies.
  }
  if (stored === null) return DEFAULT_EFFORT
  // `auto` is the one answer that means "apply nothing": the CLI implements it
  // by clearing the setting, so typing it at a session that already has no
  // effort would be a command that changes nothing, sent every time a session
  // opens. Null is this function's way of saying there is nothing to do.
  if (stored === 'auto') return null
  return EFFORT_OPTIONS.some((option) => option.id === stored) ? stored : DEFAULT_EFFORT
}

function rememberEffort(store: Pick<Storage, 'setItem'> | null, value: string): void {
  try {
    store?.setItem(EFFORT_MEMORY_KEY, value)
  } catch {
    // A quota or a blocked store costs the memory, not the change: the value was
    // already typed into the session, which is the part that mattered.
  }
}

function storage(): Storage | null {
  return (globalThis as unknown as { localStorage?: Storage }).localStorage ?? null
}

/**
 * Sessions this window has already applied the default to.
 *
 * Module-level rather than a ref because the same session can be on screen in
 * two places at once — the window's bar and a pane's bar both mount this — and
 * two components each holding their own "not yet" would type the command twice
 * at one prompt. Never pruned: an id is a few dozen bytes and a window that
 * opened ten thousand sessions has bigger problems.
 */
const defaulted = new Set<string>()

export function useSessionControls(
  sessionId: string | undefined,
  cwd: string | null | undefined,
  provider: string | undefined,
): SessionControlsState {
  const [readings, setReadings] = useState<SessionReadings | null>(null)
  const [models, setModels] = useState<ModelRow[] | null>(null)
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
          /*
           * …and the *clicked* value is what is remembered, which is the one
           * place the two deliberately differ.
           *
           * The reading answers "what is this session set to". The memory
           * answers "what does he want new sessions set to", and for `auto` the
           * two cannot be the same fact: the CLI implements auto by clearing the
           * setting, so the reading that comes back is an absence. Storing the
           * absence would lose the choice and hand him extra-high again on the
           * next session — the exact loop `preferredEffort` exists to end.
           */
          if (control === 'effort' && answer.ok) rememberEffort(storage(), value)
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

  /*
   * The default effort, applied once to a session that has none.
   *
   * ## Why this types a command rather than displaying a value
   *
   * Because the alternative is a lie, and this file's whole discipline is built
   * to refuse it. A control that printed `Extra high` because that is the
   * default, over a session running at whatever the CLI does by itself, would be
   * showing a value it never read — which is the single failure the readings
   * layer, the source note and `unreadLabel` all exist to prevent. If the bar is
   * to say extra-high then the session has to *be* extra-high, and the only
   * channel this app has for that is the one a person uses: `/effort xhigh`,
   * through the same gate, with the same refusals.
   *
   * ## Every condition below is a way this could be wrong
   *
   *  - **Claude only.** These are Claude Code's commands. `unsupportedProviderNote`
   *    says the same thing to the reader; this is the same fact, enforced.
   *  - **A reading has landed** and it reports *nothing* — no screen line, no
   *    transcript, no `settings.json`, no `CLAUDE_CODE_EFFORT_LEVEL`. Anything at
   *    all means somebody or something already chose, and a default that
   *    overrides a choice is not a default.
   *  - **No stated reason it is unavailable**, which is the account being barred
   *    from the control rather than the value being unknown.
   *  - **The gate is open.** The main process would refuse anyway; asking first
   *    means not queueing a command behind a half-typed prompt.
   *  - **Nothing else mid-change**, so two commands never race into one pty.
   *  - **Once per session id**, across both mounts of this cluster.
   *
   * ## And it is silent
   *
   * No notice. The bubble under the bar is the answer to something you pressed,
   * and nobody pressed this. What a reader sees is a session that came up at
   * extra high, which is what a default looks like when it is working.
   */
  useEffect(() => {
    const want = preferredEffort(storage())
    if (want === null || !wired || !sessionId || provider !== 'claude') return
    if (readings === null || busy !== null) return
    if (readings.effort.label !== null || readings.effort.unavailableReason !== undefined) return
    if (!readings.gate.canType) return
    if (defaulted.has(sessionId)) return

    const apply = bridge?.applyAgentControl
    if (typeof apply !== 'function') return
    defaulted.add(sessionId)
    setBusy('effort')
    void (async () => {
      try {
        const answer = asApplyResult(
          await apply({ sessionId, cwd: cwd ?? undefined, control: 'effort', value: want, provider }),
        )
        if (!alive.current) return
        setReadings((was) => (was ? { ...was, effort: answer.reading } : was))
      } catch {
        // A default that could not be applied leaves the control saying
        // "Unknown", which is true, and leaves the menu one click away.
      } finally {
        if (alive.current) setBusy(null)
        void refresh()
      }
    })()
  }, [wired, sessionId, provider, readings, busy, bridge, cwd, refresh])

  /**
   * Ask this session's own `/model` picker what it offers.
   *
   * ## Why this is a click and not a poll
   *
   * Because it types. `refresh` above is passive — it scrapes a screen the
   * session drew anyway — and it runs every time the session prints something,
   * which is the right shape for a reading and completely the wrong shape for a
   * keystroke. This one opens a dialog in somebody's terminal and closes it
   * again, so it happens when a person opens the menu and at no other moment.
   *
   * ## Why a failure is not silent
   *
   * The commonest reason this cannot answer is that the session is mid-turn,
   * and the main process explains that in a sentence worth reading. Swallowing
   * it would leave the menu showing the captured list with nothing on screen
   * saying it is the captured list — which is the class of quiet
   * half-truth this whole cluster is being rebuilt to remove. So the message
   * goes to the same notice strip a failed change uses.
   */
  const discoverModels = useCallback((): void => {
    const ask = bridge?.discoverAgentModels
    if (!sessionId || typeof ask !== 'function') return
    void (async () => {
      try {
        const answer = await ask({ sessionId, provider })
        if (!alive.current) return
        const rows = asModelRows(answer)
        setModels(rows)
        const message = isRecord(answer) && typeof answer.message === 'string' ? answer.message : null
        if (message !== null) setNotice({ ok: false, text: message })
        // Opening and cancelling the picker makes the CLI print
        // `Kept model as …`, which settles the current model on a session that
        // had never said. Re-reading here is how that reaches the chip.
        void refresh()
      } catch {
        // A bridge that throws leaves `models` as it was: the captured list is
        // still a real picker from a real CLI, and blanking it would trade a
        // slightly old truth for no answer at all.
      }
    })()
  }, [bridge, sessionId, provider, refresh])

  const dismissNotice = useCallback(() => setNotice(null), [])

  return { readings, busy, notice, dismissNotice, wired, pick, models, discoverModels }
}
