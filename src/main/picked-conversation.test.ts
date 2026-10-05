import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it, vi } from 'vitest'
import { PickedConversations, TYPING_GAP_MS, hasTranscript, sessionFileConversation } from './picked-conversation'
import { transcriptDir } from './transcript'

/**
 * Learning which conversation a person picked on Claude Code's list — from two
 * sources that name this process, and only for a transcript that exists here.
 * Everything lives in a throwaway folder; no real Claude store is read.
 */

const root = mkdtempSync(join(tmpdir(), 'td-picked-'))
afterAll(() => rmSync(root, { recursive: true, force: true }))

const FRESH = '11111111-1111-4111-8111-111111111111'
const PICKED = '22222222-2222-4222-8222-222222222222'
const OTHER = '33333333-3333-4333-8333-333333333333'

function fixture(name: string) {
  const cwd = join(root, name, 'work')
  const configDir = join(root, name, 'cfg')
  mkdirSync(cwd, { recursive: true })
  mkdirSync(join(configDir, 'sessions'), { recursive: true })
  const transcript = (id: string, body = '{"type":"user"}\n') => {
    const dir = transcriptDir(cwd, configDir)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, `${id}.jsonl`), body)
  }
  const record = (pid: number, sessionId: string, owner = pid) =>
    writeFileSync(join(configDir, 'sessions', `${pid}.json`), JSON.stringify({ pid: owner, sessionId, cwd }))
  return { cwd, configDir, transcript, record }
}

const start = (sessionId: string | null, cliSessionId: string | null, provider = 'claude', event = 'SessionStart') =>
  ({ provider, event, sessionId, cliSessionId })

describe('the transcript check', () => {
  it('accepts only a non-empty transcript under this folder, named by a conversation id', async () => {
    const f = fixture('check')
    expect(await hasTranscript(f, PICKED)).toBe(false)
    f.transcript(PICKED, '')
    expect(await hasTranscript(f, PICKED)).toBe(false)
    f.transcript(PICKED)
    expect(await hasTranscript(f, PICKED)).toBe(true)
    expect(await hasTranscript(f, '../../etc/passwd')).toBe(false)
  })

  it('reads the CLI process record only when it is about that process', async () => {
    const f = fixture('record')
    f.record(4242, PICKED)
    expect(await sessionFileConversation(f.configDir, 4242)).toBe(PICKED)
    f.record(4343, PICKED, 9999)
    expect(await sessionFileConversation(f.configDir, 4343)).toBeNull()
    expect(await sessionFileConversation(f.configDir, 5555)).toBeNull()
  })
})

describe('from the SessionStart hook', () => {
  it('ignores the fresh id held while the list is open, then learns the picked one once', async () => {
    const f = fixture('hook')
    const learned = vi.fn()
    const picked = new PickedConversations({ pidOf: () => null, learned })
    picked.watch('tab-1', f)

    await picked.noteHook(start('tab-1', FRESH))
    expect(learned).not.toHaveBeenCalled()

    f.transcript(PICKED)
    await picked.noteHook(start('tab-1', PICKED))
    await picked.noteHook(start('tab-1', PICKED))
    expect(learned.mock.calls).toEqual([['tab-1', PICKED]])
  })

  it('ignores other agents, other events and sessions it is not watching', async () => {
    const f = fixture('ignore')
    f.transcript(PICKED)
    const learned = vi.fn()
    const picked = new PickedConversations({ pidOf: () => null, learned })
    picked.watch('tab-1', f)
    await picked.noteHook(start('tab-1', PICKED, 'codex'))
    await picked.noteHook(start('tab-1', PICKED, 'claude', 'UserPromptSubmit'))
    await picked.noteHook(start('tab-2', PICKED))
    await picked.noteHook(start(null, PICKED))
    expect(learned).not.toHaveBeenCalled()
  })

  it('learns nothing for a session closed while the disk was being asked', async () => {
    const f = fixture('closed')
    f.transcript(PICKED)
    const learned = vi.fn()
    const picked = new PickedConversations({ pidOf: () => null, learned })
    picked.watch('tab-1', f)
    const pending = picked.noteHook(start('tab-1', PICKED))
    picked.forget('tab-1')
    await pending
    expect(learned).not.toHaveBeenCalled()
  })
})

describe('from the CLI process record, when hooks are off', () => {
  it('reads on typing, at most once per gap, and follows a later pick', async () => {
    const f = fixture('typing')
    let now = 1_000_000
    const learned = vi.fn()
    const picked = new PickedConversations({ pidOf: () => 777, learned, now: () => now })
    picked.watch('tab-1', f)

    f.record(777, FRESH)
    await picked.noteTyping('tab-1')
    expect(learned).not.toHaveBeenCalled()

    f.transcript(PICKED)
    f.record(777, PICKED)
    await picked.noteTyping('tab-1')
    expect(learned).not.toHaveBeenCalled() // inside the gap: not read again

    now += TYPING_GAP_MS
    await picked.noteTyping('tab-1')
    expect(learned.mock.calls).toEqual([['tab-1', PICKED]])

    f.transcript(OTHER)
    f.record(777, OTHER)
    now += TYPING_GAP_MS
    await picked.noteTyping('tab-1')
    expect(learned.mock.calls.at(-1)).toEqual(['tab-1', OTHER])
  })

  it('reads nothing for a session that is not watched or has no process', async () => {
    const f = fixture('unwatched')
    f.transcript(PICKED)
    f.record(777, PICKED)
    const learned = vi.fn()
    const pidOf = vi.fn(() => null)
    const picked = new PickedConversations({ pidOf, learned })
    await picked.noteTyping('tab-1')
    expect(pidOf).not.toHaveBeenCalled()
    picked.watch('tab-1', f)
    await picked.noteTyping('tab-1')
    expect(learned).not.toHaveBeenCalled()
  })
})
