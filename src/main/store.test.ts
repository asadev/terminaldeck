import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { installPaths, resetPaths } from './platform/paths'
import { store } from './store'
import type { SavedSession } from './session-restore'

/**
 * The store's job here is one thing: be right about what was open, including
 * after a launch that never got a chance to shut down cleanly.
 *
 * So these are about the file rather than the API — what an older `state.json`
 * does when it has never heard of the new field, and whether what was written
 * is what comes back. The store is a singleton over one path, which is why
 * everything below works against the same instance and the file is cleared
 * between tests rather than the module being re-imported.
 */

const USER_DATA = join(tmpdir(), `terminaldeck-store-test-${process.pid}`)
const STATE = join(USER_DATA, 'state.json')

/*
 * The store asks `platform/paths.ts` where userData is, not Electron, so a test
 * says where by installing a provider — which is what both shells do at boot.
 * This used to be `vi.mock('electron')`, and it is worth noting the replacement
 * is not a workaround: mocking a whole runtime to redirect one directory was
 * always heavier than the question deserved.
 */
function pointAt(dir: string): void {
  resetPaths()
  installPaths(atDir(dir))
}

const atDir = (dir: string): Parameters<typeof installPaths>[0] => ({
  userData: () => dir,
  home: () => dir,
  downloads: () => dir,
  appRoot: () => dir,
})

/**
 * A store re-imported from scratch, pointed at `dir`.
 *
 * `vi.resetModules()` throws away `platform/paths` along with the store, so the
 * provider has to be installed on the *fresh* copy of that module — installing
 * it on this file's copy leaves the new store asking a module that nobody told
 * anything, and it throws by design.
 */
async function freshStore(dir: string): Promise<typeof import('./store')> {
  vi.resetModules()
  const paths = await import('./platform/paths')
  paths.installPaths(atDir(dir))
  return await import('./store')
}

afterAll(() => {
  resetPaths()
  rmSync(USER_DATA, { recursive: true, force: true })
})

beforeEach(() => {
  pointAt(USER_DATA)
  mkdirSync(USER_DATA, { recursive: true })
  store().setOpenSessions([])
})

const session = (overrides: Partial<SavedSession> = {}): SavedSession => ({
  cwd: '/Users/asad/Projects/terminaldeck',
  provider: 'claude',
  profileId: null,
  cols: 100,
  rows: 30,
  lastSeenAt: 42,
  ...overrides,
})

const onDisk = (): Record<string, unknown> =>
  JSON.parse(readFileSync(STATE, 'utf8')) as Record<string, unknown>

describe('remembering what was open', () => {
  it('gives back exactly what it was given, in order', () => {
    const sessions = [session({ cwd: '/a' }), session({ cwd: '/b' }), session({ cwd: '/a' })]
    store().setOpenSessions(sessions)
    expect(store().getOpenSessions()).toEqual(sessions)
  })

  it('writes through to the file immediately', () => {
    // Not batched behind a timer on purpose: the case this list exists for is a
    // machine that lost power, and a write still sitting in a timer is a write
    // that never happened.
    store().setOpenSessions([session({ cwd: '/written' })])
    expect(onDisk().openSessions).toEqual([session({ cwd: '/written' })])
  })

  it('hands out a copy, so a caller cannot reorder what the next launch restores', () => {
    // The list goes straight to the restore planner, which sorts by recency to
    // decide which tab in a folder continues. A planner sorting the store's own
    // array in place would rewrite the tab order the store is holding.
    store().setOpenSessions([session({ cwd: '/a' }), session({ cwd: '/b' })])
    const first = store().getOpenSessions()
    first.reverse()
    expect(store().getOpenSessions().map((s) => s.cwd)).toEqual(['/a', '/b'])
  })

  it('forgets everything when handed an empty list', () => {
    store().setOpenSessions([session()])
    store().setOpenSessions([])
    expect(store().getOpenSessions()).toEqual([])
    expect(onDisk().openSessions).toEqual([])
  })

  it('leaves the projects and preferences alone', () => {
    const before = { ...store().getPreferences() }
    store().addProject('/Users/asad/Projects/terminaldeck')
    store().setOpenSessions([session()])
    expect(store().getPreferences()).toEqual(before)
    expect(store().getProjects().map((p) => p.path)).toContain('/Users/asad/Projects/terminaldeck')
  })
})

