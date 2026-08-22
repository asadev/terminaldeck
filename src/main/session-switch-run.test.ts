import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { SessionMeta } from '../shared/types'
import { createHostCore } from './host-core'
import { installPaths, resetPaths } from './platform/paths'
import { createProfile, resetProfilesCache, type Profile } from './profiles'
import type { SavedSession } from './session-restore'
import { createSessionSwitch, type SwitchCore } from './session-switch-run'

/**
 * The account switch and the sign-in, as the machine both shells share.
 *
 * Asad, inside a session on a headless server: *"when I am inside the server, I
 * cannot even change the accounts."* The operations were fine and the desktop
 * pressed them every day — they were simply assembled inside `src/main/index.ts`,
 * which the headless build never loads. What is pinned here is the move's whole
 * point, at both ends:
 *
 * 1. the **capability follows the verb** — a real `createHostCore` given
 *    `switchAccount`/`signInAccount` offers the account and logins seams on its
 *    fanout, and one given neither offers neither (that seam is exactly what
 *    `remote/server.ts` advertises `CAPABILITY.account`/`logins` from and
 *    refuses without);
 * 2. the **operations behave over a core** — the same refusal sentences, the
 *    same wire shape, the same start-then-stop order the desktop proved in use.
 *
 * The per-connection narrowing of what a *device* may see of these —
 * `accountShared(deviceId, …)`, `anyAccountFor`, `ownDevice` — deliberately does
 * not live in this module and is tested where it lives, in the remote server's
 * own tests. Nothing here fans out.
 */

let dir: string

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), 'terminaldeck-switch-run-'))
  mkdirSync(join(dir, 'remote'), { recursive: true })
  resetPaths()
  installPaths({
    userData: () => dir,
    home: () => dir,
    downloads: () => dir,
    appRoot: () => dir,
  })
  resetProfilesCache()
})

afterAll(() => {
  resetPaths()
  rmSync(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 })
})

/* ----------------------------------------- the capability follows the verb -- */

describe('what a shell hands createHostCore decides what the fanout offers', () => {
  it('offers no account seam and no logins seam when the shell supplies neither', async () => {
    const core = createHostCore({ storageDir: join(dir, 'remote'), userData: dir })
    try {
      // What the headless build used to be: terminals, and no way to change
      // whose they are. `remote/server.ts` reads exactly these two fields when
      // it decides whether to advertise — and to serve — the capabilities.
      expect(core.sessions.account).toBeUndefined()
      expect(core.sessions.logins).toBeUndefined()
    } finally {
      core.ptys.killAll()
      await core.ptys.drain()
      await core.credentials.stop()
    }
  })

  it('offers both seams the moment the shell hands the two verbs over', async () => {
    const answer = { ok: false, message: 'test double', session: null }
    const core = createHostCore({
      storageDir: join(dir, 'remote'),
      userData: dir,
      switchAccount: () => Promise.resolve(answer),
      signInAccount: () => Promise.resolve(answer),
    })
    try {
      // The whole mechanism by which a headless host grows the account chip:
      // two options, and the fanout advertises what they make possible.
      expect(core.sessions.account).toBeDefined()
      expect(core.sessions.logins).toBeDefined()
    } finally {
      core.ptys.killAll()
      await core.ptys.drain()
      await core.credentials.stop()
    }
  })
})

/* ------------------------------------------------ the operations, over a core -- */

