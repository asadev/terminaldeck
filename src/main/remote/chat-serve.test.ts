/**
 * The chat view's reading, over the wire.
 *
 * Against real files, because every interesting thing this module does is about
 * a file: which one a session's conversation is in, and where each viewer's
 * cursor into it has got to. The transcripts written here are the shape
 * `parseChatLine` accepts — compact JSON, `"type":"user"` with no space, an
 * `origin.kind` of `human` on a prompt — which is not a detail: the first
 * fixture written for this had spaces in it, `mayCarryChat` refused every line
 * before `JSON.parse` was reached, and the view rendered empty against a
 * transcript that was perfectly good.
 */

import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import { createChatServe } from './chat-serve'
import { encodeProjectPath } from '../transcript'
import type { SessionMeta } from '../../shared/types'

let home: string
let cwd: string

function transcript(name: string, lines: object[]): string {
  const dir = join(home, 'projects', encodeProjectPath(cwd))
  mkdirSync(dir, { recursive: true })
  const path = join(dir, `${name}.jsonl`)
  // Compact, like the CLI's own. `mayCarryChat` is a substring gate before the
  // parse and it looks for `"type":"user"` exactly.
  writeFileSync(path, lines.map((line) => JSON.stringify(line)).join('\n') + '\n')
  return path
}

let clock = 1_787_230_000_000
function said(who: 'you' | 'agent', text: string, uuid: string): object {
  clock += 60_000
  const at = new Date(clock).toISOString()
  if (who === 'you') {
    return {
      type: 'user',
      uuid,
      sessionId: 'sess',
      cwd,
      timestamp: at,
      origin: { kind: 'human' },
      message: { role: 'user', content: text },
    }
  }
  return {
    type: 'assistant',
    uuid,
    sessionId: 'sess',
    cwd,
    timestamp: at,
    message: { id: `msg_${uuid}`, role: 'assistant', model: 'claude-opus-5', content: [{ type: 'text', text }] },
  }
}

function session(over: Partial<SessionMeta> = {}): SessionMeta {
  return {
    id: 'S1',
    cwd,
    title: 'work',
    provider: 'claude',
    exitCode: null,
    createdAt: 0,
    ...over,
  } as SessionMeta
}

beforeEach(() => {
  // A scratch config directory standing in for `~/.claude`, passed through
  // `configDirFor` on every case below. That is not a convenience: it is the
  // seam a session running as a second login uses, so exercising it everywhere
  // means the ordinary path is the scoped one rather than a special case.
  home = mkdtempSync(join(tmpdir(), 'chat-serve-'))
  cwd = mkdtempSync(join(tmpdir(), 'chat-cwd-'))
})

