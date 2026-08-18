import { describe, expect, it } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import {
  MAX_TICK_GAP_MS,
  SCAN_HOLD_MS,
  answerSummary,
  groupBySession,
  initialScanState,
  isScanning,
  pauseSentence,
  scanProgress,
  scanReducer,
  statusSentence,
  type ScanEvent,
  type ScanState,
} from './scan'

/**
 * The scan playhead, against a fake clock.
 *
 * The whole reason this module is a pure reducer over an injected `at` is that
 * timing is the one part of driving mode that cannot be checked by looking at
 * the screen — a stop that is 40 ms too long and a stop that is 400 ms too long
 * look identical in a screenshot, and only one of them is the feature.
 */

function play(count = 3, at = 0): ScanState {
  return scanReducer(initialScanState(), { kind: 'play', at, count })
}

function run(state: ScanState, events: ScanEvent[]): ScanState {
  return events.reduce(scanReducer, state)
}

/* ------------------------------------------------------- the inversion -- */

describe('the scan runs at machine speed, not reading speed', () => {
  it('holds every stop for exactly the same time, whatever it says', () => {
    /*
     * This is the assertion the whole rewrite exists for, and it is written as a
     * *sameness* check on purpose. The old engine took the quote and the note,
     * counted words, corrected for symbol density and divided by a chosen
     * words-a-minute — so two stops were almost never the same length. Now
     * nothing in this module has ever seen the text of a stop: the reducer takes
     * a `count` and not a list of quotes, which is what makes it structurally
     * impossible to reintroduce a per-stop reading estimate without changing the
     * shape of `play`.
     */
    let state = run(play(3, 0), [{ kind: 'arrive', at: 0 }])
    expect(state.status).toBe('scanning')

    state = scanReducer(state, { kind: 'tick', at: SCAN_HOLD_MS - 1 })
    expect(state.index).toBe(0)

    state = scanReducer(state, { kind: 'tick', at: SCAN_HOLD_MS })
    expect(state.index).toBe(1)
    expect(state.status).toBe('travelling')
  })

  it('is fast enough to be watched and slow enough to be seen', () => {
    /*
     * A range rather than the number, so somebody tuning it has room and
     * somebody deleting the reasoning does not. Below ~150 ms consecutive
     * positions blur into one another — a saccade plus a fixation is about
     * 150 ms — and the box reads as flicker rather than as having been anywhere.
     * Above ~400 ms it stops looking like a machine and starts looking like the
     * slideshow this replaced.
     */
    expect(SCAN_HOLD_MS).toBeGreaterThanOrEqual(150)
    expect(SCAN_HOLD_MS).toBeLessThanOrEqual(400)
  })

  it('does not start the clock until the box is actually drawn', () => {
    // Travel is not scanning. At 260 ms a stop, charging a tab switch and an
    // xterm refit against the hold would eat most of it, and the stop nobody
    // saw would be the one on the slowest session.
    let state = play(2, 0)
    expect(state.status).toBe('travelling')
    state = scanReducer(state, { kind: 'tick', at: 900 })
    expect(state.index).toBe(0)
    expect(state.status).toBe('travelling')
  })
})

/* -------------------------------------------------------- interruption -- */

