/**
 * The scan: the playhead for driving mode, at machine speed, and the answer it
 * leaves behind.
 *
 * ## What this replaces, and why the replacement is smaller
 *
 * Driving mode was built as a **read-along**. It stopped at each place and held
 * it there for as long as the app estimated a person needed to read it —
 * `estimate.ts` counted words, corrected for symbol density, divided by a
 * chosen words-a-minute, and learned a per-reader correction from how early
 * somebody pressed →. Around six hundred lines existed to answer one question:
 * *how long does this take to read?*
 *
 * That question no longer has a caller. Asad, 2026-08-17:
 *
 *   > *"Currently it stays for us to read. Let's not make it for us to read. It
 *   > will do it in a way that it is reading it in very fast mode — it is going
 *   > here and there, it is going to all of those sessions… and we can see which
 *   > words it is making focus… it is scanning everything very fast and we can
 *   > see like a machine is working, a proper feel of high-speed intelligence."*
 *
 * So there are two phases, and **the reading happens at the end, not during**:
 * the scan, which is watched rather than read, and then the answer, which is
 * read at whatever pace the person likes, in one place. Nothing between those
 * two needs to know how fast anybody reads, which is why the whole reading-time
 * model was deleted rather than configured down to zero. A dial that no longer
 * moves anything is worse than no dial: somebody will find it, set it, and be
 * lied to.
 *
 * ## What survived, and why each one earned it
 *
 * - **Interruption.** Touching anything still stops the scan dead. That was
 *   never about reading speed — it is about the screen belonging to the person
 *   in front of it — and it matters *more* now, because a machine-speed scan is
 *   harder to catch by hand.
 * - **The stall guard.** `MAX_TICK_GAP_MS`: a gap between frames that large
 *   means the renderer was not running — a shut lid, a hidden window — and the
 *   scan must not come back mid-flight.
 * - **Two index spaces.** The record is indexed by the plan; the playhead is
 *   indexed by what is still playable. See `tour-player.ts`.
 *
 * ## Why the whole model lives in `shared/`
 *
 * Because it has to run in three places and must not be written three times.
 * The desktop renderer plays it, the main process's tool authors it, and the web
 * client — which has no copilot surface yet — will need exactly this reducer the
 * day it grows one. `pwa/src` already reaches into `../../src/shared` for
 * `brand`, `sealed`, `relay-wire` and `short-code`, so the road already exists.
 * Porting a playhead is how two clients come to disagree about what a scan is,
 * which is precisely the failure the parallel copies of `StopReason` are already
 * careful about.
 *
 * There is no DOM here, no React and no timer. Everything is a reducer over an
 * injected clock, which is what makes every timing rule in this feature
 * checkable against a fake clock rather than against a screenshot.
 */

/* ------------------------------------------------------------- the clock -- */

/**
 * How long the focus rests on one stop.
 *
 * This is the number the whole inversion comes down to, so it is worth being
 * explicit about what it is and is not. It is **not** a reading time — nothing
 * about the content changes it, and that is the point. It is the time a jump
 * needs to register as a jump.
 *
 * Bounded from both directions by facts rather than taste:
 *
 * - **Below about 150 ms** consecutive positions blur into one another. The eye
 *   needs a fixation to land, and a saccade plus a fixation is roughly 50 ms +
 *   100 ms; under that the box does not read as having *been* anywhere, it reads
 *   as flicker, and flicker reads as a bug.
 * - **Above about 400 ms** it stops looking like a machine and starts looking
 *   like a slideshow — which is what this feature just stopped being.
 *
 * 260 ms sits between them with room either side. Twelve stops is a little over
 * three seconds of scanning, which is the length of thing you *watch*. The box
 * fade in `tokens.css` is `--dur` (200 ms), so the hold is deliberately longer
 * than the fade: a stop that ended before it had finished appearing would be a
 * stop nobody saw.
 */
export const SCAN_HOLD_MS = 260

