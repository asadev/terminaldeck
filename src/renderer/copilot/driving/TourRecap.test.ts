import { describe, expect, it } from 'vitest'
import { readRecords, watchForFinishedScans, type RecapWatch } from './TourRecap'
import type { TourRecord } from './tour'

/**
 * The second half of driving mode, and the part of it that had no test at all.
 *
 * What is checked here is not the markup — that is judged by eye on
 * `.harness/answer.tsx`, which is why the card is mountable on its own. It is
 * the two decisions that make the card show *the scan you just watched* rather
 * than the one before it:
 *
 *  1. **which announcements make it read again**, and, as sharply, which do not;
 *  2. **which records it will show**, now that a re-read can land in the middle
 *     of a scan that is still on the screen.
 *
 * Driven through the exported wiring rather than through a rendered component,
 * because this repository has no jsdom — `where.ts` gives the reason where it
 * explains why it takes its `document` as an argument — and because the wiring
 * is genuinely the thing at risk. A subscription that never fires and a
 * subscription that fires on the wrong edge look identical from the outside
 * until somebody watches a scan and reads yesterday's answer.
 */

function record(over: Partial<TourRecord> = {}): TourRecord {
  return {
    v: 1,
    id: 'tour_1700000000000_aaaaaaaa',
    startedAt: 1,
    endedAt: 2,
    askedBy: 'user',
    question: 'what happened last night?',
    headline: 'four sessions ran',
    stops: [],
    stoppedAfter: null,
    dropped: [],
    ...over,
  }
}

/** A fake pair of announcements, with a hand on each. */
function watcher(): {
  watch: RecapWatch
  front(inFront: boolean): void
  row(value: unknown): void
  dropped(): number
} {
  const fronts: Array<(inFront: boolean) => void> = []
  const rows: Array<(row: unknown) => void> = []
  let dropped = 0
  return {
    watch: {
      watchFront: (handler) => {
        fronts.push(handler)
        return () => {
          dropped += 1
        }
      },
      onCopilotAction: (handler) => {
        rows.push(handler)
        return () => {
          dropped += 1
        }
      },
    },
    front: (inFront) => {
      for (const handler of fronts) handler(inFront)
    },
    row: (value) => {
      for (const handler of rows) handler(value)
    },
    dropped: () => dropped,
  }
}

describe('what makes the card read again', () => {
  it('does not read on the first publication, which is the state at subscribe time', () => {
    // `watchCopilotFrontmost` answers immediately before it answers on change,
    // and at that moment the mount effect has already asked. Reading twice for
    // one arrival is a wasted round trip on every copilot start.
    const fake = watcher()
    let reads = 0
    watchForFinishedScans(() => (reads += 1), fake.watch)
    fake.front(true)
    expect(reads).toBe(0)
  })

  it('reads when this page arrives in front, which is how a scan ends', () => {
    // `finish()` -> `returnToCopilot()` -> `selectTab(copilotSessionId)`, which
    // is what puts `data-copilot-active` back on the rail's copilot row.
    const fake = watcher()
    let reads = 0
    watchForFinishedScans(() => (reads += 1), fake.watch)
    fake.front(true)
    fake.front(false)
    fake.front(true)
    expect(reads).toBe(1)
  })

  it('does not read when the page is left, only when it is arrived at', () => {
    const fake = watcher()
    let reads = 0
    watchForFinishedScans(() => (reads += 1), fake.watch)
    fake.front(true)
    fake.front(false)
    expect(reads).toBe(0)
  })

  it('reads on a scan row, which is the only announcement a background scan makes', () => {
    // Interactive mode off: `stage.quietly()` writes a closed record and sends
    // nothing to any window, so nothing navigates and the arrival above never
    // happens. The action row is all there is.
    const fake = watcher()
    let reads = 0
    watchForFinishedScans(() => (reads += 1), fake.watch)
    fake.row({ tool: 'tour.play', outcome: 'ok' })
    expect(reads).toBe(1)
  })

  it('ignores every other tool call on the same stream', () => {
    // The whole action log arrives on this channel — a copilot doing ordinary
    // work would otherwise have this card re-reading disk on every tool call.
    const fake = watcher()
    let reads = 0
    watchForFinishedScans(() => (reads += 1), fake.watch)
    fake.row({ tool: 'sessions.send' })
    fake.row({ tool: 'browser.step' })
    fake.row({ action: 'tool.tour.play' })
    fake.row(null)
    fake.row('tour.play')
    expect(reads).toBe(0)
  })

  it('gives both subscriptions back', () => {
    // The card is mounted for the life of the copilot session and unmounted with
    // it; two listeners left on the window per copilot start is a leak that only
    // shows up after a long day.
    const fake = watcher()
    const stop = watchForFinishedScans(() => {}, fake.watch)
    stop()
    expect(fake.dropped()).toBe(2)
  })

  it('runs against a bridge that has neither, which is what the harness mounts', () => {
    expect(() => watchForFinishedScans(() => {}, {})()).not.toThrow()
  })
})

describe('which scans it will show', () => {
  it('drops a scan the main process has not closed', () => {
    /*
     * The re-read can land mid-scan for a reason that is a control rather than a
     * race: the dot in the drive panel folds this page back in front while the
     * scan carries on behind it. The open record has no `endedAt` and no stop
     * with a `shownAt`, which the card would draw as a scan where every line
     * says "Not reached" — an account of a failure over one going fine.
     */
    const found = readRecords([
      record({ id: 'tour_1700000000002_bbbbbbbb', endedAt: null }),
      record({ id: 'tour_1700000000000_aaaaaaaa' }),
    ])
    expect(found.map((entry) => entry.id)).toEqual(['tour_1700000000000_aaaaaaaa'])
  })

  it('keeps a record that never carried the field, rather than hiding it on a guess', () => {
    // `endedAt: null` is a value this app writes and overwrites. A record with no
    // `endedAt` at all is not a shape it has ever written, and the promise this
    // function makes is to drop what is malformed, not what is unfamiliar.
    const { endedAt: _endedAt, ...withoutTheField } = record()
    expect(readRecords([withoutTheField])).toHaveLength(1)
  })

  it('still drops what is malformed', () => {
    expect(readRecords('a tour')).toEqual([])
    expect(readRecords([null, 'x', { v: 2 }, { v: 1, id: 7 }, { v: 1, id: 'a' }])).toEqual([])
  })
})
