/**
 * This machine's sessions asking a paired computer to act on a browser window it
 * holds, and the desk that keeps those questions straight.
 *
 * ## One desk, both directions
 *
 * Nothing in this file knows which end of a link it is on. It takes a peer id, a
 * session id and a verb; it starts a clock; it hands back whatever came. So the
 * app builds **two** of these and they differ only in the wire they are handed:
 *
 *  - one for the devices connected *to* this app's host, whose ids are device
 *    ids and whose wire is a connection in `server.ts`;
 *  - one for the machines this app dials *out* to, whose ids are machine ids and
 *    whose wire is a link in `machines/ipc.ts`.
 *
 * The second exists because the arrangement is not always the one the first
 * assumes. A desktop that dialled out watches the far machine's sessions and
 * attaches its own windows to them — that is the first desk's case, read from
 * the far machine — and the mirror is a session *here* whose window is in the
 * app over there. Same conversation, ends swapped; see `CAPABILITY.hostWindows`.
 *
 * The parameter below is still called `deviceId`, and that is deliberate rather
 * than left over: renaming it would be a rename in four files for a word that
 * means the same thing in both — *the peer that holds the window* — and the ids
 * are opaque to everything here. What must never happen is one desk being handed
 * the other's ids, which is why each is constructed beside the wire that mints
 * them.
 *
 * ## Why a session here asks a computer there
 *
 * A browser window is a `WebContentsView` in the renderer of the app somebody is
 * looking at. When Asad starts a session on his PC *from his Mac* and attaches a
 * browser window to it, the relation is written on the Mac — that is where the
 * window object is — and the pty is on the PC. So the session's browser verbs
 * run on a machine that does not hold the window, and until this file existed
 * they answered *"no window by that name"* about a page the person could see:
 *
 * > *"even if I open a browser in the same remote device and also browser is in
 * > the remote device like the same machine and I select open a session also in
 * > the remote device but they cannot even connect to each other if I am driving
 * > them from another device as a remote"*
 *
 * This is the asking half. `remote/machines/window-serve.ts` is the answering
 * half, on the machine whose browser it is, and every decision — the grant, the
 * binding lookup, the tier, the confirmation, the log — is made there. Nothing
 * here decides anything: it addresses a device, starts a clock, and hands back
 * whatever came.
 *
 * ## Why the device is not chosen here either
 *
 * A call names a session, and the session was started *by* a device — that is
 * the whole reason it has a window somewhere else. So the caller supplies the
 * device id along with the session id, taken from the record made when the
 * session was created, and this file never guesses. Guessing would mean sending
 * a session's page-read to whichever device happened to be connected.
 *
 * ## The two deadlines, and why the shorter one is not a retry
 *
 * `credentials.ts` next door answers the same problem with an ack and two
 * clocks, because it is waiting on a *human*. This is waiting on an app, so
 * there is one clock — but it is still not the tool client's clock, and that is
 * the point of {@link WINDOW_ASK_TIMEOUT_MS}: it is set under the sixty seconds
 * an MCP client allows a call, so a device that has gone to sleep produces a
 * sentence in this app's own words rather than a timeout in the model's.
 */

import { randomUUID } from 'node:crypto'
import { MAX_WINDOW_HOLDS, type WindowCallFrame } from './protocol'

/**
 * How long a forwarded verb waits for the machine holding the window.
 *
 * Under the sixty seconds an MCP client allows a tool call, and comfortably over
 * the one verb here that waits on a person: `browser.handover` returns after
 * about forty-five seconds by design, with `resumed: false` meaning *"they are
 * still working"*. A deadline under that would turn this app's most patient
 * control into one that always appears to fail.
 */
export const WINDOW_ASK_TIMEOUT_MS = 55_000

/** What one answer looks like, whichever way it went. */
export interface WindowAnswer {
  ok: boolean
  /** JSON text: the tool's value, or `{ "message": "…" }` for a refusal. */
  body: string
}

