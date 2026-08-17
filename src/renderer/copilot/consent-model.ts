/**
 * The alter-tier question, as a person has to be able to read it.
 *
 * `src/main/deck-control/consent.ts` owns the gate: it holds the pending
 * questions, the clock, and the rule that every path except a human pressing
 * Allow resolves to a refusal. This file owns nothing about the decision. It
 * turns the question into the four things somebody needs in order to answer it:
 *
 *   **what** is being asked, **who** is asking, **with what arguments**, and
 *   **what happens if you say nothing.**
 *
 * All four are stated because a permission prompt that omits any of them is one
 * people clear by reflex, which is the state in which a permission system has
 * stopped working. The fourth is the one usually left out and the one that
 * matters most here: this dialog *expires*, and it expires into a refusal. A
 * person who walks away has not deferred the decision, they have made it — so
 * the dialog says so, and it counts down in front of them rather than
 * disappearing with an outcome they never saw.
 *
 * Everything here is a pure function so the countdown, the argument rendering
 * and the refusal sentences are testable without a DOM — which this project has
 * none of, on purpose.
 */

/* ------------------------------------------------------------------ shapes -- */

/** Mirrors `Tier` in `src/main/deck-control/surface.ts`. */
export type Tier = 'read' | 'act' | 'alter'

/** Mirrors `ConsentRequest`. Everything is already scrubbed for display. */
export interface ConsentRequestView {
  id: string
  tool: string
  tier: Tier
  summary: string
  args: Record<string, unknown>
  requestedAt: number
  expiresAt: number
}

/** Mirrors `RefusalReason`, as the settled push delivers it. */
export type RefusalReason =
  | 'no-approver'
  | 'declined'
  | 'timeout'
  | 'approver-gone'
  | 'shutting-down'
  | 'caller-gone'
  | 'too-many-pending'
  | 'not-permitted-unattended'
  | 'rate-limited'
  | 'not-permitted'
  | 'not-granted'

export interface ConsentSettledView {
  id: string
  granted: boolean
  reason: RefusalReason | null
  /**
   * Which surface answered it: `'window'`, `device:<id>`, or null for nobody.
   *
   * The dialog on this Mac is no longer the only place a confirmation can be
   * answered — a device with its own copilot connection can answer its own run's
   * questions, and first answer wins. So when this dialog closes without the
   * person having pressed anything, it has to be able to say *where the answer
   * came from* rather than vanishing. A dialog that disappears on its own
   * teaches a person that the app does things behind their back.
   *
   * The device id itself is deliberately not rendered. It is opaque, it means
   * nothing to a person reading it, and the Activity pane is where a row can be
   * resolved to a device by name.
   */
  by: string | null
}

/* --------------------------------------------------------------- narrowing -- */

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

const TIERS: readonly Tier[] = ['read', 'act', 'alter']

/**
 * A request, or null when what arrived is not one.
 *
 * Strict, and much stricter than the copilot-state reader beside it, because
 * the failure modes are not comparable. A half-read state draws a pane with a
 * field missing; a half-read consent request draws a dialog that asks somebody
 * to approve something it cannot name. Every field an answer depends on —
 * the id, the tool, the tier, the sentence, the deadline — is required, and a
 * request missing any of them is dropped rather than shown.
 */
export function readConsentRequest(value: unknown): ConsentRequestView | null {
  const source = record(value)
  if (!source) return null
  const { id, tool, tier, summary, requestedAt, expiresAt } = source
  if (typeof id !== 'string' || id === '') return null
  if (typeof tool !== 'string' || tool === '') return null
  if (typeof tier !== 'string' || !TIERS.includes(tier as Tier)) return null
  if (typeof summary !== 'string' || summary === '') return null
  if (typeof requestedAt !== 'number' || !Number.isFinite(requestedAt)) return null
  if (typeof expiresAt !== 'number' || !Number.isFinite(expiresAt)) return null
  return {
    id,
    tool,
    tier: tier as Tier,
    summary,
    args: record(source.args) ?? {},
    requestedAt,
    expiresAt,
  }
}

export function readConsentSettled(value: unknown): ConsentSettledView | null {
  const source = record(value)
  if (!source) return null
  if (typeof source.id !== 'string' || source.id === '') return null
  const outcome = record(source.outcome)
  if (!outcome) return null
  const reason = outcome.reason
  return {
    id: source.id,
    granted: outcome.granted === true,
    reason: typeof reason === 'string' ? (reason as RefusalReason) : null,
    by: typeof outcome.by === 'string' ? outcome.by : null,
  }
}

/* ------------------------------------------------------------------- words -- */

/**
 * What the copilot is asking to do, in a heading.
 *
 * The tool's own `title` when the window has the catalogue — `deck-control:status`
 * carries one per tool — and the dotted id otherwise. The id is a poor heading
 * and it is never a *wrong* one, which is the property that matters: a dialog
 * that has not managed to read the catalogue must still say which tool, exactly,
 * is being approved.
 */
