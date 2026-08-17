/**
 * The playhead: what the tour is showing, for how much longer, and every reason
 * it is not moving.
 *
 * This is the pacing half of DRIVING-MODE.md §9's `tour-state.ts`. The
 * navigation half — which session, which anchor, where to scroll — is not here
 * and should not be: this module never touches the DOM, never knows what a
 * session is, and can be run entirely from a fake clock. Everything that makes
 * pacing hard is a timing question, and timing questions are the ones that
 * cannot be checked by looking at the screen.
 *
 * ## The rule the whole file is built around
 *
 * **The reader is the authority and the estimate is only a default.**
 *
 * `estimate.ts` says how long a stop probably takes. This module's job is to
 * make sure that guess is never allowed to win an argument with the person
 * watching. Every one of the transitions below exists because there is some way
 * for the tour to be wrong about a reader, and the correct response to being
 * wrong about a reader is to stop.
 *
 * ## Interaction is evidence, not a hint
 *
 * A scroll, a click, a keystroke, a text selection, the window losing focus —
 * every one of them **pauses**, immediately and completely. Not "slows down",
 * not "extends this stop": pauses, and stays paused until the reader says
 * otherwise. Somebody who touched something is not finished reading, and that
 * is not a probabilistic claim that deserves a heuristic. It is the single most
 * likely way this feature ends up switched off, and Asad named it first.
 *
 * The one interaction that does **not** pause is `next`. Pressing → is the only
 * gesture in the set that unambiguously means "I have finished with this", so
 * treating it as evidence of the opposite would be perverse — and it would also
 * break the two things that make a fast reader's experience bearable, because
 * both the learned speed and the Skim offer need to watch somebody advance
 * early several times in a row *while the tour is still running*.
 *
 * DRIVING-MODE.md §8's table says ← and → both "pause auto-advance for the rest
 * of the tour", which contradicts its own §5 ("converges within about four
 * stops", "after three consecutive early advances, the panel offers Skim") —
 * neither is observable if the first → stops the clock. Resolved in favour of
 * §5, with the split drawn where the evidence actually is: **→ keeps playing,
 * ← pauses.** Going back means something was missed, and the reader who missed
 * it needs time rather than another countdown.
 *
 * ## Time that is not reading time
 *
 * Three kinds of elapsed wall-clock are deliberately not credited:
 *
 * - **Travel.** The clock does not start until `arrive`. A stop whose scroll
 *   animation ate 300 ms of its own dwell is a stop that felt rushed for a
 *   reason nobody could see.
 * - **Hover.** While the pointer rests inside the highlighted box the clock is
 *   frozen. It is the cheapest possible way for a reader to say "still on this"
 *   — no badge, nothing to dismiss, and it costs nothing to express.
 * - **Stalls.** If two ticks arrive more than `MAX_TICK_GAP_MS` apart, the
 *   renderer was not running: the lid was shut, the window was hidden, the
 *   machine slept. That gap is not reading, and a tour that had advanced eight
 *   stops while the laptop was closed is exactly the kind of thing that gets a
 *   feature turned off. The gap is discarded *and* the tour pauses, because
 *   coming back to a screen already in motion is the worst frame of the whole
 *   feature.
 */

import {
  FIXATION_MS,
  clamp,
  effectiveWpm,
  forgetLearned,
  isHold,
  learn,
  stopDwellMs,
  type PaceName,
  type PacedStop,
  type ReadingSpeed,
  DEFAULT_SPEED,
} from './estimate'

/* ---------------------------------------------------------------- shapes -- */

export type PacerStatus =
  /** Nothing is playing. */
  | 'idle'
  /** Moving to a stop; the clock has not started. */
  | 'travelling'
  /** The box is drawn and the estimate is running down. */
  | 'playing'
  /** Something the reader did stopped it. */
  | 'paused'
  /** Too long to automate — waiting for the reader to press next. */
  | 'holding'
  /** Past the last stop, or stopped by hand. */
  | 'finished'

/**
 * Why it is not moving. Every one of these is shown to the reader in words,
 * because a paused tour that does not say what paused it looks broken.
 */
