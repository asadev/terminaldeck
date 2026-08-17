import { describe, expect, it } from 'vitest'
import { matchTranscript, START_TOLERANCE_MS, type TranscriptChoice } from './transcript-match'

/**
 * The defect, pinned so it cannot come back.
 *
 * Every tool here resolved a session's transcript with `newestChatTranscript(cwd)`
 * — the folder's most recently written conversation. A real copilot, asked
 * *"which of my sessions needs me?"* against this machine, noticed within one
 * turn: four sessions shared the copilot's folder, all four came back with the
 * same `transcriptPath`, and one of them was the copilot's own conversation
 * being reported as somebody else's work.
 *
 * That is the fleet case, which is the case this whole tool surface exists for.
 * Its consequences ran all the way through: `sessions.result` would have
 * reported one session's spend four times and `progress.ts` would have called
 * four sessions stuck because one of them was.
 *
 * The assertions below are mostly about what this module *refuses* to claim.
 */

const T0 = Date.parse('2026-08-17T09:00:00.000Z')

function file(over: Partial<TranscriptChoice> = {}): TranscriptChoice {
  return {
    path: '/store/a.jsonl',
    sessionId: 'cli-a',
    createdAt: T0,
    modifiedAt: T0 + 60_000,
    bytes: 4096,
    ...over,
  }
}

function session(over: { id?: string; createdAt?: number; resumed?: boolean } = {}) {
  return { id: 'deck-1', createdAt: T0, ...over }
}

/** A live session in the folder. Defaults to the one under test. */
function here(id: string, createdAt = T0): { id: string; createdAt: number } {
  return { id, createdAt }
}

/**
 * The second half of the same defect, found the same way.
 *
 * With the timing rules in place, a folder holding one Claude conversation and
 * one live *shell* session still handed the conversation to the shell — the
 * `only-one` rule fires when no other live session competes, and a shell was
 * counted as competition-free rather than as ineligible. The copilot then
 * reported, in a summary that was otherwise entirely correct, that the user's
 * shell session had been given a brief and had spent 780,000 tokens. Every
 * figure was real; none of them was that session's.
 */
describe('a session of a kind that writes no transcript', () => {
  it('is never given one, however unambiguous the folder looks', () => {
    const match = matchTranscript({ ...session(), provider: 'shell' }, [file()], [here('deck-1')])
    expect(match.path).toBeNull()
    expect(match.basis).toBe('none')
    // And the reason says what kind of absence this is, so a caller can write
    // "a shell keeps no transcript" instead of implying the session was quiet.
    expect(match.note).toMatch(/writes no transcript/)
  })

  it('is not counted as a rival for somebody else\'s conversation', () => {
    /*
     * A Claude session sharing a folder with two shells has an unambiguous
     * conversation. Reporting it as ambiguous would teach the reader to
     * discount a warning that is nearly always wrong.
     */
    const match = matchTranscript({ ...session(), provider: 'claude' }, [file()], [
      here('deck-1'),
      { ...here('shell-1'), provider: 'shell' as const },
      { ...here('shell-2'), provider: 'shell' as const },
    ])
    expect(match.path).toBe('/store/a.jsonl')
    expect(match.basis).toBe('only-one')
    expect(match.ambiguous).toBe(false)
    expect(match.otherSessions).toEqual([])
  })

  it('still competes when it is another Claude session', () => {
    // The guard narrows the field to sessions that could own the file; it does
    // not narrow it to nothing. Two Claude sessions are still two candidates.
    const match = matchTranscript({ ...session(), provider: 'claude' }, [file(), file({ path: '/store/b.jsonl', createdAt: T0 + 1_000 })], [
      here('deck-1'),
      { ...here('deck-2', T0 + 1_000), provider: 'claude' as const },
    ])
    expect(match.otherSessions).toEqual(['deck-2'])
  })

  it('assumes eligibility when nobody said what kind it is', () => {
    // The parameter is optional so a caller with less information than the app
    // has keeps the old behaviour. "We did not say" must not become
    // "certainly not".
    const match = matchTranscript(session(), [file()], [here('deck-1')])
    expect(match.path).toBe('/store/a.jsonl')
  })
})

