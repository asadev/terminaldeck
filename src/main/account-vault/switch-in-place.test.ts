import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Seat } from './server'
import {
  clearNudge,
  nudge,
  NUDGE_BODY,
  NUDGE_FILE,
  REFRESH_LOCK,
  REFRESH_WAIT_MS,
  refreshInProgress,
  switchInPlace,
  type InPlaceDeps,
} from './switch-in-place'

/**
 * The steps of a switch made in place, without the CLI: what is refused first,
 * the wait for a refresh, the retarget, and the file whose time makes a running
 * Claude Code read its login again. The CLI itself, against these, is
 * `switch-in-place.cli.test.ts`.
 */

let dir = ''
beforeEach(() => {
  dir = mkdtempSync('/tmp/tdip-')
})
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('the nudge', () => {
  it('creates `{}` when there is no plaintext store — which the CLI reads exactly like none', () => {
    expect(nudge(dir)).toBe('created')
    expect(readFileSync(join(dir, NUDGE_FILE), 'utf8')).toBe(NUDGE_BODY)
    expect(statSync(join(dir, NUDGE_FILE)).mode & 0o777).toBe(0o600)
  })

  it('only changes the time of one that exists — a login in it is never touched', () => {
    const file = join(dir, NUDGE_FILE)
    writeFileSync(file, '{"claudeAiOauth":{"accessToken":"x"}}', { mode: 0o600 })
    const old = new Date(Date.now() - 60_000)
    utimesSync(file, old, old)
    const before = statSync(file).mtimeMs
    expect(nudge(dir)).toBe('touched')
    expect(statSync(file).mtimeMs).toBeGreaterThan(before)
    expect(readFileSync(file, 'utf8')).toBe('{"claudeAiOauth":{"accessToken":"x"}}')
  })

  it('takes back only a file that still holds exactly what was put there', () => {
    const file = join(dir, NUDGE_FILE)
    nudge(dir)
    expect(clearNudge(file)).toBe(true)
    expect(existsSync(file)).toBe(false)
    writeFileSync(file, '{"claudeAiOauth":{}}')
    expect(clearNudge(file)).toBe(false)
    expect(existsSync(file)).toBe(true)
  })
})

describe('a refresh in progress', () => {
  it('is the CLI’s lock in that folder, while it is fresh', () => {
    expect(refreshInProgress(dir)).toBe(false)
    mkdirSync(join(dir, REFRESH_LOCK))
    expect(refreshInProgress(dir)).toBe(true)
    const stale = new Date(Date.now() - 120_000)
    utimesSync(join(dir, REFRESH_LOCK), stale, stale)
    expect(refreshInProgress(dir)).toBe(false)
  })
})

/** A fake world: one seated session, a clock the waits move. */
function world(over: Partial<InPlaceDeps> = {}): {
  deps: InPlaceDeps
  order: string[]
  seat: Seat
} {
  const order: string[] = []
  const seat: Seat = { launch: 'a', launchDir: dir, serving: 'a', lastServed: 'a', sessionId: 's1' }
  let clock = 1_000_000
  const deps: InPlaceDeps = {
    seat: (sessionId) => (sessionId === 's1' ? seat : null),
    source: () => ({ kind: 'vault' }),
    adopting: () => false,
    held: () => true,
    keep: () => true,
    user: 'me',
    retarget: (_sessionId, accountId) => {
      order.push(`retarget:${accountId}`)
      seat.serving = accountId
      return true
    },
    launchDir: () => dir,
    sha256: (text) => text,
    now: () => clock,
    wait: async (ms) => {
      clock += ms
      order.push(`wait:${ms}`)
    },
    ...over,
  }
  return { deps, order, seat }
}

const B = { id: 'b', name: 'Work', configDir: '/cfg/b' }

describe('switching in place', () => {
  it('retargets the seat, then nudges — nothing else', async () => {
    const { deps, order, seat } = world()
    const result = await switchInPlace('s1', B, deps)
    expect(result).toMatchObject({ ok: true, nudged: 'created', waitedForRefreshMs: 0 })
    expect(order).toEqual(['retarget:b'])
    expect(seat.serving).toBe('b')
    expect(existsSync(join(dir, NUDGE_FILE))).toBe(true)
  })

  it('waits for a refresh in the session’s folder to finish before retargeting', async () => {
    mkdirSync(join(dir, REFRESH_LOCK))
    let polls = 0
    const { deps, order } = world({
      wait: async () => {
        polls++
        order.push('wait')
        if (polls === 3) rmSync(join(dir, REFRESH_LOCK), { recursive: true })
      },
    })
    const result = await switchInPlace('s1', B, deps)
    expect(result.ok).toBe(true)
    expect(order).toEqual(['wait', 'wait', 'wait', 'retarget:b'])
  })

  it('goes ahead after the ceiling rather than wait on a lock that never clears', async () => {
    mkdirSync(join(dir, REFRESH_LOCK))
    const { deps } = world()
    const result = await switchInPlace('s1', B, deps)
    expect(result).toMatchObject({ ok: true })
    if (result.ok) expect(result.waitedForRefreshMs).toBeGreaterThanOrEqual(REFRESH_WAIT_MS)
  })

  it('a session with no seat is not switched in place', async () => {
    const { deps, order } = world()
    expect(await switchInPlace('other', B, deps)).toMatchObject({ ok: false })
    expect(order).toEqual([])
  })

  it('an account made before the vault is moved in first, from its own keychain item', async () => {
    const kept: Array<[string, string | null]> = []
    const asked: string[][] = []
    const { deps, order } = world({
      held: () => false,
      adopting: () => true,
      keep: (id, _slot, value) => {
        kept.push([id, value])
        order.push('kept')
        return true
      },
      keychain: async (argv) => {
        asked.push([...argv])
        return { code: 0, stdout: 'LOGIN-B\n', stderr: '' }
      },
    })
    expect(await switchInPlace('s1', B, deps)).toMatchObject({ ok: true })
    expect(asked[0]).toEqual(['find-generic-password', '-a', 'me', '-w', '-s', 'Claude Code-credentials-/cfg/b'])
    expect(kept).toEqual([['b', 'LOGIN-B']])
    expect(order).toEqual(['kept', 'retarget:b'])
  })

  it('refuses — and leaves the session alone — when that account has no login', async () => {
    const { deps, order } = world({
      held: () => false,
      adopting: () => true,
      keychain: async () => ({ code: 44, stdout: '', stderr: 'not found' }),
    })
    const result = await switchInPlace('s1', B, deps)
    expect(result).toMatchObject({ ok: false })
    if (!result.ok) expect(result.why).toMatch(/Work is not signed in yet/)
    expect(order).toEqual([])
  })

  it('checks a login the agent keeps exists — without ever asking for the secret', async () => {
    const asked: string[][] = []
    const { deps } = world({
      source: () => ({ kind: 'keychain', dir: null }),
      keychain: async (argv) => {
        asked.push([...argv])
        return { code: 0, stdout: 'attributes', stderr: '' }
      },
    })
    expect(await switchInPlace('s1', { id: 'system', name: 'Personal', configDir: '/Users/me/.claude' }, deps)).toMatchObject({
      ok: true,
    })
    expect(asked).toEqual([['find-generic-password', '-a', 'me', '-s', 'Claude Code-credentials']])
  })

  it('refuses an account whose kept login is out of reach', async () => {
    const { deps, order } = world({ source: () => null })
    expect(await switchInPlace('s1', B, deps)).toMatchObject({ ok: false })
    expect(order).toEqual([])
  })
})
