import { describe, expect, it } from 'vitest'
import type { SessionStatus } from '@shared/types'
import {
  attentionLabel,
  attentionOf,
  countBoard,
  folderOf,
  formatElapsed,
  providerLabel,
  sortBoard,
  stateSentence,
  statusObserved,
  summaryLine,
  summaryParts,
  wantsYou,
  workFromSummary,
  type BoardSession,
} from './board'

const NOW = Date.parse('2026-08-16T12:00:00.000Z')
const MINUTE = 60_000

function session(overrides: Partial<BoardSession> & { id: string }): BoardSession {
  return {
    title: 'Untitled',
    projectPath: '/Users/apple/Projects/terminaldeck',
    provider: 'claude',
    account: null,
    status: 'idle',
    statusSince: NOW,
    startedAt: NOW,
    work: null,
    ...overrides,
  }
}

/* ------------------------------------------------------------- attention -- */

describe('attentionOf', () => {
  it('separates the two states that are your turn', () => {
    // A session that asked a question has stopped mid-task; one that finished
    // its turn has not. Both want you, and the first wants you more.
    expect(attentionOf('input')).toBe('blocked')
    expect(attentionOf('completed')).toBe('finished')
    expect(wantsYou('blocked')).toBe(true)
    expect(wantsYou('finished')).toBe(true)
    expect(wantsYou('working')).toBe(false)
    expect(wantsYou('ready')).toBe(false)
  })

  it('collapses waiting and idle into one word', () => {
    // `StatusDot` already calls both "Ready" and draws both the same hollow
    // ring, because a person cannot act on the difference. Two words for it on
    // this board would be two words nobody can use.
    expect(attentionOf('waiting')).toBe('ready')
    expect(attentionOf('idle')).toBe('ready')
    expect(attentionLabel(attentionOf('waiting'))).toBe(attentionLabel(attentionOf('idle')))
  })

  it('has a word for every status the app can produce', () => {
    const all: SessionStatus[] = ['idle', 'working', 'waiting', 'input', 'completed', 'exited']
    for (const status of all) {
      expect(attentionLabel(attentionOf(status)), status).not.toBe('')
    }
  })
})

/* ----------------------------------------------------------------- order -- */

describe('sortBoard', () => {
  it('puts a session that is waiting on you first', () => {
    const rows = sortBoard([
      session({ id: 'working', status: 'working' }),
      session({ id: 'ready', status: 'waiting' }),
      session({ id: 'blocked', status: 'input' }),
      session({ id: 'finished', status: 'completed' }),
      session({ id: 'gone', status: 'exited' }),
    ])
    expect(rows.map((row) => row.id)).toEqual(['blocked', 'finished', 'working', 'ready', 'gone'])
  })

  /**
   * The tiebreak is the half that is easy to get backwards, and getting it
   * backwards buries the exact card the page was built to surface: the one
   * that has been ignored longest.
   */
  it('ranks the longest-ignored blocked session above a fresher one', () => {
    const rows = sortBoard([
      session({ id: 'just-asked', status: 'input', statusSince: NOW - MINUTE }),
      session({ id: 'ignored', status: 'input', statusSince: NOW - 40 * MINUTE }),
    ])
    expect(rows.map((row) => row.id)).toEqual(['ignored', 'just-asked'])
  })

  it('ranks the most recently started working session first', () => {
    // The opposite direction on purpose: the one grinding away since breakfast
    // is the least likely to want you.
    const rows = sortBoard([
      session({ id: 'old', status: 'working', statusSince: NOW - 40 * MINUTE }),
      session({ id: 'new', status: 'working', statusSince: NOW - MINUTE }),
    ])
    expect(rows.map((row) => row.id)).toEqual(['new', 'old'])
  })

  it('does not mutate the list it was given', () => {
    const input = [
      session({ id: 'a', status: 'working' }),
      session({ id: 'b', status: 'input' }),
    ]
    sortBoard(input)
    expect(input.map((row) => row.id)).toEqual(['a', 'b'])
  })
})

/* ---------------------------------------------------------------- counts -- */

describe('countBoard and summaryLine', () => {
  it('counts the two attention states together as "wants you"', () => {
    const counts = countBoard([
      session({ id: '1', status: 'input' }),
      session({ id: '2', status: 'completed' }),
      session({ id: '3', status: 'working' }),
    ])
    expect(counts.wantsYou).toBe(2)
    expect(counts.total).toBe(3)
  })

  it('leaves the empty groups out of the line', () => {
    // A strip reading "2 need you · 0 finished · 1 working · 0 at a prompt" is
    // four things to read for two facts, and the zeros are the noise.
    const line = summaryLine(
      countBoard([
        session({ id: '1', status: 'input' }),
        session({ id: '2', status: 'input' }),
        session({ id: '3', status: 'working' }),
      ]),
    )
    expect(line).toBe('2 need you · 1 working')
  })

  it('says "1 needs you", not "1 need you"', () => {
    expect(summaryLine(countBoard([session({ id: '1', status: 'input' })]))).toBe('1 needs you')
  })

  /**
   * Caught by looking at it: written as one string the whole summary took one
   * colour, so a board with a single blocked session painted "1 needs you ·
   * 1 working · 1 at a prompt" entirely in the alarm colour — three urgent
   * figures where there was one.
   */
  it('marks only the blocked group as the one that needs you', () => {
    const parts = summaryParts(
      countBoard([
        session({ id: '1', status: 'input' }),
        session({ id: '2', status: 'working' }),
        session({ id: '3', status: 'waiting' }),
      ]),
    )
    expect(parts.map((part) => part.attention)).toEqual(['blocked', 'working', 'ready'])
    expect(parts.filter((part) => part.attention === 'blocked')).toHaveLength(1)
  })
})

