import { describe, expect, it } from 'vitest'
import {
  FASTEST_WPM,
  FIXATION_MS,
  SLOWEST_WPM,
  effectiveWpm,
  stopDwellMs,
  type PacedStop,
  type ReadingSpeed,
} from './estimate'
import {
  MAX_TICK_GAP_MS,
  REWIND_SAMPLE,
  REWIND_WINDOW_MS,
  SCROLL_SETTLE_MS,
  SKIM_AFTER,
  SKIP_FLOOR_MS,
  aboutDuration,
  dwellOf,
  initialPacerState,
  isRunning,
  measuredSentence,
  offersSkim,
  pacerReducer,
  pauseSentence,
  positionLabel,
  progress,
  remainingMs,
  statusSentence,
  stopRemainingMs,
  stopsLeft,
  type PacerEvent,
  type PacerState,
  type PauseReason,
} from './pacer'

/**
 * The playhead, driven by a fake clock.
 *
 * Every claim here is about *timing*, which is the class of defect this
 * repository cannot see any other way: a tour that advances 40 ms early looks
 * identical in a screenshot to one that does not, and a tour that keeps
 * counting while the lid is shut looks identical to one that stops until you
 * open the lid four hours later.
 *
 * The clock is a number that only these tests move. There is no `setTimeout`,
 * no `vi.useFakeTimers`, and nothing that takes real time to run — a suite that
 * has to *wait* to check a pause is a suite nobody runs, and this app has a
 * standing rule against manufacturing load to test timing at all.
 *
 * The claims are grouped by the two failures Asad named:
 *
 *   > "some people will be reading and it keeps moving"  → §running away
 *   > "some are faster and are waiting for it to move on" → §getting ahead
 *
 * and everything before those two is the machinery both depend on.
 */

/* ----------------------------------------------------------------- setup -- */

const PROSE =
  'The migration ran twice against the same database, so two of the tables now hold ' +
  'duplicate rows and the session has stopped to ask what you want done about it.'

const STOPS: readonly PacedStop[] = [
  { quote: PROSE, note: 'It is waiting on you.' },
  { quote: 'npm test', note: 'It passed.' },
  { quote: PROSE.slice(0, 90), note: 'Then it carried on.' },
]

const STEADY: ReadingSpeed = { pace: 'steady', scale: 1 }

/** A tiny driver, so each test reads as a sequence of things a person did. */
class Run {
  state: PacerState

  constructor(speed: ReadingSpeed = STEADY) {
    this.state = initialPacerState(speed)
  }

  send(event: PacerEvent): this {
    this.state = pacerReducer(this.state, event)
    return this
  }

  play(at: number, stops: readonly PacedStop[] = STOPS, travel = false): this {
    return this.send({ kind: 'play', at, stops, travel })
  }

  /** Ticks in `step` increments to `at`, the way a frame loop actually would. */
  tickTo(at: number, step = 16): this {
    let now = this.state.lastTickAt ?? 0
    while (now < at) {
      now = Math.min(at, now + step)
      this.send({ kind: 'tick', at: now })
    }
    return this
  }
}

const dwell0 = stopDwellMs(STOPS[0], STEADY)

describe('the shape of a tour', () => {
  it('opens on the first stop, already counting', () => {
    const run = new Run().play(0)
    expect(run.state.status).toBe('playing')
    expect(run.state.index).toBe(0)
    expect(run.state.elapsedMs).toBe(0)
    expect(dwellOf(run.state)).toBe(dwell0)
  })

  it('finishes immediately on an empty plan rather than sitting at nothing', () => {
    const run = new Run().play(0, [])
    expect(run.state.status).toBe('finished')
    expect(isRunning(run.state)).toBe(false)
  })

  it('advances by itself once the estimate runs out', () => {
    const run = new Run().play(0).tickTo(dwell0 + 32)
    expect(run.state.index).toBe(1)
  })

  it('ends after the last stop instead of wrapping or sticking', () => {
    const run = new Run().play(0)
    run.send({ kind: 'next', at: 100 })
    run.send({ kind: 'next', at: 200 })
    run.send({ kind: 'next', at: 300 })
    expect(run.state.status).toBe('finished')
    expect(remainingMs(run.state)).toBe(0)
    expect(stopsLeft(run.state)).toBe(0)
  })

  it('stops where it is when told to stop', () => {
    // Esc must not snap back to where the tour started: that is a second
    // unrequested movement at the exact moment somebody asked movement to stop.
    const run = new Run().play(0).tickTo(dwell0 + 32)
    const wasAt = run.state.index
    run.send({ kind: 'stop', at: 9_000 })
    expect(run.state.status).toBe('finished')
    expect(run.state.index).toBe(wasAt)
  })
})

