/**
 * The tour: the copilot writes it, the app checks it, the window plays it.
 *
 * `DRIVING-MODE.md` §0 is the decision this whole file falls out of, and it is
 * worth restating because every awkward thing below is a consequence of it:
 *
 * > **The copilot writes a tour. The app plays it.**
 *
 * Not: the copilot takes a turn, moves the screen, waits for the reader, takes
 * another turn. That shape is the obvious one and it loses four separate
 * arguments — cost (twelve turns of a prompt that already holds the transcripts
 * it read), latency (a pause has to land in one frame, not after a round trip
 * through MCP), interruptibility (stopping must not cancel a model turn and
 * leave half a thought in its transcript), and determinism (rewind and the recap
 * both need the tour to be *a value that exists*).
 *
 * So there is one tool call, `tour.play`, carrying a whole plan. This module is
 * what happens to that plan between the model emitting it and a window drawing
 * it, and it does three jobs that are deliberately not the renderer's:
 *
 *  1. **Refuse a plan that is over budget.** Twelve stops, six hundred
 *     characters of quote, a hundred and sixty of note.
 *  2. **Drop a stop whose claim the app's own data does not support**, and
 *     report the drop. {@link supports} in `importance.ts` is the check; nothing
 *     here re-implements it.
 *  3. **Drop a stop whose quote is not really there.** This is the one that
 *     makes fabricated evidence undisplayable rather than merely discouraged.
 *
 * ## Why the validation is here and not in the renderer
 *
 * `DRIVING-MODE.md` §9: *"Validation lives in `control.ts` beside the tier gate,
 * not in the renderer: the preconditions in §4 are checks against main-process
 * data, and a renderer that validated them would be a second copy of
 * `attention.ts`'s judgement."* Every precondition — attention, progress, git
 * changes, spend — is derived here already, for the overnight report. A second
 * derivation in the window is how the morning summary and the tour of the same
 * night come to disagree about which sessions mattered, which is the failure
 * `importance.ts` exists to prevent and is worse than either feature alone.
 *
 * The renderer still checks one thing, and only one: **where the quote is on
 * screen right now**. That is not a second judgement, it is the placement of a
 * box, and it is unanswerable from here because the buffer lives in xterm. A
 * stop that passes here and cannot be located there is degraded or dropped by
 * the player, which reports it in the same list. See `terminal-region.ts`.
 *
 * ## Two checks, one comparison
 *
 * The quote check on this side runs against the **retained pty scrollback** —
 * the same 4 000-chunk window `terminal-region.ts` caps its own scan at, for the
 * reason stated there: beyond the main process's retention there is nothing the
 * copilot could have read in order to quote it. Both sides call
 * `shared/quote-match.ts`, so "is this string in that text" has exactly one
 * answer in this codebase.
 *
 * ## What this module is not
 *
 * It does not play anything, does not know what a box is, and has no timer. The
 * playhead is renderer state — it changes at frame rate and nothing outside the
 * window needs it (`DRIVING-MODE.md` §8). What comes *back* here is the record,
 * which is a different thing and is written by {@link TourStage}.
 */

import { randomUUID } from 'node:crypto'
import { containsQuote, stripAnsi } from '../../shared/quote-match'
import {
  fleetContext,
  supports,
  UNCHECKED_REASONS,
  type FleetContext,
  type ImportanceInput,
  type StopReason,
} from './importance'
import { assessProgress } from './progress'
import { importanceOf, reportOnSession } from './report'
import type { DeckSurface, SessionView } from './surface'

/* ------------------------------------------------------------------ budgets -- */

/**
 * The most stops one tour may carry.
 *
 * Twelve, because a tour is a *briefing*. At the default reading pace twelve
 * stops of a typical size run about five minutes, which is roughly the length of
 * the thing Asad described — *"I just woke up and I can just ask it to give me an
 * overview"* — and past which nobody is watching anyway.
 *
 * **A plan over this is refused, not truncated.** Same call `catalogue.ts` makes
 * for `log.note` and for the same reason: truncation lets a bad plan half
 * succeed, and a model that learns overreaching is free will overreach every
 * time. The refusal says which limit was hit and by how much, so the retry is
 * informed rather than a second guess.
 */