/**
 * A gap between ticks that means the renderer was not running.
 *
 * A busy frame is 16 ms and a bad one 200. A full second is a window that was
 * hidden, throttled or asleep — `requestAnimationFrame` stops entirely in a
 * background window, which is why the loop is built on it rather than on
 * `setTimeout`. The gap is discarded *and* the scan pauses, because coming back
 * to a screen that is already in motion is the worst frame of the whole feature.
 */
export const MAX_TICK_GAP_MS = 1_000

/* -------------------------------------------------------------- statuses -- */

export type ScanStatus =
  /** Nothing is playing. */
  | 'idle'
  /** Moving to a stop; the hold has not started. */
  | 'travelling'
  /** The box is on the words and the hold is running down. */
  | 'scanning'
  /** Something the person did stopped it. */
  | 'paused'
  /** Past the last stop, or stopped by hand. */
  | 'finished'

/**
 * Why it is not moving.
 *
 * Every one of these is shown in words, because a stopped scan that does not say
 * what stopped it looks like a hang — and at machine speed the person will not
 * have seen which of their own gestures did it.
 */
export type PauseReason =
  /** The Stop/Pause control, or Space. */
  | 'asked'
  | 'scrolled'
  | 'clicked'
  | 'typed'
  | 'selected'
  | 'left-window'
  | 'hidden'
  /** Stepped back by hand — a deliberate look at something that went past. */
  | 'stepped-back'
  /** A permission prompt arrived. It outranks the scan. */
  | 'consent'
  /** The renderer stopped running for a while. See {@link MAX_TICK_GAP_MS}. */
  | 'stalled'

/* ----------------------------------------------------------------- state -- */

export interface ScanState {
  readonly status: ScanStatus
  /** How many stops are playable. The playhead's index space, not the record's. */
  readonly count: number
  readonly index: number
  /** Time credited at this stop. Excludes travel and stalls. */
  readonly elapsedMs: number
  readonly pausedBy: PauseReason | null
  readonly lastTickAt: number | null
  /** When the box was drawn, or null while travelling. */
  readonly arrivedAt: number | null
  /** How many renderer stalls have been swallowed. Reported, not hidden. */
  readonly stalls: number
  /**
   * How many times the box has actually been drawn somewhere, ever.
   *
   * Monotonic, and not the same as `seen.length`: stepping back onto a stop
   * already visited is a real arrival that adds nothing to the trace. The dot
   * field surges on a change to this, so the surge marks *the machine landing*
   * rather than *the machine reaching somewhere new* — which is what a person
   * watching is actually seeing happen.
   */
  readonly arrivals: number
  /**
   * Stops whose box has actually been drawn, oldest first.
   *
   * The panel draws this as a trace — the machine's own record of where it has
   * been, accumulating while you watch. It is what makes a scan legible at a
   * speed nobody can read at: you cannot follow the boxes, but you can watch the
   * list fill.
   */
  readonly seen: readonly number[]
}

export type ScanEvent =
  | { kind: 'play'; at: number; count: number }
  /** Travel finished and the box is drawn. Starts the hold. */
  | { kind: 'arrive'; at: number }
  | { kind: 'tick'; at: number }
  | { kind: 'next'; at: number; travel?: boolean }
  | { kind: 'back'; at: number; travel?: boolean }
  | { kind: 'jump'; at: number; index: number; travel?: boolean }
  | { kind: 'pause'; at: number; reason: PauseReason }
  | { kind: 'resume'; at: number }
  | { kind: 'stop'; at: number }
  /** The playable set shrank — a session went while the scan was paused. */
  | { kind: 'recount'; at: number; count: number; index: number }

export function initialScanState(): ScanState {
  return {
    status: 'idle',
    count: 0,
    index: 0,
    elapsedMs: 0,
    pausedBy: null,
    lastTickAt: null,
    arrivedAt: null,
    stalls: 0,
    arrivals: 0,
    seen: [],
  }
}

