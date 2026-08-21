import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useCopilotNaming } from '../copilot/useCopilotNaming'
import { useOptionalStore } from '../state/store'
import {
  namesFrom,
  readSessions,
  resolveAgentSessions,
  resolveTarget,
  sendPayload,
  submitLine,
  whyDisabled,
  type AgentServerShell,
  type AgentSession,
  type AgentSessionBridge,
  type NameSource,
  type SendOutcome,
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

/** The slice a send to a terminal on a server needs. Feature-detected the same way. */
interface ServerSendBridge {
  writeToServerShell(shellId: string, data: string): Promise<unknown>
}

function serverSend(): ServerSendBridge | null {
  const deck = (globalThis as { deck?: Partial<ServerSendBridge> }).deck
  return deck && typeof deck.writeToServerShell === 'function' ? (deck as ServerSendBridge) : null
}

/**
 * `servers:shell:write` answers `{ written: boolean }` and nothing else.
 *
 * There is no sentence to carry back, and inventing one here would be this
 * machine guessing about somebody's server. The only two things that make it
 * false are a shell id the main process has no channel for and a non-string
 * argument, and both mean the same thing to the person: that terminal is gone.
 */
function wroteToServer(answer: unknown, serverName: string): SendOutcome {
  const written =
    typeof answer === 'object' && answer !== null && (answer as { written?: unknown }).written === true
  return written ? { ok: true } : { ok: false, message: `That terminal on ${serverName} is no longer open.` }
}

export function useAgentTarget(
  bridge?: AgentSessionBridge | null,
  /**
   * The shells this window has open on servers.
   *
   * A parameter rather than something read off the preload, because there is
   * nothing over there to read: a server runs no copy of this app, so the shells
   * exist only as long as this window holds their connections and this window's
   * own list is the whole truth. `App.tsx` owns that list and hands it down.
   * Absent — every test, and any host that has no servers area — is an empty
   * list, which lists nothing rather than failing to list something.
   */
  servers: readonly AgentServerShell[] = [],
): AgentTarget {
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
   * Two sources — the store, and the copilot's instruction file by way of
   * `useCopilotNaming` — and the rule for combining them is `namesFrom` in
   * `agent-target.ts`, where it can be tested. This hook only supplies them.
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
   * The shells on servers, flattened to what can change a row.
   *
   * Same argument as `namesKey` one line up: `servers` is an array the window
   * rebuilds on every render that touches it, so depending on the array itself
   * would re-read the session list on renders that changed nothing about it.
   */
  const serversKey = servers
    .map((shell) => `${shell.tabId}\u0000${shell.shellId}\u0000${shell.serverName}\u0000${shell.startIn}\u0000${shell.ended}`)
    .join('\u0001')

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
  const names = useMemo<NameSource>(
    () => namesFrom(stored ?? [], copilot),
    // Keyed on `namesKey` rather than on `stored`, which is a fresh array on
    // every store write — a status change, a byte of output landing. The note
    // where `namesKey` is built carries the argument; this dependency list is
    // the whole reason it exists.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [namesKey, copilot.sessionId, copilot.name],
  )

  /*
   * The same list, in a ref.
   *
   * `refresh` is rebuilt on `serversKey` and deliberately not on `servers`,
   * which is a fresh array on renders that changed nothing about it. This is
   * what a callback that survived one of those reads, so it still sees the
   * current array rather than the one it closed over.
   */
  const shells = useRef(servers)
  shells.current = servers

  const refresh = useCallback(() => {
    if (!api) return
    let live = true
    api
      .listSessions()
      .then((value) => {
        if (live) setSessions(readSessions(value, names, shells.current))
      })
      .catch(() => {
        // Leave the last good list rather than emptying the picker under the
        // pointer. A failed refresh is not evidence the sessions have gone.
      })
    return () => {
      live = false
    }
    // `serversKey` rather than `servers`: the array is rebuilt on renders that
    // changed nothing about it, and re-reading the whole list on each of those
    // would be an IPC round trip per keystroke somewhere else in the window.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [api, names, serversKey])

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
   * One chunk of characters into the chosen session, wherever it is.
   *
   * Three routes, one rule: the row says which, and it is read off the row at
   * the moment of the press rather than remembered.
   *
   *  - **This computer** — `writeToSession`, unchanged since the day this picker
   *    was built, and the only one of the three that cannot fail once the
   *    session has resolved.
   *  - **A paired machine** — `sendToMachineSession`, which rides the
   *    `session.send` verb: typing authorised by the device's folder reach, with
   *    no attach and so no scrollback replayed into a terminal somebody is
   *    reading.
   *  - **A terminal on a server** — `writeToServerShell`, the same channel the
   *    terminal pane itself types through, addressed by the handle the server
   *    answered `servers:shell:open` with.
   *
   * Every one of the three is feature-detected rather than assumed. A window
   * running against a preload older than one of these channels must refuse with
   * a sentence, not throw `undefined is not a function` into a click handler and
   * leave the button saying nothing at all.
   */
  const writeOne = useCallback(
    async (target: AgentSession, data: string): Promise<SendOutcome> => {
      if (!api) return { ok: false, message: 'This build cannot type into your sessions.' }
      if (target.serverId !== '') {
        const server = serverSend()
        if (!server) {
          return { ok: false, message: `This build cannot type into a terminal on ${target.machineName}.` }
        }
        const answer = await server.writeToServerShell(target.shellId, data).catch(() => null)
        return wroteToServer(answer, target.machineName)
      }
      if (target.machineId === '') {
        api.writeToSession(target.id, data)
        return { ok: true }
      }
      const remote = machineSend()
      if (!remote) {
        return { ok: false, message: `This build cannot type into a session on ${target.machineName}.` }
      }
      // The far machine's own words when it refuses, because it is the only end
      // that knows why — the folder was unshared a minute ago, the pty exited
      // between the list and the press. A sentence written here would be a guess
      // about a computer this one is not on.
      const outcome = await remote
        .sendToMachineSession(target.machineId, target.id, data)
        .catch(() => ({ ok: false, message: `${target.machineName} did not answer.` }))
      return outcome.ok
        ? { ok: true }
        : { ok: false, message: outcome.message || `${target.machineName} refused it.` }
    },
    [api],
  )

  /**
   * Put the line into the chosen session **and press Return on it**.
   *
   * The second half of that sentence is the whole of the 2026-08-21 change. This
   * used to be one `writeToSession(now.id, line)` with no carriage return at
   * all, so a send left the composed line typed and unsent in the target
   * session's prompt box and the agent never saw it. Asad, having pressed Send
   * and then walked over to the session to find it sitting there: *"it should
   * not be waiting us to come and send… Just make it like this send actually
   * send and pushed inside the session also."*
   *
   * Appending `\r` would not have fixed it. `submitLine` carries the measurement
   * — a stdin chunk of 64 bytes or more is read as pasted text, where a carriage
   * return is a newline — and every line this picker composes is over that,
   * because every one of them carries a path and a pixel size. So it is two
   * writes with a real gap between them, through whichever of the three routes
   * the row names.
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
      const outcome = await submitLine(line, (data) => writeOne(now, data))
      if (!outcome.ok) {
        setProblem(outcome.message)
        return false
      }
      return true
    },
    [api, chosenId, sessions, writeOne],
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