export const MAX_TOUR_STOPS = 12

/**
 * The longest a single quote may be.
 *
 * A ceiling, not a target. `estimate.ts` measured the consequence: at the
 * default pace a 600-character prose quote lands past `HOLD_ABOVE_MS`, so the
 * tour stops driving and hands the reader the wheel. That is the pacing engine
 * telling the tour's author something true — **a 600-character quote is two
 * stops, not one** — rather than quietly racing somebody through it.
 */
export const MAX_QUOTE_CHARS = 600

/** The copilot's one line about why a stop matters. One line means one line. */
export const MAX_NOTE_CHARS = 160

/**
 * The answer, in prose, posted to chat before anything moves.
 *
 * Long enough for a real paragraph about a night's work and short enough that it
 * is still an answer rather than the tour written out twice. The tour is the
 * evidence; this is the finding.
 */
export const MAX_HEADLINE_CHARS = 1200

/** His question, kept verbatim in the record so the recap says what was asked. */
export const MAX_QUESTION_CHARS = 400

/* -------------------------------------------------------------------- shapes -- */

/**
 * Where a stop points, as a closed set with no CSS-selector escape hatch.
 *
 * A selector produced by a model is two bad things at once. It is an **injection
 * surface**, because these arguments were composed from other sessions'
 * transcripts, which `COPILOT-CAPABILITIES.md` §3.2 item 8 classes as evidence
 * from an untrusted source — and handing one to `querySelector` lets a
 * transcript decide what a person is directed to look at. And it is **silently
 * broken by refactoring**: it fails as "the box is somewhere else" rather than
 * as an error. `focus-target.ts` makes the same argument from the other side of
 * the bridge and carries the matching enum.
 *
 * ## Two of the five anchors are deliberately not here
 *
 * `focus-target.ts` supports five and a tour may name two of them. The other
 * three are real anchors with real uses — a "take me there" button in the recap
 * can point at any of them — and they are not things a *tour* can point at,
 * because a tour has to be able to bring the thing on screen first:
 *
 *  - **`session-row`** is a row in the sidebar, and `DRIVING-MODE.md` §1 puts
 *    the driving panel over the sidebar's own column for the length of a tour.
 *    The element is still in the DOM, so it still measures, so a stop naming it
 *    would draw a perfectly correct box **underneath the panel** — visible to
 *    nobody. The design note lists both facts pages apart and does not notice
 *    they contradict; this is the resolution, and it is the direction that
 *    cannot produce a box the reader is told to look at and cannot see.
 *  - **`alert`** lives in `AlertsWindow`, which is a sheet rather than one of
 *    the ten project views. Nothing in the four-function navigator a tour is
 *    given can open a sheet — deliberately, see `navigator.ts` — so a tour
 *    would navigate nowhere and point behind a closed surface.
 *  - **`message`** is not missing: it is the `message` *stop kind*, which
 *    carries a quote that can be checked against the transcript. An anchor with
 *    no quote pointing at a bubble would be a stop that says "look at this" and
 *    cannot say what "this" is.
 *
 * Both survivors — a changed file in Source control, a session's usage reading —
 * sit inside `.main`, which is exactly the half of the window a tour drives.
 *
 * The second was `usage-strip` until the composer's control row was taken out
 * *"from the chat box side completely"*, which deleted the strip it was named
 * after. The reading survived the move into the chrome's `UsageBar`, so the kind
 * survived under the name that still describes it. See `focus-target.ts`, which
 * carries the matching union and the longer version of this note.
 */
export type TourAnchorAt = 'git-file' | 'usage'