/** How this desk reaches the devices. Injected by `server.ts`. */
export interface WindowWire {
  /**
   * Put the frame to that peer on every channel it is on, and say how many heard
   * it.
   *
   * Zero is the answer this file turns into a sentence rather than a wait. A
   * peer that is asleep, gone, or running a build that has never heard of
   * `window.call` is not reachable, and the check for the last of those is what
   * keeps an old build from becoming a fifty-five second stall.
   *
   * Typed to the one frame this desk ever sends rather than to a direction's
   * whole union, which is what lets the same desk serve both directions:
   * `server.ts` puts it on a connection as a `ServerMessage` and `ipc.ts` puts
   * it on a machine link as a `ClientMessage`, and neither of those is this
   * file's business.
   */
  ask(deviceId: string, message: WindowCallFrame): number
  /**
   * Could {@link ask} reach that device right now, without sending anything?
   *
   * The same two conditions `ask` applies — a live channel to that device, on a
   * build that advertised `windows` — asked ahead of time by the launch gate.
   * Separate from `ask` rather than an `ask` with no message, because a probe
   * that put a frame on a socket would be a launch writing to somebody's
   * network.
   */
  reaches(deviceId: string): boolean
}

/** What `server.ts` needs from a desk, so a test can supply another. */
export interface WindowAskDesk {
  /**
   * Hand this desk the way to reach the devices.
   *
   * Late rather than at construction, and the shape is `credentials.ts`'s
   * exactly: the desk is built by the assembly — it is what `deck-control`'s
   * browser tools forward through, so it has to exist before the remote endpoint
   * does — while the live connections belong to the endpoint, which is built
   * after. Called once; a second call replaces the wire, which is what a restart
   * of the endpoint does.
   */
  serve(wire: WindowWire): void
  /**
   * That device has told us it is holding browser windows for these sessions of
   * ours. The list replaces whatever it said last.
   *
   * ## Why the device says so rather than this machine working it out
   *
   * Until this existed, the only sessions whose windows could be reached were
   * the ones a device had *started* — `window-owner.ts` writes that down at the
   * spawn, because that is the one moment the device id and the session id are
   * both in hand. It is a true fact and it is the wrong question. Asad attaches
   * a browser window in his Mac's app to a session already running on his PC —
   * one he started at that keyboard, or one that came back with a restore — and
   * the PC has no spawn to have recorded. Every verb from it was served on the
   * PC, resolved in the PC's own empty map, and answered *"no browser window is
   * attached to this session"* about a page he was looking at.
   *
   * Nothing on this machine can know that. The relation is a `WebContentsView`
   * and a `Map` in the *other* app's process — see `browser-binding.ts`, which
   * writes it under `<machineId>\0<sessionId>` where the machine id is this
   * computer as that app knows it. So the fact travels: the app that holds the
   * window says which of this machine's sessions it is holding one for, on the
   * `windows` capability it already advertises, and re-says it on every welcome
   * because a reconnection is the ordinary state of a link rather than an error.
   *
   * ## Why a whole list rather than "attached"/"detached"
   *
   * A delta needs both ends to have seen every message ever sent. This one is
   * idempotent: a link that dropped and came back sends its set again and the
   * two ends agree, with nothing to reconcile and no way to drift. It is also
   * how a *detach* arrives — the session simply stops being on the list.
   */
  held(deviceId: string, sessions: readonly string[]): void
  /**
   * Which devices say they hold a browser window for this session, newest claim
   * last. Empty when nobody does.
   *
   * A list rather than one device, because two paired machines can each attach a
   * window of their own to one session here and neither of them is wrong. The
   * caller — `index.ts`'s forwarder — is what decides that a verb with two
   * possible destinations is refused with a sentence rather than sent to a guess.
   */
  holdersOf(sessionId: string): string[]
  /**
   * Is there a live channel to that device that can serve a browser verb at all?
   *
   * Asked at *launch*, by the gate in `host-core.ts` that decides whether a
   * session started for a device is given the six verbs. A phone is the case it
   * exists for: it is connected, it holds no browser windows and its client has
   * never heard of `window.call`, so handing its session the verbs produces six
   * tools that answer *"the computer holding that browser window is not
   * connected right now"* about a device that is sitting there connected. The
   * honest answer is the one it had before — no verbs, and a sentence saying
   * why.
   *
   * It is a snapshot and cannot be anything else: the device may go before the
   * first call. That is fine and is a different sentence, composed per call.
   * What this rules out is the case that is already decided at exec time.
   */
  reaches(deviceId: string): boolean
  /** Ask the device that started this session to act on its window. */
  call(input: {
    deviceId: string
    sessionId: string
    tool: string
    args: string
  }): Promise<WindowAnswer>
  /** A `window.result` arrived. False when nothing was waiting for it. */
  answer(id: string, result: WindowAnswer): boolean
  /**
   * That device's channel has gone.
   *
   * Every question outstanding to it is settled now, with a sentence, rather
   * than left to the deadline. A tool call that could be answered in
   * milliseconds must not spend fifty-five seconds finding out the device hung
   * up — which is the same argument `TokenGrant.signal` makes about a caller
   * going away, read from the other end.
   */
  gone(deviceId: string): void
  /** Settle everything, for shutdown. Test seam too. */
  stop(): void
  /** How many questions are outstanding. For diagnostics and for the tests. */
  readonly waiting: number
}

