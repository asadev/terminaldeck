import { useCallback, useEffect, useMemo, useState } from 'react'
import { useCopilotNaming } from '../copilot/useCopilotNaming'
import { folderName } from '../session-title'
import { useOptionalStore } from '../state/store'
import {
  readSessions,
  resolveAgentSessions,
  resolveTarget,
  sendPayload,
  whyDisabled,
  type AgentSession,
  type AgentSessionBridge,
  type NameSource,
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
  /**
   * Put a line into the chosen session, and answer whether it landed.
   *
   * A promise, since 2026-08-20, and that is the shape of the cross-machine
   * change rather than tidiness. A send to this computer is a synchronous write
   * into a pty that cannot fail once the session has been resolved; a send to
   * another machine is a round trip that the far end can refuse — the folder was
   * unshared a minute ago, the session exited between the list and the press.
   * The caller has to be able to wait for that answer, or the button says "Sent"
   * about a line nobody received, which is the one thing this whole file exists
   * to prevent.
   *
   * `submit` appends the return that makes an agent act on it. It is off by
   * default because this hook's first caller sends *context* — an element, a
   * flow, a screenshot's description — into a session for somebody to read and
   * edit before they press Return themselves, and a `\r` there would fire off a
   * half-written prompt. The copilot's rail panel is the other kind of caller:
   * what is typed in a chat box is a message, and a message that lands on the
   * agent's command line without being sent is a box that silently did nothing.
   */
  send(text: string, options?: { submit?: boolean }): Promise<boolean>
  /**
   * What went wrong with the last send, in the far machine's own words, or
   * empty.
   *
   * Separate from {@link reason}, which is about the *choice* and is known
   * before anything is pressed. This is about the *attempt*, is known only
   * afterwards, and is cleared the moment another send starts.
   */
  problem: string
  /** The preload cannot list sessions in this build. */
  unavailable: boolean
}

/** The slice of the preload a cross-machine send needs. Feature-detected. */
interface MachineSendBridge {
  sendToMachineSession(
    machineId: string,
    sessionId: string,
    data: string,
  ): Promise<{ ok: boolean; message: string }>
}