export interface TourStopBase {
  /**
   * The session this stop is *about*.
   *
   * Required on every kind, including `anchor`, and that is a correction to the
   * design note rather than an addition to it. Every value of {@link StopReason}
   * is a fact about a session — `attention.ts` derives it per session,
   * `progress.ts` reads one session's transcript, `git` answers for one folder —
   * so a stop with no session named is a claim with nothing to check it against.
   * The note's own §4 table already agrees: every precondition in it is keyed on
   * a session.
   */
  sessionId: string
  /** The copilot's one line. Prose, always, and visually distinct from the quote. */
  note: string
  why: StopReason
}

export type TourStop =
  /** A bubble in the chat view, cited by the id the transcript reader gave it. */
  | (TourStopBase & { kind: 'message'; messageId: string; quote: string })
  /** A passage of terminal output, anchored by its text. */
  | (TourStopBase & { kind: 'screen'; quote: string })
  /**
   * A named place in the app's own chrome.
   *
   * **No quote.** Every other kind carries verbatim text that this module can
   * check against a real source; there is no source for "the row in the
   * sidebar", and a quote nobody can verify is exactly the thing the
   * verification rule exists to keep off the screen. So an anchor stop shows its
   * note and its reason badge, both of which are the app's own words or a
   * checked claim, and nothing that claims to be somebody else's.
   */
  | (TourStopBase & { kind: 'anchor'; at: TourAnchorAt; path?: string })

export interface TourPlan {
  v: 1
  id: string
  /** His words, verbatim, so the recap says what was asked. */
  question: string
  /**
   * The answer, as prose. Posted to the copilot's chat **before** the first stop.
   *
   * This ordering is the quiet fix for the whole pacing anxiety: if he never
   * watches the tour, he still got what he asked for. The tour is the evidence,
   * not the answer.
   */
  headline: string
  stops: TourStop[]
  askedBy: 'user' | 'offer'
}

/** Why a stop was thrown away. Every value is something the panel says out loud. */
export type DropReason = 'quote-not-found' | 'session-gone' | 'over-budget' | 'reason-unsupported'

export interface DroppedStop {
  /** Enough to know which stop this was, without repeating the quote. */
  title: string
  why: DropReason
  /** One sentence naming the fact that disagreed. */
  detail: string
}

export interface ValidatedTour {
  plan: TourPlan
  dropped: DroppedStop[]
  /** Titles as they were at validation time — sessions get renamed and closed. */
  titles: Record<string, string>
  /**
   * Each session's folder, kept for the same reason the titles are.
   *
   * A `git-file` anchor is keyed on a folder rather than a session — see
   * `focus-target.ts` — and a recap read two weeks later has no session to ask.
   */
  folders: Record<string, string>
}

/* -------------------------------------------------------------- the refusals -- */

/**
 * A plan that broke a budget, and by how much.
 *
 * Thrown rather than returned, and caught by the tool, so that there is exactly
 * one shape for "this plan is not playable at all" and it cannot be confused
 * with "these two stops were dropped". The distinction matters to the model on
 * the other end: a refusal means *send a smaller plan*, and a drop means *the
 * tour played without those*.
 */
export class TourRefused extends Error {}

function refuse(what: string, limit: number, actual: number, unit: string): never {
  throw new TourRefused(
    `${what} is capped at ${limit} ${unit} and this plan has ${actual}. The plan was refused rather than ` +
      'trimmed, because a tour cut down by the app is not the tour you wrote and you would have no way to ' +
      'know which part went. Send it again within the limit — splitting a long quote across two stops is ' +
      'usually the right fix.',
  )
}

/* ------------------------------------------------------------------ parsing -- */

/**
 * Whatever arrived over the wire, made into a plan, or refused.
 *
 * Hand-written rather than run through a schema validator, for the reason
 * `catalogue.ts` gives at length: the schema is advertised to a *language model*,
 * which makes it a hint rather than a contract, and the actual boundary has to
 * be code that throws a sentence the model can act on.
 */
