/**
 * The scan, in a browser tab: what it walks, what it says at the end, and the
 * clock that moves it.
 *
 * ## The model is not here. That is the whole point of the file.
 *
 * `src/shared/scan.ts` holds the playhead — `scanReducer`, `SCAN_HOLD_MS`,
 * `groupBySession`, `answerSummary` — and its own header says why it lives
 * there rather than in the renderer that plays it:
 *
 *   > *"Because it has to run in three places and must not be written three
 *   > times. The desktop renderer plays it, the main process's tool authors it,
 *   > and the web client — which has no copilot surface yet — will need exactly
 *   > this reducer the day it grows one."*
 *
 * This is that day. Nothing below re-implements a rule that file already states:
 * the hold is its constant, the interruption reasons are its vocabulary, the
 * grouping is its function, and the summary sentence is its sentence. What is
 * here is the two things it deliberately does not have — **a clock**, because it
 * is a pure reducer over an injected `now`, and **a subject**, because what a
 * scan walks is different on every surface.
 *
 * ## What this client can honestly scan, and what it cannot
 *
 * The desktop's scan is authored by the copilot: `tour.play` carries a plan of
 * stops, each with a quote the main process has *verified is really in that
 * session's scrollback* (`shared/quote-match.ts`), and a stop whose quote cannot
 * be found is dropped rather than shown. That check is what makes fabricated
 * evidence undisplayable there.
 *
 * **A tour does not cross the wire.** There is no `copilot.tour` frame; the plan
 * goes from the model to `deck-control/tour.ts` to that window's renderer and no
 * further. So this client cannot receive the desktop's scan, and inventing one —
 * composing plausible sentences about sessions from a browser that has never
 * read them — is precisely the thing the whole review is against.
 *
 * What this client *does* have is real and is enough for a real scan:
 *
 *  - **the fleet**, from `welcome.sessions` and the pushed `sessions` frames:
 *    every session on the machine, its title, its folder, its agent, its status
 *    and its exit code;
 *  - **when each one last did something**, from the activity map this client
 *    keeps as `output`, `status` and `created` frames arrive;
 *  - **which of them the copilot started**, from `copilot.sessions`, with
 *    `originRunId` pointing at the action-log row that started it;
 *  - **the machine's own sentence about that row**, from `copilot.tool` —
 *    `detail` is written by the desktop, about a call that really happened.
 *
 * So every field of every stop below is a fact that came off the wire, and the
 * one that reads like prose — the quote — is *the machine's own line*, joined to
 * its session through `originRunId` rather than guessed at. A session the
 * copilot never touched carries no quote, and the answer shows none. That is the
 * honest floor: a smaller scan that says only what it knows.
 *
 * ## Two phases, and the reading is at the end
 *
 * > *"Currently it stays for us to read. Let's not make it for us to read… it is
 * > scanning everything very fast and we can see like a machine is working."*
 *
 * Phase one is watched, at {@link SCAN_HOLD_MS} a stop. Phase two is read, in one
 * place, grouped by session. Nothing in between needs to know how fast anybody
 * reads, which is why there is no estimate anywhere in this file.
 *
 * ## The toggle, and why the answer cannot depend on it
 *
 * Interactive on plays the scan; interactive off does the same work with none of
 * the driving. **The answer is identical either way** — literally the same
 * function over the same stops — and the one field that could differ is handled
 * by the shared model rather than here: `groupBySession(stops, {background})`
 * marks every finding as delivered when there was no visible scan to be stopped
 * part-way through. Getting that backwards would put "not reached" against every
 * line of a scan that found everything.
 */

import {
  SCAN_HOLD_MS,
  answerSummary,
  groupBySession,
  initialScanState,
  isScanning,
  scanReducer,
  statusSentence,
  type AnswerSession,
  type PauseReason,
  type ScanEvent,
  type ScanState,
} from '../../src/shared/scan'
import { formatSince, sessionTone, statusLabel } from './sessions'
import type { CopilotActionRow, CopilotSessionRow, RemoteSession } from './protocol-client'

