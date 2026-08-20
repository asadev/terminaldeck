/**
 * Is there an agent running in the session on screen?
 *
 * ## Why the question is not "which provider was this session started as"
 *
 *   > "Starting a session gives you a plain shell. Today that shell still shows
 *   > the chat/terminal switch and the account dropdown — both of which mean
 *   > nothing until an agent is running in it."
 *
 * `SessionMeta.provider` answers what this app *launched*, and that is the right
 * answer for exactly one of the two cases:
 *
 *  - **An agent session.** `providers.ts` spawns the CLI as the pty's own
 *    process — `{ command: 'claude', args: [] }` on POSIX, `cmd /c claude` on
 *    Windows, `exec claude` inside a distro. Nothing sits between the terminal
 *    and the agent, so the agent is running for exactly as long as the session
 *    is, and `exitCode === null` is not a guess but the same fact stated twice.
 *
 *  - **A shell session.** The pty is `$SHELL -l`, and whether an agent is in
 *    front of it depends on what has been typed into it since. Pressing Run
 *    Claude starts one; `/exit` ends it and leaves the shell — and the session
 *    alive — behind. There is nothing in the session record that changes at
 *    either moment, which is precisely why this cannot be read off the record.
 *
 * So the shell case is asked of the session's own screen, through
 * `agent:controls:read`, which already reads that screen for the model and the
 * permission footer. `readAgentFromScreen` in `src/main/agent-controls.ts`
 * documents what the markers are, where they were captured from, and what a
 * match is worth.
 *
 * ## Unknown is a third answer and it is kept
 *
 * `running` is `null` when nothing has answered — before the first read, and
 * for the whole life of a build with no controls channel — and the caller draws
 * neither control there rather than picking one. The thing it must never do is
 * offer to start an agent on a hunch: typing `claude` into a session that
 * already has Claude in it does not start anything, it submits the word
 * "claude" as a prompt.
 *
 * The same `null` is used for the one weak spot in the reading itself. A marker
 * on the screen cannot get there by accident, so `true` is believed at once; a
 * screen with no marker on it is a weaker claim, because the CLI could be
 * caught mid-repaint. {@link settle} spends one extra reading on that, and only
 * when a disappearance is actually being claimed.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import type { ProviderId } from '@shared/types'
import { controlsWired, readControlsAt, watchSessionOutput, type ControlsTarget } from './controls-target'

/** The session the chrome is about, as much of it as this needs. */
export interface ChromeSession {
  /** The pty id. */
  id: string
  /** What this app launched into it. */
  provider: ProviderId
  /** Set once the process is gone. */
  exited: boolean
}

export interface AgentPresence {
  /** True or false when something real said so; null while nothing has. */
  running: boolean | null
  /** `session` — the pty *is* the agent. `screen` — read off its viewport. */
  source: 'session' | 'screen' | null
  /** The line the screen was read from, so a caller can show its working. */
  saw: string | null
}

export const UNKNOWN_PRESENCE: AgentPresence = { running: null, source: null, saw: null }

/**
 * What the session record alone settles, or null when it settles nothing.
 *
 * Pure, and separate from the hook, because this is the half that is exact and
 * it should be possible to say so in a test without a bridge or a screen.
 */
export function presenceFromSession(session: ChromeSession | null): AgentPresence | null {
  if (!session) return UNKNOWN_PRESENCE
  // A dead session has nothing running in it whatever it was started as. Stated
  // before the provider check so an exited agent tab does not keep claiming an
  // agent — the tab stays in the list until it is closed.
  if (session.exited) return { running: false, source: 'session', saw: null }
  if (session.provider !== 'shell') return { running: true, source: 'session', saw: null }
  return null
}

/**
 * Which of the three states the account slot is in.
 *
 * Pure and exported so the decision can be pinned exhaustively. It cannot be
 * reached through a render test: two of the three states depend on an answer
 * that arrives from the main process, and this project's render tests produce a
 * static string with no chance for a promise to resolve. Leaving the decision
 * inline would mean the most important case in item 1 — a live shell with no
 * agent in it, which is what every new session starts as — had no test at all.
 *
 *   `run`     offer to start one
 *   `account` the account picker, as before
 *   `none`    nothing is known yet, so nothing is claimed
 */