export function parseTourPlan(raw: Record<string, unknown>): TourPlan {
  const question = requireText(raw, 'question', MAX_QUESTION_CHARS)
  const headline = requireText(raw, 'headline', MAX_HEADLINE_CHARS)
  const askedBy = raw.start === 'offer' ? 'offer' : 'user'

  const list = raw.stops
  if (!Array.isArray(list) || list.length === 0) {
    throw new TourRefused('stops must be a non-empty array; a tour with nothing to show is not a tour')
  }
  if (list.length > MAX_TOUR_STOPS) {
    refuse('A tour', MAX_TOUR_STOPS, list.length, 'stops')
  }

  const stops = list.map((entry, index) => parseStop(entry, index))
  return { v: 1, id: newTourId(), question, headline, stops, askedBy }
}

function parseStop(entry: unknown, index: number): TourStop {
  if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
    throw new TourRefused(`stop ${index + 1} is not an object`)
  }
  const raw = entry as Record<string, unknown>
  const at = `stop ${index + 1}`
  const sessionId = requireText(raw, 'sessionId', 200, at)
  const note = requireText(raw, 'note', MAX_NOTE_CHARS, at)
  const why = raw.why
  if (typeof why !== 'string' || !isStopReason(why)) {
    throw new TourRefused(
      `${at} has why=${JSON.stringify(why)}, which is not one of the reasons this app checks. ` +
        `They are: ${REASONS.join(', ')}.`,
    )
  }
  const base = { sessionId, note, why }

  switch (raw.kind) {
    case 'message':
      return {
        ...base,
        kind: 'message',
        messageId: requireText(raw, 'messageId', 400, at),
        quote: requireText(raw, 'quote', MAX_QUOTE_CHARS, at),
      }
    case 'screen':
      return { ...base, kind: 'screen', quote: requireText(raw, 'quote', MAX_QUOTE_CHARS, at) }
    case 'anchor': {
      const anchorAt = raw.at
      if (typeof anchorAt !== 'string' || !ANCHORS.includes(anchorAt as TourAnchorAt)) {
        throw new TourRefused(
          `${at} is an anchor stop with at=${JSON.stringify(anchorAt)}. Anchors are: ${ANCHORS.join(', ')}.`,
        )
      }
      const kind = anchorAt as TourAnchorAt
      if (kind === 'git-file') {
        return { ...base, kind: 'anchor', at: kind, path: requireText(raw, 'path', 1000, at) }
      }
      return { ...base, kind: 'anchor', at: kind }
    }
    default:
      throw new TourRefused(
        `${at} has kind=${JSON.stringify(raw.kind)}. A stop is 'message' (a bubble in the chat view), ` +
          "'screen' (a passage of terminal output) or 'anchor' (a named place in the app's own chrome).",
      )
  }
}

const ANCHORS: readonly TourAnchorAt[] = ['git-file', 'usage']

const REASONS: readonly StopReason[] = [
  'blocked-on-you',
  'failed',
  'finished',
  'looping',
  'tool-failing',
  'compacted',
  'expensive',
  'files-changed',
  'question-asked',
  'decision',
]

function isStopReason(value: string): value is StopReason {
  return (REASONS as readonly string[]).includes(value)
}

function requireText(raw: Record<string, unknown>, key: string, cap: number, at = 'the plan'): string {
  const value = raw[key]
  if (typeof value !== 'string' || value.trim() === '') {
    throw new TourRefused(`${at} needs a non-empty ${key}`)
  }
  if (value.length > cap) {
    refuse(`${at}'s ${key}`, cap, value.length, 'characters')
  }
  return value
}

/** `tour_<epoch>_<8 random>`, as the record's filename and its id. */
export function newTourId(): string {
  return `tour_${Date.now()}_${randomUUID().replace(/-/g, '').slice(0, 8)}`
}