export type PauseReason =
  /** The Pause button, or Space. */
  | 'asked'
  | 'scrolled'
  | 'clicked'
  | 'typed'
  | 'selected'
  | 'left-window'
  | 'hidden'
  /** Stepped back — see the note about ← above. */
  | 'stepped-back'
  /** A permission prompt arrived. DRIVING-MODE.md §7: it outranks the tour. */
  | 'consent'
  /** The renderer stopped running for a while. See `MAX_TICK_GAP_MS`. */
  | 'stalled'

export interface PacerState {
  readonly status: PacerStatus
  readonly stops: readonly PacedStop[]
  /**
   * One estimate per stop, computed when the stops or the speed change.
   *
   * Kept rather than derived per frame because "how much is left" sums all of
   * them and the transport asks for it several times a second. Recomputing
   * `textStats` over a dozen 600-character quotes at that rate is work nobody
   * needs to do while a terminal is repainting beside it.
   */
  readonly dwells: readonly number[]
  readonly index: number
  /** Reading time credited at this stop. Excludes travel, hover and stalls. */
  readonly elapsedMs: number
  readonly speed: ReadingSpeed
  readonly pausedBy: PauseReason | null
  readonly hovering: boolean
  /** Time the hover-hold froze at this stop. Evidence that the reader is slow. */
  readonly heldMs: number
  /** Clock time before which the driven surface is still in motion. */
  readonly settledAt: number
  readonly lastTickAt: number | null
  /** When the box was drawn, or null while travelling. */
  readonly arrivedAt: number | null
  /** When the last *automatic* advance happened, for spotting a rewind. */
  readonly autoAdvancedAt: number | null
  /** Consecutive stops the reader got ahead of. Drives the Skim offer. */
  readonly earlyRun: number
  /** How many renderer stalls have been swallowed. Reported, not hidden. */
  readonly stalls: number
}

export type PacerEvent =
  | { kind: 'play'; at: number; stops: readonly PacedStop[]; travel?: boolean }
  /** Travel finished and the box is drawn. Starts the clock. */
  | { kind: 'arrive'; at: number }
  | { kind: 'tick'; at: number }
  | { kind: 'next'; at: number; travel?: boolean }
  | { kind: 'back'; at: number; travel?: boolean }
  | { kind: 'jump'; at: number; index: number; travel?: boolean }
  | { kind: 'pause'; at: number; reason: PauseReason }
  | { kind: 'resume'; at: number }
  | { kind: 'stop'; at: number }
  /** The driven surface scrolled, from any source. Blocks advancing. */
  | { kind: 'moved'; at: number }
  | { kind: 'hover'; at: number; inside: boolean }
  | { kind: 'pace'; at: number; pace: PaceName }
  | { kind: 'forget-learned'; at: number }

/* ------------------------------------------------------------- constants -- */

/**
 * How long after the last scroll event the surface counts as still.
 *
 * Never advance while the reader is mid-scroll — but "mid-scroll" is not one
 * event, it is a burst of them, and the gaps inside one gesture are what this
 * number has to bridge. A trackpad fling emits a `scroll` every frame (~16 ms);
 * a slow deliberate two-finger drag can leave 150–250 ms between notches;
 * macOS momentum keeps firing for a second or more after the fingers lift.
 *
 * 400 ms clears the largest gap inside a single deliberate gesture without
 * leaving the tour frozen noticeably after the reader stops. It is a floor on
 * advancing, not a timer of its own: nothing waits for it except the decision
 * to move on.
 */
export const SCROLL_SETTLE_MS = 400

/**
 * A gap between ticks that means the renderer was not running.
 *
 * A busy frame is 16 ms, a bad one 200 ms, a garbage collection maybe 300. One
 * full second is not a slow frame — it is a window that was hidden, throttled
 * or asleep. `requestAnimationFrame` stops entirely in a background window,
 * which is exactly why the loop is built on it rather than on `setTimeout`;
 * this is the other half of that defence, for the case where it resumes.
 */
export const MAX_TICK_GAP_MS = 1_000

/**
 * The earliest an advance can be read as "I read that quickly".
 *
 * Below this the reader did not read it, they skipped it — the box had barely
 * finished fading in. A skip is a real signal about the *tour* (it feeds the
 * Skim offer) and no signal at all about reading speed, so it is counted in one
 * place and not the other. Set one full second past the fixation allowance,
 * which is the earliest moment at which any words have been taken in at all.
 */