describe('a state file written by an older build', () => {
  /*
   * The field is additive and there is no migration, which is a claim worth
   * testing rather than asserting in a comment. A file from a build that had
   * never heard of `openSessions` must load as "nothing was open" — not as
   * undefined that something later spreads into a crash.
   */
  it('loads as nothing open rather than as undefined', async () => {
    const dir = join(tmpdir(), `terminaldeck-store-legacy-${process.pid}`)
    mkdirSync(dir, { recursive: true })
    writeFileSync(
      join(dir, 'state.json'),
      JSON.stringify({ version: 1, projects: [{ path: '/x', lastOpenedAt: 1 }] }),
      'utf8',
    )

    // A fresh module, because the store is a singleton over one path and this
    // case is about what a *first* read of an older file does.
    const fresh = await freshStore(dir)
    try {
      expect(fresh.store().getOpenSessions()).toEqual([])
      expect(fresh.store().getProjects()).toHaveLength(1)
    } finally {
      vi.resetModules()
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('ignores an openSessions field that is not a list', async () => {
    const dir = join(tmpdir(), `terminaldeck-store-junk-${process.pid}`)
    mkdirSync(dir, { recursive: true })
    writeFileSync(
      join(dir, 'state.json'),
      JSON.stringify({ version: 1, projects: [], openSessions: 'all of them' }),
      'utf8',
    )

    const fresh = await freshStore(dir)
    try {
      expect(fresh.store().getOpenSessions()).toEqual([])
    } finally {
      vi.resetModules()
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('the project list, as an event', () => {
  /**
   * The listener exists for one caller and one direction: the copilot holds a
   * read grant over these folders that the operating system fixed when its
   * process started, so a folder *leaving* the list has to reach it promptly or
   * the app is enforcing something the person has already withdrawn.
   *
   * A fresh store per test, because the listener set lives on the instance and
   * the file is shared with everything above.
   */
  async function withStore(): Promise<{
    api: Awaited<ReturnType<typeof freshStore>>
    seen: readonly string[][]
    off: () => void
  }> {
    const dir = join(USER_DATA, `projects-${Math.random().toString(16).slice(2)}`)
    mkdirSync(dir, { recursive: true })
    const api = await freshStore(dir)
    const seen: string[][] = []
    const off = api.store().onProjectsChanged((paths) => seen.push([...paths]))
    return { api, seen, off }
  }

  it('fires when a folder is added', async () => {
    const { api, seen, off } = await withStore()
    api.store().addProject('/Users/asad/Projects/one')
    expect(seen).toEqual([['/Users/asad/Projects/one']])
    off()
  })

  it('fires when a folder is removed', async () => {
    const { api, seen, off } = await withStore()
    api.store().addProject('/Users/asad/Projects/one')
    api.store().removeProject('/Users/asad/Projects/one')
    expect(seen).toHaveLength(2)
    expect(seen[1]).toEqual([])
    off()
  })

  it('says nothing when a folder already in the list is re-opened', async () => {
    // Re-opening bumps `lastOpenedAt` and reorders `getProjects()`, and that
    // happens every time somebody clicks a folder. A listener that fired on it
    // would fire constantly and mean nothing — and, for the copilot, would keep
    // asking whether a grant it already holds is still correct.
    const { api, seen, off } = await withStore()
    api.store().addProject('/Users/asad/Projects/one')
    api.store().addProject('/Users/asad/Projects/one')
    expect(seen).toHaveLength(1)
    off()
  })

  it('says nothing when a folder that was never there is removed', async () => {
    const { api, seen, off } = await withStore()
    api.store().removeProject('/Users/asad/Projects/never')
    expect(seen).toEqual([])
    off()
  })

  it('stops after the unsubscribe it handed back', async () => {
    const { api, seen, off } = await withStore()
    off()
    api.store().addProject('/Users/asad/Projects/one')
    expect(seen).toEqual([])
  })

  it('still opens the project when a listener throws', async () => {
    // The callers are the IPC handlers on the path a person takes to open a
    // folder. A consequence of the change must not become part of it.
    const dir = join(USER_DATA, `projects-throwing-${process.pid}`)
    mkdirSync(dir, { recursive: true })
    const api = await freshStore(dir)
    const off = api.store().onProjectsChanged(() => {
      throw new Error('listener is broken')
    })
    expect(() => api.store().addProject('/Users/asad/Projects/one')).not.toThrow()
    expect(api.store().getProjects().map((project) => project.path)).toEqual([
      '/Users/asad/Projects/one',
    ])
    off()
  })
})

describe('what is known about a Claude login', () => {
  const ACCOUNT = '/Users/asad/Library/Application Support/terminaldeck/profiles/one'

  it('says nothing is known, rather than that there is nothing to know', () => {
    /*
     * The distinction the gate in `plan-limit.ts` turns on, so it is pinned
     * here. "Nothing has been established about this account" is a reason to
     * look; "this account was established to have nothing" is a reason to stop.
     * A store that answered an empty record for the first would stop this app
     * asking about every login it has never met.
     */
    expect(store().getAccountLimit('/never/seen')).toBeNull()
  })

  it('merges what is learned separately, because it is learned separately', () => {
    // The billing comes off a banner that happened to be on screen; the answer
    // comes off a `/usage` that ran. Neither writer may erase the other's work.
    store().setAccountLimit(ACCOUNT, { billing: 'api' })
    store().setAccountLimit(ACCOUNT, { answer: 'no-limits' })
    expect(store().getAccountLimit(ACCOUNT)).toMatchObject({
      billing: 'api',
      answer: 'no-limits',
    })
  })

  it('writes through to the file, because a restart is the case it exists for', () => {
    store().setAccountLimit(ACCOUNT, { answer: 'no-limits' })
    const written = onDisk().accountLimits as Record<string, { answer?: string }>
    expect(written[ACCOUNT].answer).toBe('no-limits')
  })

  it('forgets an account outright, which is what a person pressing Check means', () => {
    store().setAccountLimit(ACCOUNT, { billing: 'api', answer: 'no-limits' })
    store().forgetAccountLimit(ACCOUNT)
    expect(store().getAccountLimit(ACCOUNT)).toBeNull()
    // Gone from the file too, not merely from memory: forgetting that survives
    // only until the next launch is not forgetting.
    expect(onDisk().accountLimits).not.toHaveProperty(ACCOUNT)
  })

  it('keeps one login out of another login\'s record', () => {
    store().setAccountLimit('/a', { answer: 'no-limits' })
    store().setAccountLimit('/b', { billing: 'subscription' })
    expect(store().getAccountLimit('/a')).toMatchObject({ answer: 'no-limits' })
    expect(store().getAccountLimit('/b')?.answer).toBeUndefined()
  })

  it('reads a file that has never heard of any of this as knowing nothing', async () => {
    const dir = join(tmpdir(), `terminaldeck-store-accounts-${process.pid}`)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'state.json'), JSON.stringify({ version: 1, projects: [] }), 'utf8')
    const fresh = await freshStore(dir)
    expect(fresh.store().getAccountLimit(ACCOUNT)).toBeNull()
    rmSync(dir, { recursive: true, force: true })
  })

  it('reads a hand-edited mess as knowing nothing, rather than as knowing rubbish', async () => {
    /*
     * `state.json` is a file on somebody's disk, and this particular field
     * decides whether this app types into their terminal. Trusting a list where
     * a map should be costs the feature; distrusting it costs one `/usage`.
     */
    const dir = join(tmpdir(), `terminaldeck-store-junk-${process.pid}`)
    mkdirSync(dir, { recursive: true })
    writeFileSync(
      join(dir, 'state.json'),
      JSON.stringify({ version: 1, projects: [], accountLimits: ['not', 'a', 'map'] }),
      'utf8',
    )
    const fresh = await freshStore(dir)
    expect(fresh.store().getAccountLimit(ACCOUNT)).toBeNull()
    rmSync(dir, { recursive: true, force: true })
  })
})