/** A core of five members, which is all the switch is allowed to reach. */
function fakeCore(over: Partial<SwitchCore> = {}): {
  core: SwitchCore
  started: Parameters<SwitchCore['startSession']>[0][]
  killed: { id: string; reason: string | undefined }[]
  records: Map<string, SavedSession>
} {
  const started: Parameters<SwitchCore['startSession']>[0][] = []
  const killed: { id: string; reason: string | undefined }[] = []
  const records = new Map<string, SavedSession>()
  const core: SwitchCore = {
    ptys: {
      list: () => [],
      kill: (id: string, reason?: string) => {
        killed.push({ id, reason })
      },
      scrollback: () => '',
    } as unknown as SwitchCore['ptys'],
    ledger: {
      get: (id: string) => records.get(id) ?? null,
      entries: () => [...records].map(([id, saved]) => ({ id, saved })),
      forget: (id: string) => {
        records.delete(id)
      },
    } as unknown as SwitchCore['ledger'],
    startSession: (input) => {
      started.push(input)
      return Promise.resolve({
        id: 'replacement',
        cwd: input.cwd,
        title: 'replacement',
        provider: input.provider,
        exitCode: null,
        createdAt: 2,
        resumed: input.resume === true,
      } as SessionMeta)
    },
    statablePath: (cwd) => cwd,
    canContinue: () => true,
    ...over,
  }
  return { core, started, killed, records }
}

describe('switchAccount answers the wire shape with the refusal as written', () => {
  it('refuses a session that is not running, and names the session it left alone', async () => {
    const { core } = fakeCore()
    const verbs = createSessionSwitch(core)
    const answer = await verbs.switchAccount('nobody', 'anything')
    expect(answer.ok).toBe(false)
    // `switchRefusal`'s own sentence, not a wrapper around it.
    expect(answer.message).toContain('not running any more')
    // The id the session still has — a switch that did not happen left it be.
    expect(answer.session).toBe('nobody')
  })

  it('refuses a session this shell did not open as a tab', async () => {
    const meta: SessionMeta = {
      id: 'device-owned',
      cwd: join(dir, 'proj'),
      title: 'proj',
      provider: 'claude',
      exitCode: null,
      createdAt: 1,
    }
    const { core } = fakeCore({
      ptys: { list: () => [meta], kill: () => undefined, scrollback: () => '' } as unknown as SwitchCore['ptys'],
    })
    const verbs = createSessionSwitch(core)
    const answer = await verbs.switchAccount('device-owned', 'anything')
    expect(answer.ok).toBe(false)
    // The ledger holds exactly the sessions that are somebody's tab; a device's
    // confined session and the copilot's are refused in one sentence.
    expect(answer.message).toContain('Only a session you opened here')
  })
})

describe('a switch that can happen: start, prove alive, then stop the old one', () => {
  let project: string
  let work: Profile

  beforeAll(() => {
    project = join(dir, 'switch-project')
    mkdirSync(project, { recursive: true })
    work = createProfile('Work')
  })

  it('runs the whole path over the real planner and the real survival probe', async () => {
    const old: SessionMeta = {
      id: 'old-session',
      cwd: project,
      title: 'switch-project',
      provider: 'claude',
      exitCode: null,
      createdAt: 1,
    }
    const saved: SavedSession = {
      cwd: project,
      provider: 'claude',
      profileId: null,
      cols: 120,
      rows: 40,
      lastSeenAt: 1,
    }
    const { core, started, killed, records } = fakeCore()
    records.set('old-session', saved)
    // Alive before and after: the old session until it is replaced, and the
    // replacement from the moment the fake spawn answers.
    const live = new Set(['old-session', 'replacement'])
    ;(core.ptys as { list(): SessionMeta[] }).list = () =>
      [old].filter((session) => live.has(session.id))
    const originalKill = core.ptys.kill.bind(core.ptys)
    ;(core.ptys as { kill(id: string, reason?: string): void }).kill = (id, reason) => {
      killed.push({ id, reason })
      live.delete(id)
      void originalKill
    }
    ;(core.ptys as { scrollback(id: string): string }).scrollback = () => ''
    // `alive` inside the survival probe asks the list for the replacement's id.
    const alive = core.ptys.list
    ;(core.ptys as { list(): SessionMeta[] }).list = () => {
      const rows = alive()
      return live.has('replacement')
        ? [...rows, { ...old, id: 'replacement' }].filter((session) => live.has(session.id))
        : rows
    }

    const verbs = createSessionSwitch(core)
    const answer = await verbs.switchAccount('old-session', work.id)

    expect(answer).toEqual({ ok: true, message: '', session: 'replacement' })
    // The replacement was started as the target account, in the same folder,
    // at the same size, and named the session it replaces — the conversation
    // guard's exemption, which is the whole of "it's not keeping the history".
    expect(started).toHaveLength(1)
    expect(started[0]).toMatchObject({
      cwd: project,
      cols: 120,
      rows: 40,
      provider: 'claude',
      profileId: work.id,
      replaces: 'old-session',
    })
    // Start, then stop: the old session was killed as `replaced` — the reason
    // the window's swap listens for — and only after the probe.
    expect(killed).toEqual([{ id: 'old-session', reason: 'replaced' }])
    // And the ledger forgot the outgoing id, so a crash in the gap cannot
    // bring it back beside its replacement.
    expect(records.has('old-session')).toBe(false)
  }, 15_000)
})