/* --------------------------------------------------------------- validation -- */

/** What one session's claims are checked against, gathered once and reused. */
interface SessionFacts {
  session: SessionView
  importance: ImportanceInput
  title: string
  /** Messages near the end of the transcript, for citing one. Empty when none. */
  messages: Array<{ id: string; text: string }>
  /** The retained pty bytes, for checking a `screen` quote. */
  screen: string
  /** Root-relative paths git reports as changed in this session's folder. */
  changed: Set<string>
}

export interface ValidateDeps {
  surface: DeckSurface
  /** Sessions as the dispatcher sees them, already carrying their attention. */
  sessions: readonly SessionView[]
  now: number
}

/**
 * Check every stop, drop the ones the app's own data will not stand behind, and
 * say which and why.
 *
 * The order of the checks is the order in which their failures are most
 * informative, and it is not arbitrary:
 *
 *  1. **Is the session still there?** Everything else is a fact about it.
 *  2. **Does the reason hold *now*?** {@link supports} is re-evaluated at this
 *     moment rather than trusted from when the plan was written — a session can
 *     finish, die or unblock in between, and walking somebody to a stop whose
 *     reason stopped being true is worse than one stop shorter.
 *  3. **Is the quote really there?** Last because it is the most expensive and
 *     because the two above already caught the cheap lies.
 *
 * `decision` is the one reason with no mechanical detector — there is no honest
 * check for "a choice was made you should know about", which is a judgement
 * about meaning and exactly what the model is for. It is bounded instead of
 * checked: at most one per session per tour, and its quote is verbatim like
 * every other, so the model gets one sentence per session to editorialise in and
 * has to source it.
 */
export async function validateTour(plan: TourPlan, deps: ValidateDeps): Promise<ValidatedTour> {
  const facts = new Map<string, SessionFacts | null>()
  const wanted = new Set(plan.stops.map((stop) => stop.sessionId))
  for (const id of wanted) {
    facts.set(id, await factsFor(deps, id))
  }

  /*
   * The fleet the `expensive` claim is measured against.
   *
   * Only the sessions this plan names, which is a real limitation and is stated
   * rather than hidden: `HEAVY_MIN_SAMPLE` is five, so a three-stop tour cannot
   * support an `expensive` claim at all and the stop is dropped as unsupported.
   * That is the honest direction — "expensive" means *far above its peers*, and
   * three sessions are not a fleet. The copilot that wants to make the claim can
   * ask for the fleet report first, which reads them all.
   */
  const context = fleetContext(
    [...facts.values()].map((entry) => (entry === null ? null : entry.importance.totalTokens)),
  )

  const kept: TourStop[] = []
  const dropped: DroppedStop[] = []
  const titles: Record<string, string> = {}
  const folders: Record<string, string> = {}
  const decided = new Set<string>()

  for (const stop of plan.stops) {
    const entry = facts.get(stop.sessionId) ?? null
    if (entry === null) {
      dropped.push({
        title: stopTitle(stop, null),
        why: 'session-gone',
        detail: `There is no live session with id ${stop.sessionId} any more.`,
      })
      continue
    }
    titles[stop.sessionId] = entry.title
    folders[stop.sessionId] = entry.session.cwd

    if (stop.why === 'decision') {
      if (decided.has(stop.sessionId)) {
        dropped.push({
          title: stopTitle(stop, entry),
          why: 'over-budget',
          detail:
            'A tour gets one "decision" per session, because that is the one reason this app cannot check. ' +
            'This was the second for this session.',
        })
        continue
      }
      decided.add(stop.sessionId)
    }

    if (!supports(stop.why, entry.importance, context)) {
      dropped.push({
        title: stopTitle(stop, entry),
        why: 'reason-unsupported',
        detail: unsupportedSentence(stop.why, entry, context),
      })
      continue
    }

    const missing = quoteProblem(stop, entry)
    if (missing !== null) {
      dropped.push({ title: stopTitle(stop, entry), why: 'quote-not-found', detail: missing })
      continue
    }

    kept.push(stop)
  }

  return { plan: { ...plan, stops: kept }, dropped, titles, folders }
}

