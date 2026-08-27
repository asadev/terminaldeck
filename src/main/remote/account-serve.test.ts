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
import { createAccountServe, createLoginsServe } from './account-serve'
import type { SignInReport } from '../profiles-signin'

/**
 * The probe seam, so no test here spawns `claude auth status`.
 *
 * Every construction below passes one. `createAccountServe` defaults to the real
 * `readSignIn` — which is right in the app and wrong in a unit test, where it
 * would run three agent CLIs against a temp directory and answer differently on
 * every machine the suite is run on.
 */
function report(over: Partial<SignInReport> = {}): SignInReport {
  return {
    profileId: 'system',
    provider: 'claude',
    state: 'signed-in',
    account: 'sherzod.davlatov@gmail.com',
    plan: 'max',
    detail: 'Signed in as sherzod.davlatov@gmail.com on the max plan.',
    command: 'claude auth status --json',
    checkedAt: 1,
    ...over,
  }
}

const SILENT = (): Promise<SignInReport> =>
  Promise.resolve(report({ state: 'unknown', account: null, plan: null, detail: 'Could not tell.' }))

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
      readSignIn: SILENT,
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
      readSignIn: SILENT,
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
      readSignIn: SILENT,
      describeSession: () => null,
      switchAccount: () => Promise.resolve({ ok: true, message: '', session: null }),
    })
    const answer = await serve.read('nothing-by-that-id')
    expect(answer.current).toBeNull()
    expect(answer.accounts.length).toBeGreaterThan(0)
  })

  /**
   * *"It is saying default, so never default."*
   *
   * The list used to be names alone, and for the machine's own install that name
   * is the key `systemProfileId` generates — so the chip over a session on his
   * PC printed `Default` while the Claude Code banner three lines below it in
   * the same pane printed `sherzod.davlatov@gmail.com`. The address exists on
   * that machine; no frame carried it.
   */
  it('sends who each login actually is, so no chip has to fall back to the key', async () => {
    createProfile('work@example.com')
    const asked: string[] = []
    const serve = createAccountServe({
      readSignIn: (profile) => {
        asked.push(profile.id)
        return Promise.resolve(report({ profileId: profile.id }))
      },
      describeSession: () => null,
      switchAccount: () => Promise.resolve({ ok: true, message: '', session: null }),
    })

    const answer = await serve.read('nothing-by-that-id')
    // Every row, not only the one a session happens to be on: the menu is a
    // choice of all of them and each row has to name a login.
    expect(asked.length).toBe(answer.accounts.length)
    for (const row of answer.accounts) {
      expect(row.signIn).toEqual({
        state: 'signed-in',
        account: 'sherzod.davlatov@gmail.com',
        plan: 'max',
        detail: 'Signed in as sherzod.davlatov@gmail.com on the max plan.',
      })
    }
    // And not the fifth field of the report. `command` is a command line for a
    // shell on *this* machine, offered to a window that is on another one.
    expect(answer.accounts.every((row) => !('command' in (row.signIn ?? {})))).toBe(true)
  })

  it('leaves the login unsaid when the probe could not be made at all', async () => {
    /*
     * Absent, never a composed state. "This machine did not answer" and "this
     * machine answered and could not tell" have different remedies, and the chip
     * on the other end tells them apart — see `NOT_REPORTED` in
     * `renderer/machines/machine-account.ts`.
     */
    createProfile('work@example.com')
    const serve = createAccountServe({
      readSignIn: () => Promise.reject(new Error('the CLI is not installed')),
      describeSession: () => null,
      switchAccount: () => Promise.resolve({ ok: true, message: '', session: null }),
    })
    const answer = await serve.read('nothing-by-that-id')
    expect(answer.accounts.length).toBeGreaterThan(0)
    for (const row of answer.accounts) expect(row.signIn).toBeUndefined()
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
      readSignIn: SILENT,
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

/**
 * The machine-scoped half, which exists because the session-scoped one could not
 * be asked without a session.
 *
 * The pane on the other machine used to say so in a sentence — *"its logins are
 * read through a session running on it, and it has none open"* — which is
 * exactly backwards from what somebody wants, since a machine with nothing
 * running is when they open a settings pane to look at it.
 */
describe('what a paired machine is told about this machine’s logins', () => {
  it('lists every login with no session in the question', async () => {
    const work = createProfile('work@example.com')
    const serve = createLoginsServe({
      readSignIn: SILENT,
      signIn: () => Promise.resolve({ ok: false, message: '', session: null }),
      signOut: () => Promise.resolve({ ok: true, message: '', session: null }),
    })

    const accounts = await serve.read()
    expect(accounts.map((row) => row.name)).toContain('work@example.com')
    // The machine's own install is here too — it is a login, and the pane is a
    // list of what this computer has rather than of what somebody added.
    expect(accounts.some((row) => row.system)).toBe(true)
    expect(accounts.find((row) => row.id === work.id)?.color).toBe(work.color)
  })

  it('reports who each login is, so the pane never has to fall back to the key', async () => {
    createProfile('work@example.com')
    const serve = createLoginsServe({
      readSignIn: () => Promise.resolve(report()),
      signIn: () => Promise.resolve({ ok: false, message: '', session: null }),
      signOut: () => Promise.resolve({ ok: true, message: '', session: null }),
    })

    const accounts = await serve.read()
    // The same field the chip reads, from the same probe. Without it the row for
    // this machine's own install has nothing to print but `Default`, which is a
    // key `profiles.ts` mints on every install and names nobody.
    expect(accounts.every((row) => row.signIn?.account === 'sherzod.davlatov@gmail.com')).toBe(true)
    // Never the command line: it names paths on *this* disk and could only be
    // offered to somebody who cannot run it.
    expect(JSON.stringify(accounts)).not.toContain('claude auth status')
  })

  it('hands the sign-in straight to the shell’s own, and passes its answer back unchanged', async () => {
    /*
     * The same property the switch above has, for the same reason: there is one
     * thing on a machine that starts a session — the login shell's PATH, the
     * fallback when a CLI is missing, the profile's redirected config directory
     * — and a second arrangement of it written on the remote side is a session
     * that is subtly not the same kind of session.
     */
    const calls: string[] = []
    const serve = createLoginsServe({
      readSignIn: SILENT,
      signIn: (accountId) => {
        calls.push(accountId)
        return Promise.resolve({
          ok: true,
          message: 'A terminal is open on this computer for work@example.com. Finish the login in it.',
          session: 'sess-new',
        })
      },
      signOut: () => Promise.resolve({ ok: true, message: '', session: null }),
    })

    const answer = await serve.signIn('p-work')
    expect(calls).toEqual(['p-work'])
    // The session travels, because an interactive login nobody can see is one
    // nobody can complete.
    expect(answer).toEqual({
      ok: true,
      message: 'A terminal is open on this computer for work@example.com. Finish the login in it.',
      session: 'sess-new',
    })
  })
})