export type ChipMode = 'run' | 'account' | 'none'

export function chipMode(session: ChromeSession | null, agent: AgentPresence): ChipMode {
  // No session is the folder case: two callers render the chip to ask which
  // account a *new* session here would use, and a folder has no agent in it.
  if (!session) return 'account'
  if (agent.running === true) return 'account'
  if (agent.running === false) return 'run'
  return 'none'
}

/*
 * The bridge is reached through `controls-target.ts` rather than read here.
 *
 * This file used to hold its own two-method view of `window.deck`, naming
 * `readAgentControls` and `onSessionData` — both of which address *this*
 * machine's session layer by *this* machine's session id. Over a session on a
 * paired PC or a terminal on a server they asked about something that does not
 * exist here, so presence was permanently unknown and the control cluster it
 * gates was permanently withdrawn.
 *
 * Routing it through the same module `useSessionControls` uses is not tidiness.
 * These two hooks read one fact — is there an agent in front of this session —
 * and the last time two components on one bar answered that from two sources,
 * the account chip drew its picker over a running agent while the model chip
 * forty pixels away withdrew itself. One router, one answer, whichever computer
 * the session is on.
 */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Narrow the `agent` block off a `ControlsReading`. Anything odd is "not known". */
export function parseAgentReading(value: unknown): AgentPresence {
  if (!isRecord(value)) return UNKNOWN_PRESENCE
  const agent = value.agent
  if (!isRecord(agent) || typeof agent.running !== 'boolean') return UNKNOWN_PRESENCE
  return {
    running: agent.running,
    source: 'screen',
    saw: typeof agent.saw === 'string' ? agent.saw : null,
  }
}

/**
 * How long the session has to stop printing before the screen is re-read.
 *
 * The same quiet-period `AgentControls` uses, for the same reason and against
 * the same event: nothing on the screen can change without the pty producing
 * output, and reading mid-repaint gets a half-drawn footer. It is what makes
 * this arrive within half a second of an agent starting or exiting without
 * anything resembling a poll.
 */
const SETTLE_MS = 400

/**
 * Hysteresis, and which direction it is applied in.
 *
 * A screen reading is strong when it finds a marker and weak when it does not:
 * a marker cannot appear by accident, but Claude Code can plausibly be caught
 * mid-repaint with neither its idle footer nor `esc to interrupt` on screen for
 * one frame. So "an agent appeared" is believed immediately, and "the agent has
 * gone" is believed only after a second reading agrees — *and only for a
 * session that has been seen to have one*.
 *
 * That last clause is what keeps the common case instant. A session that has
 * never had an agent in it is the state every new session starts in, and its
 * first reading of "no marker" is not a disappearance, it is the answer. Run
 * Claude appears at once there and waits out one extra reading only where a
 * disappearance is actually being claimed.
 */
export function settle(previous: AgentPresence, reading: AgentPresence, seenAgent: boolean): AgentPresence {
  if (reading.running !== false) return reading
  if (!seenAgent) return reading
  // First disagreement after an agent was seen: hold the last real answer.
  return previous.running === true ? { ...previous, running: null } : reading
}