/**
 * Everything one session's claims can be checked against, read once.
 *
 * `reportOnSession` is the same call the overnight report makes, and using it
 * rather than re-deriving here is the whole reason `importance.ts` was written
 * as a shared module: the tour and the report reach `supports` holding the same
 * numbers, so they cannot disagree about which sessions mattered.
 *
 * Null when the session is gone. That is a real answer — a plan written at 09:00
 * about a session that exited at 09:01 is a plan with a hole in it, and the hole
 * is reported rather than papered over.
 */
async function factsFor(deps: ValidateDeps, sessionId: string): Promise<SessionFacts | null> {
  const session = deps.sessions.find((entry) => entry.id === sessionId)
  if (session === undefined) return null

  const report = await reportOnSession(deps.surface, session)
  const importance = importanceOf(report)

  /*
   * The tail of the conversation, only when a `message` stop could need it.
   *
   * Bounded to the same 256 KB window `report.ts` reads its last message from.
   * A tour cites something recent by construction — it is a briefing about what
   * just happened — and reading a 154 MB transcript to confirm a message id
   * would be the single most expensive thing this app does, on the path a
   * person is waiting on.
   */
  const messages: SessionFacts['messages'] = []
  const path = report.transcript?.path ?? null
  if (path !== null) {
    const bytes = report.transcript?.bytes ?? 0
    const from = Math.max(0, bytes - MESSAGE_WINDOW_BYTES)
    for (const message of await deps.surface.readTranscriptFrom(path, from)) {
      messages.push({ id: message.id, text: message.text })
    }
  }

  return {
    session,
    importance,
    title: session.title || session.cwd,
    messages,
    /*
     * Stripped, and the strip is not cosmetic.
     *
     * `sessionScrollback` hands back what the *process wrote*, not what xterm
     * *drew* — so a line git printed as ` package.json | 2 +-` arrives wrapped
     * in colour codes, and the quote the copilot read off the rendered screen
     * has none of them. Without this the check was measured failing on real
     * output: the uncoloured lines matched, every coloured one was dropped as
     * "not there", and the tour lost exactly the stops worth showing, because
     * the interesting lines are the ones a CLI colours.
     *
     * `normalizeLine` alone is not enough. It turns the escape *byte* into a
     * space and leaves `[32m` behind as visible text, which is worse than
     * leaving the sequence intact: the needle then has to match around a piece
     * of noise that was never on screen.
     */
    screen: stripAnsi(deps.surface.sessionScrollback(session.id)),
    changed: new Set((report.changes?.paths ?? []).map((entry) => entry)),
  }
}

/** How much of the end of a transcript is read to confirm a cited message. */
export const MESSAGE_WINDOW_BYTES = 256 * 1024

/**
 * Why this stop's quote cannot be stood behind, or null when it can.
 *
 * The three kinds fail differently and the sentence says which, because the
 * useful next move differs: a message id that names nothing means *cite a real
 * one*, a message that does not contain its quote means *the quote was not from
 * that message*, and a screen quote nobody can find means *it has scrolled out
 * of what this app still holds*.
 */
function quoteProblem(stop: TourStop, facts: SessionFacts): string | null {
  if (stop.kind === 'anchor') {
    if (stop.at === 'git-file') {
      const path = stop.path ?? ''
      if (!facts.changed.has(path)) {
        return `git does not report ${path} as changed in ${facts.session.cwd}.`
      }
    }
    // Everything else an anchor names is an element, and whether it is on screen
    // right now is the window's question rather than this one's. The player
    // reports `anchor-missing` and degrades — see `focus-target.ts`.
    return null
  }

  if (stop.kind === 'message') {
    const message = facts.messages.find((entry) => entry.id === stop.messageId)
    if (message === undefined) {
      return `No message with id ${stop.messageId} in the last ${Math.round(MESSAGE_WINDOW_BYTES / 1024)} KB of that session's transcript.`
    }
    if (!containsQuote(message.text, stop.quote)) {
      return 'That message does not contain the quoted text.'
    }
    return null
  }

  if (!containsQuote(facts.screen, stop.quote)) {
    return 'That text is not in what this app still holds of that terminal.'
  }
  return null
}