export const SKIP_FLOOR_MS = FIXATION_MS + 1_000

/**
 * A `back` within this long of an automatic advance is a rewind.
 *
 * The tour moved on and the reader immediately pulled it back, which is the
 * clearest evidence there is that the estimate was too fast. Long enough to
 * cover reaching for the key and noticing what happened; short enough that
 * going back to something three stops later is not mistaken for it.
 */
export const REWIND_WINDOW_MS = 4_000

/**
 * What a rewind teaches.
 *
 * A fixed nudge, not a computed ratio, and the honesty is the point: a rewind
 * says the estimate was too fast and says **nothing about by how much**.
 * Deriving a magnitude from it would be inventing data. 0.8 is a quarter-step
 * slower — smaller than one named pace — so a single mis-press cannot move the
 * reader's speed anywhere they would notice, and three of them will.
 */
export const REWIND_SAMPLE = 0.8

/** Early advances in a row before the panel offers to skip to the recap. */
export const SKIM_AFTER = 3

/* --------------------------------------------------------------- opening -- */

export function initialPacerState(speed: ReadingSpeed = DEFAULT_SPEED): PacerState {
  return {
    status: 'idle',
    stops: [],
    dwells: [],
    index: 0,
    elapsedMs: 0,
    speed,
    pausedBy: null,
    hovering: false,
    heldMs: 0,
    settledAt: 0,
    lastTickAt: null,
    arrivedAt: null,
    autoAdvancedAt: null,
    earlyRun: 0,
    stalls: 0,
  }
}

/* --------------------------------------------------------------- reducer -- */

export function pacerReducer(state: PacerState, event: PacerEvent): PacerState {
  switch (event.kind) {
    case 'play': {
      const dwells = event.stops.map((stop) => stopDwellMs(stop, state.speed))
      const opened: PacerState = {
        ...initialPacerState(state.speed),
        stops: event.stops,
        dwells,
        lastTickAt: event.at,
      }
      if (event.stops.length === 0) return { ...opened, status: 'finished' }
      return enterStop(opened, 0, event.at, event.travel === true)
    }

    case 'arrive': {
      /*
       * Recorded whatever the status is, and only *acted on* while travelling.
       *
       * The case that forces the split: the reader scrolls while the tour is
       * still scrolling to a stop, so the tour pauses mid-travel; the scroll
       * animation then finishes and the driver reports the arrival it was
       * always going to report. Ignoring it because the status was `paused`
       * left `arrivedAt` null for good, and `resume` sends a tour with a fully
       * drawn box back to `travelling` — waiting for a second arrival that
       * nothing will ever send.
       */
      if (state.arrivedAt !== null) return state
      const arrived: PacerState = { ...state, arrivedAt: event.at, lastTickAt: event.at }
      if (state.status !== 'travelling') return arrived
      return { ...arrived, status: isHold(dwellOf(state)) ? 'holding' : 'playing' }
    }

    case 'tick':
      return tick(state, event.at)

    case 'next':
      return leave(state, event.at, state.index + 1, true, event.travel === true)

    case 'back': {
      // A rewind is the strongest "too fast" signal there is, and it is only a
      // rewind if the tour moved on by itself a moment ago. Stepping back to
      // something from five stops ago is navigation, not feedback.
      const rewound =
        state.autoAdvancedAt !== null && event.at - state.autoAdvancedAt <= REWIND_WINDOW_MS
      const taught = rewound ? { ...state, speed: learn(state.speed, REWIND_SAMPLE) } : state
      const back = leave(taught, event.at, Math.max(0, state.index - 1), true, event.travel === true)
      // Going back means something was missed. Another countdown is the wrong
      // response to that, so ← always hands control over.
      return { ...back, status: 'paused', pausedBy: 'stepped-back' }
    }

    case 'jump':
      // Clamped rather than passed through, because a jump is navigation: the
      // stop list is clickable, and a click past the end of a tour that has
      // just had stops dropped from it must land on the last stop rather than
      // ending the tour. `next` is the only thing allowed to walk off the end.
      return leave(
        state,
        event.at,
        clamp(event.index, 0, Math.max(0, state.stops.length - 1)),
        true,
        event.travel === true,
      )

    case 'pause': {
      if (state.status === 'idle' || state.status === 'finished') return state
      if (state.status === 'paused') return state
      return { ...state, status: 'paused', pausedBy: event.reason, lastTickAt: event.at }
    }

    case 'resume': {
      if (state.status !== 'paused') return state
      return { ...state, ...resumedStatus(state), pausedBy: null, lastTickAt: event.at }
    }

    case 'stop': {
      if (state.status === 'idle') return state
      return { ...state, status: 'finished', pausedBy: null, hovering: false }
    }

    case 'moved':
      // Deliberately does not pause. The only scrolls that reach here without a
      // user gesture behind them are the tour's own travel and a live session
      // appending output; pausing on the second would freeze the tour on any
      // busy fleet, which is most of them. A scroll the *reader* made arrives
      // as a `pause` from the interruption watch, off `wheel`, not off this.
      return { ...state, settledAt: Math.max(state.settledAt, event.at + SCROLL_SETTLE_MS) }

    case 'hover': {
      if (state.hovering === event.inside) return state
      return { ...state, hovering: event.inside, lastTickAt: event.at }
    }

    case 'pace': {
      // Re-estimate every stop, including the one on screen. The reader changed
      // their pace *because* the current stop was wrong for them, so applying it
      // only from the next stop onwards answers the wrong question.
      const speed: ReadingSpeed = { pace: event.pace, scale: state.speed.scale }
      return reprice({ ...state, speed })
    }

    case 'forget-learned':
      return reprice({ ...state, speed: forgetLearned(state.speed) })
  }
}

