import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  readSessions,
  resolveAgentSessions,
  resolveTarget,
  whyDisabled,
  type AgentSession,
  type AgentSessionBridge,
} from './agent-target'

/**
 * The chosen session, for one browser window.
 *
 * ## Why the state lives here and not somewhere shared
 *
 * One hook instance per `BrowserWorkspace`, and a workspace is one browser
 * window in the strip. That is exactly the scope he asked for: *"that specific
 * popup from that browser links to one session… If I open a new browser, then I
 * will have to select."* A module-level store would make one choice for the
 * whole app; `localStorage` would carry it across restarts to a session id that
 * no longer exists. React state in the workspace is the shape of the
 * requirement.
 *
 * Nothing is chosen at mount and nothing is ever chosen automatically — not the
 * only session, not the newest one. Sending to a session nobody named is the
 * behaviour being replaced.
 */
export interface AgentTarget {
  /** Every session, dead ones included so the list explains itself. */
  sessions: AgentSession[]
  /** What the picker is set to. Empty means nothing has been chosen. */
  chosenId: string
  choose(id: string): void
  /** The session a send would reach right now, or null. */
  target: AgentSession | null
  /** Why sending is off, in a sentence. Empty when it is on. */
  reason: string
  /** True once it has been sent. Returns false when there was nowhere to send. */
  send(text: string): boolean
  /** The preload cannot list sessions in this build. */
  unavailable: boolean
}

export function useAgentTarget(bridge?: AgentSessionBridge | null): AgentTarget {
  const api = useMemo(
    () =>
      bridge !== undefined
        ? bridge
        : resolveAgentSessions(
            typeof window === 'undefined' ? null : (window as unknown as { deck?: unknown }).deck,
          ),
    [bridge],
  )

  const [sessions, setSessions] = useState<AgentSession[]>([])
  const [chosenId, setChosenId] = useState('')

  /*
   * Re-read the list rather than patching it.
   *
   * `session:created` carries a whole `SessionMeta` and `session:exit` carries
   * only an id and a code, so a patching reducer would have to reproduce the
   * labelling rule in two places and would still be wrong about ordering after
   * a session that exited and one that started. The list is a handful of rows
   * and the call is a single IPC round trip; re-reading it is both simpler and
   * the only version that cannot drift.
   */
  const refresh = useCallback(() => {
    if (!api) return
    let live = true
    api
      .listSessions()
      .then((value) => {
        if (live) setSessions(readSessions(value))
      })
      .catch(() => {
        // Leave the last good list rather than emptying the picker under the
        // pointer. A failed refresh is not evidence the sessions have gone.
      })
    return () => {
      live = false
    }
  }, [api])

  useEffect(() => refresh(), [refresh])

  useEffect(() => {
    if (!api) return
    const offCreated = api.onSessionCreated(() => refresh())
    const offExit = api.onSessionExit(() => refresh())
    return () => {
      offCreated()
      offExit()
    }
  }, [api, refresh])

  const target = resolveTarget(chosenId, sessions)

  const send = useCallback(
    (text: string): boolean => {
      const line = text.trim()
      if (!api || !line) return false
      // Resolved again at the moment of sending rather than trusting the value
      // this closure captured. The gap between rendering an enabled button and
      // pressing it is where a session exits.
      const now = resolveTarget(chosenId, sessions)
      if (!now) return false
      api.writeToSession(now.id, line)
      return true
    },
    [api, chosenId, sessions],
  )

  return {
    sessions,
    chosenId,
    choose: setChosenId,
    target,
    reason: whyDisabled(chosenId, sessions, api !== null),
    send,
    unavailable: api === null,
  }
}
