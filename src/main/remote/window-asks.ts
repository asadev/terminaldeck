/**
 * This machine's sessions asking a paired device to act on a browser window it
 * holds, and the desk that keeps those questions straight.
 *
 * ## Why a session here asks a device there
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
import type { ServerMessage } from './protocol'

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
   * Put the frame to that device on every channel it is on, and say how many
   * heard it.
   *
   * Zero is the answer this file turns into a sentence rather than a wait. A
   * device that is asleep, gone, or running a build that has never heard of
   * `window.call` is not reachable, and the check for the last of those is what
   * keeps an old client from becoming a fifty-five second stall.
   */
  ask(deviceId: string, message: ServerMessage): number
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