describe('the person is still the authority', () => {
  it('stops on anything they did, and stays stopped', () => {
    const state = run(play(3, 0), [
      { kind: 'arrive', at: 0 },
      { kind: 'pause', at: 10, reason: 'clicked' },
      { kind: 'tick', at: 10 + SCAN_HOLD_MS * 4 },
    ])
    expect(state.status).toBe('paused')
    expect(state.index).toBe(0)
  })

  it('hands over when they step back, because that means they missed something', () => {
    /*
     * The asymmetry between ← and →. Pressing → is "carry on from there" and the
     * scan keeps running; reaching for ← at machine speed means "wait, what was
     * that", and the only useful answer to that is to stop moving. Answering it
     * with another 260 ms countdown would make the gesture useless.
     */
    // `travel: true` on both, as the player always sends them: moving to a stop
    // is a navigation and the clock must not start before the box is drawn.
    const forward = run(play(3, 0), [
      { kind: 'arrive', at: 0 },
      { kind: 'next', at: 5, travel: true },
    ])
    expect(forward.status).toBe('travelling')

    const back = run(forward, [
      { kind: 'arrive', at: 6 },
      { kind: 'back', at: 7, travel: true },
    ])
    expect(back.status).toBe('paused')
    expect(back.pausedBy).toBe('stepped-back')
  })

  it('discards a gap that means the renderer was not running', () => {
    /*
     * A shut lid, a hidden window, a machine asleep. The gap is thrown away
     * *and* the scan stops, because coming back to a screen already in motion is
     * the worst frame of the whole feature — and at this speed it would already
     * have walked the whole fleet.
     */
    const state = run(play(4, 0), [
      { kind: 'arrive', at: 0 },
      { kind: 'tick', at: MAX_TICK_GAP_MS + 1 },
    ])
    expect(state.status).toBe('paused')
    expect(state.pausedBy).toBe('stalled')
    expect(state.index).toBe(0)
    expect(state.stalls).toBe(1)
  })
})

/* --------------------------------------------------------- the trace -- */

describe('the trace, which is what a person can actually follow', () => {
  it('records every stop the box was drawn at, once', () => {
    const state = run(play(3, 0), [
      { kind: 'arrive', at: 0 },
      { kind: 'next', at: 1, travel: true },
      { kind: 'arrive', at: 2 },
      { kind: 'back', at: 3, travel: true },
      { kind: 'arrive', at: 4 },
    ])
    expect(state.seen).toEqual([0, 1])
    // Three arrivals, two of them somewhere new. The dot field pulses on the
    // arrival count rather than on the trace, so going back still shows the
    // machine landing.
    expect(state.arrivals).toBe(3)
  })

  it('drops trace entries a recount has renumbered rather than mislabelling them', () => {
    /*
     * `seen` holds playhead indices, and a recount — a session that closed while
     * the scan was held — renumbers them. Carrying the old numbers across would
     * label rows with the wrong stop, confidently, which is the failure mode
     * this whole feature is most careful about.
     */
    const state = run(play(5, 0), [
      { kind: 'arrive', at: 0 },
      { kind: 'next', at: 1, travel: true },
      { kind: 'arrive', at: 2 },
      { kind: 'next', at: 3, travel: true },
      { kind: 'arrive', at: 4 },
      { kind: 'recount', at: 5, count: 2, index: 1 },
    ])
    expect(state.count).toBe(2)
    expect(state.seen).toEqual([0, 1])
  })
})

/* -------------------------------------------------------- the wording -- */

describe('what the panel says', () => {
  it('measures progress across the fleet, not across one stop', () => {
    /*
     * The opposite of the ring it replaces. A ring filling over one stop was a
     * promise about when the app would move on, which a reader needed and a
     * watcher does not: at machine speed the only interesting question is how
     * much of the fleet is left.
     */
    const start = run(play(4, 0), [{ kind: 'arrive', at: 0 }])
    expect(scanProgress(start)).toBeCloseTo(0, 5)
    const third = run(start, [
      { kind: 'next', at: 1, travel: true },
      { kind: 'arrive', at: 2 },
      { kind: 'next', at: 3, travel: true },
      { kind: 'arrive', at: 4 },
    ])
    expect(scanProgress(third)).toBeCloseTo(0.5, 5)
  })

  it('never leaves a running scan with nothing to say', () => {
    // A moving screen with a blank status line reads as a hang, and at this
    // speed a person cannot tell a stalled scan from a fast one by watching.
    for (const status of ['travelling', 'scanning', 'paused'] as const) {
      const state: ScanState = { ...play(3, 0), status }
      expect(statusSentence(state)).not.toBe('')
    }
    expect(statusSentence({ ...play(3, 0), status: 'finished' })).toContain('answer')
  })

  it('names every reason it could have stopped for', () => {
    // A stopped scan that does not say what stopped it looks broken — and at
    // machine speed the person will not have seen which of their own gestures
    // did it.
    const reasons = [
      'asked',
      'scrolled',
      'clicked',
      'typed',
      'selected',
      'left-window',
      'hidden',
      'stepped-back',
      'consent',
      'stalled',
    ] as const
    for (const reason of reasons) expect(pauseSentence(reason)).not.toBe('')
  })

  it('is not running before it plays or after it finishes', () => {
    expect(isScanning(initialScanState())).toBe(false)
    expect(isScanning(play(0, 0))).toBe(false)
    expect(isScanning(play(2, 0))).toBe(true)
  })
})

