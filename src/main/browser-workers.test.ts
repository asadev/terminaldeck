import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * One temporary `userData` for the whole file, minted before the module mock
 * is hoisted above the imports — `vi.hoisted` is the supported way to have a
 * value that both the factory and the tests can see.
 */
const box = vi.hoisted(() => {
  const { mkdtempSync: make } = require('node:fs') as typeof import('node:fs')
  const { tmpdir: tmp } = require('node:os') as typeof import('node:os')
  const { join: j } = require('node:path') as typeof import('node:path')
  return { dir: make(j(tmp(), 'td-workers-')) }
})

vi.mock('electron', () => {
  const made = new Map<string, unknown>()
  return {
    app: { getPath: () => box.dir, userAgentFallback: 'test' },
    session: {
      fromPartition: (partition: string) => {
        if (!made.has(partition)) {
          made.set(partition, {
            partition,
            setPermissionRequestHandler: () => undefined,
            setPermissionCheckHandler: () => undefined,
            registerPreloadScript: () => 'id',
            setUserAgent: () => undefined,
            on: () => undefined,
          })
        }
        return made.get(partition)
      },
    },
  }
})

const {
  MAX_WORKER_COUNT,
  ensureWorkers,
  isWorkerProfile,
  leaseWorker,
  pool,
  readWorkerStore,
  registerWorker,
  resetWorkersForTests,
  setPoolClockForTests,
  setWorkerPace,
  unregisterWorker,
  workerForSession,
  workerList,
  workerSessionFor,
  workersPath,
} = await import('./browser-workers')
const { resetProfilesForTests, createProfile, profileState } = await import('./browser-profiles')

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-workers-case-'))
  resetProfilesForTests()
  resetWorkersForTests()
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

afterEach(() => {
  rmSync(box.dir, { recursive: true, force: true })
})

describe('the file a pool is remembered in', () => {
  it('drops an id this app never minted rather than handing it to fromPartition', () => {
    /*
     * `session.fromPartition` will make a directory for **any** string,
     * including one with a path separator in it — the same trap `partitionFor`
     * exists for one file over. An id arriving from a JSON file on disk gets the
     * same suspicion as one arriving over IPC.
     */
    const store = readWorkerStore({ workers: ['../../etc', 42, 'persist:something'] })
    expect(store.workers).toEqual([])
  })

  it('never enrols the default profile, whatever the file says', () => {
    /*
     * The default partition holds every login from before profiles existed.
     * Enrolling it as a worker would put his own live sessions into a pool that
     * gets driven in parallel and injected into.
     */
    expect(readWorkerStore({ workers: ['default'] }).workers).toEqual([])
  })

  it('collapses to something usable rather than throwing on rubbish', () => {
    expect(readWorkerStore(null).workers).toEqual([])
    expect(readWorkerStore('nonsense').pace.maxConcurrent).toBeGreaterThan(0)
  })
})

describe('minting workers', () => {
  it('makes as many as were asked for and remembers them across a reload', () => {
    expect(ensureWorkers(dir, 3)).toHaveLength(3)
    resetWorkersForTests()
    resetProfilesForTests()
    expect(workerList(dir)).toHaveLength(3)
    expect(JSON.parse(readFileSync(workersPath(dir), 'utf8')).workers).toHaveLength(3)
  })

  it('grows only — asking for fewer never throws a profile away', () => {
    /*
     * The expensive thing in a worker is not the profile: it is the clearance a
     * site granted that browser, which is bound to the jar and cannot be earned
     * again on demand. A function that read "3" as "delete five" would spend
     * five of those on a typo.
     */
    ensureWorkers(dir, 6)
    expect(ensureWorkers(dir, 3)).toHaveLength(6)
  })

  it('never gives two profiles the same Worker number, even after one is removed', () => {
    /*
     * Numbering from the pool's length is wrong in a way that only appears after
     * a removal: unregister `Worker 2` out of three and the pool is two long, so
     * the next mint would be a *second* `Worker 3`. Two rows with one name is an
     * ambiguity the tools cannot resolve — a caller asking for `Worker 3` gets
     * whichever comes first.
     */
    const three = ensureWorkers(dir, 3)
    unregisterWorker(dir, three[1].profileId)
    const after = ensureWorkers(dir, 3)
    const names = after.map((worker) => worker.name)
    expect(names).toEqual(['Worker 1', 'Worker 3', 'Worker 4'])
    expect(new Set(names).size).toBe(names.length)
  })

  it('will not mint more than the ceiling', () => {
    expect(ensureWorkers(dir, 500)).toHaveLength(MAX_WORKER_COUNT)
  })

  it('enrols a profile that already exists, so a warmed-up one need not be remade', () => {
    const existing = createProfile(dir, 'Warm')
    expect(registerWorker(dir, existing.id).map((worker) => worker.name)).toEqual(['Warm'])
    expect(isWorkerProfile(dir, existing.id)).toBe(true)
  })

  it('refuses to enrol the default profile', () => {
    expect(registerWorker(dir, 'default')).toEqual([])
  })

  it('refuses to enrol an id that is not a profile at all', () => {
    expect(registerWorker(dir, '11111111-2222-4333-8444-555555555555')).toEqual([])
  })
})