/* --------------------------------------------------------------- reducer -- */

export function scanReducer(state: ScanState, event: ScanEvent): ScanState {
  switch (event.kind) {
    case 'play': {
      const opened: ScanState = { ...initialScanState(), count: event.count, lastTickAt: event.at }
      if (event.count === 0) return { ...opened, status: 'finished' }
      return enter(opened, 0, event.at, true)
    }

    case 'arrive': {
      /*
       * Recorded whatever the status is, and only *acted on* while travelling.
       *
       * The case that forces the split: somebody scrolls while the scan is still
       * travelling, so it pauses mid-travel; the navigation then completes and
       * the overlay reports the arrival it was always going to report. Ignoring
       * it because the status was `paused` left `arrivedAt` null for good, and
       * `resume` then sends a scan with a fully drawn box back to `travelling`,
       * waiting for a second arrival nothing will ever send.
       */
      if (state.arrivedAt !== null) return state
      const arrived: ScanState = {
        ...state,
        arrivedAt: event.at,
        lastTickAt: event.at,
        arrivals: state.arrivals + 1,
        seen: state.seen.includes(state.index) ? state.seen : [...state.seen, state.index],
      }
      if (state.status !== 'travelling') return arrived
      return { ...arrived, status: 'scanning' }
    }

    case 'tick':
      return tick(state, event.at)

    case 'next':
      return leave(state, event.at, state.index + 1, event.travel === true)

    case 'back': {
      const back = leave(state, event.at, Math.max(0, state.index - 1), event.travel === true)
      /*
       * Going back is the one movement that hands control over.
       *
       * At machine speed, reaching for ← means "wait — what was that", and the
       * only useful answer to that is to stop moving. Resuming is one key away
       * and is the person's decision, not the scan's.
       */
      return { ...back, status: 'paused', pausedBy: 'stepped-back' }
    }

    case 'jump':
      // Clamped rather than passed through: the trace is clickable, and a click
      // on a row that a recount has just dropped must land on the last stop
      // rather than ending the scan. `next` is the only thing allowed to walk
      // off the end.
      return leave(state, event.at, clamp(event.index, 0, Math.max(0, state.count - 1)), true)

    case 'pause': {
      if (state.status === 'idle' || state.status === 'finished') return state
      if (state.status === 'paused') return state
      return { ...state, status: 'paused', pausedBy: event.reason, lastTickAt: event.at }
    }

    case 'resume': {
      if (state.status !== 'paused') return state
      return {
        ...state,
        status: state.arrivedAt === null ? 'travelling' : 'scanning',
        pausedBy: null,
        lastTickAt: event.at,
      }
    }

    case 'stop': {
      if (state.status === 'idle') return state
      return { ...state, status: 'finished', pausedBy: null }
    }

    case 'recount': {
      if (event.count <= 0) return { ...state, count: 0, status: 'finished', pausedBy: null }
      const index = clamp(event.index, 0, event.count - 1)
      /*
       * The trace keeps only what is still addressable.
       *
       * `seen` holds playhead indices, and a recount renumbers them — so a trace
       * carried across one would label rows with the wrong stop, confidently.
       * Dropping the tail is the honest repair: what is gone is gone, and the
       * record on disk still has every stop that was shown.
       */
      return {
        ...state,
        count: event.count,
        index,
        seen: state.seen.filter((entry) => entry < event.count),
        lastTickAt: event.at,
      }
    }
  }
}

/* ------------------------------------------------------------------ ticks -- */

