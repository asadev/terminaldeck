import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { recoverConversationId } from './conversation-id'

/**
 * Which conversation a session is on when nothing put its id on the command
 * line — a tab restored at launch. Four rules, one case each; see the module.
 */

let dir = ''
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-conversation-id-'))
})
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

function conversation(id: string, modifiedAt: number, body = '{"type":"user"}\n'): void {
  mkdirSync(dir, { recursive: true })
  const file = join(dir, `${id}.jsonl`)
  writeFileSync(file, body)
  utimesSync(file, modifiedAt / 1000, modifiedAt / 1000)
}

describe('recovering the conversation a session is on', () => {
  it('takes the one conversation written to since the session started', async () => {
    const start = Date.now() - 10_000
    conversation('older', start - 60_000)
    conversation('mine', start + 5_000)
    expect(await recoverConversationId({ dirs: [dir], startedAt: start, claimed: new Set() })).toBe('mine')
  })

  it('leaves out every conversation another live tab is on', async () => {
    const start = Date.now() - 10_000
    conversation('mine', start + 1_000)
    conversation('theirs', start + 5_000)
    expect(await recoverConversationId({ dirs: [dir], startedAt: start, claimed: new Set(['theirs']) })).toBe('mine')
  })

  it('answers nothing rather than guess when two unclaimed conversations are moving', async () => {
    const start = Date.now() - 10_000
    conversation('a', start + 1_000)
    conversation('b', start + 2_000)
    expect(await recoverConversationId({ dirs: [dir], startedAt: start, claimed: new Set() })).toBeNull()
  })

  it('with nothing written since it started, it is on the newest conversation it attached to', async () => {
    const start = Date.now()
    conversation('newest-then', start - 5_000)
    conversation('older', start - 60_000)
    conversation('empty', start - 1_000, '')
    expect(await recoverConversationId({ dirs: [dir], startedAt: start, claimed: new Set() })).toBe('newest-then')
  })
})