/* --------------------------------------------------------- the answer -- */

describe('the answer, which is the half that gets read', () => {
  const stop = (sessionId: string, title: string, note: string, shownAt: number | null) => ({
    sessionId,
    sessionTitle: title,
    why: 'finished',
    note,
    quote: 'q',
    shownAt,
  })

  it('groups by session, keeping each session at its most important stop', () => {
    /*
     * *"This session did this, this session did that."* A scan visits stops in
     * importance order and one session can come up twice, so a flat list makes
     * the reader reassemble "what happened in session X" from rows four apart —
     * which is the work this whole feature exists to save.
     *
     * Sessions keep the order of their FIRST stop, so the grouping never quietly
     * reorders the fleet against what was just on screen.
     */
    const grouped = groupBySession([
      stop('a', 'api', 'one', 1),
      stop('b', 'web', 'two', 2),
      stop('a', 'api', 'three', 3),
    ])
    expect(grouped.map((entry) => entry.sessionId)).toEqual(['a', 'b'])
    expect(grouped[0].lines.map((line) => line.note)).toEqual(['one', 'three'])
  })

  it('counts what was shown, never what was planned', () => {
    /*
     * The one sentence in this feature that must never be wrong. Somebody who
     * pressed Escape after two stops must not be told that eleven things were
     * looked at.
     */
    const grouped = groupBySession([
      stop('a', 'api', 'one', 1),
      stop('b', 'web', 'two', null),
      stop('c', 'db', 'three', null),
    ])
    expect(answerSummary(grouped)).toBe('1 thing across 1 session.')
  })

  it('says so plainly when nothing was shown at all', () => {
    const grouped = groupBySession([stop('a', 'api', 'one', null)])
    expect(answerSummary(grouped)).toBe('Nothing was shown.')
  })
})

/* ------------------------------------------------------- the deletion -- */

describe('the reading-time model is gone, not turned down', () => {
  it('leaves nothing behind that computes how long text takes to read', () => {
    /*
     * A guard rather than a comment, because this is the instruction the whole
     * rewrite answers to: *"delete what the new model makes meaningless rather
     * than leaving it configured to zero — a dial that no longer does anything
     * is exactly the kind of thing he has been finding all night."*
     *
     * The failure it catches is somebody restoring the old engine one helper at
     * a time, each of which looks harmless on its own. If a future feature does
     * genuinely need to estimate reading time, this test is where the argument
     * for it has to be made.
     */
    const root = new URL('../renderer/copilot/driving', import.meta.url).pathname
    const files = readdirSync(root)
    expect(files).not.toContain('estimate.ts')
    expect(files).not.toContain('pacer.ts')
    expect(files).not.toContain('reading-speed.ts')
    expect(files).not.toContain('PaceControls.tsx')

    const banned = /wordsPerMinute|wordsAMinute|\bwpm\b|readingTimeMs|stopDwellMs/
    for (const name of files) {
      if (!name.endsWith('.ts') && !name.endsWith('.tsx')) continue
      const text = readFileSync(join(root, name), 'utf8')
      expect(banned.test(text), `${name} still computes a reading time`).toBe(false)
    }
  })
})