/* ----------------------------------------------------------------- ticks -- */

function tick(state: PacerState, at: number): PacerState {
  const gap = state.lastTickAt === null ? 0 : at - state.lastTickAt

  // Time did not pass here in any sense that matters. Discard the gap and hand
  // the tour back rather than crediting an hour of sleep as an hour of reading.
  if (gap > MAX_TICK_GAP_MS) {
    const stalled: PacerState = { ...state, lastTickAt: at, stalls: state.stalls + 1 }
    if (state.status === 'playing' || state.status === 'travelling') {
      return { ...stalled, status: 'paused', pausedBy: 'stalled' }
    }
    return stalled
  }

  // A clock that runs backwards is a clock that has been swapped underneath us.
  const elapsedGap = Math.max(0, gap)

  if (state.status !== 'playing') return { ...state, lastTickAt: at }

  // Hover-hold: the pointer is on the thing being read, so nothing is spent —
  // but the time is remembered, because it is the only evidence the app gets
  // that a reader is slower than the estimate without them pressing anything.
  if (state.hovering) {
    return { ...state, lastTickAt: at, heldMs: state.heldMs + elapsedGap }
  }

  const elapsed = state.elapsedMs + elapsedGap
  const advanced: PacerState = { ...state, lastTickAt: at, elapsedMs: elapsed }
  if (elapsed < dwellOf(state)) return advanced

  // Never advance out from under a moving pane, whatever the clock says.
  if (at < state.settledAt) return advanced

  return leave(advanced, at, state.index + 1, false, false)
}

/* ------------------------------------------------------------- movements -- */

/**
 * Leave the current stop for another, learning whatever the way it was left
 * has to teach.
 */
function leave(
  state: PacerState,
  at: number,
  target: number,
  manual: boolean,
  travel: boolean,
): PacerState {
  if (state.status === 'idle' || state.status === 'finished') return state

  const observed = observeLeaving(state, manual)
  const carried: PacerState = {
    ...state,
    speed: observed.speed,
    earlyRun: observed.earlyRun,
    autoAdvancedAt: manual ? state.autoAdvancedAt : at,
  }
  const repriced = observed.speed === state.speed ? carried : reprice(carried)

  if (target >= state.stops.length) {
    return { ...repriced, status: 'finished', hovering: false, pausedBy: null }
  }
  return enterStop(repriced, clamp(target, 0, state.stops.length - 1), at, travel)
}

