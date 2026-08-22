/**
 * Which paired devices may move the browser on this screen.
 *
 * The fourth grant axis, and since T30 the one whose default is the device's
 * **kind**: a device the person approved as their own drives by default — the
 * connection is the authorization — and a guest stays off until ticked. What is
 * worth pinning is the whole three-state table and both of its edges: a build
 * with no kinds store must read everyone as a guest, and an explicit no must
 * beat every default, because the one direction this grant may fail in is
 * handing a stranger's machine this person's signed-in browser.
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

/** A kinds table for tests: listed ids are the owner's own, the rest guests. */
function mineAre(...ids: string[]): { kindOf: (id: string) => 'mine' | 'guest' } {
  return { kindOf: (id) => (ids.includes(id) ? 'mine' : 'guest') }
}

describe('the default, which is the kind', () => {
  it('lets a device approved as your own drive with no row in the file at all', () => {
    // T30: the connection IS the authorization. Approving a device as "mine"
    // is the person vouching for it — the same act adding a server is.
    const grants = new WindowGrants(tempDir(), mineAre('my-laptop'))
    expect(grants.drives('my-laptop')).toBe(true)
    // And nothing was written to say so: the default is the kind's, not a row.
    expect(grants.list()).toEqual([])
  })

  it('keeps a guest off until somebody ticks it', () => {
    const grants = new WindowGrants(tempDir(), mineAre('my-laptop'))
    expect(grants.drives('their-phone')).toBe(false)
    expect(grants.set('their-phone', true)).toBe(true)
    expect(grants.drives('their-phone')).toBe(true)
  })

  it('reads every device as a guest when no kinds store was wired', () => {
    // The closed default this store always had. A build that cannot tell the
    // owner's laptop from a stranger's phone has to treat both as the phone.
    const grants = new WindowGrants(tempDir())
    expect(grants.drives('device-a')).toBe(false)
    expect(grants.list()).toEqual([])
    expect(grants.drives('')).toBe(false)
  })

  it('answers a kind decided after construction on the very next call', () => {
    // The seam is read per call, so re-approving a guest as your own lands
    // without a restart — and so does the other direction.
    let kind: 'mine' | 'guest' = 'guest'
    const grants = new WindowGrants(tempDir(), { kindOf: () => kind })
    expect(grants.drives('device-a')).toBe(false)
    kind = 'mine'
    expect(grants.drives('device-a')).toBe(true)
  })
})