/**
 * What is running in a session, as opposed to what this app launched into it.
 *
 * Only one case differs, and it exists because Run Claude does (NEXT-UPDATE
 * item 1): a session spawned as `$SHELL -l` with an agent now in front of it.
 * `provider` still says `shell` — it is a record of the spawn and it is not
 * wrong — but every piece of copy keyed off it would be. The pane would go on
 * telling a reader with a live conversation in front of them that "a shell just
 * runs what you type, so there is nothing here to read".
 *
 * The answer is `undefined`, not `'claude'`. `undefined` already means "not
 * known" everywhere this is passed, and not known is the truth: somebody typed
 * a CLI into a terminal and this app never saw which one. Naming Claude here
 * would be a guess that reads as a fact, and `codex` is one keystroke away from
 * being the thing actually running. `refuseByProvider` in
 * `src/main/agent-controls.ts` is the far end of that agreement: handed
 * `undefined` it consults the *screen* and writes only when the screen carries
 * Claude Code's own markers, so "not known" costs nothing and claims nothing.
 *
 * Anything other than a shell is returned untouched, including `undefined`.
 *
 * ## Why it lives here rather than in the one component that used to own it
 *
 * It was written in `components/ChatView.tsx`, because the chat pane was the
 * first surface that had to tell a spawn apart from what is in front of it. It
 * moved the day a second surface needed the same distinction — the window's
 * control cluster, which had been asking the *record* while the account chip
 * eighteen pixels to its left asked the *screen*, and so withdrew the model,
 * the effort and the usage reading from every session Asad starts as a shell
 * and types `claude` into. Two components on one bar disagreeing about whether
 * an agent is running is the fault; one function, in the module that owns the
 * question, is the fix. Importing it out of `ChatView` was not an option worth
 * having — `ChatView` already imports {@link useAgentPresence} from here, so
 * that direction is a cycle.
 */
export function runningProvider(
  provider: ProviderId | undefined,
  agentRunning: boolean | null,
): ProviderId | undefined {
  if (provider === 'shell' && agentRunning === true) return undefined
  return provider
}

export function useAgentPresence(
  session: ChromeSession | null,
  /**
   * Which computer the session is on. Absent means this one — see
   * {@link ControlsTarget}.
   */
  target?: ControlsTarget,
): AgentPresence {
  const settled = presenceFromSession(session)
  /*
   * Flattened to two primitives for the dependency arrays below, for the reason
   * `useSessionControls` flattens the same value: an object literal rebuilt at
   * each render is a new value at each render, so a target in a dependency list
   * would re-arm the output subscription every frame.
   */
  const targetKind = target?.kind ?? 'local'
  const targetMachine = target?.kind === 'machine' ? target.machineId : ''
  const where: ControlsTarget | undefined =
    targetKind === 'machine'
      ? { kind: 'machine', machineId: targetMachine }
      : targetKind === 'server'
        ? { kind: 'server' }
        : undefined
  const [screen, setScreen] = useState<AgentPresence>(UNKNOWN_PRESENCE)
  const alive = useRef(true)
  /** Whether this session's screen has ever carried an agent's own markers. */
  const seenAgent = useRef(false)

  // Only the shell case needs the screen; everything else is already decided.
  const sessionId = settled === null ? session?.id : undefined

  const read = useCallback(async (): Promise<void> => {
    if (!sessionId || !controlsWired(where)) return
    try {
      const reading = parseAgentReading(await readControlsAt(where, { sessionId }))
      if (!alive.current) return
      setScreen((previous) => settle(previous, reading, seenAgent.current))
      if (reading.running === true) seenAgent.current = true
    } catch {
      // A read that fails leaves the last real one alone. Blanking it would
      // withdraw a control because one IPC call went missing.
    }
    // `where` is rebuilt from the two primitives at each render and is not in
    // this list for that reason; the primitives are, and they are what actually
    // changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, targetKind, targetMachine])

  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  useEffect(() => {
    // A different session is a different question; the previous answer is not
    // an answer to it, and neither is what its screen has ever shown.
    setScreen(UNKNOWN_PRESENCE)
    seenAgent.current = false
    if (!sessionId) return
    void read()

    let timer: ReturnType<typeof setTimeout> | null = null
    const off = watchSessionOutput(where, sessionId, () => {
      if (timer !== null) clearTimeout(timer)
      timer = setTimeout(() => {
        timer = null
        void read()
      }, SETTLE_MS)
    })
    if (off === null) return
    return () => {
      if (timer !== null) clearTimeout(timer)
      off()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, targetKind, targetMachine, read])

  return settled ?? screen
}