/* --------------------------------------------------- time that is not reading -- */

describe('time that is not reading time', () => {
  it('does not start the clock until the box is drawn', () => {
    /*
     * Travel is the scroll to the next stop. Counting it as reading is how a
     * tour that looks correctly paced on paper feels rushed on screen, and it is
     * invisible in every artefact except a stopwatch.
     */
    const run = new Run().play(0, STOPS, true)
    expect(run.state.status).toBe('travelling')
    run.tickTo(5_000)
    expect(run.state.elapsedMs).toBe(0)
    expect(run.state.index).toBe(0)

    run.send({ kind: 'arrive', at: 5_000 })
    expect(run.state.status).toBe('playing')
    run.tickTo(5_000 + dwell0 + 32)
    expect(run.state.index).toBe(1)
  })

  it('freezes while the pointer rests on the thing being read', () => {
    /*
     * Hover-hold. No badge, nothing to dismiss, nothing to learn — resting the
     * pointer on what you are reading stops the clock. It is the cheapest
     * possible way for a reader to say "still on this".
     */
    const run = new Run().play(0).tickTo(2_000)
    const before = run.state.elapsedMs
    run.send({ kind: 'hover', at: 2_000, inside: true })
    run.tickTo(2_000 + dwell0 * 3)
    expect(run.state.elapsedMs).toBe(before)
    expect(run.state.index).toBe(0)
    expect(run.state.heldMs).toBeGreaterThan(dwell0 * 2)

    run.send({ kind: 'hover', at: run.state.lastTickAt ?? 0, inside: false })
    run.tickTo((run.state.lastTickAt ?? 0) + dwell0)
    expect(run.state.index).toBe(1)
  })

  it('throws away a gap that means the renderer was not running', () => {
    /*
     * The lid-shut case. `requestAnimationFrame` stops in a hidden or sleeping
     * window and resumes with an enormous delta; crediting it would advance the
     * whole tour in one frame, with nobody watching. The gap is discarded *and*
     * the tour pauses, because coming back to a screen already in motion is the
     * worst frame in the feature.
     */
    const run = new Run().play(0).tickTo(1_000)
    const before = run.state.elapsedMs
    run.send({ kind: 'tick', at: 1_000 + MAX_TICK_GAP_MS + 1 })
    expect(run.state.elapsedMs).toBe(before)
    expect(run.state.status).toBe('paused')
    expect(run.state.pausedBy).toBe('stalled')
    expect(run.state.stalls).toBe(1)
  })

  it('credits an ordinary slow frame, because a busy frame is not a sleep', () => {
    const run = new Run().play(0)
    run.send({ kind: 'tick', at: 300 })
    expect(run.state.elapsedMs).toBe(300)
    expect(run.state.status).toBe('playing')
  })

  it('never counts backwards if the clock is swapped underneath it', () => {
    const run = new Run().play(0).tickTo(2_000)
    const before = run.state.elapsedMs
    run.send({ kind: 'tick', at: 500 })
    expect(run.state.elapsedMs).toBe(before)
  })
})

/* -------------------------------------------------------- running away -- */