export { SCAN_HOLD_MS, answerSummary, isScanning, statusSentence }
export type { AnswerSession, ScanState }

/* ----------------------------------------------------------------- stops -- */

/**
 * One stop: a session, why it is worth a look, and what the machine said.
 *
 * Structurally what `groupBySession` asks for, which is four fields and a
 * timestamp, and that shape is the shared model's rather than this file's — see
 * its note on why it takes four fields instead of the desktop's record type.
 */
export interface ScanStop {
  sessionId: string
  sessionTitle: string
  /** A reason from a fixed vocabulary, derived from status and exit code. */
  why: string
  /** One concrete fact: the status, and when it last did something. */
  note: string
  /** The machine's own line about the call that started it, or empty. */
  quote: string
  /** When the box was actually drawn here, or null. Filled by the player. */
  shownAt: number | null
}

/**
 * How many stops one scan may carry.
 *
 * The desktop refuses a tour over twelve, and the number is the same here for
 * the same reason it is there: a scan is a briefing, and past a dozen nobody is
 * watching. It matters more in a browser than on the desktop, because the desktop
 * caps a *plan somebody authored* and this caps a *fleet somebody happens to
 * have* — a machine with forty sessions would otherwise produce forty stops of
 * 260 ms, which is ten seconds of driving and a wall of answer.
 *
 * The fleet is sorted before it is cut, so what falls off the end is what
 * `rankOf` judged least worth looking at, and the summary counts what was
 * actually shown rather than what exists.
 */
export const MAX_SCAN_STOPS = 12

/**
 * How a session is ranked for the scan, lowest first.
 *
 * The same judgement the session list already makes, extended by one rank rather
 * than replaced: `sortSessions` puts a session needing input first and a finished
 * one last, and the extra distinction here is between finishing cleanly and
 * failing. A non-zero exit is the one thing on this screen somebody would get out
 * of bed for, and it is invisible in a list that sorts every finished session
 * together.
 */
export function rankOf(session: RemoteSession): number {
  // A clean finish is **last**, below a session that is merely quiet, and that
  // is the same call `sortSessions` makes: something still running is something
  // that can still go wrong, and something that finished is finished. A failure
  // is first for the opposite half of the same reason.
  if (session.exitCode !== null) return session.exitCode === 0 ? 5 : 0
  switch (sessionTone(session)) {
    case 'input':
      return 1
    case 'waiting':
      return 2
    case 'working':
      return 3
    default:
      return 4
  }
}

/**
 * The short reason the scan stopped here — and it is the session list's own
 * word, not a second vocabulary.
 *
 * This used to have five words of its own: *Needs you*, *Waiting*, *Working*,
 * *Done*, *Quiet*. Looked at on a real answer card, three of them said exactly
 * what the line beneath already said — `Working · Working`, `Quiet · Idle` —
 * which is the quantity spam his design rules name, and worse than that, *Quiet*
 * was a **claim** about a status this build has never heard of. `statusLabel` is
 * the machine's own word, it is what the session list prints for the same row,
 * and for an unrecognised status it prints the machine's string rather than
 * guessing at it.
 *
 * The one distinction added on top is the one the label cannot make: a non-zero
 * exit is the thing on this screen somebody would get out of bed for, and
 * `Exited (1)` reads like a footnote.
 */
export function whyOf(session: RemoteSession): string {
  if (session.exitCode !== null && session.exitCode !== 0) return 'Stopped with an error'
  return statusLabel(session)
}

/**
 * The one concrete line under a stop: what is not already in the reason.
 *
 * Deliberately **not** the status again. `formatSince` returns null when nothing
 * true is known — the wire carries no activity timestamp for a session this
 * browser has never heard from — and printing the moment the list arrived,
 * dressed up as the moment the session last did something, would be inventing
 * the one fact this line exists to carry.
 *
 * ## Empty, where it used to say so
 *
 * It printed *"Nothing seen from this browser yet"*, and that sentence turned up
 * under a run that had **just answered** — because a session that has never sent
 * an `output` frame to *this* client carries no timestamp here, however busy it
 * has been. So the sentence was both prose on a screen that is not allowed any
 * and, read on that row, plainly false.
 *
 * The answer is the rule the rest of this client already follows: an absence is
 * drawn as an absence. The empty string means the caller draws no line at all —
 * `''` rather than null so that every caller keeps one type and a template
 * cannot print `null`.
 */
