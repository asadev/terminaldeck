/**
 * Choosing which of this machine's logins a device gets.
 *
 * Asad, 2026-08-21: *"Maybe we can give one selection step when we give access
 * to any remote device… If they wants to give access of the accounts too, so
 * they can give it"*, and *"he can choose if he wants to give multiple or one or
 * whatever."*
 *
 * Three answers, not two — all, some, none — and the third is the one a store
 * with only a list would lose. It is spelled as an empty `selected` here, and
 * `any()` is what turns it into "draw no chip at all" one layer up.
 *
 * The enforcement over a real socket is pinned next door in `account-serve`'s
 * own tests and in `server.test.ts`; this file is the store and its three
 * states.
 */

import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { AccountGrants, REMOTE_ACCOUNTS_FILE } from './account-grants'

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'td-account-grants-'))
}

describe('the store', () => {
  it('answers null for a device nobody has narrowed, and shares every login', () => {
    const grants = new AccountGrants(tempDir())
    // Null and not `{ mode: 'all' }`: the panel branches on the difference.
    expect(grants.granted('device-a')).toBeNull()
    expect(grants.list()).toEqual([])
    // Absence is not denial on this axis either. Two machines were paired with
    // working account chips when this shipped, and narrowing them by default
    // would take a feature away on a computer in another room.
    expect(grants.shares('device-a', 'system')).toBe(true)
    expect(grants.any('device-a')).toBe(true)
  })

  it('keeps the ticked ids under selected, in the order they were ticked', () => {
    const grants = new AccountGrants(tempDir())
    grants.set('device-a', 'selected', ['p-work', 'system'])
    expect(grants.granted('device-a')).toEqual({
      deviceId: 'device-a',
      mode: 'selected',
      accounts: ['p-work', 'system'],
    })
    expect(grants.shares('device-a', 'p-work')).toBe(true)
    expect(grants.shares('device-a', 'system:codex')).toBe(false)
  })

  it('treats an empty selection as none, which is a real answer and not a gap', () => {
    const grants = new AccountGrants(tempDir())
    grants.set('device-a', 'selected', [])
    // A row exists, so this is not the unnarrowed state…
    expect(grants.granted('device-a')).toEqual({ deviceId: 'device-a', mode: 'selected', accounts: [] })
    // …and it shares nothing, which is what `any` turns into a withheld
    // capability rather than an empty menu.
    expect(grants.shares('device-a', 'system')).toBe(false)
    expect(grants.any('device-a')).toBe(false)
  })

  it('drops the ticks under all, rather than keeping a shadow list', () => {
    const grants = new AccountGrants(tempDir())
    grants.set('device-a', 'selected', ['p-work'])
    grants.set('device-a', 'all', ['p-work'])
    expect(grants.granted('device-a')).toEqual({ deviceId: 'device-a', mode: 'all', accounts: [] })
    // An account added tomorrow is covered by `all` — that is the whole reason
    // it is a mode rather than a list holding every id there is today.
    expect(grants.shares('device-a', 'an-account-minted-later')).toBe(true)
  })

  it('cleans a list the way every other grant store does', () => {
    const grants = new AccountGrants(tempDir())
    const written = grants.set('device-a', 'selected', [
      'p-work',
      'p-work',
      '   ',
      42,
      null,
      '  p-spaced  ',
      'x'.repeat(500),
    ])
    expect(written.accounts).toEqual(['p-work', 'p-spaced'])
  })

  it('forgets a device, because a revoked id can never be issued again', () => {
    const grants = new AccountGrants(tempDir())
    grants.set('device-a', 'selected', ['system'])
    expect(grants.forget('device-a')).toBe(true)
    expect(grants.granted('device-a')).toBeNull()
    expect(grants.forget('device-a')).toBe(false)
  })

  it('drops a deleted account from every device that had ticked it', () => {
    const grants = new AccountGrants(tempDir())
    grants.set('device-a', 'selected', ['system', 'p-gone'])
    grants.set('device-b', 'selected', ['p-gone'])
    grants.set('device-c', 'all', [])
    expect(grants.dropAccount('p-gone')).toBe(true)
    expect(grants.granted('device-a')?.accounts).toEqual(['system'])
    // Device B is left on `selected` with nothing, which is *none* — the honest
    // outcome of having shared exactly one account and then deleting it. It is
    // not widened to `all` to be kind.
    expect(grants.granted('device-b')?.accounts).toEqual([])
    expect(grants.any('device-b')).toBe(false)
    // Nothing to do for a device on `all`, and no write for it either.
    expect(grants.granted('device-c')).toEqual({ deviceId: 'device-c', mode: 'all', accounts: [] })
    expect(grants.dropAccount('p-gone')).toBe(false)
  })

  it('survives a restart, because the choice is on disk and not in the window', () => {
    const dir = tempDir()
    new AccountGrants(dir).set('device-a', 'selected', ['p-work'])
    const reopened = new AccountGrants(dir)
    expect(reopened.granted('device-a')).toEqual({
      deviceId: 'device-a',
      mode: 'selected',
      accounts: ['p-work'],
    })
    const state = JSON.parse(readFileSync(join(dir, REMOTE_ACCOUNTS_FILE), 'utf8')) as {
      version: number
      devices: Record<string, unknown>
    }
    expect(state.version).toBe(1)
    expect(state.devices['device-a']).toEqual({ mode: 'selected', accounts: ['p-work'] })
  })

  it('reads an unreadable file as "nobody has narrowed anybody", which fails open', () => {
    const dir = tempDir()
    writeFileSync(join(dir, REMOTE_ACCOUNTS_FILE), '{ this is not json')
    const grants = new AccountGrants(dir)
    expect(grants.list()).toEqual([])
    // The same direction `FolderGrants` chose, and for the same reason: a JSON
    // typo must not leave every paired machine with no logins, with the failure
    // landing on a computer somewhere else and the fix living here.
    expect(grants.shares('device-a', 'system')).toBe(true)
  })

  it('narrows a row it cannot understand, rather than widening it', () => {
    const dir = tempDir()
    writeFileSync(
      join(dir, REMOTE_ACCOUNTS_FILE),
      JSON.stringify({
        version: 1,
        devices: { 'device-a': { mode: 'everything', accounts: ['system', 7] } },
      }),
    )
    const grants = new AccountGrants(dir)
    // `everything` is not `all`, so it is read as `selected` and shares only
    // what parsed. Corruption inside a record cannot come out wider than it
    // went in.
    expect(grants.granted('device-a')).toEqual({
      deviceId: 'device-a',
      mode: 'selected',
      accounts: ['system'],
    })
    expect(grants.shares('device-a', 'p-work')).toBe(false)
  })
})