function enterStop(state: PacerState, index: number, at: number, travel: boolean): PacerState {
  const arrived = travel ? null : at
  const dwell = state.dwells[index] ?? 0
  return {
    ...state,
    index,
    elapsedMs: 0,
    heldMs: 0,
    lastTickAt: at,
    arrivedAt: arrived,
    pausedBy: null,
    status: travel ? 'travelling' : isHold(dwell) ? 'holding' : 'playing',
  }
}

/** Where a resume lands, which is wherever the pause interrupted. */
function resumedStatus(state: PacerState): { status: PacerStatus } {
  if (state.arrivedAt === null) return { status: 'travelling' }
  return { status: isHold(dwellOf(state)) ? 'holding' : 'playing' }
}

/** Re-estimate every stop against the current speed, keeping the playhead. */
function reprice(state: PacerState): PacerState {
  return { ...state, dwells: state.stops.map((stop) => stopDwellMs(stop, state.speed)) }
}

/* ------------------------------------------------------------- observing -- */

/**
 * What leaving a stop this way says about the reader, if anything.
 *
 * Three signals count as evidence and one deliberately does not.
 *
 * **Early advance (fast).** The reader pressed → before the estimate ran out,
 * far enough in to have actually read something. The ratio is taken over the
 * *reading* part of the dwell, with the fixation allowance removed from both
 * sides — leaving it in would make every short stop look like the reader was
 * faster than they are, because the 450 ms is a constant that does not scale.
 *
 * **Hover-hold (slow).** The reader kept the pointer on the box past the
 * estimate. `dwell / (dwell + held)` is below 1 by exactly the fraction they
 * needed extra.
 *
 * **A rewind (slow).** Handled in the `back` case, because it is about the stop
 * being left *behind*, not the one being left.
 *
 * **A timeout nobody reacted to teaches nothing**, and this is the important
 * one. The estimate expired and the reader neither hurried it nor held it.
 * That is equally consistent with "the estimate was right" and with "he was
 * looking at his phone", and a system that learns from silence will eventually
 * decide that a person who left the room reads very slowly.
 */
function observeLeaving(
  state: PacerState,
  manual: boolean,
): { speed: ReadingSpeed; earlyRun: number } {
  const dwell = dwellOf(state)
  const early = manual && state.status === 'playing' && state.elapsedMs < dwell

  if (early) {
    const run = state.earlyRun + 1
    if (state.elapsedMs < SKIP_FLOOR_MS) {
      // Skipped, not read. Counts as being ahead of the tour, teaches nothing
      // about how fast this person reads.
      return { speed: state.speed, earlyRun: run }
    }
    const estimatedReading = Math.max(1, dwell - FIXATION_MS)
    const observedReading = Math.max(1, state.elapsedMs - FIXATION_MS)
    return { speed: learn(state.speed, estimatedReading / observedReading), earlyRun: run }
  }

  if (state.heldMs > 0 && dwell > 0) {
    return { speed: learn(state.speed, dwell / (dwell + state.heldMs)), earlyRun: 0 }
  }

  return { speed: state.speed, earlyRun: 0 }
}

/* ------------------------------------------------------------- selectors -- */

export function dwellOf(state: PacerState): number {
  return state.dwells[state.index] ?? 0
}

export function currentStop(state: PacerState): PacedStop | null {
  return state.stops[state.index] ?? null
}

export function isRunning(state: PacerState): boolean {
  return state.status !== 'idle' && state.status !== 'finished'
}

/**
 * How full the ring on Next is, 0 to 1.
 *
 * Zero while travelling and while holding, and both zeroes are honest: during
 * travel nothing is being read, and a holding stop is not counting down at all,
 * so a ring creeping round would be promising an advance that is never coming.
 * The panel says so in words instead — see `statusSentence`.
 */
export function progress(state: PacerState): number {
  if (state.status === 'travelling' || state.status === 'holding') return 0
  const dwell = dwellOf(state)
  if (dwell <= 0) return 0
  return clamp(state.elapsedMs / dwell, 0, 1)
}

/** Milliseconds left on this stop, or null when nothing is counting down. */
export function stopRemainingMs(state: PacerState): number | null {
  if (state.status === 'holding' || state.status === 'travelling') return null
  if (!isRunning(state)) return null
  return Math.max(0, dwellOf(state) - state.elapsedMs)
}

