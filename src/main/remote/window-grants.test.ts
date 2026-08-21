/**
 * Which paired devices may move the browser on this screen.
 *
 * The fourth grant axis, and the only one whose empty state means **no**. That
 * inversion is the whole of what is worth pinning here: the three stores beside
 * it fail open, deliberately, because they narrow something that already worked
 * — and a copy of their tests with the assertions flipped would be a store that
 * hands a stranger's machine this person's signed-in browser the first time a
 * file fails to parse.
 *
 * The enforcement over a real socket is pinned in `server.test.ts`; the decision
 * this store feeds is `machines/window-serve.test.ts`. This file is the store.
 */

import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { WindowGrants, REMOTE_WINDOWS_FILE } from './window-grants'

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'td-window-grants-'))
}

describe('the store', () => {
  it('allows nobody until somebody says so', () => {
    const grants = new WindowGrants(tempDir())
    expect(grants.drives('device-a')).toBe(false)
    expect(grants.list()).toEqual([])
    // Nothing has ever been able to drive a window here from another computer,
    // so there is no behaviour to preserve and no argument for failing open.
    expect(grants.drives('')).toBe(false)
  })

  it('remembers a yes and forgets a no, and writes only the yeses', () => {
    const dir = tempDir()
    const grants = new WindowGrants(dir)
    expect(grants.set('device-a', true)).toBe(true)
    expect(grants.drives('device-a')).toBe(true)
    expect(grants.list()).toEqual(['device-a'])

    /*
     * The file holds the allowed ids and nothing else. A row per device with a
     * boolean in it would have three states on disk — true, false and absent —
     * and two of them mean the same thing, which is one more way for a
     * hand-edited file to read as permission by accident.
     */
    const stored: unknown = JSON.parse(readFileSync(join(dir, REMOTE_WINDOWS_FILE), 'utf8'))
    expect(stored).toEqual({ version: 1, devices: ['device-a'] })

    expect(grants.set('device-a', false)).toBe(false)
    expect(grants.drives('device-a')).toBe(false)
    expect(JSON.parse(readFileSync(join(dir, REMOTE_WINDOWS_FILE), 'utf8'))).toEqual({
      version: 1,
      devices: [],
    })
  })

  it('survives a restart, because a permission that forgets itself is not one', () => {
    const dir = tempDir()
    new WindowGrants(dir).set('device-a', true)
    expect(new WindowGrants(dir).drives('device-a')).toBe(true)
  })

  it('drops a revoked device, so no id is left holding a permission', () => {
    /*
     * Revocation is permanent — a returning machine pairs again and is issued a
     * *new* device id — so the entry left behind could never be reached again.
     * On this axis it is not merely tidying: an id left in the set is a
     * permission to move this person's browser with nobody attached to it.
     */
    const grants = new WindowGrants(tempDir())
    grants.set('device-a', true)
    expect(grants.forget('device-a')).toBe(true)
    expect(grants.drives('device-a')).toBe(false)
    // And a second forget is a no-op rather than a write.
    expect(grants.forget('device-a')).toBe(false)
  })

  it('refuses an id that is not one, rather than storing it', () => {
    const grants = new WindowGrants(tempDir())
    expect(grants.set(42, true)).toBe(false)
    expect(grants.set('', true)).toBe(false)
    expect(grants.set('  ', true)).toBe(false)
    expect(grants.set('x'.repeat(500), true)).toBe(false)
    expect(grants.list()).toEqual([])
  })

  it('reads anything but true as no', () => {
    // The channel behind this takes whatever the renderer put in it, however the
    // type reads. Only `true` is a yes.
    const grants = new WindowGrants(tempDir())
    expect(grants.set('device-a', 'yes')).toBe(false)
    expect(grants.set('device-a', 1)).toBe(false)
    expect(grants.drives('device-a')).toBe(false)
  })
})

describe('a file this store cannot read', () => {
  it('allows nobody, which is the only direction this grant may fail in', () => {
    /*
     * `FolderGrants` and `AccountGrants` widen on a parse failure, on purpose,
     * because the alternative leaves a phone with nothing and the fix on the
     * desktop. This one is the permission itself, so it fails the way its default
     * points: a hand-edited typo must not hand somebody's browser to a machine
     * across a relay.
     */
    const dir = tempDir()
    writeFileSync(join(dir, REMOTE_WINDOWS_FILE), '{ not json at all')
    expect(new WindowGrants(dir).list()).toEqual([])

    const wrong = tempDir()
    writeFileSync(join(wrong, REMOTE_WINDOWS_FILE), JSON.stringify({ version: 1, devices: 'all' }))
    expect(new WindowGrants(wrong).drives('device-a')).toBe(false)
  })

  it('drops the entries it cannot read and keeps the ones it can', () => {
    const dir = tempDir()
    writeFileSync(
      join(dir, REMOTE_WINDOWS_FILE),
      JSON.stringify({ version: 1, devices: ['device-a', 7, '', null, 'device-b'] }),
    )
    expect(new WindowGrants(dir).list()).toEqual(['device-a', 'device-b'])
  })

  it('ignores a file too large to be one this app wrote', () => {
    const dir = tempDir()
    writeFileSync(
      join(dir, REMOTE_WINDOWS_FILE),
      JSON.stringify({ version: 1, devices: ['device-a'.padEnd(200_000, 'x')] }),
    )
    expect(new WindowGrants(dir).list()).toEqual([])
  })
})