/** One sentence naming the fact that refused the claim. */
function unsupportedSentence(why: StopReason, facts: SessionFacts, context: FleetContext): string {
  const input = facts.importance
  switch (why) {
    case 'blocked-on-you':
      return `That session is ${input.attention}, not blocked.`
    case 'failed':
      return input.exitCode === null
        ? 'That session has not exited.'
        : `That session exited ${input.exitCode}, which this app does not classify as a failure.`
    case 'finished':
      return `That session is ${input.attention}, not done.`
    case 'looping':
      return `progress.ts reads that session as ${input.progress?.verdict ?? 'unreadable'}, not looping.`
    case 'tool-failing':
      return 'No tool in the window that was read has failed often enough to count.'
    case 'compacted':
      return 'No compaction in the part of that transcript that was read.'
    case 'expensive':
      return context.sample < 5
        ? `"Expensive" is a comparison, and only ${context.sample} of the sessions in this plan have any tokens on them — too few to have a median worth comparing against.`
        : 'That session is not spending far enough above the others to count.'
    case 'files-changed':
      return 'git reports nothing changed in that session’s folder.'
    case 'question-asked':
      return 'The last thing that session said does not end in a question mark.'
    case 'decision':
      // Unreachable: `supports` answers true for it. Kept so the switch is total
      // and so the next reason added cannot be forgotten here.
      return 'A decision needs no check.'
  }
}

function stopTitle(stop: TourStop, facts: SessionFacts | null): string {
  const where = facts?.title ?? stop.sessionId
  return `${where} — ${stop.note.slice(0, 60)}`
}

/* ---------------------------------------------------------------- the record -- */

/**
 * What the app showed a person under the copilot's name.
 *
 * Written by the app, into `<userData>/copilot-log/tours/`, which is **outside
 * `<userData>/copilot/`** — the folder the copilot can write to. Same argument
 * `COPILOT-CAPABILITIES.md` §7 used to move the action log out: the audited
 * party must not be able to author, edit or delete the record of what it did. A
 * copilot that could rewrite this after the fact makes every quote in it worth
 * nothing.
 */
export interface TourStopRecord {
  index: number
  sessionId: string
  /** At tour time. The session may be renamed or gone by the time this is read. */
  sessionTitle: string
  /**
   * Enough to point at this stop again, weeks later.
   *
   * The record is not only an audit artefact; §6 gives every stop in the recap a
   * **Take me there**, which replays that one stop — navigate, box, dim, no
   * timer. That needs the same target the tour built, and the target cannot be
   * recovered from a quote alone: a `screen` stop is anchored by its text, a
   * `message` stop by an id, and an `anchor` stop by a place and a path.
   *
   * `cwd` rather than looking the folder up from the session, because by the
   * time somebody reads a two-week-old recap the session is long gone and the
   * folder is the only thing that still resolves.
   */
  kind: 'message' | 'screen' | 'anchor'
  /** The folder the session was running in, for a `git-file` anchor. */
  cwd: string
  /** `message` stops only. */
  messageId?: string
  /** `anchor` stops only. */
  at?: TourAnchorAt
  /** `git-file` anchors only. */
  path?: string
  why: StopReason
  /** Verbatim, exactly what was checked. Empty for an anchor stop, which has none. */
  quote: string
  note: string
  /** Null when the tour ended before this stop was reached. */
  shownAt: number | null
  /** How long was actually spent on it, excluding travel. */
  dwellMs: number | null
  /** True when the window could navigate to it but not box it. See `FocusFailure`. */
  degraded: boolean
  /** Why there was no box, when there was none. */
  degradedWhy: string | null
}

