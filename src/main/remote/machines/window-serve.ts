/**
 * A browser verb arriving from another machine, and the two questions asked of
 * it before this app's browser moves.
 *
 * ## What this is for
 *
 * Asad, 2026-08-21, after testing 0.9.1:
 *
 * > *"i need full capability for all sessions to drive browsers the ones they
 * > open or the ones we connect to the session"*
 *
 * and, of the case he hit:
 *
 * > *"even if I open a browser in the same remote device and also browser is in
 * > the remote device like the same machine and I select open a session also in
 * > the remote device but they cannot even connect to each other if I am driving
 * > them from another device as a remote"*
 *
 * The relation was never broken. The window and the session really were attached
 * to each other, under exactly the key `browser-binding.ts` describes:
 * `<machineId>\0<sessionId>`, machine id being his PC. What was missing is that
 * the two halves of *acting* on that relation were on two computers. The window
 * object is a `WebContentsView` in the renderer of the app he is looking at —
 * always, in every arrangement, because that is the only app with a screen in
 * front of him. The session's tools are on the machine the pty is on. Nothing
 * carried a verb from the second to the first.
 *
 * `remote/protocol.ts`'s `window.call` is that wire, and this is the end of it
 * that decides. The far machine forwards; **this** end — the one whose browser
 * it is — is where the grant, the binding lookup and every tier check live.
 *
 * ## The two questions, in this order
 *
 *  1. **May that machine ask at all?** {@link WindowServeDeps.allowed}, read per
 *     call. A machine paired here, whose folders and sessions this desktop can
 *     reach, has not thereby been handed the browser on this screen — see
 *     `MachineStore.drivesWindows` for why windows are their own axis and why
 *     that axis defaults closed.
 *  2. **Is that verb one of the six?** {@link SESSION_TOOLS}, the same positive
 *     list a session on this machine holds on its own token. Checked here as
 *     well as by `server.ts`'s `allowed` predicate, because this path does not
 *     go through `server.ts` at all: it reaches `DeckControl.call` directly, so
 *     the allow-list has to be applied by whoever is doing the reaching. A
 *     forwarded caller that could name `sessions.start` would be the one hole
 *     that makes *"driving other sessions is only for the copilot"* untrue.
 *
 * Everything after that is `deck-control`'s: the tool's own `precheck` resolves
 * the window inside that session's binding and finds nothing for a window
 * belonging to anybody else, the tier table decides whether a person is asked,
 * the budgets apply, and the row lands in `actions.jsonl` with the machine
 * recorded on it. None of that is re-implemented here and none of it may be —
 * a second dispatcher is how one of them comes to allow what the other refuses.
 *
 * ## What is deliberately refused even when everything is allowed
 *
 * `browser.screenshot`. It writes a PNG into this machine's copilot folder and
 * answers with the *path*, which is a file the asking session cannot open: it is
 * on the wrong computer. Returning it would be a tool that reports success and
 * hands back nothing usable — the dead control this round is about, wearing a
 * green tick. So it is refused with the sentence that says why and names the
 * verb that does work across the wire.
 */

import { SESSION_TOOLS, SESSION_TIERS } from '../../deck-control/session-tools'
import type { CallResult } from '../../deck-control/control'

/** What one forwarded call carries. */
export interface WindowCall {
  /** The far machine's own id for the session that is asking. */
  sessionId: string
  /** A tool id or its wire name — both spellings are on {@link SESSION_TOOLS}. */
  tool: string
  /** Its arguments, as the JSON text that crossed the wire. */
  args: string
}

export interface WindowServeDeps {
  /**
   * May sessions on this machine act on windows here? Asked per call.
   *
   * A function rather than a boolean captured when the link came up, for the
   * reason `callers.ts` gives about `TokenGrant.caller`: a person unticking the
   * grant must land on the very next call, not on the next reconnection.
   */
  allowed(machineId: string): boolean
  /**
   * The dispatcher, or null before `deck-control` has finished starting.
   *
   * Null is a real state and gets its own sentence rather than a generic
   * failure: the control server binds a few hundred milliseconds after the
   * window is built, and a machine that reconnects inside that window would
   * otherwise be told something untrue about itself.
   */
  control(): {
    call(
      name: string,
      args: unknown,
      options: { caller: { kind: 'session'; sessionId: string; machineId: string; tiers: typeof SESSION_TIERS }; attended: boolean },
    ): Promise<CallResult>
  } | null
}