/* --------------------------------------------------------------- wording -- */

describe('formatElapsed', () => {
  it('never rounds a measured duration down to nothing', () => {
    expect(formatElapsed(400)).toBe('1s')
    expect(formatElapsed(0)).toBe('1s')
  })

  it('steps through the units without a stray zero', () => {
    expect(formatElapsed(45_000)).toBe('45s')
    expect(formatElapsed(12 * MINUTE)).toBe('12m')
    expect(formatElapsed(2 * 60 * MINUTE)).toBe('2h')
    expect(formatElapsed(2 * 60 * MINUTE + 5 * MINUTE)).toBe('2h 5m')
    expect(formatElapsed(24 * 60 * MINUTE)).toBe('1d')
    expect(formatElapsed(26 * 60 * MINUTE)).toBe('1d 2h')
  })

  it('says nothing for a duration that is not one', () => {
    expect(formatElapsed(-1)).toBe('')
    expect(formatElapsed(Number.NaN)).toBe('')
  })
})

describe('stateSentence', () => {
  it('says how long a session has been waiting on you', () => {
    const row = session({ id: '1', status: 'input', statusSince: NOW - 12 * MINUTE })
    expect(stateSentence(row, NOW)).toBe('Waiting on you for 12m')
  })

  it('says a session finished its turn rather than that it is idle', () => {
    const row = session({ id: '1', status: 'completed', statusSince: NOW - 3 * MINUTE })
    expect(stateSentence(row, NOW)).toBe('Finished its turn for 3m')
  })

  /**
   * `statusSince` is when *this window* saw the state, and for a session
   * restored at launch that is the launch. "At a prompt for 3 hours" would be
   * reporting how long the app has been open under a label claiming to report
   * the session — so the one state a session is *added* in prints no clock.
   */
  it('puts no clock on a session sitting at a prompt', () => {
    const row = session({ id: '1', status: 'waiting', statusSince: NOW - 3 * 60 * MINUTE })
    expect(stateSentence(row, NOW)).toBe('At a prompt')
  })

  it('puts no clock on a status it never observed beginning', () => {
    const row = session({ id: '1', status: 'idle', statusSince: 0 })
    expect(statusObserved(row)).toBe(false)
    expect(stateSentence(row, NOW)).toBe('At a prompt')
  })

  it('says when a session exited rather than repeating the chip', () => {
    // The chip two lines above already reads "Exited"; the line under it is
    // the only place the card can say *when*.
    const row = session({ id: '1', status: 'exited', statusSince: NOW - 9 * MINUTE })
    expect(stateSentence(row, NOW)).toBe('Exited 9m ago')
  })
})

describe('labels', () => {
  it('names an agent the way a person would', () => {
    expect(providerLabel('claude')).toBe('Claude Code')
    // An id this build does not know is printed as it is, not as "Unknown".
    expect(providerLabel('opencode')).toBe('opencode')
  })

  it('takes the last segment of a path on either platform', () => {
    expect(folderOf('/Users/apple/Projects/terminaldeck')).toBe('terminaldeck')
    expect(folderOf('C:\\Users\\asad\\ClaudeImza')).toBe('ClaudeImza')
    expect(folderOf('/Users/apple/Projects/terminaldeck/')).toBe('terminaldeck')
  })
})

/* ------------------------------------------------------------ transcripts -- */

/** A `SessionSummary` row as `cost:project` hands it across the bridge. */
function summaryWith(row: Record<string, unknown>): unknown {
  return { sessions: [row] }
}

describe('workFromSummary', () => {
  const usage = {
    input: 1000,
    output: 2000,
    cacheWrite5m: 500,
    cacheWrite1h: 0,
    cacheRead: 40_000,
  }

  it('sums every token class, not just input and output', () => {
    const work = workFromSummary(
      summaryWith({
        sessionId: 'abc',
        requests: 12,
        usage,
        context: { percent: 62 },
        lastActivityAt: NOW,
      }),
      'abc',
      '/t/abc.jsonl',
    )
    expect(work?.tokens).toBe(43_500)
    expect(work?.requests).toBe(12)
    expect(work?.contextPercent).toBe(62)
  })

  it('reports no context reading before the first request', () => {
    // Reading a percent off a missing block yields 0, and "0% of the window" is
    // a reading, not an absence.
    const work = workFromSummary(
      summaryWith({ sessionId: 'abc', requests: 1, usage }),
      'abc',
      '/t/abc.jsonl',
    )
    expect(work?.contextPercent).toBeNull()
  })

  it('matches on the transcript id and refuses to guess', () => {
    // The transcript's session id and this window's tab id are different
    // namespaces. Matching the wrong one silently yields another session's
    // money under this session's name, which is the bug the whole attribution
    // chain exists to prevent.
    expect(workFromSummary(summaryWith({ sessionId: 'abc', requests: 1 }), 'xyz', '/t/x.jsonl')).toBeNull()
    expect(workFromSummary(null, 'abc', '/t/a.jsonl')).toBeNull()
    expect(workFromSummary({ sessions: 'not an array' }, 'abc', '/t/a.jsonl')).toBeNull()
  })
})
