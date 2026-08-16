import { describe, expect, it } from 'vitest'
import type { TranscriptFileView } from '../session-transcript'
import { attachWork, folderPlan, type FolderWork, type LiveSession } from './useBoard'

/**
 * The half of the board that decides *whose numbers these are*.
 *
 * Everything here is pure, and it is the part most worth pinning, because its
 * failure mode is silent and expensive: a card that shows a stranger's spend
 * under this session's name looks exactly like a card that is working. That has
 * already happened once in this app — a tab opened at 16:52 reported 143
 * requests and $18.49 it had never spent, because a `claude` running outside
 * the app had written more recently in the same folder.
 */

const NOW = Date.parse('2026-08-16T12:00:00.000Z')
const MINUTE = 60_000
const HERE = '/Users/apple/Projects/terminaldeck'

function live(overrides: Partial<LiveSession> & { id: string }): LiveSession {
  return {
    title: 'Untitled',
    projectPath: HERE,
    provider: 'claude',
    account: null,
    status: 'working',
    statusSince: NOW,
    startedAt: NOW - 10 * MINUTE,
    resumed: false,
    ...overrides,
  }
}

function file(sessionId: string, createdAt: number, modifiedAt = createdAt): TranscriptFileView {
  return { path: `/store/${sessionId}.jsonl`, sessionId, createdAt, modifiedAt }
}

function work(files: TranscriptFileView[], rows: Array<Record<string, unknown>>): FolderWork {
  return { files, summary: { sessions: rows } }
}

const USAGE = { input: 1000, output: 500, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 8500 }

function row(sessionId: string): Record<string, unknown> {
  return {
    sessionId,
    requests: 7,
    usage: USAGE,
    cost: { cost: { total: 0.62 }, byModel: { 'claude-opus-5': {} } },
    context: { percent: 31 },
    lastActivityAt: NOW - MINUTE,
  }
}

describe('attachWork', () => {
  it('attaches the figures of the conversation that began after the tab did', () => {
    const folders = new Map([
      [HERE, work([file('own', NOW - 9 * MINUTE)], [row('own')])],
    ])
    const [card] = attachWork([live({ id: 'tab-1' })], folders)
    expect(card.work?.transcriptPath).toBe('/store/own.jsonl')
    expect(card.work?.requests).toBe(7)
    expect(card.work?.costUsd).toBe(0.62)
  })

  /**
   * The bug, in miniature. `stranger` is the most recently *written* file in
   * the folder and it began before this tab existed, so it cannot be this
   * tab's — and ranking by last write is exactly what handed it over.
   */
  it('shows nothing rather than a conversation that predates the session', () => {
    const folders = new Map([
      [HERE, work([file('stranger', NOW - 3 * 60 * MINUTE, NOW)], [row('stranger')])],
    ])
    const [card] = attachWork([live({ id: 'tab-1' })], folders)
    expect(card.work).toBeNull()
  })

  it('shows nothing for a folder that has not been read yet', () => {
    const [card] = attachWork([live({ id: 'tab-1' })], new Map())
    expect(card.work).toBeNull()
  })

  it('gives a continued session the conversation it continued', () => {
    // `--continue` appends to the folder's last conversation, so a resumed
    // tab's transcript is older than the tab by design and the rule above
    // would rule out the only correct answer.
    const folders = new Map([
      [HERE, work([file('older', NOW - 3 * 60 * MINUTE, NOW)], [row('older')])],
    ])
    const [card] = attachWork([live({ id: 'tab-1', resumed: true })], folders)
    expect(card.work?.transcriptPath).toBe('/store/older.jsonl')
  })

  it('carries every field the card renders straight through', () => {
    const folders = new Map([[HERE, work([file('own', NOW - 9 * MINUTE)], [row('own')])]])
    const [card] = attachWork(
      [live({ id: 'tab-1', title: 'Fix the relay', account: 'Personal', provider: 'codex' })],
      folders,
    )
    expect(card).toMatchObject({
      id: 'tab-1',
      title: 'Fix the relay',
      account: 'Personal',
      provider: 'codex',
      projectPath: HERE,
    })
  })
})

describe('folderPlan', () => {
  const OTHER = '/Users/apple/Projects/science-locus'

  it('asks for each folder once, however many sessions are in it', () => {
    const plan = folderPlan(
      [
        live({ id: 'a' }),
        live({ id: 'b' }),
        live({ id: 'c', projectPath: OTHER }),
      ],
      new Map(),
    )
    expect(plan.map((entry) => entry.cwd).sort()).toEqual([OTHER, HERE].sort())
    expect(plan).toHaveLength(2)
  })

  it('keys a folder on its session set, so the index is re-read when it changes', () => {
    const one = folderPlan([live({ id: 'a' })], new Map())[0]
    const two = folderPlan([live({ id: 'a' }), live({ id: 'b' })], new Map())[0]
    expect(one.sessionKey).not.toBe(two.sessionKey)
    // Order of arrival must not count as a change, or every status update
    // would re-read the directory.
    const forwards = folderPlan([live({ id: 'a' }), live({ id: 'b' })], new Map())[0]
    const backwards = folderPlan([live({ id: 'b' }), live({ id: 'a' })], new Map())[0]
    expect(forwards.sessionKey).toBe(backwards.sessionKey)
  })

  it('keeps looking while a session has no transcript, and stops once it has', () => {
    // A session writes its first transcript line when its first prompt is
    // answered, not when its tab opens — so the retry has to survive that gap.
    expect(folderPlan([live({ id: 'a' })], new Map())[0].awaiting).toBe(true)
    const found = new Map([[HERE, work([file('own', NOW - 9 * MINUTE)], [row('own')])]])
    expect(folderPlan([live({ id: 'a' })], found)[0].awaiting).toBe(false)
  })

  it('stops looking for a transcript an exited session will never write', () => {
    // Otherwise a folder full of dead sessions polls the disk forever.
    expect(folderPlan([live({ id: 'a', status: 'exited' })], new Map())[0].awaiting).toBe(false)
  })

  it('only watches a folder that still has something running', () => {
    // `cost:watch` puts an fs.watch on the transcript directory and primes it
    // with a scan. A folder whose sessions have all exited will never append.
    expect(folderPlan([live({ id: 'a', status: 'exited' })], new Map())[0].live).toBe(false)
    expect(
      folderPlan([live({ id: 'a', status: 'exited' }), live({ id: 'b' })], new Map())[0].live,
    ).toBe(true)
  })
})