export function noteOf(session: RemoteSession, lastActivityAt: number | null, now: number): string {
  const parts: string[] = []
  if (session.exitCode !== null && session.exitCode !== 0) parts.push(`Exit code ${session.exitCode}`)
  const since = formatSince(now, lastActivityAt)
  if (since !== null) parts.push(`Last active ${since}`)
  return parts.join(' · ')
}

export interface PlanInput {
  sessions: readonly RemoteSession[]
  /** When this browser last saw each session do something. */
  activity: ReadonlyMap<string, number>
  /** The sessions the copilot started, for the join to the action log. */
  started: readonly CopilotSessionRow[]
  /** The live tool rows, for the machine's own sentence about a start. */
  tools: readonly CopilotActionRow[]
  now: number
}

/**
 * The plan: the fleet, ordered, cut to {@link MAX_SCAN_STOPS}, with real quotes.
 *
 * The join is the part worth reading twice. `CopilotSessionRow.originRunId` is
 * *"the action-log row that started it, so the phone can link the two"*, and
 * `CopilotActionRow.detail` is *"the one line the Activity pane shows. Written
 * by the desktop."* So a session the copilot started, whose starting row this
 * browser has seen, gets that machine-written line as its quote. Everything else
 * gets an empty one and the answer draws no quote at all.
 *
 * There is deliberately **no fallback quote**. A stop with nothing to quote is a
 * stop with nothing to quote; substituting the folder, the title or the status
 * would produce a line that looks like evidence and is not.
 */
export function scanPlan(input: PlanInput): ScanStop[] {
  const detailOf = new Map<string, string>()
  for (const row of input.tools) if (row.detail !== '') detailOf.set(row.id, row.detail)
  const originOf = new Map<string, string | null>()
  for (const row of input.started) originOf.set(row.id, row.originRunId)

  const ordered = [...input.sessions].sort((a, b) => {
    const byRank = rankOf(a) - rankOf(b)
    if (byRank !== 0) return byRank
    const byActivity = (input.activity.get(b.id) ?? 0) - (input.activity.get(a.id) ?? 0)
    if (byActivity !== 0) return byActivity
    return a.title.localeCompare(b.title)
  })

  return ordered.slice(0, MAX_SCAN_STOPS).map((session) => {
    const origin = originOf.get(session.id) ?? null
    return {
      sessionId: session.id,
      sessionTitle: session.title,
      why: whyOf(session),
      note: noteOf(session, input.activity.get(session.id) ?? null, input.now),
      quote: origin === null ? '' : (detailOf.get(origin) ?? ''),
      shownAt: null,
    }
  })
}

/**
 * The answer, grouped by session.
 *
 * A pass-through to the shared function, and it is a named pass-through rather
 * than a direct call at the two call sites because `background` is the argument
 * that is easy to get backwards — and getting it backwards is the one failure
 * the shared model calls out by name. Reading it as *"was this scan visible"* at
 * the call site, and as *"deliver everything"* inside, is how a single `!` ends
 * up in the wrong place.
 */
export function scanAnswer(stops: readonly ScanStop[], interactive: boolean): AnswerSession[] {
  return groupBySession(stops, { background: !interactive })
}

/**
 * What the answer card says it is, above the sessions.
 *
 * Says where it came from, because the honest thing this scan can be mistaken
 * for is the copilot's own reading of those sessions, and it is not that — see
 * the header. `answerSummary` supplies the count, and it counts what was shown
 * rather than what was planned.
 */
export const ANSWER_PROVENANCE = 'From what the machine reported about each session.'

/* ---------------------------------------------------------------- clock -- */

export interface ScanClock {
  /** Monotonic milliseconds. `performance.now` in a browser, a counter in tests. */
  now(): number
  requestFrame(callback: () => void): number
  cancelFrame(handle: number): void
}