describe('taking a worker out of the pool', () => {
  it('leaves the profile, its jar and its clearance completely alone', () => {
    /*
     * The distinction this feature is built on. "Remove" is the word people
     * reach for when they want a row gone, and it is the word that would have
     * destroyed the expensive part — so the only removal here unregisters, and
     * the profile is still in the profile store afterwards.
     */
    const workers = ensureWorkers(dir, 2)
    const gone = workers[0]
    expect(unregisterWorker(dir, gone.profileId)).toHaveLength(1)
    expect(profileState(dir).profiles.some((profile) => profile.id === gone.profileId)).toBe(true)
    expect(isWorkerProfile(dir, gone.profileId)).toBe(false)
  })

  it('does not leave a lease behind that nothing can see or release', () => {
    const workers = ensureWorkers(dir, 2)
    pool.lease({ holder: 'h', profileId: workers[0].profileId })
    expect(pool.outstanding()).toBe(1)
    unregisterWorker(dir, workers[0].profileId)
    expect(pool.outstanding()).toBe(0)
  })
})

describe('which jar a page may be opened in', () => {
  it('answers for a registered worker and refuses everything else', () => {
    /*
     * This is the whole of the guard on the new `browser:create` argument. A
     * `profileId` arrives from the renderer, and "not a worker" has to be
     * indistinguishable from "not a profile" here — otherwise the argument
     * becomes a way to open a page in the jar holding his bank login.
     */
    const [worker] = ensureWorkers(dir, 1)
    const ordinary = createProfile(dir, 'Personal')
    expect(workerSessionFor(dir, worker.profileId)).not.toBeNull()
    expect(workerSessionFor(dir, ordinary.id)).toBeNull()
    expect(workerSessionFor(dir, 'default')).toBeNull()
    expect(workerSessionFor(dir, '../../etc')).toBeNull()
    expect(workerSessionFor(dir, undefined)).toBeNull()
  })

  it('recognises a live session as one of its workers, by identity', () => {
    const [worker] = ensureWorkers(dir, 1)
    const jar = workerSessionFor(dir, worker.profileId)
    expect(jar).not.toBeNull()
    expect(workerForSession(dir, jar as never)?.profileId).toBe(worker.profileId)
    expect(workerForSession(dir, {} as never)).toBeNull()
  })
})

