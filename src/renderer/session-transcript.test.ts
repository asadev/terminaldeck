import { describe, expect, it } from 'vitest'
import { insightsTarget } from './components/SessionInspector'
import {
  asTranscriptFiles,
  pickSessionTranscript,
  type TranscriptFileView,
  type TranscriptLookup,
} from './session-transcript'

/**
 * The run that produced these numbers is worth keeping literal.
 *
 * A tab opened at 16:52 in `~/ClaudeAsad` reported 143 requests, $18.49, an
 * elapsed time of 1h 53m and a first request at 15:31:26 — an hour and a half
 * before the tab existed — along with tools it had never called. Every one of
 * those belonged to `8ae018a8-….jsonl`, a `claude` running in the same folder
 * that this app had not started and knew nothing about. It won because it was
 * the most recently written file in the directory, which is the only question
 * anything was asking.
 */
const at = (clock: string): number => Date.parse(`2026-08-13T${clock}+04:00`)

/** The stranger: began at 15:31, still being typed into at 17:35. */
const FOREIGN: TranscriptFileView = {
  path: '/p/8ae018a8.jsonl',
  sessionId: '8ae018a8',
  createdAt: at('15:31:19'),
  modifiedAt: at('17:35:02'),
}

/** The tab's own conversation: began after it opened, quiet since. */
const OWN: TranscriptFileView = {
  path: '/p/aa11.jsonl',
  sessionId: 'aa11',
  createdAt: at('16:55:00'),
  modifiedAt: at('16:56:10'),
}

const TAB = { startedAt: at('16:52:00') }

describe('pickSessionTranscript', () => {
  it('refuses a conversation that began before the tab did', () => {
    // The whole bug in one assertion. Nothing here is this session's, and
    // saying so is the correct answer — the alternative is publishing a
    // stranger's spend under this tab's name.
    expect(pickSessionTranscript([FOREIGN], TAB)).toBeNull()
  })

  it('prefers its own quiet conversation over a stranger writing constantly', () => {
    const choice = pickSessionTranscript([FOREIGN, OWN], TAB)
    expect(choice?.sessionId).toBe('aa11')
    expect(choice?.attribution).toBe('session')
  })

  it('takes the first conversation to begin after the tab, not the busiest', () => {
    // A second tab in the same folder starts a conversation later and works
    // harder. Ranking by last write hands it to the wrong tab; ranking by when
    // the conversation began does not.
    const later: TranscriptFileView = {
      path: '/p/bb22.jsonl',
      sessionId: 'bb22',
      createdAt: at('17:10:00'),
      modifiedAt: at('17:40:00'),
    }
    expect(pickSessionTranscript([FOREIGN, OWN, later], TAB)?.sessionId).toBe('aa11')
  })

  it('counts a conversation begun in the same millisecond as the tab', () => {
    const instant: TranscriptFileView = { ...OWN, createdAt: TAB.startedAt }
    expect(pickSessionTranscript([instant], TAB)?.attribution).toBe('session')
  })

  it('lets a continued session have the file it continued', () => {
    // `--continue` appends to a conversation older than the tab by design, so
    // "began after the tab" can only ever rule it out. The newest write is the
    // same file the CLI itself picked.
    const choice = pickSessionTranscript([FOREIGN, OWN], { ...TAB, resumed: true })
    expect(choice?.sessionId).toBe('8ae018a8')
    expect(choice?.attribution).toBe('resumed')
  })

  it('does not give a continued session a conversation that started after it', () => {
    // OWN began after the tab, so it belongs to something else entirely — a
    // continued session is by definition writing into an older file.
    const choice = pickSessionTranscript([OWN], { ...TAB, resumed: true })
    expect(choice?.sessionId).toBe('aa11')
    // Nothing older exists, so this is a guess, and it is labelled as one
    // rather than as the session's own.
    expect(choice?.attribution).toBe('resumed')
  })

  it('still answers the folder question when there is no session in play', () => {
    const choice = pickSessionTranscript([FOREIGN, OWN], null)
    expect(choice?.sessionId).toBe('8ae018a8')
    expect(choice?.attribution).toBe('project')
  })

  it('has nothing to say about an empty folder', () => {
    expect(pickSessionTranscript([], TAB)).toBeNull()
    expect(pickSessionTranscript([], null)).toBeNull()
  })

  it('does not reorder the caller’s array', () => {
    const files = [FOREIGN, OWN]
    pickSessionTranscript(files, null)
    expect(files[0]).toBe(FOREIGN)
  })
})

describe('asTranscriptFiles', () => {
  it('keeps well-formed rows and drops everything else', () => {
    expect(asTranscriptFiles([FOREIGN, null, 'x', {}, { path: '/p/a.jsonl' }])).toEqual([FOREIGN])
  })

  it('treats a bridge that answered with nothing as an empty folder', () => {
    // The harness stub resolves unimplemented methods to null, and a preload
    // that predates this channel resolves to undefined.
    expect(asTranscriptFiles(null)).toEqual([])
    expect(asTranscriptFiles(undefined)).toEqual([])
    expect(asTranscriptFiles({ files: [FOREIGN] })).toEqual([])
  })
})

describe('insightsTarget', () => {
  const ready: TranscriptLookup = {
    status: 'ready',
    choice: { path: OWN.path, sessionId: OWN.sessionId, attribution: 'session' },
  }
  const none: TranscriptLookup = { status: 'none' }
  const loading: TranscriptLookup = { status: 'loading' }

  it('never falls back to the folder for a session with no transcript', () => {
    // The regression itself: the dialog was opened about a session and answered
    // about a folder, and the folder's newest transcript was a stranger's.
    expect(insightsTarget(null, '/p', TAB, none)).toEqual({ kind: 'none' })
  })

  it('reads nothing at all until the lookup settles', () => {
    // Otherwise the dialog opens on the folder's newest for a beat, which is
    // the same wrong numbers, briefly.
    expect(insightsTarget(null, '/p', TAB, loading)).toEqual({ kind: 'waiting' })
  })

  it('reads the transcript the session was matched to', () => {
    expect(insightsTarget(null, '/p', TAB, ready)).toEqual({ kind: 'transcript', path: OWN.path })
  })

  it('answers about the folder only when asked about a folder', () => {
    expect(insightsTarget(null, '/p', null, none)).toEqual({ kind: 'folder', cwd: '/p' })
    expect(insightsTarget(null, null, null, none)).toEqual({ kind: 'none' })
  })

  it('lets an explicit transcript win over everything', () => {
    // Alerts open this dialog on a transcript they already identified.
    expect(insightsTarget('/p/named.jsonl', '/p', TAB, none)).toEqual({
      kind: 'transcript',
      path: '/p/named.jsonl',
    })
  })
})
