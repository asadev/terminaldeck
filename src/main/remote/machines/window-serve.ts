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
 *
 * ## And two things this end must not assume on the way out
 *
 * Whether anybody is here — {@link WindowServeDeps.attended}, which was a
 * hardcoded `true` and a paragraph of argument for one evening — and whether the
 * answer will fit. {@link fitAnswer} at the bottom of this file holds the second,
 * and it is the more serious of the two: an uncapped page outline is over both
 * of the wire's size caps, and both of them are answered by *closing the
 * connection*. Reading a page must never be a way to lose the machine.
 */

import { SESSION_TOOLS, SESSION_TIERS } from '../../deck-control/session-tools'
import type { CallResult } from '../../deck-control/control'
import { MAX_MESSAGE_BYTES, MAX_WINDOW_RESULT_BYTES } from '../protocol'

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
  /**
   * Is there a person at *this* computer — the one whose browser is about to
   * move — right now?
   *
   * Asked, not asserted. This used to be a hardcoded `true` with a paragraph
   * arguing that a person must be there, and the paragraph is the tell: the one
   * thing `attended` decides is whether an `alter`-tier call may raise a
   * confirmation and wait for somebody to answer it, so a wrong `true` is a
   * dialog drawn at an empty desk and a browser held open until it times out.
   * `browser.step`'s first change on a public website is exactly that call.
   *
   * The honest question is whether this app has a window that could draw the
   * dialog. It is not "is somebody looking" — nothing can know that — and it is
   * deliberately not stricter than the answer a session in this window gets from
   * `session-tools.ts`, which is `true` on the same grounds: there is a window
   * on a screen. What it rules out is the case that assertion could not: this
   * app with no window at all, which on macOS is an ordinary running app and is
   * where a confirmation goes nowhere.
   */
  attended(): boolean
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
     * Asked of this computer rather than asserted about it. See
     * {@link WindowServeDeps.attended}: the one thing this decides is whether a
     * confirmation can be raised and waited on, and there is no honesty in
     * answering that from a comment.
     */
    attended: deps.attended(),
  })

  if (!result.ok) return refuse(result.error ?? 'that could not be done.')
  return fitAnswer(result.value)
}

/**
 * How much of an answer can cross, and what happens to the rest.
 *
 * ## The failure this closes
 *
 * `JSON.stringify(result.value)` used to go straight onto the wire. `browser.read`
 * builds a page outline with up to `MAX_OUTLINE_TEXT_CHARS` — forty thousand
 * characters — of the page's own words, plus every link and button on it, and
 * that does not fit. The two ends have two different caps and *both* of them end
 * the connection: `parseClientMessage` refuses a `window.result` body over
 * {@link MAX_WINDOW_RESULT_BYTES}, and before it ever gets there the frame
 * reader refuses the whole message over {@link MAX_MESSAGE_BYTES} and answers
 * `CLOSE.messageTooBig`. So a thin page worked and a real one dropped the link
 * between the two machines — the session's terminal, its file transfers and
 * everything else on it, lost to a page read.
 *
 * That must not be a possible outcome of reading a page, which is why this is a
 * truncation and not a refusal. A refusal was the original design (see
 * `MAX_WINDOW_RESULT_BYTES`) and it is the wrong half of the trade: a page too
 * big to send whole is a *normal* page, and an agent that asks for a page and is
 * told "no" learns nothing about the page.
 *
 * ## And it says so, in the answer
 *
 * A silently shortened page reading is the same class of failure as a silently
 * skipped download: the model quotes what it was given, and what it was given
 * ends in the middle of the sentence that mattered. So the value carries
 * {@link TRUNCATION_KEY} — how many characters and how many list entries were
 * dropped, and the two arguments that get them back — and the model can see that
 * it is holding part of a page.
 *
 * ## Why it shrinks fields rather than cutting the text
 *
 * Because the body is JSON and half of a JSON document does not parse; the
 * forwarding end would report *"answered with something unreadable"*, which is a
 * lost page dressed as a bug. So the *structure* is preserved and its two
 * unbounded parts — long strings, long arrays — are cut down inside it.
 */
const TRUNCATION_KEY = 'truncatedOnTheWay'

