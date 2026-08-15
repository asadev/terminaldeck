import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest'
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

vi.mock('electron', async () => {
  const { tmpdir: tmp } = await import('node:os')
  const { join: j } = await import('node:path')
  return { app: { getPath: () => j(tmp(), `terminaldeck-store-test-${process.pid}`) } }
})

afterAll(() => rmSync(USER_DATA, { recursive: true, force: true }))

beforeEach(() => {
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

    vi.resetModules()
    vi.doMock('electron', () => ({ app: { getPath: () => dir } }))
    const fresh = await import('./store')
    try {
      expect(fresh.store().getOpenSessions()).toEqual([])
      expect(fresh.store().getProjects()).toHaveLength(1)
    } finally {
      vi.doUnmock('electron')
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

    vi.resetModules()
    vi.doMock('electron', () => ({ app: { getPath: () => dir } }))
    const fresh = await import('./store')
    try {
      expect(fresh.store().getOpenSessions()).toEqual([])
    } finally {
      vi.doUnmock('electron')
      vi.resetModules()
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
