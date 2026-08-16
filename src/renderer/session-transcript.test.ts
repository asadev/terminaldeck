import { describe, expect, it } from 'vitest'
import { insightsTarget } from './components/SessionInspector'
import {
  asTranscriptFiles,
  attributeTranscript,
  pickSessionTranscript,
  sameLookup,
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

  it('ignores a busy conversation that a later tab could equally have written', () => {
    /*
     * This case used to assert the opposite — that the *first* conversation to
     * begin after the tab is the tab's — and that rule is the bug in item 3.
     * It only looked right because this example has the second tab's
     * conversation starting last. Reverse the order (see
     * `two tabs in one folder` below) and the same rule hands every tab in the
     * folder the same file. The honest reading of these three files is that
     * `aa11` began while this tab was the only one open, so it is this tab's;
     * `bb22` began after a second tab did and could belong to either.
     */
    const later: TranscriptFileView = {
      path: '/p/bb22.jsonl',
      sessionId: 'bb22',
      createdAt: at('17:10:00'),
      modifiedAt: at('17:40:00'),
    }
    const secondTab = at('17:05:00')
    expect(pickSessionTranscript([FOREIGN, OWN, later], TAB, [secondTab])?.sessionId).toBe('aa11')
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

/**
 * Item 3 of NEXT-UPDATE.md, in his words:
 *
 *   > "your chat and terminal is not mostly showing the same context and same
 *   > things sometime terminal is showing some different chat and chat view is
 *   > showing something else"
 *
 * Two shapes produce it, and every case below fails on the rule this file used
 * to implement — "the earliest conversation that began after this tab, decided
 * once".
 */
describe('two views of one session disagreeing', () => {
  /** Three tabs opened back to back on one project, before any of them is used. */
  const first = at('16:52:00')
  const second = at('16:52:06')
  const third = at('16:52:11')

  /** …and then somebody types in the middle one. Its conversation starts first. */
  const middlesWork: TranscriptFileView = {
    path: '/p/mid.jsonl',
    sessionId: 'mid',
    createdAt: at('16:53:00'),
    modifiedAt: at('17:20:00'),
  }

  it('does not hand one tab’s conversation to the two tabs beside it', () => {
    /*
     * The regression itself. Under the old rule all three tabs resolved to
     * `mid` — the only file that existed — so two of the three chat panes read
     * a conversation belonging to a terminal two clicks away, and each of those
     * two panes disagreed with the terminal behind it.
     *
     * The honest answer for the first two tabs is that either of them could
     * have written it: `mid` began after all three tabs were open. The third
     * tab is the one case time settles — it opened *after* the conversation
     * began, so the conversation cannot be its.
     */
    const files = [middlesWork]
    const late = { ...middlesWork, createdAt: at('16:52:20') }
    expect(attributeTranscript(files, { startedAt: first }, [second, third])).toEqual({
      kind: 'ambiguous',
      candidates: 1,
      competing: 2,
    })
    expect(attributeTranscript(files, { startedAt: second }, [first, third])).toEqual({
      kind: 'ambiguous',
      candidates: 1,
      competing: 1,
    })
    expect(attributeTranscript([late], { startedAt: at('16:52:30') }, [first, second, third])).toEqual({
      kind: 'none',
    })
  })

  it('claims a conversation that began while this tab was the only one open', () => {
    // The other half: a second tab opened later cannot have written something
    // that already existed, so the first tab owns it outright and both panes
    // agree with their terminals.
    const early: TranscriptFileView = {
      path: '/p/early.jsonl',
      sessionId: 'early',
      createdAt: at('16:52:03'),
      modifiedAt: at('17:20:00'),
    }
    expect(attributeTranscript([early], { startedAt: first }, [second, third])).toEqual({
      kind: 'choice',
      choice: { path: '/p/early.jsonl', sessionId: 'early', attribution: 'session' },
    })
  })

  it('says it cannot tell rather than picking one of two equal claims', () => {
    // Two tabs, two conversations, and the *second* tab spoke first. Nothing in
    // a transcript records which terminal wrote it — checked against the real
    // files on this machine — so pairing them up by age would be right half the
    // time and confidently wrong the other half.
    const a: TranscriptFileView = { path: '/p/a.jsonl', sessionId: 'a', createdAt: at('16:54:00'), modifiedAt: at('16:59:00') }
    const b: TranscriptFileView = { path: '/p/b.jsonl', sessionId: 'b', createdAt: at('16:53:00'), modifiedAt: at('16:58:00') }
    const verdict = attributeTranscript([a, b], { startedAt: first }, [second])
    expect(verdict).toEqual({ kind: 'ambiguous', candidates: 2, competing: 1 })
  })

  it('treats a sibling started in the same millisecond as a real claim', () => {
    // Two tabs opened by one click of a restore, stamped identically. Reading a
    // tie as "the other one had not started yet" is the same bug in miniature.
    const file: TranscriptFileView = { ...OWN, createdAt: at('16:53:00') }
    expect(attributeTranscript([file], { startedAt: first }, [first]).kind).toBe('ambiguous')
  })

  it('follows the session into the conversation it started after /clear', () => {
    /*
     * One tab, no ambiguity at all, and the old rule still got it wrong: it
     * took the *first* conversation the tab began and never looked again, so a
     * `/clear` — or quitting the CLI and running it again in a shell tab — left
     * chat rendering a finished conversation for the rest of the tab's life
     * while the terminal beside it showed the live one.
     */
    const before: TranscriptFileView = {
      path: '/p/before.jsonl',
      sessionId: 'before',
      createdAt: at('16:55:00'),
      modifiedAt: at('17:29:00'),
    }
    const after: TranscriptFileView = {
      path: '/p/after.jsonl',
      sessionId: 'after',
      createdAt: at('17:31:00'),
      modifiedAt: at('17:35:00'),
    }
    const verdict = attributeTranscript([before, after], TAB, [])
    expect(verdict).toEqual({
      kind: 'choice',
      choice: { path: '/p/after.jsonl', sessionId: 'after', attribution: 'session' },
    })
  })

  it('still refuses a stranger’s conversation once it starts rebinding', () => {
    // Following the newest conversation must not become "follow the newest file
    // in the folder", which is the bug this module was written for.
    const verdict = attributeTranscript([FOREIGN, OWN], TAB, [])
    expect(verdict).toEqual({
      kind: 'choice',
      choice: { path: OWN.path, sessionId: 'aa11', attribution: 'session' },
    })
  })

  it('reports nothing rather than ambiguity when the session has written nothing', () => {
    // "Cannot tell which of these is yours" and "you have not said anything
    // yet" are different sentences and only one of them is true here.
    expect(attributeTranscript([FOREIGN], { startedAt: first }, [second])).toEqual({ kind: 'none' })
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

describe('sameLookup', () => {
  /**
   * The lookup re-runs on every transcript append now, not only on a timer, so
   * it answers the same question several times a second all the way through a
   * long reply. A fresh object holding the same answer is still a new state and
   * still a re-render of the pane; this is what stops that.
   */
  const ready = (path: string): TranscriptLookup => ({
    status: 'ready',
    choice: { path, sessionId: 'x', attribution: 'session' },
  })

  it('treats two readings of the same transcript as the same answer', () => {
    expect(sameLookup(ready('/p/a.jsonl'), ready('/p/a.jsonl'))).toBe(true)
  })

  it('notices the session moving to a different conversation', () => {
    // The `/clear` rebind. Missing this is the bug, not the optimisation.
    expect(sameLookup(ready('/p/a.jsonl'), ready('/p/b.jsonl'))).toBe(false)
  })

  it('notices a second session arriving in the folder', () => {
    const alone: TranscriptLookup = { status: 'ambiguous', candidates: 2, competing: 1 }
    const crowded: TranscriptLookup = { status: 'ambiguous', candidates: 2, competing: 2 }
    expect(sameLookup(alone, crowded)).toBe(false)
    expect(sameLookup(alone, ready('/p/a.jsonl'))).toBe(false)
  })
})
