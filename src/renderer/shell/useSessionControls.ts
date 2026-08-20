import { useCallback, useEffect, useRef, useState } from 'react'
import {
  DEFAULT_EFFORT,
  EFFORT_OPTIONS,
  type ControlId,
  type ControlReading,
  type ControlsReading,
} from '../chat/controls/catalog'
import {
  applyControlAt,
  controlsWired,
  readControlsAt,
  watchSessionOutput,
  type ControlsTarget,
} from './controls-target'

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
 * ## There used to be a second copy of this, and there is not any more
 *
 * `chat/controls/AgentControls.tsx` ran the same conversation with the same
 * bridge from the chat composer's own control row, and this note used to argue
 * at length for keeping the two apart: folding them together would have moved
 * lines that `AgentControls.test.tsx` and `wiring.test.ts` read out of that
 * file's **source text** — that it names the provider on both bridge calls, that
 * it writes `answer.reading` rather than the value that was clicked, that it
 * renders `<ControlPicker` and `<ControlSection` — and a source-text pin goes
 * silent the moment the line it reads moves into a hook.
 *
 * That argument is settled by deletion rather than by decision. *"Since we have
 * it on top we actually don't need them here… remove them from the chat box side
 * completely."* The composer's control row is gone, `AgentControls.tsx` and its
 * test with it, and every one of those pins now reads
 * `renderer/shell/SessionControls.tsx` instead — see `wiring.test.ts`, which
 * still requires that file to hold `<ControlPicker` and `<ControlSection` and
 * still counts the `<SessionControls>` mounts in `App.tsx`. The reasoning is
 * kept because it is still the reason this is a *hook* with a component beside
 * it rather than one file: what a source-text pin can see has not changed, only
 * which file it is pointed at.
 *
 * What was true then and is still true: the part that would really hurt to
 * duplicate — what the options *are*, what each is called, what a value means
 * and where it was read from — is not duplicated at all. It is in
 * `chat/controls/catalog.ts`, which is the one file both surfaces ever imported.
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

/*
 * `models` and `discoverModels` used to be on this state and they are gone.
 *
 * They were the session's *own* `/model` picker, read live: `discoverModels`
 * typed `/model` into the pty, waited for the CLI to draw its dialog, parsed the
 * rows and pressed Esc, and the menu drew what came back instead of the
 * catalogue. The reason was real and is worth keeping — a live read is the
 * account's list, so it can never offer a model the organisation has restricted
 * away, which a table in this repo absolutely can — and so was the known cost,
 * written down in that function: cancelling the picker makes the CLI print
 * `Kept model as …`, so every look left a line behind.
 *
 * What settled it was watching somebody use it:
 *
 *   > *"if I click on Opus, it will run a command just to view, just to view it
 *   > is running a command… as soon as drop down comes down it runs the command
 *   > automatically. At least when I click on something then it should run."*
 *
 * Five `/model` blocks stacked in a working conversation, none of them asked
 * for. A menu is opened to find out what is in it, often by accident, and this
 * app's one hard rule about sessions is that it types what a person would have
 * typed — nobody runs a slash command in order to look at a list. So the trade
 * was taken the other way: the catalogue can be slightly stale, and staleness
 * fails safely (`/model <name>` by hand for a missing row; the CLI's own
 * refusal, shown verbatim, for a row the account cannot use), while writing into
 * somebody's work to render a menu does not.
 *
 * The whole argument, with the fallback list's own limits spelled out, is beside
 * `optionsForRow` in `SessionControls.tsx`. `discoverAgentModels` still exists on
 * the bridge and in `src/main/agent-controls.ts`; nothing in the renderer calls
 * it any more.
 */

/*
 * The bridge is not read directly here any more, and that is the whole of what
 * made these controls reach a session on another computer.
 *
 * There used to be a `Bridge` interface in this file naming `readAgentControls`,
 * `applyAgentControl` and `onSessionData` — three channels that all address
 * *this* machine's `PtyManager` by *this* machine's session id. Over a session
 * on a paired PC or in a terminal on a server they asked about a session that
 * does not exist here, were answered with nothing, and the window drew a
 * sentence in place of the menus. Asad reported that three times.
 *
 * `controls-target.ts` is where the three destinations now live, and it is one
 * module rather than a branch in this hook because `agent-presence.ts` asks the
 * same question for a different reason — whether an agent is running at all,
 * which decides whether this cluster is drawn. Two components on one bar reading
 * one fact from two sources is a bug this project has already shipped once.
 */


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

/**
 * Rebuild the target from the two primitives the hooks carry.
 *
 * The pair exists because a fresh object literal in a dependency array is a new
 * value every render; this turns it back into the shape the router takes, at the
 * moment of the call, where identity does not matter. `'local'` is the absent
 * target — the session is on this computer — which is what every caller written
 * before `controls-target.ts` meant.
 */