describe('the wait a lease owes', () => {
  it('is actually awaited before the worker is handed over', async () => {
    /*
     * The single most important assertion in this file.
     *
     * A "delay" written into a config and never awaited is what the pipeline
     * had. The mechanism here is that `leaseWorker` does not resolve until the
     * sleep has, so a caller cannot skip it by forgetting — and the test proves
     * that by watching the sleep be called with the number, and by watching the
     * promise still be pending until it resolves.
     */
    ensureWorkers(dir, 1)
    setWorkerPace(dir, { maxConcurrent: 4, minDelayMs: 2_000, jitterMs: 0 })
    const [worker] = workerList(dir)

    // Pin the pool's clock (and its jitter) so the pace is exactly its
    // configured value, not a real-time subtraction. The release and the lease
    // then read the same instant — elapsed is 0 — so the wait is 2000 to the
    // millisecond. With a real `Date.now()`, ~1ms passing between the release
    // and the lease under CI load turns 2000 into 1999, which is the flake this
    // test kept hitting on the macOS runner.
    setPoolClockForTests(() => 5_000_000, () => 0)

    const first = await leaseWorker(dir, { holder: 'h' }, async () => undefined)
    expect(first.ok).toBe(true)
    pool.release({ holder: 'h', profileId: worker.profileId })

    const slept: number[] = []
    let let_go: (() => void) | null = null
    const sleep = (ms: number): Promise<void> => {
      slept.push(ms)
      return new Promise<void>((resolve) => {
        let_go = resolve
      })
    }
    let settled = false
    const pending = leaseWorker(dir, { holder: 'h' }, sleep).then((answer) => {
      settled = true
      return answer
    })
    // One microtask turn is enough for a promise that was going to resolve
    // immediately; the point is that this one has not.
    await Promise.resolve()
    await Promise.resolve()
    expect(slept).toEqual([2_000])
    expect(settled).toBe(false)
    ;(let_go as unknown as () => void)()
    const answer = await pending
    expect(settled).toBe(true)
    expect(answer.ok && answer.pacedMs).toBe(2_000)
  })

  it('reports the wait it actually served, so a pace of zero is visible', async () => {
    ensureWorkers(dir, 1)
    setWorkerPace(dir, { maxConcurrent: 4, minDelayMs: 0, jitterMs: 0 })
    // Pinned for the same reason, so this asserts a computed 0 rather than a 0
    // that only holds because real time keeps `now` ahead of the last release.
    setPoolClockForTests(() => 5_000_000, () => 0)
    const answer = await leaseWorker(dir, { holder: 'h' }, async () => undefined)
    expect(answer.ok && answer.pacedMs).toBe(0)
  })
})

/**
 * A file's source with its comments taken out.
 *
 * The scans below are about what the code *does*, and this whole feature is
 * documented by naming the things it must never call — so a scan of the raw
 * bytes would be failed by the comment that argues for the rule. Block comments
 * only: every mention this file cares about is in one, and a blunter stripper
 * would start eating the `https://` inside a string.
 */
function codeOf(name: string): string {
  return readFileSync(new URL(name, import.meta.url), 'utf8').replace(/\/\*[\s\S]*?\*\//g, ' ')
}

describe('what this feature is structurally unable to do', () => {
  it('never deletes a profile', () => {
    /*
     * Read as source rather than exercised, because the property is *absence*
     * and no test can call a function that is not called. A worker's clearance
     * cannot be re-earned on demand, so the one API that would destroy it must
     * not appear in this file at all — the day somebody adds a tidy-up that
     * calls it, this line is what argues with them.
     */
    const source = codeOf('./browser-workers.ts')
    expect(source).not.toContain('deleteProfile')
    expect(source).not.toContain('clearStorageData')
  })

  it('is the only route from a renderer’s profileId to a cookie jar', () => {
    /*
     * The wiring, held as a contract because it is three lines in a file this
     * lane otherwise does not own.
     *
     * `browser:create` now takes a `profileId`, and a `WebContentsView`'s
     * session is fixed when it is constructed — so the choice has to be made
     * there. What must stay true is that the *only* thing that turns that
     * argument into a session is `workerSession`, which asks this module and is
     * answered null for every id that is not a registered worker. A second
     * route — `sessionForPartition(opts.profileId)`, say — would look identical
     * in a diff and would open a page in whatever jar a caller named, including
     * the one holding his bank login.
     */
    const tab = codeOf('./browser-tab.ts')
    expect(tab).toContain('const worker = workerSession(opts.profileId)')
    expect(tab).toContain(
      'session: isolatedSession(opts.isolationKey) ?? worker ?? hardenedGuestSession(),',
    )
    // `opts.profileId` reaches exactly two places: the guard, and the stamp that
    // records which profile the tab ended up in.
    expect((tab.match(/opts\.profileId/g) ?? []).length).toBe(2)
  })

  it('never opens a window, hidden or otherwise', () => {
    /*
     * Item 11, pinned. Headful is structurally true in this app — the browser is
     * a visible window — and the way that stops being true is a "convenience"
     * that constructs a window with `show: false` to do some work off-screen.
     * Every real target this feature exists for answers a headless client with a
     * 403, so such a path would be a capability regression wearing the shape of
     * a shortcut. These two files hand out a `Session`; turning one into a page
     * is `browser:create`, in the window the person is looking at.
     */
    for (const name of ['./browser-workers.ts', './browser-worker-pool.ts', './browser-session-lift.ts']) {
      const source = codeOf(name)
      expect(source).not.toContain('BrowserWindow')
      expect(source).not.toContain('WebContentsView')
      expect(source).not.toContain('show: false')
      expect(source).not.toMatch(/offscreen|headless/i)
    }
  })
})