describe('the explicit answers', () => {
  it('lets a person turn one of their own machines off, and the no survives a restart', () => {
    /*
     * The half that did not exist under the yes-only format: with an open
     * default, unticking must write a real no or the switch is a control that
     * looks like it works and does not — the defect this round is about.
     */
    const dir = tempDir()
    const grants = new WindowGrants(dir, mineAre('my-laptop'))
    expect(grants.set('my-laptop', false)).toBe(false)
    expect(grants.drives('my-laptop')).toBe(false)
    expect(new WindowGrants(dir, mineAre('my-laptop')).drives('my-laptop')).toBe(false)
    // And the way back works too.
    expect(grants.set('my-laptop', true)).toBe(true)
    expect(new WindowGrants(dir, mineAre('my-laptop')).drives('my-laptop')).toBe(true)
  })

  it('remembers a guest ticked on across a restart, because a permission that forgets itself is not one', () => {
    const dir = tempDir()
    new WindowGrants(dir).set('device-a', true)
    expect(new WindowGrants(dir).drives('device-a')).toBe(true)
  })

  it('keeps an explicit yes when the kind changes, and an explicit no likewise', () => {
    // The person answered about the device; a kind edit does not erase answers.
    const dir = tempDir()
    const grants = new WindowGrants(dir, mineAre())
    grants.set('device-a', true)
    expect(new WindowGrants(dir, mineAre('device-a')).drives('device-a')).toBe(true)
    const second = new WindowGrants(tempDir(), mineAre('device-b'))
    second.set('device-b', false)
    expect(second.drives('device-b')).toBe(false)
  })

  it('writes both sets, and a file the old format wrote reads back with its yeses intact', () => {
    const dir = tempDir()
    const grants = new WindowGrants(dir, mineAre('my-laptop'))
    grants.set('device-a', true)
    grants.set('my-laptop', false)
    const stored: unknown = JSON.parse(readFileSync(join(dir, REMOTE_WINDOWS_FILE), 'utf8'))
    expect(stored).toEqual({ version: 1, devices: ['device-a'], denied: ['my-laptop'] })

    // A yes-only file from the previous release: `denied` absent, not empty.
    const old = tempDir()
    writeFileSync(join(old, REMOTE_WINDOWS_FILE), JSON.stringify({ version: 1, devices: ['device-a'] }))
    const read = new WindowGrants(old)
    expect(read.drives('device-a')).toBe(true)
    expect(read.drives('device-b')).toBe(false)
  })

  it('drops a revoked device from both sets, so no id is left holding an answer', () => {
    /*
     * Revocation is permanent — a returning machine pairs again and is issued a
     * *new* device id — so the entry left behind could never be reached again.
     * On this axis it is not merely tidying: an id left in the yes set is a
     * permission to move this person's browser with nobody attached to it.
     */
    const grants = new WindowGrants(tempDir(), mineAre('my-laptop'))
    grants.set('device-a', true)
    expect(grants.forget('device-a')).toBe(true)
    expect(grants.drives('device-a')).toBe(false)
    grants.set('my-laptop', false)
    expect(grants.forget('my-laptop')).toBe(true)
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
    expect(grants.drives('device-a')).toBe(false)
  })
})

describe('a file this store cannot read', () => {
  it('records nothing, so only the kind defaults stand', () => {
    /*
     * `FolderGrants` and `AccountGrants` widen on a parse failure, on purpose,
     * because the alternative leaves a phone with nothing and the fix on the
     * desktop. This one is the permission itself, so a broken file grants no
     * guest anything: a hand-edited typo must not hand somebody's browser to a
     * machine across a relay.
     */
    const dir = tempDir()
    writeFileSync(join(dir, REMOTE_WINDOWS_FILE), '{ not json at all')
    expect(new WindowGrants(dir).list()).toEqual([])
    expect(new WindowGrants(dir).drives('device-a')).toBe(false)
    // A device of the owner's own still drives — its authorization is the
    // approval, not this file.
    expect(new WindowGrants(dir, mineAre('my-laptop')).drives('my-laptop')).toBe(true)

    const wrong = tempDir()
    writeFileSync(join(wrong, REMOTE_WINDOWS_FILE), JSON.stringify({ version: 1, devices: 'all' }))
    expect(new WindowGrants(wrong).drives('device-a')).toBe(false)
  })

  it('drops the entries it cannot read and keeps the ones it can', () => {
    const dir = tempDir()
    writeFileSync(
      join(dir, REMOTE_WINDOWS_FILE),
      JSON.stringify({ version: 1, devices: ['device-a', 7, '', null, 'device-b'], denied: [3, 'device-c'] }),
    )
    const grants = new WindowGrants(dir)
    expect(grants.list()).toEqual(['device-a', 'device-b'])
    expect(grants.drives('device-c')).toBe(false)
  })

  it('lets a hand-written no beat a hand-written yes for the same id', () => {
    // An id in both sets is a file somebody edited by hand, and the no wins —
    // the only direction a grant like this may fail in.
    const dir = tempDir()
    writeFileSync(
      join(dir, REMOTE_WINDOWS_FILE),
      JSON.stringify({ version: 1, devices: ['device-a'], denied: ['device-a'] }),
    )
    expect(new WindowGrants(dir, mineAre('device-a')).drives('device-a')).toBe(false)
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
