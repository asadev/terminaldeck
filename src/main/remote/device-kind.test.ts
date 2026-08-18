import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { DeviceKinds, REMOTE_KINDS_FILE, asDeviceKind } from './device-kind'

/**
 * The two kinds of device, and the three properties that make them a boundary.
 *
 * Every test here is one of:
 *
 *   1. **Unknown is a guest.** Not an error, not a gap, not "whatever the
 *      desktop is offering" — a guest, in every reading path, including the ones
 *      reached by a corrupted file. This is the reversal of `folder-grants.ts`'s
 *      fail-open rule and the reason this is a separate file.
 *   2. **A kind cannot change.** There is no method that overwrites one, and the
 *      one that writes refuses a second, different answer.
 *   3. **It survives a restart.** A store that forgot on relaunch would make
 *      every device a guest the morning after, which reads as the app breaking
 *      rather than as a rule.
 */

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'td-kinds-'))
}

describe('unknown is a guest', () => {
  it('answers guest for a device it has never heard of', () => {
    const kinds = new DeviceKinds(tempDir())
    expect(kinds.kindOf('never-seen')).toBe('guest')
    // And says so honestly to the one screen that is allowed to ask, which needs
    // to tell "somebody chose guest" from "this predates the choice existing".
    expect(kinds.decided('never-seen')).toBe(false)
  })

  it('answers guest for an empty or non-string id', () => {
    const kinds = new DeviceKinds(tempDir())
    expect(kinds.kindOf('')).toBe('guest')
    expect(kinds.kindOf(undefined as unknown as string)).toBe('guest')
  })

  it('answers guest when the file is unreadable JSON', () => {
    const dir = tempDir()
    const store = new DeviceKinds(dir)
    store.claim('phone', 'mine')
    writeFileSync(join(dir, REMOTE_KINDS_FILE), '{ not json')
    expect(new DeviceKinds(dir).kindOf('phone')).toBe('guest')
  })

  it('drops a record whose kind is not one of the two, rather than keeping it', () => {
    const dir = tempDir()
    // Hand-written, which is the case this guards: the failure that matters is a
    // file somebody edited or a format that changed, not a value this code wrote.
    writeFileSync(
      join(dir, REMOTE_KINDS_FILE),
      JSON.stringify({
        version: 1,
        devices: {
          typo: { kind: 'Mine', decidedAt: 1 },
          truthy: { kind: true, decidedAt: 1 },
          real: { kind: 'mine', decidedAt: 1 },
        },
      }),
    )
    const kinds = new DeviceKinds(dir)
    expect(kinds.kindOf('typo')).toBe('guest')
    expect(kinds.kindOf('truthy')).toBe('guest')
    // And the one good row is still read: failing closed must not mean failing
    // entirely, or one bad byte would demote a household.
    expect(kinds.kindOf('real')).toBe('mine')
  })

  it('never produces mine from a value that is not the literal string', () => {
    // The narrowing itself, because it is the only door `mine` comes through and
    // a loosened comparison here would loosen every check downstream at once.
    expect(asDeviceKind('mine')).toBe('mine')
    expect(asDeviceKind('guest')).toBe('guest')
    for (const bad of ['MINE', ' mine', 'owner', 1, true, null, undefined, {}]) {
      expect(asDeviceKind(bad)).toBeNull()
    }
  })
})

describe('a kind cannot change after pairing', () => {
  it('refuses a second, different kind for the same device', () => {
    const kinds = new DeviceKinds(tempDir())
    expect(kinds.claim('laptop', 'guest')).toBe(true)
    expect(kinds.claim('laptop', 'mine')).toBe(false)
    expect(kinds.kindOf('laptop')).toBe('guest')
  })

  it('accepts a repeat of the same kind, so a retried approval is not an error', () => {
    const kinds = new DeviceKinds(tempDir())
    expect(kinds.claim('laptop', 'mine')).toBe(true)
    expect(kinds.claim('laptop', 'mine')).toBe(true)
    expect(kinds.kindOf('laptop')).toBe('mine')
  })

  it('exposes no way to overwrite one', () => {
    // The absence is the mechanism, so it is asserted rather than described. A
    // future `set` or `update` on this class is the escalation the whole design
    // removes, and it should fail here first.
    const surface = Object.getOwnPropertyNames(DeviceKinds.prototype)
    expect(surface).toEqual(
      expect.arrayContaining(['constructor', 'kindOf', 'decided', 'list', 'claim', 'forget']),
    )
    expect(surface).not.toContain('set')
    expect(surface).not.toContain('update')
  })

  it('forgets one only on revoke, which is what makes re-pairing the way to change it', () => {
    const kinds = new DeviceKinds(tempDir())
    kinds.claim('phone', 'guest')
    expect(kinds.forget('phone')).toBe(true)
    expect(kinds.decided('phone')).toBe(false)
    // A new pairing mints a new device id, so in practice this row never comes
    // back — but the same id must be claimable again, or revoke-and-repair would
    // be a door that closes behind you.
    expect(kinds.claim('phone', 'mine')).toBe(true)
    expect(kinds.kindOf('phone')).toBe('mine')
  })
})

describe('what is on disk', () => {
  it('survives a restart', () => {
    const dir = tempDir()
    new DeviceKinds(dir).claim('laptop', 'mine')
    expect(new DeviceKinds(dir).kindOf('laptop')).toBe('mine')
  })

  it('records when the choice was made, from the injected clock', () => {
    const kinds = new DeviceKinds(tempDir(), () => 1_760_000_000_000)
    kinds.claim('laptop', 'mine')
    expect(kinds.list()).toEqual([
      { deviceId: 'laptop', kind: 'mine', decidedAt: 1_760_000_000_000 },
    ])
  })

  it('writes a version, so a later format can tell itself apart', () => {
    const dir = tempDir()
    const kinds = new DeviceKinds(dir)
    kinds.claim('laptop', 'guest')
    const parsed = JSON.parse(readFileSync(kinds.file, 'utf8')) as { version: number }
    expect(parsed.version).toBe(1)
  })

  it('holds a device id that is not a plain word', () => {
    // Ids come from `randomUUID`, but the file is a JSON object keyed by them and
    // a key that collided with `Object.prototype` would answer the wrong thing.
    const dir = tempDir()
    const kinds = new DeviceKinds(dir)
    kinds.claim('__proto__', 'guest')
    expect(new DeviceKinds(dir).kindOf('__proto__')).toBe('guest')
    expect(new DeviceKinds(dir).kindOf('constructor')).toBe('guest')
  })
})