describe('running away from somebody who is still reading', () => {
  const reasons: PauseReason[] = [
    'asked',
    'scrolled',
    'clicked',
    'typed',
    'selected',
    'left-window',
    'hidden',
    'consent',
  ]

  for (const reason of reasons) {
    it(`stops dead on ${reason}, and stays stopped`, () => {
      /*
       * Not "slows down", not "extends this stop". A person doing something is
       * unambiguous evidence they are not finished, and the correct response to
       * unambiguous evidence is not a heuristic.
       */
      const run = new Run().play(0).tickTo(1_000)
      run.send({ kind: 'pause', at: 1_000, reason })
      expect(run.state.status).toBe('paused')
      expect(run.state.pausedBy).toBe(reason)

      const held = run.state.elapsedMs
      run.tickTo(1_000 + dwell0 * 4)
      expect(run.state.index).toBe(0)
      expect(run.state.elapsedMs).toBe(held)
    })
  }

  it('does not resume itself when the window comes back', () => {
    // Blur pauses; focus does not un-pause. Coming back to an app whose screen
    // is already moving is the frame that gets this feature switched off.
    const run = new Run().play(0).tickTo(500)
    run.send({ kind: 'pause', at: 500, reason: 'left-window' })
    run.tickTo(20_000)
    expect(run.state.status).toBe('paused')
    run.send({ kind: 'resume', at: 20_000 })
    expect(run.state.status).toBe('playing')
  })

  it('keeps the progress it had when it resumes', () => {
    const run = new Run().play(0).tickTo(3_000)
    run.send({ kind: 'pause', at: 3_000, reason: 'scrolled' })
    run.send({ kind: 'resume', at: 60_000 })
    expect(run.state.elapsedMs).toBe(3_000)
    // And the 57 seconds it was paused for are not reading time.
    run.send({ kind: 'tick', at: 60_016 })
    expect(run.state.elapsedMs).toBe(3_016)
  })

  it('resumes into travel when it was paused before it arrived', () => {
    const run = new Run().play(0, STOPS, true)
    run.send({ kind: 'pause', at: 100, reason: 'clicked' })
    run.send({ kind: 'resume', at: 200 })
    expect(run.state.status).toBe('travelling')
  })

  it('does not lose an arrival that lands while it is paused', () => {
    /*
     * The reader scrolls while the tour is still scrolling to a stop, so it
     * pauses mid-travel; the scroll animation then finishes and the driver
     * reports the arrival it was always going to report. Dropping that arrival
     * because the status was `paused` left the tour permanently travelling
     * after the resume, waiting for a second arrival nothing will ever send.
     */
    const run = new Run().play(0, STOPS, true)
    run.send({ kind: 'pause', at: 100, reason: 'scrolled' })
    run.send({ kind: 'arrive', at: 400 })
    expect(run.state.status).toBe('paused')
    expect(run.state.arrivedAt).toBe(400)

    run.send({ kind: 'resume', at: 500 })
    expect(run.state.status).toBe('playing')
    run.tickTo(500 + dwell0 + 32)
    expect(run.state.index).toBe(1)
  })

  it('lands a jump past the end on the last stop rather than ending the tour', () => {
    // A jump is navigation — the stop list is clickable — and a click past the
    // end of a tour that has had stops dropped from it must not finish it.
    const run = new Run().play(0)
    run.send({ kind: 'jump', at: 100, index: 99 })
    expect(run.state.index).toBe(STOPS.length - 1)
    expect(run.state.status).not.toBe('finished')

    run.send({ kind: 'jump', at: 200, index: -3 })
    expect(run.state.index).toBe(0)
  })

  it('never advances while the pane is still moving, whatever the clock says', () => {
    /*
     * The mid-scroll guard, and it is a *separate* mechanism from pausing.
     * A scroll the reader made pauses (through the interruption watch); a scroll
     * anything else made — the tour's own travel, a live session appending
     * output — only blocks the advance until the surface settles. Advancing out
     * from under a moving pane is how a reader loses the thing they were
     * following mid-line.
     */
    const run = new Run().play(0).tickTo(dwell0 - 100)
    run.send({ kind: 'moved', at: dwell0 - 100 })
    run.tickTo(dwell0 + 200)
    expect(run.state.index).toBe(0)
    expect(run.state.elapsedMs).toBeGreaterThan(dwellOf(run.state))

    run.tickTo(dwell0 - 100 + SCROLL_SETTLE_MS + 32)
    expect(run.state.index).toBe(1)
  })

  it('does not pause on movement, because the tour moves the pane itself', () => {
    // If `moved` paused, the tour would pause itself the instant it scrolled to
    // a stop, and would freeze permanently on any session still printing.
    const run = new Run().play(0)
    run.send({ kind: 'moved', at: 100 })
    expect(run.state.status).toBe('playing')
    expect(run.state.pausedBy).toBeNull()
  })

  it('hands the reader the wheel on a stop too long to automate', () => {
    const long: PacedStop[] = [{ quote: PROSE.repeat(4), note: 'Long one.' }, STOPS[1]]
    const run = new Run().play(0, long)
    expect(run.state.status).toBe('holding')
    run.tickTo(10 * 60_000)
    expect(run.state.index).toBe(0)
    expect(progress(run.state)).toBe(0)
    expect(stopRemainingMs(run.state)).toBeNull()
    run.send({ kind: 'next', at: 10 * 60_000 })
    expect(run.state.index).toBe(1)
  })

  it('pauses when the reader steps back, because going back means something was missed', () => {
    const run = new Run().play(0).tickTo(dwell0 + 32)
    expect(run.state.index).toBe(1)
    run.send({ kind: 'back', at: dwell0 + 40 })
    expect(run.state.index).toBe(0)
    expect(run.state.status).toBe('paused')
    expect(run.state.pausedBy).toBe('stepped-back')
  })
})

