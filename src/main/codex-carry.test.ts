import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { carryCodexThread, findCodexThread } from './codex-carry'
import { planSwitch } from './session-switch'
import type { SessionMeta } from '../shared/types'
import type { Profile } from './profiles'
import type { SavedSession } from './session-restore'

/**
 * A Codex conversation carried across an account switch: found in the account
 * the session is on, copied to the same place under the other account's
 * folder, resumed there by id. The layout and the first line are Codex's own
 * (`codex-rs/rollout`): `sessions/YYYY/MM/DD/rollout-<UTC time>-<thread id>.jsonl`,
 * opening with a `session_meta` line naming the thread and its folder.
 */

let root = ''
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-codex-carry-'))
})
afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

const THREAD = '0199a6e2-7b3c-7d10-9a1e-2f3c4d5e6f70'
const OTHER = '0199a6e2-7b3c-7d10-9a1e-2f3c4d5e6f71'

/** Write a rollout the way Codex does, at `at` (UTC), for `cwd`. */
function rollout(home: string, at: Date, id: string, cwd: string, more = ''): string {
  const pad = (n: number): string => String(n).padStart(2, '0')
  const day = join(String(at.getUTCFullYear()), pad(at.getUTCMonth() + 1), pad(at.getUTCDate()))
  const stamp = `${at.getUTCFullYear()}-${pad(at.getUTCMonth() + 1)}-${pad(at.getUTCDate())}T${pad(at.getUTCHours())}-${pad(at.getUTCMinutes())}-${pad(at.getUTCSeconds())}`
  const dir = join(home, 'sessions', day)
  mkdirSync(dir, { recursive: true })
  const file = join(dir, `rollout-${stamp}-${id}.jsonl`)
  const meta = { timestamp: at.toISOString(), type: 'session_meta', payload: { id, timestamp: at.toISOString(), cwd, originator: 'codex_cli_rs' } }
  writeFileSync(file, `${JSON.stringify(meta)}\n${more}`)
  return file
}

describe('finding the conversation a Codex session is in', () => {
  it('is the one rollout started in this folder after the session started', () => {
    const home = join(root, 'a')
    const cwd = join(root, 'proj')
    mkdirSync(cwd)
    const started = Date.now() - 60_000
    rollout(home, new Date(started - 3_600_000), OTHER, cwd) // an older conversation, here
    const file = rollout(home, new Date(started + 5_000), THREAD, cwd, '{"type":"response_item"}\n')
    expect(findCodexThread({ home, cwd, startedAt: started })).toEqual({
      id: THREAD,
      file,
      relative: file.slice(join(home, 'sessions').length + 1),
    })
  })

  it('is nothing when nothing has been said yet', () => {
    const cwd = join(root, 'proj')
    expect(findCodexThread({ home: join(root, 'a'), cwd, startedAt: Date.now() })).toBeNull()
  })

  it('is nothing when two conversations could be it — a guess would continue somebody else’s', () => {
    const home = join(root, 'a')
    const cwd = join(root, 'proj')
    const started = Date.now() - 60_000
    rollout(home, new Date(started + 1_000), THREAD, cwd)
    rollout(home, new Date(started + 2_000), OTHER, cwd)
    expect(findCodexThread({ home, cwd, startedAt: started })).toBeNull()
    expect(findCodexThread({ home, cwd, startedAt: started, claimed: new Set([OTHER]) })?.id).toBe(THREAD)
  })

  it('ignores conversations in other folders', () => {
    const home = join(root, 'a')
    const started = Date.now() - 60_000
    rollout(home, new Date(started + 1_000), THREAD, join(root, 'elsewhere'))
    expect(findCodexThread({ home, cwd: join(root, 'proj'), startedAt: started })).toBeNull()
  })
})

describe('carrying it to the other account', () => {
  it('copies it to the same place under the other account’s sessions — a copy, never a link', () => {
    const cwd = join(root, 'proj')
    const started = Date.now() - 60_000
    const file = rollout(join(root, 'a'), new Date(started + 1_000), THREAD, cwd, '{"type":"response_item"}\n')
    const thread = findCodexThread({ home: join(root, 'a'), cwd, startedAt: started })
    if (thread === null) throw new Error('not found')
    const placed = carryCodexThread(thread, join(root, 'b'))
    expect(placed).toBe(join(root, 'b', 'sessions', thread.relative))
    expect(readFileSync(placed ?? '', 'utf8')).toBe(readFileSync(file, 'utf8'))
    // Written to independently from here on: the old process's late writes
    // cannot reach the new one's file.
    writeFileSync(file, 'changed')
    expect(readFileSync(placed ?? '', 'utf8')).not.toBe('changed')
  })

  it('replaces an older copy left there by an earlier switch', () => {
    const cwd = join(root, 'proj')
    const started = Date.now() - 60_000
    const at = new Date(started + 1_000)
    rollout(join(root, 'b'), at, THREAD, cwd) // what B had from last time
    rollout(join(root, 'a'), at, THREAD, cwd, '{"type":"response_item","n":2}\n')
    const thread = findCodexThread({ home: join(root, 'a'), cwd, startedAt: started })
    if (thread === null) throw new Error('not found')
    const placed = carryCodexThread(thread, join(root, 'b'))
    expect(readFileSync(placed ?? '', 'utf8')).toContain('"n":2')
  })

  it('answers null when the file is gone, so the switch starts fresh rather than resume nothing', () => {
    const thread = { id: THREAD, file: join(root, 'nope.jsonl'), relative: 'x/rollout.jsonl' }
    expect(carryCodexThread(thread, join(root, 'b'))).toBeNull()
    expect(existsSync(join(root, 'b', 'sessions', 'x'))).toBe(false)
  })
})

describe('the plan for a Codex switch', () => {
  const meta: SessionMeta = { id: 's1', cwd: '/w', title: 'w', provider: 'codex', exitCode: null, createdAt: 1, profileId: 'a', profileName: 'A' }
  const saved: SavedSession = { cwd: '/w', provider: 'codex', profileId: 'a', cols: 80, rows: 24, lastSeenAt: 1 }
  const target = { id: 'b', name: 'B', provider: 'codex', configDir: '/b', system: false } as unknown as Profile
  const decision = { outcome: 'resume', session: saved, configDir: '/b', reason: '' } as never

  it('says the conversation is carried when it was found, and asks the replacement to resume it', () => {
    const plan = planSwitch({ sessionId: 's1', meta, saved, target, decision, occupied: false, sharedStore: false, carried: true })
    expect(plan).toMatchObject({ refusal: null, conversation: 'carried', resume: true, mode: 'restart' })
  })

  it('says it starts fresh when there was nothing to carry', () => {
    const plan = planSwitch({ sessionId: 's1', meta, saved, target, decision, occupied: false, sharedStore: false })
    expect(plan).toMatchObject({ refusal: null, conversation: 'separate', resume: false, mode: 'restart' })
  })
})