/**
 * Room left for the envelope the body travels in.
 *
 * The body is escaped into `{"t":"window.result","id":"…","ok":true,"body":"…"}`,
 * which is about sixty bytes, and the escaping itself is the part worth leaving
 * room for: every quote and newline in a page's text becomes two characters. So
 * the check below measures the *escaped* body against the frame cap rather than
 * assuming it is the same size, and this is only the fixed overhead around it.
 */
const ENVELOPE_BYTES = 512

function bytes(text: string): number {
  return Buffer.byteLength(text, 'utf8')
}

/**
 * Would this body cross both ends' caps? Both, because they measure different
 * things and either one of them closes the connection.
 */
function fits(body: string): boolean {
  if (bytes(body) > MAX_WINDOW_RESULT_BYTES) return false
  return bytes(JSON.stringify(body)) + ENVELOPE_BYTES <= MAX_MESSAGE_BYTES
}

/** What was left out, so the answer can say it. */
interface Dropped {
  chars: number
  items: number
}

/**
 * The biggest shrinkable field of an object, or null when there is none.
 *
 * "Biggest" is measured serialised, because that is the thing being cut down to
 * a size. Strings and arrays only: a number cannot be shortened and an object
 * cut in half is a shape the far end will read as fact.
 */
function fattest(value: Record<string, unknown>): string | null {
  let name: string | null = null
  let size = 0
  for (const [key, entry] of Object.entries(value)) {
    if (typeof entry !== 'string' && !Array.isArray(entry)) continue
    const entrySize = bytes(JSON.stringify(entry) ?? '')
    if (entrySize <= size) continue
    size = entrySize
    name = key
  }
  return name
}

/**
 * One answer, cut to fit if it has to be, saying what it lost.
 *
 * Exported for its own test: this is a bound on something that crosses a network
 * and is worth pinning by hand rather than through a socket.
 */
export function fitAnswer(value: unknown): WindowServed {
  const whole = JSON.stringify(value ?? null)
  if (whole !== undefined && fits(whole)) return { ok: true, body: whole }

  /*
   * Only an object can be shrunk honestly. Everything the six verbs answer with
   * is one — an outline, a `{ selector, text }`, a `{ opened }` — and a bare
   * string or array too large to send is a shape nothing here produces, so it is
   * refused with a sentence rather than mangled into a different shape than the
   * tool's own schema promises.
   */
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return refuse(
      'that answer was too large to send between the two computers. Ask again for less of it — a ' +
        '`selector` for the one part you need, or a smaller `textChars`.',
    )
  }

  const shrunk: Record<string, unknown> = { ...(value as Record<string, unknown>) }
  const dropped: Dropped = { chars: 0, items: 0 }
  /*
   * Bounded, because a loop that cuts a fraction each time converges but is
   * still a loop over somebody else's data. Sixty-four halvings of the largest
   * field takes any real page under the cap many times over; the exit below is
   * for the shape nobody has thought of yet.
   */
  for (let step = 0; step < 64; step += 1) {
    shrunk[TRUNCATION_KEY] = note(dropped)
    const body = JSON.stringify(shrunk)
    if (body !== undefined && fits(body)) return { ok: true, body }
    const key = fattest(shrunk)
    if (key === null || key === TRUNCATION_KEY) break
    const entry = shrunk[key]
    if (typeof entry === 'string') {
      // Two thirds each pass rather than a computed cut: a character is not a
      // byte and escaping is not a fixed cost, so the honest way to hit a byte
      // budget is to cut and measure.
      const kept = Math.floor(entry.length * 0.66)
      dropped.chars += entry.length - kept
      shrunk[key] = entry.slice(0, kept)
    } else if (Array.isArray(entry)) {
      const kept = Math.floor(entry.length * 0.66)
      dropped.items += entry.length - kept
      shrunk[key] = entry.slice(0, kept)
    } else {
      break
    }
  }

  return refuse(
    'that answer was too large to send between the two computers, and could not be shortened. Ask ' +
      'again for less of it — a `selector` for the one part you need, or a smaller `textChars`.',
  )
}

/** The sentence the model reads beside a page it is only holding part of. */
function note(dropped: Dropped): Record<string, unknown> {
  return {
    message:
      'This answer was too large to send between the two computers, so part of it was left out on the ' +
      'way. The page itself is unchanged. Ask again with a `selector` for the part you need, or a ' +
      'smaller `textChars`, and do not treat what is here as the whole page.',
    charactersDropped: dropped.chars,
    entriesDropped: dropped.items,
  }
}