export function toolHeading(tool: string, titles: Readonly<Record<string, string>>): string {
  return titles[tool] ?? tool
}

/**
 * The arguments, flattened into rows a dialog can lay out.
 *
 * Objects and arrays are rendered as compact JSON rather than expanded into a
 * tree. Two reasons, and the second is the important one. A tree in a
 * confirmation dialog invites scrolling, and a value that has to be scrolled to
 * is a value nobody read. And these are already scrubbed by
 * `action-log.ts`'s `scrubArgs`, so what arrives is small by construction — a
 * settings patch, a session id, a line of text. Anything genuinely large would
 * be a bug on the far side rather than a layout problem here.
 *
 * The order is the object's own. The tools build these argument objects in the
 * order their schema declares, so following it keeps the dialog reading the way
 * the tool's own documentation does.
 */
export interface ArgRow {
  name: string
  value: string
}

export function argRows(args: Record<string, unknown>): ArgRow[] {
  return Object.entries(args).map(([name, value]) => ({ name, value: renderArg(value) }))
}

function renderArg(value: unknown): string {
  if (typeof value === 'string') return value
  if (value === null) return 'null'
  if (value === undefined) return 'not set'
  try {
    return JSON.stringify(value)
  } catch {
    // A cyclic or otherwise unserialisable value. It cannot have come from the
    // JSON that crossed the bridge, so this is unreachable in practice — and
    // saying so beats printing "[object Object]" next to a request to change
    // somebody's settings.
    return 'unreadable'
  }
}

/**
 * Seconds left before the question refuses itself, floored at zero.
 *
 * Seconds and not a progress bar: the number is the fact, and a bar makes a
 * deadline look like a loading state. Floored rather than allowed to go negative
 * because the settled push and the clock do not arrive in a guaranteed order —
 * a dialog one frame past its deadline should read "0s", not "-1s".
 */
export function secondsLeft(request: ConsentRequestView, now: number): number {
  return Math.max(0, Math.ceil((request.expiresAt - now) / 1000))
}

/**
 * What happens if nobody answers, said in the dialog rather than discovered
 * afterwards.
 *
 * One sentence, and it names the outcome rather than the mechanism: "refused"
 * is what the copilot will be told, and it is the word the action log will use.
 */
export function timeoutSentence(seconds: number): string {
  if (seconds <= 0) return 'Time is up — this is being refused.'
  return `Refused automatically in ${seconds}s if nothing is answered.`
}

/**
 * Why a question closed without this window answering it.
 *
 * Shown briefly in place of the dialog, because a dialog that vanishes on its
 * own teaches a person that the app does things behind their back. Only the
 * reasons a *window* can witness are worded here; the rest are refusals the
 * copilot was given before any dialog existed and are the action log's business,
 * not this dialog's.
 */
export function settledSentence(settled: ConsentSettledView): string | null {
  /*
   * Answered somewhere else, and said so.
   *
   * Checked before `granted`, because an *allowed* question is the one case that
   * used to return null — there was nothing to say, since the only surface that
   * could allow it was this one. That is no longer true: a device holding a
   * copilot connection can answer its own run's question, and this dialog then
   * closes on an outcome the person in front of it did not choose. Saying so is
   * the difference between a race that is visible and one that is not.
   *
   * A refusal answered on a device gets the same treatment, and it comes first
   * so that "declined" — which normally returns null, because the person here
   * just pressed the button — does not swallow a decline that happened
   * elsewhere.
   */
  if (settled.by?.startsWith('device:') === true) {
    return settled.granted
      ? 'Allowed on a connected device.'
      : 'Refused on a connected device.'
  }
  if (settled.granted) return null
  switch (settled.reason) {
    case 'timeout':
      return 'Nobody answered in time, so it was refused.'
    case 'caller-gone':
      // Two callers can produce this now: the copilot at the desk hanging up,
      // and a connected device's copilot connection dropping while its own
      // question was on screen. The sentence covers both because the outcome is
      // the same — nobody is waiting for the answer any more.
      return 'The copilot stopped waiting, so the question was withdrawn.'
    case 'shutting-down':
      return 'The app is quitting, so it was refused.'
    case 'approver-gone':
      return 'The window that was asked went away, so it was refused.'
    case 'declined':
      // Answered here, in this window, a moment ago. Repeating it back would be
      // the app narrating the button the person just pressed.
      return null
    default:
      return 'It was refused.'
  }
}

/**
 * Which question is in front of the person, out of everything outstanding.
 *
 * The oldest, always. `consent.ts` caps the outstanding set at three as an
 * anti-fatigue limit, so this is choosing between at most three — and choosing
 * the oldest is what makes the countdown on screen the one that is about to
 * expire. Showing the newest instead would let a question quietly refuse itself
 * behind a dialog for a question with a minute still on it.
 */
export function nextQuestion(pending: readonly ConsentRequestView[]): ConsentRequestView | null {
  let oldest: ConsentRequestView | null = null
  for (const request of pending) {
    if (oldest === null || request.requestedAt < oldest.requestedAt) oldest = request
  }
  return oldest
}