/* -------------------------------------------------------- getting ahead -- */

describe('boring somebody who is faster than it', () => {
  it('advances at once on next, and does not treat it as an interruption', () => {
    /*
     * The one gesture that unambiguously means "I have finished with this".
     * DRIVING-MODE.md §8's table says → also pauses the tour for good; that
     * contradicts its own §5, which needs several early advances *while playing*
     * for the speed to converge and for Skim to be offered at all.
     */
    const run = new Run().play(0).tickTo(2_000)
    run.send({ kind: 'next', at: 2_000 })
    expect(run.state.index).toBe(1)
    expect(run.state.status).toBe('playing')
    expect(run.state.elapsedMs).toBe(0)
  })

  it('learns that the reader is faster when they keep getting ahead', () => {
    const run = new Run().play(0)
    const before = effectiveWpm(run.state.speed)
    // Half the estimate, three stops running, each one past the skip floor.
    for (let index = 0; index < 3; index += 1) {
      const at = (run.state.lastTickAt ?? 0) + dwellOf(run.state) / 2
      run.tickTo(at)
      run.send({ kind: 'next', at })
    }
    expect(effectiveWpm(run.state.speed)).toBeGreaterThan(before * 1.2)
  })

  it('learns nothing from a stop that was skipped rather than read', () => {
    /*
     * Pressing → within a moment of the box appearing is a skip. It says
     * something real about the *tour* — it feeds the Skim offer below — and
     * nothing at all about how fast this person reads. Treating it as a reading
     * observation would teach the app that he reads at three thousand words a
     * minute after three impatient keystrokes.
     */
    const run = new Run().play(0).tickTo(SKIP_FLOOR_MS - 200)
    const before = run.state.speed
    run.send({ kind: 'next', at: SKIP_FLOOR_MS - 200 })
    expect(run.state.speed).toBe(before)
    expect(run.state.earlyRun).toBe(1)
  })

  it('offers the document once the reader has got ahead three times', () => {
    /*
     * The honest answer to a reader faster than the tour: the fastest version of
     * a tour is not a faster tour, it is the list. An offer, never automatic —
     * deciding on somebody's behalf that they would rather read than watch is
     * the same mistake as deciding they have finished a paragraph.
     */
    const run = new Run().play(0, [STOPS[0], STOPS[0], STOPS[0], STOPS[0]])
    for (let index = 0; index < SKIM_AFTER; index += 1) {
      expect(offersSkim(run.state)).toBe(false)
      const at = (run.state.lastTickAt ?? 0) + 200
      run.tickTo(at)
      run.send({ kind: 'next', at })
    }
    expect(run.state.earlyRun).toBe(SKIM_AFTER)
    expect(offersSkim(run.state)).toBe(true)
  })

  it('forgets the run the moment the reader lets one play out', () => {
    const run = new Run().play(0, [STOPS[0], STOPS[0], STOPS[0]])
    run.send({ kind: 'next', at: 200 })
    expect(run.state.earlyRun).toBe(1)
    run.tickTo(200 + dwellOf(run.state) + 32)
    expect(run.state.earlyRun).toBe(0)
  })
})