export interface TourRecord {
  v: 1
  id: string
  startedAt: number
  endedAt: number | null
  askedBy: 'user' | 'offer'
  question: string
  headline: string
  /**
   * Whether this scan was put on the screen or done quietly.
   *
   * The toggle Asad asked for: *"Interactive mode ON — the visible scan.
   * Interactive mode OFF — it does the work in the background and returns the
   * final answer normally, with none of the driving. The answer must be
   * identical either way; only the showing differs."*
   *
   * It is a field on the **record** rather than a branch in the tool because the
   * two modes must produce the same artefact. Every stop is found, checked and
   * quoted the same way in both; the only difference is whether a box was ever
   * drawn around it. That makes this flag the one thing the answer card needs in
   * order not to lie in either direction — without it, a background scan renders
   * with "Not reached" against every line, which would say the work was not done
   * when the work is exactly what is being shown.
   */
  shown: 'screen' | 'background'
  stops: TourStopRecord[]
  /** Index of the last stop shown, when a person stopped it early. */
  stoppedAfter: number | null
  dropped: DroppedStop[]
}

/**
 * The record as it stands the moment the plan is validated, before anything is
 * shown.
 *
 * Written straight away rather than at the end, and that is the point: an
 * interrupted or crashed tour still leaves a readable account of what it was
 * going to show and what it had already dropped. A record that only exists once
 * a tour finishes cleanly is a record of the case nobody needs one for.
 */
export function openRecord(
  validated: ValidatedTour,
  at: number,
  shown: TourRecord['shown'] = 'screen',
): TourRecord {
  const { plan, dropped, titles } = validated
  return {
    v: 1,
    id: plan.id,
    startedAt: at,
    endedAt: null,
    askedBy: plan.askedBy,
    question: plan.question,
    headline: plan.headline,
    shown,
    stops: plan.stops.map((stop, index) => ({
      index,
      sessionId: stop.sessionId,
      sessionTitle: titles[stop.sessionId] ?? stop.sessionId,
      kind: stop.kind,
      cwd: validated.folders[stop.sessionId] ?? '',
      ...(stop.kind === 'message' ? { messageId: stop.messageId } : {}),
      ...(stop.kind === 'anchor' ? { at: stop.at } : {}),
      ...(stop.kind === 'anchor' && stop.path !== undefined ? { path: stop.path } : {}),
      why: stop.why,
      quote: stop.kind === 'anchor' ? '' : stop.quote,
      note: stop.note,
      shownAt: null,
      dwellMs: null,
      degraded: false,
      degradedWhy: null,
    })),
    stoppedAfter: null,
    dropped,
  }
}

/* --------------------------------------------------------- what the tool says -- */

/** The tool result: what will be shown, what was dropped, and why. */
export function tourSummary(validated: ValidatedTour): {
  playing: number
  dropped: number
  reasons: DroppedStop[]
} {
  return {
    playing: validated.plan.stops.length,
    dropped: validated.dropped.length,
    reasons: validated.dropped,
  }
}

/**
 * The importance input for a session with nothing readable behind it.
 *
 * Exported for tests and for a caller that has a session and no report. Every
 * field is the value that makes a claim *fail* rather than pass, which is the
 * right default for a check whose whole job is to refuse things it cannot
 * confirm.
 */
export function unknownImportance(session: SessionView): ImportanceInput {
  return {
    attention: session.attention,
    attentionReason: session.attentionReason,
    exitCode: session.exitCode,
    progress: assessProgress(null),
    totalTokens: null,
    changedFiles: 0,
    lastMessage: null,
  }
}

export { UNCHECKED_REASONS }
export type { StopReason }