describe('serving a session’s conversation', () => {
  it('answers the whole conversation, with reset, and says it found one', async () => {
    transcript('c1', [
      said('you', 'what does this repo do', 'u1'),
      said('agent', 'It is an Electron app.', 'a1'),
    ])
    const serve = createChatServe({ describeSession: () => session(), configDirFor: () => home })
    const answer = await serve.read('S1', false, 'phone')
    expect(answer.found).toBe(true)
    expect(answer.reset).toBe(true)
    expect(answer.rows.map((row) => [row.role, row.text])).toEqual([
      ['you', 'what does this repo do'],
      ['agent', 'It is an Electron app.'],
    ])
  })

  it('tails only what has been added since that viewer last read', async () => {
    const path = transcript('c1', [said('you', 'first', 'u1')])
    const serve = createChatServe({ describeSession: () => session(), configDirFor: () => home })
    await serve.read('S1', false, 'phone')

    writeFileSync(path, `${[said('you', 'first', 'u1'), said('agent', 'second', 'a1')].map((l) => JSON.stringify(l)).join('\n')}\n`)
    const tail = await serve.read('S1', true, 'phone')
    expect(tail.reset).toBe(false)
    expect(tail.rows.map((row) => row.text)).toEqual(['second'])
  })

  it('gives every viewer its own cursor, so two devices do not eat each other’s bubbles', async () => {
    /*
     * The reason `viewer` is on the seam at all. `chat-transcript.ts` keys its
     * readers by path, which is right for one process drawing its own windows;
     * over a wire it would mean a phone and a second phone consuming each
     * other's new lines, each seeing half a conversation with nothing on screen
     * to say so.
     */
    const path = transcript('c1', [said('you', 'first', 'u1')])
    const serve = createChatServe({ describeSession: () => session(), configDirFor: () => home })
    await serve.read('S1', false, 'phone')
    await serve.read('S1', false, 'laptop')

    writeFileSync(path, `${[said('you', 'first', 'u1'), said('agent', 'second', 'a1')].map((l) => JSON.stringify(l)).join('\n')}\n`)
    expect((await serve.read('S1', true, 'phone')).rows.map((r) => r.text)).toEqual(['second'])
    expect((await serve.read('S1', true, 'laptop')).rows.map((r) => r.text)).toEqual(['second'])
  })

  it('starts over when the session’s transcript is replaced under it', async () => {
    /*
     * Not hypothetical: an account switch ends the process and the new one
     * writes a new file. A reader still pointed at the old path tails a
     * conversation that has stopped growing — a chat view that silently freezes.
     */
    transcript('c1', [said('you', 'in the old one', 'u1')])
    let which = 'c1'
    const serve = createChatServe({
      describeSession: () => session({ agentSessionId: which }),
      configDirFor: () => home,
    })
    expect((await serve.read('S1', false, 'phone')).rows.map((r) => r.text)).toEqual(['in the old one'])

    transcript('c2', [said('you', 'in the new one', 'u2')])
    which = 'c2'
    const after = await serve.read('S1', true, 'phone')
    expect(after.reset).toBe(true)
    expect(after.rows.map((r) => r.text)).toEqual(['in the new one'])
  })

  it('reads the conversation this app named, not merely the newest file', async () => {
    /*
     * `agentSessionId` is the answer rather than a guess. Two sessions in one
     * folder reading "the most recently written transcript" is what Asad
     * recorded on 2026-08-19 — both tabs showing one conversation.
     */
    transcript('mine', [said('you', 'mine', 'u1')])
    // Written second, so it is the newest and the inference would pick it.
    transcript('theirs', [said('you', 'theirs', 'u2')])
    const serve = createChatServe({ describeSession: () => session({ agentSessionId: 'mine' }), configDirFor: () => home })
    expect((await serve.read('S1', false, 'phone')).rows.map((r) => r.text)).toEqual(['mine'])
  })

  it('falls back to the newest transcript when this app never named one', async () => {
    // A resumed session, another agent, or a session this app did not start.
    transcript('older', [said('you', 'older', 'u1')])
    transcript('newer', [said('you', 'newer', 'u2')])
    const serve = createChatServe({ describeSession: () => session(), configDirFor: () => home })
    expect((await serve.read('S1', false, 'phone')).rows.map((r) => r.text)).toEqual(['newer'])
  })

  it('says it found nothing rather than drawing an empty conversation', async () => {
    /*
     * Two different empties. A folder with no transcript at all is `found:
     * false` and takes the toggle off the phone's header; a session that has not
     * spoken yet is `found: true` with no rows.
     */
    const gone = createChatServe({ describeSession: () => null, configDirFor: () => home })
    expect(await gone.read('S1', false, 'phone')).toEqual({ rows: [], reset: true, found: false })

    const silent = createChatServe({ describeSession: () => session(), configDirFor: () => home })
    expect(await silent.read('S1', false, 'phone')).toEqual({ rows: [], reset: true, found: false })

    transcript('c1', [])
    const started = createChatServe({ describeSession: () => session(), configDirFor: () => home })
    const answer = await started.read('S1', false, 'phone')
    expect(answer.found).toBe(true)
    expect(answer.rows).toEqual([])
  })

  it('never sends more than the wire’s cap, and keeps the end', async () => {
    // A conversation is read from the bottom; the newest bubbles are the ones
    // somebody opened the view for.
    const many = Array.from({ length: 260 }, (_, at) => said('you', `line ${at}`, `u${at}`))
    transcript('c1', many)
    const serve = createChatServe({ describeSession: () => session(), configDirFor: () => home })
    const answer = await serve.read('S1', false, 'phone')
    expect(answer.rows).toHaveLength(200)
    expect(answer.rows[answer.rows.length - 1].text).toBe('line 259')
  })

  it('resolves the transcript in the store the session’s own account writes to', async () => {
    /*
     * An account is a config directory, so a session running as a second login
     * files its conversation under that login's `projects/`. Without this a
     * phone is shown the *default* account's conversation in the same folder,
     * which is words rather than a number and therefore the worse version of the
     * mistake `usage-serve.ts` names about the context window.
     */
    const other = mkdtempSync(join(tmpdir(), 'chat-acct-'))
    const dir = join(other, 'projects', encodeProjectPath(cwd))
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'acct.jsonl'), `${JSON.stringify(said('you', 'the other login', 'u9'))}\n`)
    // And a decoy in the default store, which is what would be found without it.
    transcript('acct', [said('you', 'the default login', 'u8')])

    const serve = createChatServe({
      describeSession: () => session({ agentSessionId: 'acct' }),
      configDirFor: () => resolve(other),
    })
    expect((await serve.read('S1', false, 'phone')).rows.map((r) => r.text)).toEqual(['the other login'])
  })
})
