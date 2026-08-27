import { describe, expect, it } from 'vitest'
import { HeldSessions, savedFrom, SESSIONS_HELD_CHANNEL } from './session-held'
import type { SavedSession } from './session-restore'

/**
 * Keeping a session that could not be started.
 *
 * The behaviour under test is small and the bug it closes is not. `openSessions`
 * is rewritten wholesale from the map of *live* sessions on every change, so a
 * session that failed to restart survived only until the next tab opened — at
 * which point the app forgot it had ever existed. Four of Asad's Claude sessions
 * in two WSL folders went that way on 2026-08-16, were replaced by two plain
 * terminals he opened to get something, and from then on every launch restored
 * shells and reported, correctly, that a shell has no conversation to continue.
 *
 * So each test here is one sentence of the promise: what was asked for is kept
 * as what it was, a failed retry does not throw it away, and the only way out is
 * a start or a person.
 */

const session = (over: Partial<SavedSession> = {}): SavedSession => ({
  cwd: '/home/asad/ClaudeImza',
  provider: 'claude',
  profileId: null,
  cols: 100,
  rows: 30,
  lastSeenAt: 1_700_000_000_000,
  ...over,
})

describe('holding a session that did not start', () => {
  it('keeps the agent that was asked for, not what happened instead', () => {
    const held = new HeldSessions()
    const entry = held.hold(session(), 'it could not be started again')

    // The whole point. A session that could not start as `claude` is a session
    // that failed to start — never a shell session, however plausible a shell
    // would look in the same tab.
    expect(entry.provider).toBe('claude')
    expect(held.saved()[0]?.provider).toBe('claude')
  })

  it('writes the request back to disk as a session, without the failure', () => {
    const held = new HeldSessions()
    const entry = held.hold(session({ profileId: 'work' }), 'the folder is not on this machine')

    // `savedFrom` is what goes into `openSessions`, and `openSessions` is a list
    // of what was open. `reason` and `at` are about the failure and would be two
    // fields every future reader of the stored shape has to know to ignore.
    expect(savedFrom(entry)).toEqual(session({ profileId: 'work' }))
    expect(Object.keys(savedFrom(entry))).not.toContain('reason')
    expect(held.saved()).toEqual([session({ profileId: 'work' })])
  })

  it('holds the tab it was, so Try again is that tab coming back', () => {
    /*
     * `key` above names the *row* and is minted here; this names the tab and was
     * minted by the launch that first wrote the session down. A retry that
     * dropped it would start a session in the right folder under a new name, and
     * the bar would put it on the end instead of where the person had it.
     */
    const held = new HeldSessions()
    const entry = held.hold(session({ tabKey: 'k-left' }), 'the folder is not on this machine')

    expect(entry.tabKey).toBe('k-left')
    expect(savedFrom(entry).tabKey).toBe('k-left')
  })

  it('writes no name at all for an entry from before names existed', () => {
    // `tabKey: undefined` and an absent key are the same to JSON and different
    // to `Object.hasOwn`, and the retry checks the property before it spawns.
    const entry = new HeldSessions().hold(session(), 'it could not be started again')
    expect(Object.hasOwn(entry, 'tabKey')).toBe(false)
    expect(Object.hasOwn(savedFrom(entry), 'tabKey')).toBe(false)
  })

  it('holds the device a confined session was inside, so Try again re-confines it', () => {
    // A session a device started that failed to restore is still confined work.
    // The retry hands `confineDeviceId` to `restoreSpawn`, which rebuilds the
    // boundary; dropping it here would make Try again reproduce the session
    // *unconfined*, the one thing the boundary must never do. It also has to
    // survive `savedFrom` into `openSessions`, so the next launch re-confines it
    // too.
    const held = new HeldSessions()
    const entry = held.hold(session({ confineDeviceId: 'phone-7' }), 'the boundary could not be set')

    expect(entry.confineDeviceId).toBe('phone-7')
    expect(savedFrom(entry).confineDeviceId).toBe('phone-7')
  })

  it('writes no device for a tab opened at the keyboard, which has no boundary', () => {
    const entry = new HeldSessions().hold(session(), 'it could not be started again')
    expect(Object.hasOwn(entry, 'confineDeviceId')).toBe(false)
    expect(Object.hasOwn(savedFrom(entry), 'confineDeviceId')).toBe(false)
  })

  it('keeps two tabs on one agent in one folder as two entries', () => {
    /*
     * A key derived from the folder and the agent would collapse these, and
     * that is not a hypothetical tidy-up: `planRestore` has a whole case about
     * which of two tabs in one conversation store gets to continue, so two of
     * them is an ordinary thing to have open. Collapsing would silently drop one
     * of the very sessions this module exists to stop dropping.
     */
    const held = new HeldSessions()
    const first = held.hold(session(), 'no')
    const second = held.hold(session(), 'no')

    expect(first.key).not.toBe(second.key)
    expect(held.list()).toHaveLength(2)
  })

  it('lists entries oldest first, which is the order they were tabs in', () => {
    const held = new HeldSessions()
    held.hold(session({ cwd: '/a' }), 'no')
    held.hold(session({ cwd: '/b' }), 'no')
    held.hold(session({ cwd: '/c' }), 'no')

    expect(held.list().map((row) => row.cwd)).toEqual(['/a', '/b', '/c'])
  })

  it('says why, in the same words the log says it', () => {
    const held = new HeldSessions()
    const entry = held.hold(session(), 'it could not be started again: File not found')

    // One event, one explanation. Two different sentences for one failure — one
    // in the log, one on the row — is how a support conversation goes wrong.
    expect(entry.reason).toBe('it could not be started again: File not found')
  })
})