/* ------------------------------------------------------------- learning -- */

describe('what the tour is allowed to conclude about the reader', () => {
  it('learns nothing from a timeout nobody reacted to', () => {
    /*
     * The estimate expired and the reader neither hurried it nor held it. That
     * is equally consistent with "the estimate was right" and with "he was
     * looking at his phone", and a system that learns from silence eventually
     * decides that somebody who left the room reads very slowly.
     */
    const run = new Run().play(0)
    const before = run.state.speed
    run.tickTo(dwell0 + 32)
    expect(run.state.index).toBe(1)
    expect(run.state.speed).toBe(before)
  })

  it('learns that the reader is slower when they hold past the estimate', () => {
    const run = new Run().play(0).tickTo(500)
    run.send({ kind: 'hover', at: 500, inside: true })
    run.tickTo(500 + dwell0)
    const releasedAt = 500 + dwell0
    run.send({ kind: 'hover', at: releasedAt, inside: false })
    // The 500 ms it had already read still counts, so only the rest is owed.
    run.tickTo(releasedAt + (dwell0 - 500) + 32)
    expect(run.state.index).toBe(1)
    expect(run.state.speed.scale).toBeLessThan(1)
  })

  it('reads an immediate rewind as the estimate having been too fast', () => {
    const run = new Run().play(0).tickTo(dwell0 + 32)
    expect(run.state.index).toBe(1)
    run.send({ kind: 'back', at: dwell0 + 100 })
    // A fixed nudge, not a computed ratio: a rewind says the estimate was too
    // fast and says nothing about by how much. Inventing a magnitude from it
    // would be making up data.
    expect(run.state.speed.scale).toBeLessThan(1)
    expect(run.state.speed.scale).toBeGreaterThan(REWIND_SAMPLE)
  })

  it('does not mistake ordinary navigation for a rewind', () => {
    const run = new Run().play(0).tickTo(dwell0 + 32)
    const before = run.state.speed
    run.send({ kind: 'back', at: dwell0 + REWIND_WINDOW_MS + 1_000 })
    expect(run.state.speed).toBe(before)
  })

  it('never learns its way to a speed nobody could have chosen', () => {
    // The clamp lives in `effectiveWpm`, and this is the integration proof:
    // fifty impatient advances in a row cannot take the tour past Quick.
    const run = new Run(STEADY).play(0, Array.from({ length: 50 }, () => STOPS[0]))
    for (let index = 0; index < 40; index += 1) {
      const at = (run.state.lastTickAt ?? 0) + FIXATION_MS + 1_200
      run.tickTo(at)
      run.send({ kind: 'next', at })
    }
    expect(effectiveWpm(run.state.speed)).toBeLessThanOrEqual(FASTEST_WPM)
    expect(effectiveWpm(run.state.speed)).toBeGreaterThanOrEqual(SLOWEST_WPM)
  })

  it('re-estimates the stop on screen when the pace changes', () => {
    /*
     * The reader changed their pace *because* the stop in front of them was
     * wrong for them. Applying it only from the next stop would answer a
     * question nobody asked.
     */
    const run = new Run().play(0)
    const before = dwellOf(run.state)
    run.send({ kind: 'pace', at: 100, pace: 'unhurried' })
    expect(dwellOf(run.state)).toBeGreaterThan(before)
    expect(run.state.dwells).toHaveLength(STOPS.length)
    expect(run.state.index).toBe(0)
  })

  it('keeps the choice when the measurement is thrown away', () => {
    const run = new Run({ pace: 'brisk', scale: 1.6 }).play(0)
    run.send({ kind: 'forget-learned', at: 10 })
    expect(run.state.speed).toEqual({ pace: 'brisk', scale: 1 })
  })
})