describe('matchTranscript', () => {
  it('takes the only conversation in a folder', () => {
    const match = matchTranscript(session(), [file()], [here('deck-1')])
    expect(match).toEqual({
      path: '/store/a.jsonl',
      basis: 'only-one',
      ambiguous: false,
      otherSessions: [],
      note: null,
    })
  })

  /**
   * The defect surviving inside its own fix, caught by running it.
   *
   * `conversations.length === 1` used to short-circuit to `only-one` before
   * anything else was considered. Run against the real machine, five sessions
   * shared a folder holding one conversation — and all five were told it was
   * theirs, which is exactly the sentence this module was written to stop.
   */
  it('does not hand one conversation to five sessions that share a folder', () => {
    const older = file({ createdAt: T0 - 30 * 60_000, modifiedAt: T0 + 600_000 })
    const match = matchTranscript(session(), [older], [here('deck-1'), here('deck-2', T0 + 10 * 60_000), here('deck-3', T0 + 20 * 60_000)])
    expect(match.path).toBeNull()
    expect(match.basis).toBe('none')
  })

  it('does not count an empty file as a conversation', () => {
    // The CLI opens a transcript before it has a turn to put in it, so a
    // zero-byte file is a session that started and has said nothing.
    const match = matchTranscript(session(), [file({ bytes: 0 })], [here('deck-1')])
    expect(match.path).toBeNull()
    expect(match.basis).toBe('none')
  })

  /**
   * The case that was wrong, with the numbers from the machine it was found on.
   */
  it('picks the conversation that began when the session did, not the newest one', () => {
    const mine = file({ path: '/store/mine.jsonl', createdAt: T0, modifiedAt: T0 + 1_000 })
    const theirs = file({
      path: '/store/theirs.jsonl',
      // Born half an hour earlier and still being written to — the copilot's
      // own live conversation, which is what every session in the folder used
      // to be handed.
      createdAt: T0 - 30 * 60_000,
      modifiedAt: T0 + 600_000,
    })

    const match = matchTranscript(session(), [theirs, mine], [here('deck-1'), here('deck-2', T0 + 10 * 60_000)])
    expect(match.path).toBe('/store/mine.jsonl')
    expect(match.basis).toBe('started-together')
    // Still flagged: two sessions share the folder, so a caller summarising
    // this should say which session it believes it is describing.
    expect(match.ambiguous).toBe(true)
    expect(match.otherSessions).toEqual(['deck-2'])
  })

  it('answers nothing rather than somebody else’s conversation', () => {
    // A session that has just started in a folder full of older conversations.
    // It did not resume any of them, so none of them is its.
    const older = file({ createdAt: T0 - 60 * 60_000, modifiedAt: T0 + 5_000 })
    const older2 = file({ path: '/store/b.jsonl', createdAt: T0 - 90 * 60_000, modifiedAt: T0 + 9_000 })

    const match = matchTranscript(session(), [older, older2], [here('deck-1'), here('deck-2', T0 + 10 * 60_000)])
    expect(match.path).toBeNull()
    expect(match.basis).toBe('none')
    expect(match.note).toMatch(/began before this session started/)
  })

  it('takes the nearer of two conversations that both began around it, and says it is a guess', () => {
    const a = file({ path: '/store/a.jsonl', createdAt: T0, modifiedAt: T0 + 1_000 })
    // Newer on disk, but two seconds further from when this session started.
    // Nearest start wins over most recently written, because the birth time is
    // the fact that identifies a conversation and the write time is not.
    const b = file({ path: '/store/b.jsonl', createdAt: T0 + 2_000, modifiedAt: T0 + 9_000 })

    const match = matchTranscript(session(), [a, b], [here('deck-1'), here('deck-2', T0 + 10 * 60_000)])
    expect(match.path).toBe('/store/a.jsonl')
    expect(match.basis).toBe('nearest-start')
    expect(match.ambiguous).toBe(true)
    expect(match.note).toMatch(/possibly another session's/)
  })

  /**
   * The second real failure, with the real numbers.
   *
   * Two sessions in one folder, started 104 seconds apart — inside the
   * tolerance in both directions — and two conversations. Each session
   * independently found both files "born together", each fell through to "take
   * the newest", and both were handed the same 88 KB transcript while the
   * 966-byte one was claimed by nobody. `sessions.result` then reported 9
   * requests and 306,575 tokens for *each* of them, and only one had spent
   * anything. The copilot noticed by reading the file sizes.
   *
   * The fix is that a conversation belongs to the session whose start is
   * nearest its birth — decided identically whichever session is asking — so
   * two sessions can no longer claim one file.
   */
  it('never gives one conversation to two sessions that started close together', () => {
    const older = { id: 'older', createdAt: Date.parse('2026-08-17T10:40:03Z') }
    const newer = { id: 'newer', createdAt: Date.parse('2026-08-17T10:41:47Z') }
    const small = file({
      path: '/store/small.jsonl',
      createdAt: older.createdAt + 500,
      modifiedAt: Date.parse('2026-08-17T10:40:30Z'),
      bytes: 966,
    })
    const big = file({
      path: '/store/big.jsonl',
      createdAt: newer.createdAt + 500,
      modifiedAt: Date.parse('2026-08-17T10:42:12Z'),
      bytes: 88_000,
    })

    const forOlder = matchTranscript({ ...older }, [small, big], [older, newer])
    const forNewer = matchTranscript({ ...newer }, [small, big], [older, newer])

    expect(forOlder.path).toBe('/store/small.jsonl')
    expect(forNewer.path).toBe('/store/big.jsonl')
    expect(forOlder.path).not.toBe(forNewer.path)
  })

  it('leaves a resumed session out of the claiming, so it cannot take a fresh one’s file', () => {
    const fresh = { id: 'fresh', createdAt: T0 }
    const resumed = { id: 'resumed', createdAt: T0 + 1_000, resumed: true }
    const born = file({ path: '/store/fresh.jsonl', createdAt: T0 + 200, modifiedAt: T0 + 5_000 })

    expect(matchTranscript(fresh, [born], [fresh, resumed]).path).toBe('/store/fresh.jsonl')
  })

  it('treats a resumed session as unknowable rather than as new', () => {
    // Resuming appends to a file that already existed, so "born when the
    // session started" says nothing about it — every candidate was born first.
    const a = file({ path: '/store/a.jsonl', createdAt: T0 - 86_400_000, modifiedAt: T0 + 1_000 })
    const b = file({ path: '/store/b.jsonl', createdAt: T0 - 172_800_000, modifiedAt: T0 + 5_000 })

    const match = matchTranscript(session({ resumed: true }), [a, b], [here('deck-1'), here('deck-2', T0 + 10 * 60_000)])
    expect(match.path).toBe('/store/b.jsonl')
    expect(match.basis).toBe('newest')
    expect(match.note).toMatch(/it was resumed/)
  })

  it('holds the tolerance at its edges', () => {
    const inside = file({ path: '/store/in.jsonl', createdAt: T0 + START_TOLERANCE_MS })
    const outside = file({
      path: '/store/out.jsonl',
      createdAt: T0 + START_TOLERANCE_MS + 1,
      modifiedAt: T0 + 999_999,
    })
    // Two sessions in the folder, so the birth-time rule is the one deciding.
    expect(matchTranscript(session(), [inside, outside], [here('deck-1'), here('deck-2', T0 + 10 * 60_000)]).path).toBe(
      '/store/in.jsonl',
    )
  })

  it('does not call a folder ambiguous because of a session that has gone', () => {
    // `otherSessions` is the *live* sessions the caller handed over, minus this
    // one. A folder whose other tabs have been closed is not ambiguous.
    const match = matchTranscript(session(), [file()], [here('deck-1')])
    expect(match.otherSessions).toEqual([])
    expect(match.ambiguous).toBe(false)
  })

  it('names an older conversation for the only session in the folder', () => {
    // The ordinary case, and the one the birth-time rule must not spoil: one
    // tab, one folder, a conversation it resumed or is about to.
    const older = file({ createdAt: T0 - 86_400_000, modifiedAt: T0 + 1_000 })
    expect(matchTranscript(session(), [older], [here('deck-1')]).path).toBe(older.path)
  })
})