function where(kind: string, machineId: string): ControlsTarget | undefined {
  if (kind === 'machine') return { kind: 'machine', machineId }
  if (kind === 'server') return { kind: 'server' }
  return undefined
}

export function useSessionControls(
  sessionId: string | undefined,
  cwd: string | null | undefined,
  provider: string | undefined,
  /**
   * Which computer the session is on. Absent means this one, which is what every
   * caller written before `controls-target.ts` existed meant — so a local bar
   * behaves exactly as it did.
   */
  target?: ControlsTarget,
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

  // Derived, not state: an effect that flipped this would render one frame of
  // working controls before admitting the bridge is missing, and would never
  // run at all when the bar is rendered to a string. Asked per target, because
  // "is there a channel for this" has three different answers.
  const wired = controlsWired(target) && sessionId !== undefined
  /*
   * The target, flattened to two primitives for the dependency arrays below.
   *
   * An object literal built at each render is a new object at each render, so a
   * `target` in a `useCallback`'s dependencies would rebuild `refresh` every
   * frame and re-arm the output subscription with it — a resubscribe per render,
   * for a value that has not changed. Two strings compare by value and say
   * exactly as much.
   */
  const targetKind = target?.kind ?? 'local'
  const targetMachine = target?.kind === 'machine' ? target.machineId : ''

  const refresh = useCallback(async (): Promise<void> => {
    if (!sessionId) return
    try {
      const answer = await readControlsAt(where(targetKind, targetMachine), { sessionId, cwd, provider })
      if (!alive.current) return
      const parsed = asReadings(answer)
      if (parsed) setReadings(parsed)
    } catch {
      // A read that fails leaves the previous values alone: they are still the
      // last thing genuinely read, and blanking them would be a regression in
      // honesty rather than an improvement.
    }
  }, [targetKind, targetMachine, sessionId, cwd, provider])

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

    let settle: ReturnType<typeof setTimeout> | null = null
    const off = watchSessionOutput(where(targetKind, targetMachine), sessionId, () => {
      if (settle !== null) clearTimeout(settle)
      settle = setTimeout(() => {
        settle = null
        void refresh()
      }, SETTLE_MS)
    })
    if (off === null) return

    return () => {
      if (settle !== null) clearTimeout(settle)
      off()
    }
  }, [wired, sessionId, targetKind, targetMachine, refresh])

  // A confirmation expires; a failure does not. See CONFIRM_MS.
  useEffect(() => {
    if (notice === null || !notice.ok) return
    const timer = setTimeout(() => setNotice(null), CONFIRM_MS)
    return () => clearTimeout(timer)
  }, [notice])

  const pick = useCallback(
    (control: ControlId, value: string): void => {
      if (!sessionId) return
      setBusy(control)
      setNotice(null)
      void (async () => {
        try {
          /*
           * The busy state is set before this and cleared in the `finally`, and
           * over a relay that window is seconds rather than milliseconds. That
           * is the same state a slow local response already produces — the chip
           * says "Working…" and the rest of the window keeps going — and it is
           * why nothing here blocks on the answer.
           */
          const answer = asApplyResult(
            await applyControlAt(where(targetKind, targetMachine), {
              sessionId,
              cwd,
              provider,
              control,
              value,
            }),
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
    [targetKind, targetMachine, sessionId, cwd, provider, refresh],
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
    /*
     * And only for a session on this computer, which is the one condition that
     * is about *whose* preference this is rather than about whether it can be
     * applied.
     *
     * `want` comes out of this window's `localStorage`. Typing it into a session
     * running on a paired machine would be this desktop silently changing the
     * effort of somebody else's session to match a setting they made here — and
     * the window at that machine's own desk has already applied its own default
     * to that session at the moment it started, from its own storage. Two
     * machines racing to impose their defaults on one pty is a session whose
     * effort depends on which window happened to look at it last.
     *
     * A server shell never reaches this line anyway (its `provider` is always
     * `undefined`, because this app did not launch what is in that terminal),
     * but the rule is written for the target rather than for the side effect, so
     * it stays true if that ever changes. Choosing an effort *by hand* on either
     * remote target works exactly as it does here; it is only the unasked one
     * that stops at this machine's own sessions.
     */
    if (targetKind !== 'local') return
    if (readings === null || busy !== null) return
    if (readings.effort.label !== null || readings.effort.unavailableReason !== undefined) return
    if (!readings.gate.canType) return
    if (defaulted.has(sessionId)) return

    defaulted.add(sessionId)
    setBusy('effort')
    void (async () => {
      try {
        const answer = asApplyResult(
          await applyControlAt(undefined, { sessionId, cwd, provider, control: 'effort', value: want }),
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
  }, [wired, targetKind, sessionId, provider, readings, busy, cwd, refresh])

  const dismissNotice = useCallback(() => setNotice(null), [])

  return { readings, busy, notice, dismissNotice, wired, pick }
}