function tick(state: ScanState, at: number): ScanState {
  const gap = state.lastTickAt === null ? 0 : at - state.lastTickAt

  // Time did not pass here in any sense that matters. Discard the gap and hand
  // the screen back rather than running eight stops through a shut lid.
  if (gap > MAX_TICK_GAP_MS) {
    const stalled: ScanState = { ...state, lastTickAt: at, stalls: state.stalls + 1 }
    if (state.status === 'scanning' || state.status === 'travelling') {
      return { ...stalled, status: 'paused', pausedBy: 'stalled' }
    }
    return stalled
  }

  if (state.status !== 'scanning') return { ...state, lastTickAt: at }

  // A clock that runs backwards is a clock that has been swapped underneath us.
  const elapsed = state.elapsedMs + Math.max(0, gap)
  const advanced: ScanState = { ...state, lastTickAt: at, elapsedMs: elapsed }
  if (elapsed < SCAN_HOLD_MS) return advanced
  return leave(advanced, at, state.index + 1, true)
}

/* -------------------------------------------------------------- movement -- */

function leave(state: ScanState, at: number, target: number, travel: boolean): ScanState {
  if (state.status === 'idle' || state.status === 'finished') return state
  if (target >= state.count) return { ...state, status: 'finished', pausedBy: null }
  return enter(state, clamp(target, 0, state.count - 1), at, travel)
}

function enter(state: ScanState, index: number, at: number, travel: boolean): ScanState {
  return {
    ...state,
    index,
    elapsedMs: 0,
    lastTickAt: at,
    arrivedAt: travel ? null : at,
    pausedBy: null,
    status: travel ? 'travelling' : 'scanning',
    // Entering without travel means the box is already where it needs to be,
    // which is an arrival that no `arrive` event will ever be sent for.
    arrivals: travel ? state.arrivals : state.arrivals + 1,
    seen: travel || state.seen.includes(index) ? state.seen : [...state.seen, index],
  }
}

/* ------------------------------------------------------------- selectors -- */

export function isScanning(state: ScanState): boolean {
  return state.status !== 'idle' && state.status !== 'finished'
}

/**
 * How far through the whole scan, 0 to 1.
 *
 * Across the scan rather than within one stop, which is the opposite of what the
 * old progress ring showed. A ring filling over one stop was a promise about
 * when the app would move on, which a reader needed and a watcher does not: at
 * machine speed the only interesting question is how much of the fleet is left.
 */
export function scanProgress(state: ScanState): number {
  if (!isScanning(state) || state.count === 0) return 0
  const within = clamp(state.elapsedMs / SCAN_HOLD_MS, 0, 1)
  return clamp((state.index + within) / state.count, 0, 1)
}

/** "4 of 11". One-based, because the trace beside it is not counting from zero. */
export function positionLabel(state: ScanState): string {
  if (state.count === 0) return ''
  return `${state.index + 1} of ${state.count}`
}

/** What a pause is called, in the person's terms rather than the event's. */
export function pauseSentence(reason: PauseReason): string {
  switch (reason) {
    case 'asked':
      return 'Held'
    case 'scrolled':
      return 'Held — you scrolled'
    case 'clicked':
      return 'Held — you clicked'
    case 'typed':
      return 'Held — you typed'
    case 'selected':
      return 'Held — you selected some text'
    case 'left-window':
      return 'Held — you left the window'
    case 'hidden':
      return 'Held — the window was hidden'
    case 'stepped-back':
      return 'Held — you went back'
    case 'consent':
      return 'Held — something needs your permission'
    case 'stalled':
      return 'Held — the window stopped running'
  }
}

/**
 * The one line under the trace. Never blank while a scan is running.
 *
 * "Scanning" rather than a countdown, and that is the whole difference: there is
 * no number to give because there is nothing to wait for. The old version said
 * *"about 3 min left"*, which was an accurate answer to a question nobody is
 * asking any more.
 */
export function statusSentence(state: ScanState): string {
  switch (state.status) {
    case 'idle':
      return ''
    case 'finished':
      return 'Done — the answer is in the chat'
    case 'travelling':
    case 'scanning':
      return `Scanning · ${positionLabel(state)}`
    case 'paused':
      return `${state.pausedBy === null ? 'Held' : pauseSentence(state.pausedBy)} · Space to carry on`
  }
}