export interface ScanRunner {
  state(): ScanState
  dispatch(event: ScanEvent): void
  /** Start a scan over `count` stops. */
  play(count: number): void
  stop(): void
  pause(reason: PauseReason): void
  resume(): void
  /** Frees the frame loop and drops the listener. */
  destroy(): void
}

/**
 * The thing that makes time pass, in about forty lines and no React.
 *
 * The desktop's equivalent is `renderer/copilot/driving/scan-engine.ts`, which
 * cannot be imported here: it is built on `useSyncExternalStore` and this client
 * has no React at all. What is *not* duplicated is anything that decides
 * behaviour — every rule about holds, stalls, arrivals and pauses is
 * `scanReducer`'s, imported. This is a loop and a listener.
 *
 * ## Frames, not timeouts
 *
 * `requestAnimationFrame` against a monotonic clock, never `setTimeout`. A
 * timeout keeps counting while the machine is asleep and while the tab is in the
 * background, so a scan left running as somebody switched apps would come back
 * having walked the whole fleet with nobody watching. `rAF` simply stops in a
 * hidden tab, and `MAX_TICK_GAP_MS` in the reducer catches the moment it starts
 * again and holds rather than resuming mid-flight.
 *
 * ## Publishing on shape changes only
 *
 * The reducer's state moves every frame — `elapsedMs` and `lastTickAt` are
 * counters — and nothing on screen is drawn from either. Notifying on every one
 * would re-render the panel sixty times a second to move nothing. So the
 * listener is called when something a person could see has changed, which at
 * 260 ms a stop is about four times a second.
 */
export function createScanRunner(clock: ScanClock, onChange: (state: ScanState) => void): ScanRunner {
  let live = initialScanState()
  let published = live
  let handle: number | null = null
  let dead = false

  /** The fields a watcher is actually waiting on. */
  const shape = (state: ScanState): string =>
    [state.status, state.index, state.count, state.pausedBy ?? '', state.arrivals, state.seen.length].join('|')

  const publish = (): void => {
    if (shape(live) === shape(published)) return
    published = live
    onChange(published)
  }

  const tick = (): void => {
    handle = null
    if (dead) return
    live = scanReducer(live, { kind: 'tick', at: clock.now() })
    publish()
    // Kept running while paused, deliberately. A paused scan is one Space away
    // from carrying on, and a loop that stopped would have to be restarted from
    // whichever of the six pause reasons happened to end — which is six places
    // to forget. It is a comparison per frame against a screen already painting
    // a terminal.
    if (isScanning(live)) handle = clock.requestFrame(tick)
  }

  const start = (): void => {
    if (dead || handle !== null || !isScanning(live)) return
    handle = clock.requestFrame(tick)
  }

  return {
    state: () => published,
    dispatch(event) {
      if (dead) return
      live = scanReducer(live, event)
      publish()
      start()
    },
    play(count) {
      if (dead) return
      live = scanReducer(initialScanState(), { kind: 'play', at: clock.now(), count })
      // Published unconditionally rather than through `publish`, because a scan
      // replayed over the same fleet has the identical shape as the one that
      // just ended and would otherwise start invisibly.
      published = live
      onChange(published)
      start()
    },
    stop() {
      if (dead) return
      live = scanReducer(live, { kind: 'stop', at: clock.now() })
      publish()
    },
    pause(reason) {
      if (dead) return
      live = scanReducer(live, { kind: 'pause', at: clock.now(), reason })
      publish()
    },
    resume() {
      if (dead) return
      live = scanReducer(live, { kind: 'resume', at: clock.now() })
      publish()
      start()
    },
    destroy() {
      dead = true
      if (handle !== null) clock.cancelFrame(handle)
      handle = null
    },
  }
}

/** The browser's own clock, for everything that is not a test. */
export function browserScanClock(): ScanClock {
  return {
    now: () => performance.now(),
    requestFrame: (callback) => requestAnimationFrame(callback),
    cancelFrame: (id) => cancelAnimationFrame(id),
  }
}