/**
 * Everything still to come, this stop included.
 *
 * Holding stops contribute their estimate even though they will not advance on
 * it. The number is an answer to "how long will this take me", and a long stop
 * takes long whether the app or the reader presses the key at the end of it.
 */
export function remainingMs(state: PacerState): number {
  if (!isRunning(state)) return 0
  let total = Math.max(0, dwellOf(state) - state.elapsedMs)
  for (let index = state.index + 1; index < state.dwells.length; index += 1) {
    total += state.dwells[index]
  }
  return total
}

export function stopsLeft(state: PacerState): number {
  if (!isRunning(state)) return 0
  return Math.max(0, state.stops.length - state.index - 1)
}

/** True once the reader has got ahead of the tour often enough to be offered out. */
export function offersSkim(state: PacerState): boolean {
  return isRunning(state) && state.earlyRun >= SKIM_AFTER
}

/* --------------------------------------------------------------- wording -- */

/**
 * "4 of 11". One-based, because the reader is not counting from zero and the
 * stop list beside it is not either.
 */
export function positionLabel(state: PacerState): string {
  if (state.stops.length === 0) return ''
  return `${state.index + 1} of ${state.stops.length}`
}

/**
 * A duration, rounded the way a person would say it.
 *
 * Deliberately vague above a minute and deliberately not vague below ten
 * seconds. "about 3 min" is a useful thing to know and "about 187 seconds" is
 * not; but at the short end the reader is deciding whether to wait or press the
 * key, and that decision needs the actual number.
 *
 * Never rounds *down* across a boundary: 61 seconds is "about 2 min", not
 * "about 1 min". A time estimate that expires while the thing is still running
 * is worse than one that was generous, for the same reason `MIN_SAMPLE` exists.
 */
export function aboutDuration(ms: number): string {
  if (ms <= 0) return 'no time'
  const seconds = Math.ceil(ms / 1000)
  if (seconds < 10) return `${seconds} sec`
  if (seconds < 90) return `about ${Math.ceil(seconds / 5) * 5} sec`
  return `about ${Math.ceil(seconds / 60)} min`
}

/** What a pause is called, in the reader's terms rather than the event's. */
export function pauseSentence(reason: PauseReason): string {
  switch (reason) {
    case 'asked':
      return 'Paused'
    case 'scrolled':
      return 'Paused — you scrolled'
    case 'clicked':
      return 'Paused — you clicked'
    case 'typed':
      return 'Paused — you typed'
    case 'selected':
      return 'Paused — you selected some text'
    case 'left-window':
      return 'Paused — you left the window'
    case 'hidden':
      return 'Paused — the window was hidden'
    case 'stepped-back':
      return 'Paused — you went back'
    case 'consent':
      return 'Paused — something needs your permission'
    case 'stalled':
      return 'Paused — the window stopped running'
  }
}

/**
 * The one line under the transport. Never blank while a tour is running: a
 * stalled ring with no sentence beside it reads as a hang.
 */
export function statusSentence(state: PacerState): string {
  switch (state.status) {
    case 'idle':
      return ''
    case 'finished':
      return 'Tour finished'
    case 'travelling':
      return 'Going there…'
    case 'holding':
      return 'Long one — press → when you’re ready'
    case 'paused':
      // A middot rather than a second dash. Rendered at the rail's width the
      // two-dash version read as one run-on clause — "Paused — you scrolled —
      // Space to car…" — and the half that got cut was the half telling the
      // reader how to start it again, which is the only actionable part.
      return `${state.pausedBy === null ? 'Paused' : pauseSentence(state.pausedBy)} · Space to carry on`
    case 'playing': {
      const left = remainingMs(state)
      if (stopsLeft(state) === 0) return 'Last one'
      return `${aboutDuration(left)} left`
    }
  }
}

/**
 * "Reading at about 210 words a minute", for the sentence under the speed
 * control.
 *
 * Rounded to ten because the third significant figure of an EWMA over eight
 * observations is noise, and printing it would invite somebody to try to hit an
 * exact number with a control that has five positions.
 */
export function measuredSentence(speed: ReadingSpeed): string {
  const wpm = Math.round(effectiveWpm(speed) / 10) * 10
  return `Reading at about ${wpm} words a minute`
}
