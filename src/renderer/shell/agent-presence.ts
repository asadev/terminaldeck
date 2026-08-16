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

/** The slice of the bridge this needs. Optional throughout: an unwired build says so. */
interface ControlsBridge {
  readAgentControls?: (request: { sessionId?: string; cwd?: string }) => Promise<unknown>
  onSessionData?: (cb: (id: string, data: string) => void) => () => void
}

function bridge(): ControlsBridge | undefined {
  // `globalThis`, not `window`: components in this folder are rendered to a
  // string in their own tests, where there is no window to read.
  return (globalThis as { deck?: ControlsBridge }).deck
}

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

export function useAgentPresence(session: ChromeSession | null): AgentPresence {
  const settled = presenceFromSession(session)
  const [screen, setScreen] = useState<AgentPresence>(UNKNOWN_PRESENCE)
  const alive = useRef(true)
  /** Whether this session's screen has ever carried an agent's own markers. */
  const seenAgent = useRef(false)

  // Only the shell case needs the screen; everything else is already decided.
  const sessionId = settled === null ? session?.id : undefined

  const read = useCallback(async (): Promise<void> => {
    const deck = bridge()
    if (!sessionId || typeof deck?.readAgentControls !== 'function') return
    try {
      const reading = parseAgentReading(await deck.readAgentControls({ sessionId }))
      if (!alive.current) return
      setScreen((previous) => settle(previous, reading, seenAgent.current))
      if (reading.running === true) seenAgent.current = true
    } catch {
      // A read that fails leaves the last real one alone. Blanking it would
      // withdraw a control because one IPC call went missing.
    }
  }, [sessionId])

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

    const deck = bridge()
    if (typeof deck?.onSessionData !== 'function') return
    let timer: ReturnType<typeof setTimeout> | null = null
    const off = deck.onSessionData((id) => {
      if (id !== sessionId) return
      if (timer !== null) clearTimeout(timer)
      timer = setTimeout(() => {
        timer = null
        void read()
      }, SETTLE_MS)
    })
    return () => {
      if (timer !== null) clearTimeout(timer)
      off()
    }
  }, [sessionId, read])

  return settled ?? screen
}