describe('trying again', () => {
  it('keeps the entry when the second attempt fails too', () => {
    /*
     * The one behaviour that would undo the whole module if it were wrong.
     * A retry that removed the row on failure is the original bug in miniature:
     * press the button, the row disappears, the session is gone.
     */
    const held = new HeldSessions()
    const entry = held.hold(session(), 'first reason')
    held.fail(entry.key, 'second reason')

    expect(held.list()).toHaveLength(1)
    expect(held.get(entry.key)?.reason).toBe('second reason')
  })

  it('moves the time forward so a row can say when it last tried', () => {
    const held = new HeldSessions()
    const entry = held.hold(session(), 'first')
    const before = entry.at
    held.fail(entry.key, 'second')

    expect(held.get(entry.key)?.at).toBeGreaterThanOrEqual(before)
  })

  it('ignores a key that is not being held', () => {
    // A double-clicked retry, or a window that pressed a row the main process
    // has already released. Neither is an error and neither may throw across
    // the bridge.
    const held = new HeldSessions()
    expect(() => held.fail('held-99', 'no')).not.toThrow()
    expect(held.release('held-99')).toBe(false)
  })

  it('releases an entry once, and says whether anything went', () => {
    const held = new HeldSessions()
    const entry = held.hold(session(), 'no')

    expect(held.release(entry.key)).toBe(true)
    expect(held.release(entry.key)).toBe(false)
    expect(held.empty).toBe(true)
  })
})

describe('telling whoever is holding it', () => {
  it('fires the change hook exactly once per change, and not for a no-op', () => {
    /*
     * Once, because the caller's two jobs are a disk write and a push to the
     * window, and doing either twice is a file rewritten for nothing and a rail
     * that redraws itself. Not at all for a no-op, because a retry that arrives
     * twice would otherwise announce a change that did not happen.
     */
    let changes = 0
    const held = new HeldSessions(() => {
      changes += 1
    })

    const entry = held.hold(session(), 'no')
    expect(changes).toBe(1)
    held.fail(entry.key, 'still no')
    expect(changes).toBe(2)
    held.fail('held-99', 'nobody')
    expect(changes).toBe(2)
    held.release(entry.key)
    expect(changes).toBe(3)
    held.release(entry.key)
    expect(changes).toBe(3)
  })

  it('works with no hook at all, so a test can stand one up bare', () => {
    const held = new HeldSessions()
    expect(() => held.hold(session(), 'no')).not.toThrow()
  })
})

describe('the channel it travels on', () => {
  it('is exported, which is what makes the contract test able to see it', () => {
    /*
     * Not decoration. `preload/contract.test.ts` resolves a channel registered
     * through a constant only when the constant is *exported* — it scans main
     * for `export const NAME = '…'` and then for `ipcMain.handle(NAME`. Declared
     * file-locally in `index.ts`, as this was, the guard reported "no handler at
     * all" for a handler sitting right there. Pinned here so that moving it back
     * fails a test rather than blinding the check that would have caught a
     * preload calling a channel nobody registered.
     */
    expect(SESSIONS_HELD_CHANNEL).toBe('sessions:held')
  })
})