/* ------------------------------------------------------------ what it says -- */

describe('what the reader is told', () => {
  it('always has a sentence while a tour is running', () => {
    /*
     * A bar with a stalled ring and nothing written under it reads as a hang,
     * and a reader whose app looks hung clicks something — which pauses a tour
     * that was working correctly.
     */
    const runs: PacerState[] = []
    const playing = new Run().play(0)
    runs.push(playing.state)
    runs.push(pacerReducer(playing.state, { kind: 'pause', at: 1, reason: 'scrolled' }))
    runs.push(new Run().play(0, STOPS, true).state)
    runs.push(new Run().play(0, [{ quote: PROSE.repeat(4), note: '' }]).state)
    for (const state of runs) {
      expect(isRunning(state)).toBe(true)
      expect(statusSentence(state).length).toBeGreaterThan(0)
    }
  })

  it('names what paused it, in the reader’s terms', () => {
    const state = pacerReducer(new Run().play(0).state, {
      kind: 'pause',
      at: 1,
      reason: 'scrolled',
    })
    expect(statusSentence(state)).toContain('you scrolled')
    expect(statusSentence(state)).toContain('Space')
    expect(pauseSentence('stalled')).toContain('stopped running')
  })

  it('says a long stop is waiting for the reader rather than pretending to count', () => {
    const state = new Run().play(0, [{ quote: PROSE.repeat(4), note: '' }]).state
    expect(state.status).toBe('holding')
    expect(statusSentence(state)).toContain('press →')
  })

  it('counts stops from one, because nobody counts from zero', () => {
    const run = new Run().play(0)
    expect(positionLabel(run.state)).toBe(`1 of ${STOPS.length}`)
    run.send({ kind: 'next', at: 10 })
    expect(positionLabel(run.state)).toBe(`2 of ${STOPS.length}`)
  })

  it('shrinks the estimate as the tour is watched', () => {
    const run = new Run().play(0)
    const whole = remainingMs(run.state)
    expect(whole).toBeGreaterThan(dwell0)
    run.tickTo(1_000)
    expect(remainingMs(run.state)).toBeLessThan(whole)
    run.send({ kind: 'next', at: 1_000 })
    expect(remainingMs(run.state)).toBeLessThan(whole - dwell0 + 1)
  })

  it('rounds a duration the way a person would say it, and never rounds it short', () => {
    /*
     * Vague above a minute because "about 187 seconds" is not a useful thing to
     * know; exact below ten because that is where the reader is deciding whether
     * to wait or press the key. Always rounding up, because a time estimate that
     * expires while the thing is still running is worse than a generous one.
     */
    expect(aboutDuration(0)).toBe('no time')
    expect(aboutDuration(3_400)).toBe('4 sec')
    expect(aboutDuration(12_000)).toBe('about 15 sec')
    expect(aboutDuration(61_000)).toBe('about 65 sec')
    expect(aboutDuration(95_000)).toBe('about 2 min')
    expect(aboutDuration(181_000)).toBe('about 4 min')
  })

  it('reports the learned rate roundly, because its last digit is noise', () => {
    expect(measuredSentence({ pace: 'steady', scale: 1 })).toBe('Reading at about 190 words a minute')
    expect(measuredSentence({ pace: 'steady', scale: 1.113 })).toMatch(/about 210 words a minute/)
  })

  it('fills the ring over the stop and empties it at the next one', () => {
    const run = new Run().play(0)
    expect(progress(run.state)).toBe(0)
    run.tickTo(dwell0 / 2)
    expect(progress(run.state)).toBeGreaterThan(0.45)
    expect(progress(run.state)).toBeLessThan(0.55)
    run.tickTo(dwell0 + 32)
    expect(progress(run.state)).toBeLessThan(0.1)
  })

  it('shows no ring while travelling, because nothing is being read yet', () => {
    const run = new Run().play(0, STOPS, true)
    expect(progress(run.state)).toBe(0)
    expect(stopRemainingMs(run.state)).toBeNull()
    expect(statusSentence(run.state)).toBe('Going there…')
  })
})
