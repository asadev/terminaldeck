import { describe, expect, it } from 'vitest'
import {
  droppedSentence,
  focusOf,
  focusOfRecord,
  pacedOf,
  paneFor,
  readTour,
  reasonLabel,
  stoppedSentence,
  type TourRecord,
  type TourStop,
  type TourStopRecord,
} from './tour'

/**
 * The window's half of a tour: what it accepts off the bridge, and the two
 * translations it makes.
 *
 * Nothing here re-decides what is important — that is the main process's, and a
 * second copy would be how the morning report and the tour of the same night
 * come to name different sessions. What is checked here is the narrowing at the
 * door and the joins on the way out.
 */

const SCREEN: TourStop = {
  kind: 'screen',
  sessionId: 's1',
  quote: 'the build failed',
  note: 'it failed',
  why: 'files-changed',
}

function record(over: Partial<TourRecord> = {}): TourRecord {
  return {
    v: 1,
    id: 'tour_1700000000000_aaaaaaaa',
    startedAt: 1,
    endedAt: null,
    askedBy: 'user',
    question: 'q',
    headline: 'h',
    stops: [],
    stoppedAfter: null,
    dropped: [],
    ...over,
  }
}

describe('what arrives on the bridge', () => {
  it('takes a well-formed tour', () => {
    const message = readTour({ record: record(), stops: [SCREEN] })
    expect(message?.stops).toHaveLength(1)
  })

  it('refuses anything that is not a tour, rather than throwing inside a listener', () => {
    // A throw here would take down whatever else the IPC listener was doing.
    expect(readTour(null)).toBeNull()
    expect(readTour('a tour')).toBeNull()
    expect(readTour({ record: record() })).toBeNull()
    expect(readTour({ record: { v: 2 }, stops: [SCREEN] })).toBeNull()
    expect(readTour({ record: record(), stops: [] })).toBeNull()
  })

  it('drops a stop it cannot read rather than the whole tour', () => {
    const message = readTour({ record: record(), stops: [{ kind: 'screen' }, SCREEN] })
    expect(message?.stops).toHaveLength(1)
  })

  it('refuses a tour whose every stop is unreadable', () => {
    expect(readTour({ record: record(), stops: [{ kind: 'nonsense' }] })).toBeNull()
  })
})

describe('where a stop points', () => {
  it('anchors a screen stop on its text, which is the only stable thing', () => {
    expect(focusOf(SCREEN, '/work/api')).toEqual({
      kind: 'terminal',
      sessionId: 's1',
      quote: 'the build failed',
    })
  })

  it('anchors a message stop on the id the transcript reader gave it', () => {
    const stop: TourStop = { ...SCREEN, kind: 'message', messageId: 'agent:m1' }
    expect(focusOf(stop, null)).toEqual({
      kind: 'anchor',
      anchor: { at: 'message', messageId: 'agent:m1' },
    })
  })

  it('joins a git anchor to the folder, because the git panel has no session', () => {
    const stop: TourStop = { ...SCREEN, kind: 'anchor', at: 'git-file', path: 'a.ts' }
    expect(focusOf(stop, '/work/api')).toEqual({
      kind: 'anchor',
      anchor: { at: 'git-file', cwd: '/work/api', path: 'a.ts' },
    })
  })

  it('degrades a git anchor with no folder rather than guessing one', () => {
    const stop: TourStop = { ...SCREEN, kind: 'anchor', at: 'git-file', path: 'a.ts' }
    expect(focusOf(stop, null)).toBeNull()
  })

  it('degrades an anchor this build does not know, which is the mirror’s one risk', () => {
    const stop = { ...SCREEN, kind: 'anchor', at: 'from-the-future' } as unknown as TourStop
    expect(focusOf(stop, '/work/api')).toBeNull()
  })
})

describe('which pane a stop needs', () => {
  it('sends a screen stop to the terminal and a message stop to the conversation', () => {
    // There is no mapping between the two and there cannot be one: the JSONL is
    // written by the CLI and the pty carries the CLI's *rendering* of it.
    expect(paneFor(SCREEN)).toBe('terminal')
    expect(paneFor({ ...SCREEN, kind: 'message', messageId: 'm' })).toBe('chat')
  })

  it('asks for no pane at all for an anchor, so the tour does not twitch', () => {
    expect(paneFor({ ...SCREEN, kind: 'anchor', at: 'git-file', path: 'a.ts' })).toBeNull()
  })
})