function machineSend(): MachineSendBridge | null {
  const deck = (globalThis as { deck?: Partial<MachineSendBridge> }).deck
  return deck && typeof deck.sendToMachineSession === 'function' ? (deck as MachineSendBridge) : null
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
  const [problem, setProblem] = useState('')

  /*
   * The names the window is already using for these sessions.
   *
   * Two sources, because a session's name lives in two places in this app and
   * neither of them is the session list this picker reads.
   *
   *  - **The store**, which is where a rename typed in the rail lands and where
   *    the auto-titler writes what an agent has called itself. It is React state
   *    in this window and never reaches the main process, so `session:list`
   *    could not carry it even in principle.
   *  - **The copilot's instruction file**, read by `useCopilotNaming`. The
   *    copilot is titled from its folder like everything else, and its folder is
   *    called `copilot`, which is exactly the label he objected to.
   *
   * `useOptionalStore` rather than `useStore` for the reason `session-rename.ts`
   * gives about the same call: this hook is also mounted in tests and in the
   * harness, outside any provider, where a throwing hook is a page that will not
   * render at all rather than a page whose rows fall back to their numbers.
   */
  const store = useOptionalStore()
  const stored = store?.sessions
  const copilot = useCopilotNaming()

  /*
   * A string that changes exactly when the names or the membership do.
   *
   * `stored` is a new array on every store write — a status change, a byte of
   * output landing — so depending on the array itself would rebuild the map and
   * re-read the list several times a second. This is the same list flattened to
   * the two fields that can affect a label, which is a comparison React can do
   * with `===`.
   */
  const namesKey = (stored ?? []).map((session) => `${session.id}\u0000${session.title}`).join('\u0001')

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
  const names = useMemo<NameSource>(() => {
    const map = new Map<string, string>()
    for (const session of stored ?? []) {
      // A title that is still the folder's own name is the absence of a name,
      // and `nameOf` says so as well — but it says so about the *list's* title,
      // and this map wins over that. Leaving the folder in here would therefore
      // override the far better title the main process may have derived.
      if (session.title && session.title !== folderName(session.cwd)) {
        map.set(session.id, session.title)
      }
      // The copilot is titled from its folder like everything else, and the
      // window prints its real name everywhere it draws it. This is the one row
      // in a session list that is renamed from outside the session.
      if (copilot.root !== null && session.cwd === copilot.root) map.set(session.id, copilot.name)
    }
    return map
    // Keyed on `namesKey` rather than on `stored`, which is a fresh array on
    // every store write — a status change, a byte of output landing. The note
    // where `namesKey` is built carries the argument; this dependency list is
    // the whole reason it exists.
  }, [namesKey, copilot.root, copilot.name])

  const refresh = useCallback(() => {
    if (!api) return
    let live = true
    api
      .listSessions()
      .then((value) => {
        if (live) setSessions(readSessions(value, names))
      })
      .catch(() => {
        // Leave the last good list rather than emptying the picker under the
        // pointer. A failed refresh is not evidence the sessions have gone.
      })
    return () => {
      live = false
    }
  }, [api, names])

  useEffect(() => refresh(), [refresh])

  /*
   * What the list is re-read on — three things, and the third is the one that
   * was missing.
   *
   * `session:created` is deliberately **not** fired for a session this window
   * asked for itself: `src/main/index.ts` says so where the channel is declared,
   * because the renderer is handed the same `SessionMeta` as the return value of
   * its own call and a consumer that added a row on both would show two. Which
   * is correct for the rail, and left this picker stale for the single most
   * common way a session comes into being — somebody pressing New session.
   * Asad, 2026-08-20: *"It's not updated right away. Anyways, maybe we need to
   * refresh."* He should not have had to.
   *
   * The store is what closes it. Every session this window starts is added to it
   * on the same tick, so `namesKey` — which carries membership as well as names
   * — changes, and this effect re-reads. The push channels stay because they
   * carry the sessions this window did *not* start: another device's, the
   * copilot's, and every session on every paired machine.
   */
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

  /**
   * Put the line where the chosen row says it goes.
   *
   * Two routes, one rule: `machineId` decides which, and it is read off the row
   * at the moment of the press rather than remembered. A row on this computer is
   * `writeToSession`, unchanged since the day this picker was built. A row on a
   * paired machine is `sendToMachineSession`, which rides the `session.send`
   * verb — typing authorised by the device's folder reach, with no attach and so
   * no scrollback replayed into a terminal somebody is reading.
   *
   * The remote branch is feature-detected rather than assumed. A window running
   * against a preload older than the verb must refuse with a sentence, not throw
   * `undefined is not a function` into a click handler and leave the button
   * saying nothing at all.
   */
  const send = useCallback(
    async (text: string, options?: { submit?: boolean }): Promise<boolean> => {
      // Built once, here, so both routes carry the same bytes. See
      // {@link sendPayload} for why the return is a caller's choice.
      const line = sendPayload(text, options?.submit === true)
      if (!api || line === '') return false
      setProblem('')
      // Resolved again at the moment of sending rather than trusting the value
      // this closure captured. The gap between rendering an enabled button and
      // pressing it is where a session exits.
      const now = resolveTarget(chosenId, sessions)
      if (!now) return false
      if (now.machineId === '') {
        api.writeToSession(now.id, line)
        return true
      }
      const remote = machineSend()
      if (!remote) {
        setProblem(`This build cannot type into a session on ${now.machineName}.`)
        return false
      }
      // The far machine's own words when it refuses, because it is the only end
      // that knows why — the folder was unshared a minute ago, the pty exited
      // between the list and the press. A sentence written here would be a guess
      // about a computer this one is not on.
      const outcome = await remote
        .sendToMachineSession(now.machineId, now.id, line)
        .catch(() => ({ ok: false, message: `${now.machineName} did not answer.` }))
      if (!outcome.ok) {
        setProblem(outcome.message || `${now.machineName} refused it.`)
        return false
      }
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
    problem,
    unavailable: api === null,
  }
}
