/**
 * What this machine tells another machine about one of its sessions' logins.
 *
 * The property under every test here is the one `session-account.ts` was written
 * for and that this file could most easily lose again: **a login is reported
 * only when it was established, never resolved**. Asad reported the consequence
 * about a session on this very Mac —
 *
 *   > *"here it is showing actually the wrong account — app.imatch.ae is not the
 *   > correct account which is connected to this session"*
 *
 * — and a chip a metre further away, over a session on his PC, is a harder place
 * to catch the same mistake. So the interesting case is not the happy one: it is
 * a session this app did not start, where the honest answer is a full account
 * list and no `current` at all.
 */

import { mkdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it } from 'vitest'
import { installPaths, resetPaths } from '../platform/paths'
import { createProfile, resetProfilesCache } from '../profiles'
import { configureSessionAccounts } from '../session-account'
import type { SessionMeta } from '../../shared/types'
import { createAccountServe } from './account-serve'

const USER_DATA = join(tmpdir(), `terminaldeck-account-serve-${process.pid}`)

/*
 * A real profile store in a temp directory, the way `profiles.test.ts` does it:
 * the accounts this serves are `listProfiles()`, and a fake list would prove
 * nothing about the one thing that can go wrong here — which account object is
 * handed to the wire.
 */
beforeEach(() => {
  resetPaths()
  installPaths({
    userData: () => USER_DATA,
    home: () => USER_DATA,
    downloads: () => USER_DATA,
    appRoot: () => USER_DATA,
  })
  rmSync(USER_DATA, { recursive: true, force: true })
  mkdirSync(USER_DATA, { recursive: true })
  resetProfilesCache()
  configureSessionAccounts(null)
})

afterAll(() => {
  resetPaths()
  configureSessionAccounts(null)
  rmSync(USER_DATA, { recursive: true, force: true })
})

const SESSION = 'far-session-1'

function session(overrides: Partial<SessionMeta> = {}): SessionMeta {
  return {
    id: SESSION,
    cwd: '/tmp/project',
    title: 'agent',
    provider: 'claude',
    exitCode: null,
    createdAt: 1,
    ...overrides,
  } as SessionMeta
}

describe('what a paired machine is told about a session’s account', () => {
  it('lists this machine’s logins, with the one the session was spawned under ticked', async () => {
    const work = createProfile('work@example.com')
    const meta = session({ profileId: work.id, profileName: work.name })
    configureSessionAccounts({ pidOf: () => 1234, describeSession: () => meta })

    const serve = createAccountServe({
      describeSession: () => meta,
      switchAccount: () => Promise.resolve({ ok: true, message: '', session: null }),
    })
    const answer = await serve.read(SESSION)

    // The machine's own install is in the list beside the added one, because it
    // is a login a session can be moved to and the chip is a choice of all of them.
    expect(answer.accounts.map((row) => row.name)).toContain('work@example.com')
    expect(answer.accounts.some((row) => row.system)).toBe(true)
    expect(answer.current?.id).toBe(work.id)
    // The colour travels as the custom-property *name* it is stored as, never as
    // a colour value: the palette is one stylesheet on the drawing side.
    expect(answer.current?.color).toBe(work.color)
  })

  it('names no account at all for a session this app did not start', async () => {
    createProfile('work@example.com')
    /*
     * The whole point of the file. `profileId` is absent, which is a session
     * somebody started in a shell — and on Windows, or with no pid, that is a
     * login `session-account.ts` refuses to guess at. The wire must carry that
     * refusal rather than the machine's default, because a chip naming the wrong
     * login is worse than a chip naming none.
     */
    const meta = session()
    configureSessionAccounts({
      pidOf: () => null,
      describeSession: () => meta,
      platform: 'win32',
    })

    const serve = createAccountServe({
      describeSession: () => meta,
      switchAccount: () => Promise.resolve({ ok: true, message: '', session: null }),
    })
    const answer = await serve.read(SESSION)

    expect(answer.current).toBeNull()
    // And the list is still there, because those accounts are real and the chip
    // is what moves the session onto one of them.
    expect(answer.accounts.length).toBeGreaterThan(0)
  })

  it('answers an unknown session with the list and no login, rather than throwing', async () => {
    createProfile('work@example.com')
    configureSessionAccounts({ pidOf: () => null, describeSession: () => null })
    const serve = createAccountServe({
      describeSession: () => null,
      switchAccount: () => Promise.resolve({ ok: true, message: '', session: null }),
    })
    const answer = await serve.read('nothing-by-that-id')
    expect(answer.current).toBeNull()
    expect(answer.accounts.length).toBeGreaterThan(0)
  })

  it('hands the switch straight to the shell’s own, and passes its answer back unchanged', async () => {
    /*
     * There is exactly one implementation of "run this session as somebody else"
     * on a machine, and this is the assertion that says so: the seam forwards
     * and does not compose. A second arrangement of `startSession` and a kill,
     * written on the remote side, is how one of the two comes to skip the
     * conversation guard — which is the defect *"it's not keeping the
     * conversation history"* was.
     */
    const calls: Array<[string, string]> = []
    const serve = createAccountServe({
      describeSession: () => null,
      switchAccount: (sessionId, accountId) => {
        calls.push([sessionId, accountId])
        return Promise.resolve({ ok: false, message: 'That account has never signed in.', session: sessionId })
      },
    })

    const answer = await serve.switch(SESSION, 'work')
    expect(calls).toEqual([[SESSION, 'work']])
    // The far machine's own sentence, word for word: the asking machine has no
    // way to write a better one about a computer it is not on.
    expect(answer).toEqual({
      ok: false,
      message: 'That account has never signed in.',
      session: SESSION,
    })
  })
})