/* ---------------------------------------------------------- the answer -- */

/**
 * One line of the answer: a thing that happened, in one session.
 *
 * Structural rather than tied to the record type on either side of the bridge.
 * The main process owns `TourStopRecord` and the renderer mirrors it, for the
 * reason `importance.ts` gives about the tsconfig boundary; making this function
 * demand that exact type would drag the whole record shape into `shared/` for no
 * gain. What it actually needs is four fields, so it asks for four fields.
 */
export interface AnswerLine {
  readonly why: string
  readonly note: string
  readonly quote: string
  /**
   * Whether this finding reached the person.
   *
   * False only for a stop a **visible** scan was stopped before it got to. A
   * scan run with interactive mode off delivers every finding — that is the
   * whole of what "the answer must be identical either way" means — so nothing
   * in a background scan is ever marked as missed. Getting this backwards would
   * put "Not reached" against every line of a scan that found everything, which
   * says the work was not done when the work is exactly what is being shown.
   */
  readonly shown: boolean
}

/** Everything the scan found in one session, in the order it found it. */
export interface AnswerSession {
  readonly sessionId: string
  readonly title: string
  readonly lines: readonly AnswerLine[]
}

interface GroupableStop {
  readonly sessionId: string
  readonly sessionTitle: string
  readonly why: string
  readonly note: string
  readonly quote: string
  readonly shownAt: number | null
}

/**
 * The answer, grouped the way he asked for it.
 *
 * > *"It returns to its own chat and combines everything into one structured
 * > response: this session did this, this session did that."*
 *
 * So the unit of the answer is the **session**, not the stop — which is not how
 * the scan itself is ordered. A scan visits stops in importance order, and the
 * same session can come up twice with two different reasons; reading that back
 * as a flat list means the person reassembles "what happened in session X" in
 * their head, which is the work this is supposed to save.
 *
 * Sessions keep the order of their **first** stop, so the most important session
 * is still first and the grouping does not quietly reorder the fleet against
 * what was just on screen. Within a session the stops keep scan order.
 */
export function groupBySession(
  stops: readonly GroupableStop[],
  options: { background?: boolean } = {},
): AnswerSession[] {
  const delivered = options.background === true
  const order: string[] = []
  const byId = new Map<string, { title: string; lines: AnswerLine[] }>()

  for (const stop of stops) {
    let entry = byId.get(stop.sessionId)
    if (entry === undefined) {
      entry = { title: stop.sessionTitle, lines: [] }
      byId.set(stop.sessionId, entry)
      order.push(stop.sessionId)
    }
    entry.lines.push({
      why: stop.why,
      note: stop.note,
      quote: stop.quote,
      shown: delivered || stop.shownAt !== null,
    })
  }

  return order.map((sessionId) => {
    const entry = byId.get(sessionId)
    return {
      sessionId,
      title: entry?.title ?? '',
      lines: entry?.lines ?? [],
    }
  })
}

/**
 * "Looked at 9 things across 4 sessions", or the honest version when the scan
 * was cut short.
 *
 * The count is of what was actually **shown**, never of what was planned. A
 * summary that counted the plan would tell somebody who pressed Escape after two
 * stops that eleven things were looked at, which is the one sentence in this
 * feature that must never be wrong.
 */
export function answerSummary(sessions: readonly AnswerSession[]): string {
  let shown = 0
  let sessionsShown = 0
  for (const session of sessions) {
    const here = session.lines.filter((line) => line.shown).length
    shown += here
    if (here > 0) sessionsShown += 1
  }
  if (shown === 0) return 'Nothing was shown.'
  const things = `${shown} thing${shown === 1 ? '' : 's'}`
  const where = `${sessionsShown} session${sessionsShown === 1 ? '' : 's'}`
  return `${things} across ${where}.`
}

/* --------------------------------------------------------------- helpers -- */

export function clamp(value: number, low: number, high: number): number {
  return Math.min(high, Math.max(low, value))
}