/** The answer shape `guest.ts` puts straight into a `window.result`. */
export interface WindowServed {
  ok: boolean
  body: string
}

/**
 * One sentence, wrapped the way a refusal crosses the wire.
 *
 * `ok: false` with a `message` is what `browser-tools.ts` on the other side
 * turns back into an MCP tool error, so a refusal composed here reads to the
 * model exactly like one composed by the tool itself. That sameness is the
 * point: an agent must not be able to tell "this was refused over there" from
 * "this was refused here", because the two are the same fact — it may not do
 * that — and a difference would be something to probe at.
 */
function refuse(message: string): WindowServed {
  return { ok: false, body: JSON.stringify({ message }) }
}

/**
 * The verb that cannot cross, and the one it points at instead.
 *
 * Named as a set rather than as an `if` so that the next tool with a
 * machine-local answer — a download, a file the person picks — is added to a
 * list somebody reads rather than to a condition somebody misses.
 */
const NOT_ACROSS_THE_WIRE: ReadonlyMap<string, string> = new Map([
  [
    'browser.screenshot',
    'browser.screenshot writes the picture on the computer the browser window is on, so the path it ' +
      'answers with is not a file you can open. Use browser.read: the outline is what tells you what to ' +
      'click, and a picture is not.',
  ],
])

/**
 * Decide and act on one forwarded verb. Never throws.
 *
 * Every failure comes back as `ok: false` and a sentence, because the caller is
 * a socket handler answering a tool call somebody's turn is blocked on: a
 * rejection here would leave that turn waiting out a deadline for an answer that
 * already exists.
 */
export async function serveWindowCall(
  deps: WindowServeDeps,
  machineId: string,
  call: WindowCall,
): Promise<WindowServed> {
  if (!deps.allowed(machineId)) {
    /*
     * The refusal names the switch and where it is, because this is the one
     * refusal on this path a person can do something about — and an agent told
     * only "no" will try another way in, which is the measured behaviour
     * `session-verbs.ts` exists to stop.
     */
    return refuse(
      'this machine is not allowed to act on browser windows on the computer that holds them. The ' +
        'person can turn that on for this machine in Machines, beside its name. Say what you would ' +
        'have done on the page and let them do it.',
    )
  }

  const wall = NOT_ACROSS_THE_WIRE.get(call.tool)
  if (wall !== undefined) return refuse(wall)

  if (!SESSION_TOOLS.has(call.tool)) {
    /*
     * Deliberately the same words a browser verb gets for naming a window that
     * is not its own. A sentence saying *"that tool exists but not for you"*
     * would confirm the catalogue to a caller that was told it holds six verbs,
     * and "should not be able to find it also" is a weaker property than
     * "cannot use it", not a stronger one.
     */
    return refuse('there is no such tool here.')
  }

  let args: unknown
  try {
    args = JSON.parse(call.args)
  } catch {
    return refuse('those arguments were not readable.')
  }

  const control = deps.control()
  if (control === null) {
    return refuse(
      'this computer’s control endpoint is not running yet. Try again in a moment; it comes up shortly ' +
        'after the app window does.',
    )
  }

  const result = await control.call(call.tool, args, {
    caller: {
      kind: 'session',
      sessionId: call.sessionId,
      /*
       * The key's other half, supplied by the end that knows it.
       *
       * The far machine sent its own id for the session and cannot know what
       * this desktop calls the machine it is on — the link id is minted here, on
       * pairing. Pairing the two produces exactly `<machineId>\0<sessionId>`,
       * which is the key the binding was written under when the person attached
       * the window from this app. Neither end holds the whole key and neither
       * has to.
       */
      machineId,
      tiers: SESSION_TIERS,
    },
    /*
     * Attended, and for the reason a session's own token is: the person is at
     * *this* computer, looking at the window this call is about, and a
     * confirmation can be drawn where they are looking. That it was a session on
     * another machine that asked does not change where the browser is.
     */
    attended: true,
  })

  return result.ok
    ? { ok: true, body: JSON.stringify(result.value ?? null) }
    : refuse(result.error ?? 'that could not be done.')
}