interface Pending {
  deviceId: string
  settle(answer: WindowAnswer): void
  timer: NodeJS.Timeout
}

function refusal(message: string): WindowAnswer {
  return { ok: false, body: JSON.stringify({ message }) }
}

export function createWindowAsks(options: { timeoutMs?: number } = {}): WindowAskDesk {
  const timeoutMs = options.timeoutMs ?? WINDOW_ASK_TIMEOUT_MS
  const pending = new Map<string, Pending>()
  /**
   * deviceId → the sessions of ours that device says it holds a window for.
   *
   * Keyed by device rather than by session so that one frame replaces one
   * device's whole answer, which is what makes a detach arrive at all — see
   * {@link WindowAskDesk.held}.
   *
   * Nothing is dropped when a device disconnects, and that is deliberate. A
   * laptop that closed its lid still has the window attached to it, and the
   * sentence for a verb sent there is *"that computer is not connected right
   * now"* — which is true, actionable and composed per call. Forgetting instead
   * would answer *"no browser window is attached to this session"*, which is
   * false and is the exact sentence this whole round exists to stop. The entry
   * is replaced on the device's next welcome.
   */
  const holders = new Map<string, readonly string[]>()
  let wire: WindowWire | null = null

  function finish(id: string, answer: WindowAnswer): boolean {
    const entry = pending.get(id)
    if (entry === undefined) return false
    pending.delete(id)
    clearTimeout(entry.timer)
    entry.settle(answer)
    return true
  }

  return {
    serve(next: WindowWire): void {
      wire = next
    },
    held(deviceId: string, sessions: readonly string[]): void {
      if (deviceId === '') return
      /*
       * An empty list is a real answer — "I have detached the last one" — and it
       * is kept as an empty entry rather than deleted, so that a device saying
       * nothing and a device saying none are the same thing to every reader.
       */
      holders.set(deviceId, [...sessions].slice(0, MAX_WINDOW_HOLDS))
    },
    holdersOf(sessionId: string): string[] {
      if (sessionId === '') return []
      const out: string[] = []
      for (const [deviceId, sessions] of holders) {
        if (sessions.includes(sessionId)) out.push(deviceId)
      }
      return out
    },
    reaches(deviceId: string): boolean {
      return deviceId !== '' && (wire?.reaches(deviceId) ?? false)
    },
    call({ deviceId, sessionId, tool, args }): Promise<WindowAnswer> {
      const id = randomUUID()
      return new Promise<WindowAnswer>((settle) => {
        const timer = setTimeout(() => {
          pending.delete(id)
          settle(
            refusal(
              'the computer holding that browser window did not answer. It may be asleep or the app may ' +
                'be closed there. Say what you would have done on the page and let the person do it.',
            ),
          )
        }, timeoutMs)
        // Unreferenced, so a question nobody answers can never be the reason the
        // process will not exit.
        timer.unref?.()
        pending.set(id, { deviceId, settle, timer })

        const heard =
          wire?.ask(deviceId, { t: 'window.call', id, session: sessionId, tool, args }) ?? 0
        if (heard === 0) {
          /*
           * Refused in milliseconds rather than waited out.
           *
           * `credentials.ts` makes this argument first and it is the same one: a
           * question nobody can hear is not a slow question, and a feature that
           * takes a minute to say "your other computer is not here" is a feature
           * people stop trusting.
           */
          finish(
            id,
            refusal(
              'the computer holding that browser window is not connected right now. Say what you would ' +
                'have done on the page and let the person do it.',
            ),
          )
        }
      })
    },
    answer(id: string, result: WindowAnswer): boolean {
      return finish(id, result)
    },
    gone(deviceId: string): void {
      for (const [id, entry] of [...pending]) {
        if (entry.deviceId !== deviceId) continue
        finish(
          id,
          refusal(
            'the computer holding that browser window disconnected before it answered. Say what you ' +
              'would have done on the page and let the person do it.',
          ),
        )
      }
    },
    stop(): void {
      for (const id of [...pending.keys()]) {
        finish(id, refusal('this app is shutting down.'))
      }
    },
    get waiting(): number {
      return pending.size
    },
  }
}