describe('what the pacing engine is given', () => {
  it('hands over the two pieces of text and nothing about sessions', () => {
    expect(pacedOf(SCREEN)).toEqual({ quote: 'the build failed', note: 'it failed' })
  })

  it('paces an anchor stop on its note alone, because it carries no quote', () => {
    const stop: TourStop = { ...SCREEN, kind: 'anchor', at: 'usage-strip' }
    expect(pacedOf(stop)).toEqual({ quote: '', note: 'it failed' })
  })
})

describe('pointing at a recorded stop weeks later', () => {
  const stop = (over: Partial<TourStopRecord>): TourStopRecord => ({
    index: 0,
    sessionId: 's1',
    sessionTitle: 'api',
    kind: 'screen',
    cwd: '/work/api',
    why: 'files-changed',
    quote: 'the build failed',
    note: 'n',
    shownAt: 1,
    dwellMs: 2,
    degraded: false,
    degradedWhy: null,
    ...over,
  })

  it('rebuilds a terminal target from the quote', () => {
    expect(focusOfRecord(stop({}))).toEqual({
      kind: 'terminal',
      sessionId: 's1',
      quote: 'the build failed',
    })
  })

  it('rebuilds a git anchor from the folder the record kept', () => {
    // The folder rather than a lookup: by the time somebody reads a two-week-old
    // recap the session is gone and only this still resolves.
    expect(focusOfRecord(stop({ kind: 'anchor', at: 'git-file', path: 'a.ts', quote: '' }))).toEqual({
      kind: 'anchor',
      anchor: { at: 'git-file', cwd: '/work/api', path: 'a.ts' },
    })
  })

  it('points at nothing when the record does not carry enough', () => {
    expect(focusOfRecord(stop({ kind: 'message', messageId: undefined }))).toBeNull()
    expect(focusOfRecord(stop({ kind: 'anchor', at: 'git-file', quote: '' }))).toBeNull()
  })
})

describe('the two honest sentences', () => {
  it('says nothing when a tour ran to the end', () => {
    expect(stoppedSentence(record({ stops: [], stoppedAfter: null }))).toBe('')
  })

  it('says how far it got when it was cut short', () => {
    const stops = Array.from({ length: 11 }, () => ({}) as never)
    expect(stoppedSentence(record({ stops, stoppedAfter: 3 }))).toBe('Stopped after 4 of 11.')
  })

  it('does not confess about a tour that reached its last stop', () => {
    // "Stopped after 11 of 11" makes a completed tour look interrupted.
    const stops = Array.from({ length: 11 }, () => ({}) as never)
    expect(stoppedSentence(record({ stops, stoppedAfter: 10 }))).toBe('')
  })

  it('names the reason when every drop had the same one', () => {
    const dropped = [
      { title: 'a', why: 'quote-not-found' as const, detail: '' },
      { title: 'b', why: 'quote-not-found' as const, detail: '' },
    ]
    expect(droppedSentence(dropped)).toBe('2 stops dropped — the quoted text was not there.')
  })

  it('stays general when they differ, rather than naming one of several', () => {
    const dropped = [
      { title: 'a', why: 'quote-not-found' as const, detail: '' },
      { title: 'b', why: 'session-gone' as const, detail: '' },
    ]
    expect(droppedSentence(dropped)).toContain('2 stops dropped')
  })

  it('says nothing at all when nothing was dropped', () => {
    expect(droppedSentence([])).toBe('')
  })
})

describe('the reason badge', () => {
  it('names every reason this build knows', () => {
    expect(reasonLabel('blocked-on-you')).toBe('Waiting on you')
    expect(reasonLabel('tool-failing')).toBe('Tool failing')
  })

  it('falls back to the raw value for a reason from a newer main process', () => {
    // The mirror's one failure mode. A badge reading `some-new-reason` is worse
    // than one reading "Some new reason" and infinitely better than a crash.
    expect(reasonLabel('some-new-reason' as never)).toBe('some-new-reason')
  })
})