describe('signInAccount opens a terminal rather than pretending a command exists', () => {
  it('says when the login is gone, as what it is', async () => {
    const { core, started } = fakeCore()
    const verbs = createSessionSwitch(core)
    const answer = await verbs.signInAccount('never-existed')
    expect(answer).toEqual({
      ok: false,
      message: 'There is no such login on this computer any more.',
      session: null,
    })
    expect(started).toHaveLength(0)
  })

  it('starts the terminal in the person’s home, under the account’s configuration', async () => {
    const profile = createProfile('Sign-in target')
    const opened: SessionMeta[] = []
    const { core, started } = fakeCore()
    const verbs = createSessionSwitch(core, { onSessionOpened: (meta) => opened.push(meta) })
    const answer = await verbs.signInAccount(profile.id)
    expect(answer.ok).toBe(true)
    // Never "signed in": nobody has typed anything yet.
    expect(answer.message).toContain('Finish the login in it')
    expect(answer.session).toBe('replacement')
    expect(started[0]).toMatchObject({ cwd: homedir(), provider: 'claude', profileId: profile.id })
    // The shell that owns the session is told, so the terminal becomes a tab on
    // the desktop and a pushed list on a headless host.
    expect(opened).toHaveLength(1)
  })

  it('answers the spawn failure as a sentence, not a rejection', async () => {
    const profile = createProfile('Refused target')
    const { core } = fakeCore({
      startSession: () => Promise.reject(new Error('claude is not installed on this computer')),
    })
    const verbs = createSessionSwitch(core)
    const answer = await verbs.signInAccount(profile.id)
    expect(answer).toEqual({
      ok: false,
      message: 'claude is not installed on this computer',
      session: null,
    })
  })
})

/* -------------------------------------------------- both shells hand them over -- */

describe('both shells give their core the same two verbs', () => {
  it('the desktop delegates to the shared implementation', () => {
    const source = readFileSync(join(__dirname, 'index.ts'), 'utf8')
    expect(source).toContain('signInAccount: (accountId) => sessionSwitch.signInAccount(accountId)')
    expect(source).toContain(
      'switchAccount: (sessionId, accountId) => sessionSwitch.switchAccount(sessionId, accountId)',
    )
    expect(source).toContain('const sessionSwitch = createSessionSwitch(core')
  })

  it('the headless host hands both verbs to its core — the fix itself', () => {
    /*
     * The defect in one line: this file built its core with neither option, so
     * `core.sessions.account` was undefined, `CAPABILITY.account` was never
     * advertised, and a phone attached to a server drew a bar with no rows to
     * press. The assertion is on the options actually reaching
     * `createHostCore`, not on an import existing.
     */
    const source = readFileSync(join(__dirname, '..', 'headless', 'host.ts'), 'utf8')
    const call = source.slice(source.indexOf('const core = createHostCore({'))
    // Up to where the verbs are built from the finished core — everything
    // before that line is the options object (a first-`})` cut would stop at
    // the first inline closure).
    const options = call.slice(0, call.indexOf('createSessionSwitch'))
    expect(options).toContain('switchAccount:')
    expect(options).toContain('signInAccount:')
    expect(source).toContain('createSessionSwitch(core')
  })
})
