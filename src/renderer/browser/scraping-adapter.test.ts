import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  GRANT_WORDS,
  adaptScrapingApi,
  configOf,
  identityOf,
  liftMessage,
  originsLine,
  reachOf,
  readStoreListings,
  statusOf,
} from './scraping-adapter'
import {
  liftAvailable,
  liftRequestsAvailable,
  mintAvailable,
  readOutcome,
  readScrapingConfig,
  readScrapingStatus,
  readToolListings,
  resolveScrapingApi,
  scrapingConfigAvailable,
  scrapingStatusAvailable,
  storeAvailable,
  workersAvailable,
} from './scraping-bridge'
import type { InjectReport, LiftSummary, WorkersView } from './workers-bridge'

/**
 * The join, and the three rules it is not allowed to bend.
 *
 * Every quantity is measured or says it was not; a lift that reports success
 * without a count is unconfirmed; and the lift stays a human gesture with no
 * path around it. What is pinned here is each of those against the adapter, and
 * — just as loadbearing — that the sections with no engine behind them are left
 * **absent** rather than filled with something plausible.
 */

const view = (over: Partial<WorkersView> = {}): WorkersView => ({
  workers: [],
  pace: { maxConcurrent: 4, minDelayMs: 250, jitterMs: 40 },
  paceNote: '',
  lifts: [],
  canSeedStorage: true,
  max: 16,
  ...over,
})

const worker = (over: Record<string, unknown> = {}) => ({
  profileId: 'w1',
  name: 'Worker 1',
  partition: 'persist:w1',
  busy: false,
  holder: '',
  heldMs: 0,
  readyInMs: 0,
  lastReleasedAt: 0,
  pages: [],
  queued: [],
  ...over,
})

const summary = (over: Partial<LiftSummary> = {}): LiftSummary => ({
  id: 'l1',
  takenAt: 1,
  expiresAt: 2,
  sourceProfileId: 'work',
  sourceProfileName: 'Work',
  host: 'shop.example.com',
  origin: 'https://shop.example.com',
  cookieCount: 3,
  cookieNames: ['sessionid'],
  cookieNamesTruncated: false,
  localKeys: 1,
  sessionKeys: 0,
  storageTruncated: false,
  ...over,
})

const report = (over: Partial<InjectReport> = {}): InjectReport => ({
  profileId: 'w1',
  name: 'Worker 1',
  cookiesSet: 3,
  cookiesRefused: 0,
  storageQueued: 0,
  note: '',
  ...over,
})

/* --------------------------------------------------------------- the fleet -- */

describe('the fleet, read as a configuration', () => {
  it('fills the fleet and leaves the four groups this build does not store', () => {
    // The panel draws Requests, Capture, Assets and Checks as unavailable off
    // exactly this: a group that is absent is `null`, and `null` is what those
    // sections are written to say "not available here" about.
    const config = readScrapingConfig(configOf(view({ workers: [worker()] })))
    expect(config?.fleet).toEqual({ profileIds: ['w1'], concurrency: 4, delayMs: 250 })
    expect(config?.requests).toBeNull()
    expect(config?.capture).toBeNull()
    expect(config?.assets).toBeNull()
    expect(config?.checks).toBeNull()
  })

  it('never counts a worker’s requests, because nothing in the pool counts them', () => {
    // `0` here would be a number nobody measured, printed beside a worker that
    // may have been hammering a site all morning. The panel prints "not
    // measured" for null, which is the truth.
    const status = readScrapingStatus(statusOf(view({ workers: [worker({ busy: true })] })))
    expect(status?.workers[0].requests).toBeNull()
    expect(status?.workers[0].state).toBe('busy')
  })

  it('calls a worker that is not busy idle, and reports no last use as none', () => {
    const status = readScrapingStatus(statusOf(view({ workers: [worker()] })))
    expect(status?.workers[0].state).toBe('idle')
    expect(status?.workers[0].lastAt).toBeNull()
  })

  it('measures nothing about capture, assets or coverage', () => {
    const status = readScrapingStatus(statusOf(view()))
    expect(status?.capture).toBeNull()
    expect(status?.assets).toBeNull()
    expect(status?.lastCheck).toBeNull()
  })
})

/* ---------------------------------------------------------------- the join -- */

describe('what the adapter offers a build with the four lanes on it', () => {
  const host = {
    browserWorkers: async () => view(),
    browserWorkersEnsure: async () => view(),
    browserWorkerRegister: async () => view(),
    browserWorkerUnregister: async () => view(),
    browserWorkerPace: async () => view(),
    browserWorkerLift: async () => ({ ok: true, summary: summary() }),
    browserWorkerInject: async () => ({ ok: true, reports: [report()], line: 'done' }),
    browserWorkerForgetLift: async () => view(),
    browserStore: async () => ({ view: { tools: [], folder: '/tools' }, orphans: [] }),
    browserStoreInstall: async () => ({ ok: true, message: 'in' }),
    browserStoreRemove: async () => ({ ok: true, message: 'out' }),
  }

  it('turns the settings, the fleet, the lift, minting and the store on', () => {
    const api = resolveScrapingApi(host, { viewId: () => 'tab-1' })
    expect(scrapingConfigAvailable(api)).toBe(true)
    expect(workersAvailable(api)).toBe(true)
    expect(mintAvailable(api)).toBe(true)
    expect(liftAvailable(api)).toBe(true)
    expect(storeAvailable(api)).toBe(true)
  })

  it('leaves the seams with no engine behind them absent', () => {
    const api = resolveScrapingApi(host, { viewId: () => 'tab-1' })
    // No worker event is emitted anywhere in main, so there is no push to
    // subscribe to and the fleet line says "busy not measured" rather than
    // printing a number that is as old as the last time the panel opened.
    expect(scrapingStatusAvailable(api)).toBe(false)
    // No channel lists or answers a request for a lift. Inventing one here
    // would be building the path around the gesture `session-tools.ts` exists
    // to prevent.
    expect(liftRequestsAvailable(api)).toBe(false)
    expect(api.browserScrapingCaptureClear).toBeUndefined()
    expect(api.browserScrapingCaptureReveal).toBeUndefined()
    expect(api.browserScrapingLedgerClear).toBeUndefined()
  })

  it('offers no lift at all without a page to take one from', () => {
    // Not a context, not a gesture. The lift is defined as an act on the page
    // in front of somebody.
    expect(liftAvailable(resolveScrapingApi(host))).toBe(false)
  })

  it('lets a real browserScraping* method win over the adapter', () => {
    const api = resolveScrapingApi(
      { ...host, browserScrapingConfig: async () => ({ requests: { image: 'block' } }) },
      { viewId: () => 'tab-1' },
    )
    return expect(api.browserScrapingConfig?.('default')).resolves.toEqual({
      requests: { image: 'block' },
    })
  })

  it('holds a pace change against the fleet the engine says it stored', async () => {
    const seen: unknown[] = []
    const api = resolveScrapingApi(
      {
        ...host,
        browserWorkerPace: async (pace: unknown) => {
          seen.push(pace)
          return view({ pace: { maxConcurrent: 16, minDelayMs: 250, jitterMs: 40 } })
        },
      },
      { viewId: () => 'tab-1' },
    )
    const stored = readScrapingConfig(await api.browserScrapingConfigSet?.('default', { fleet: { concurrency: 900 } }))
    // The clamp is what came back, not what was typed.
    expect(stored?.fleet?.concurrency).toBe(16)
    // And the jitter the panel has no field for is carried through rather than
    // sent as a zero, which would wipe a stored setting nothing ever showed.
    expect(seen).toEqual([{ maxConcurrent: 900, minDelayMs: 250, jitterMs: 40 }])
  })

  it('will not claim a group it cannot store was stored', async () => {
    const api = resolveScrapingApi(host, { viewId: () => 'tab-1' })
    expect(readScrapingConfig(await api.browserScrapingConfigSet?.('default', { requests: { image: 'block' } }))).toBeNull()
    expect(readScrapingConfig(await api.browserScrapingConfigSet?.('default', { capture: { on: true } }))).toBeNull()
  })
})

/* ---------------------------------------------------------------- the lift -- */

describe('the lift, which is the one act that moves a credential', () => {
  const base = {
    browserWorkers: async () => view(),
    browserWorkerInject: async () => ({ ok: true, reports: [report({ cookiesSet: 3 })], line: 'done' }),
    browserWorkerForgetLift: async () => view(),
  }

  it('says there is nothing to take when no page is open', async () => {
    const api = resolveScrapingApi(
      { ...base, browserWorkerLift: async () => ({ ok: true, summary: summary() }) },
      { viewId: () => '' },
    )
    const outcome = readOutcome(await api.browserScrapingLift?.('work', ['w1']))
    expect(outcome.ok).toBe(false)
    expect(outcome.message).toContain('no page open')
  })

  it('copies nothing when the page in front is a different account', async () => {
    /*
     * The engine lifts from the page; the panel offers a profile picker; the
     * two can disagree. Copying the wrong account's live session into eight
     * profiles and reporting the one that was asked for would be a lie about a
     * credential, so the lift is discarded and nothing is injected.
     */
    let injected = 0
    let forgotten = ''
    const api = resolveScrapingApi(
      {
        ...base,
        browserWorkerLift: async () => ({ ok: true, summary: summary({ sourceProfileId: 'personal', sourceProfileName: 'Personal' }) }),
        browserWorkerInject: async () => {
          injected += 1
          return { ok: true, reports: [report()], line: 'done' }
        },
        browserWorkerForgetLift: async (id: string) => {
          forgotten = id
          return view()
        },
      },
      { viewId: () => 'tab-1' },
    )
    const outcome = readOutcome(await api.browserScrapingLift?.('work', ['w1']))
    expect(outcome.ok).toBe(false)
    expect(outcome.message).toContain('Personal')
    expect(outcome.message).toContain('Nothing was copied')
    expect(injected).toBe(0)
    expect(forgotten).toBe('l1')
  })

  it('reports the cookies it actually set, and forgets the session after', async () => {
    let forgotten = ''
    const api = resolveScrapingApi(
      {
        ...base,
        browserWorkerLift: async () => ({ ok: true, summary: summary() }),
        browserWorkerInject: async () => ({
          ok: true,
          line: 'done',
          reports: [report({ cookiesSet: 3 }), report({ profileId: 'w2', cookiesSet: 2 })],
        }),
        browserWorkerForgetLift: async (id: string) => {
          forgotten = id
          return view()
        },
      },
      { viewId: () => 'tab-1' },
    )
    const outcome = readOutcome(await api.browserScrapingLift?.('work', ['w1', 'w2']))
    expect(outcome.ok).toBe(true)
    expect(outcome.count).toBe(5)
    // A live session does not sit in the vault for fifteen minutes after a
    // gesture that has finished.
    expect(forgotten).toBe('l1')
  })

  it('is not a success when nothing said which workers it went into', async () => {
    const api = resolveScrapingApi(
      {
        ...base,
        browserWorkerLift: async () => ({ ok: true, summary: summary() }),
        browserWorkerInject: async () => ({ ok: true, reports: [], line: '' }),
      },
      { viewId: () => 'tab-1' },
    )
    const outcome = readOutcome(await api.browserScrapingLift?.('work', ['w1']))
    expect(outcome.ok).toBe(false)
    expect(outcome.count).toBeNull()
  })

  it('carries what did not land, which a cookie count cannot say', () => {
    const line = liftMessage(summary(), [
      report({ note: '3 stored keys will be written the next time this worker opens https://shop.example.com' }),
      report({ profileId: 'w2', note: '3 stored keys will be written the next time this worker opens https://shop.example.com' }),
    ])
    expect(line).toContain('shop.example.com, from Work.')
    expect(line).toContain('3 stored keys will be written')
    // Said once, not once per worker.
    expect(line.match(/stored keys/g)).toHaveLength(1)
  })

  it('does not repeat a count the panel is already printing', () => {
    expect(liftMessage(summary(), [report()])).toBe('shop.example.com, from Work.')
  })
})

/* --------------------------------------------------------------- the store -- */

describe('the store, row by row', () => {
  const tool = (over: Record<string, unknown> = {}) => ({
    id: 'page-images',
    name: 'Full-size images',
    version: '1.0.0',
    grants: ['page-read'],
    origins: ['*'],
    state: 'available',
    sha256: 'a'.repeat(64),
    ...over,
  })

  it('says what a tool reaches before it is on disk', () => {
    const [row] = readToolListings(readStoreListings({ view: { tools: [tool()], folder: '/t' } }))
    expect(row.reach).toEqual(['Reads the page you point it at', 'Runs on any site'])
    expect(row.installed).toBe(false)
    expect(row.identity).toBe('verified')
  })

  it('passes a grant it has no words for through under its own name', () => {
    // Dropping it would understate what a tool reaches, on the one row in this
    // app whose entire job is to state that before the code lands.
    expect(reachOf(['page-write'], [])).toEqual(['page-write'])
    expect(originsLine(['a.com', 'b.com'])).toBe('Runs on a.com, b.com')
  })

  it('offers no Install for a listing carrying no usable signature', () => {
    const [row] = readToolListings(readStoreListings({ view: { tools: [tool({ sha256: '' })] } }))
    // `digestMatches` refuses anything that is not 64 hex characters, so an
    // Install drawn here would be a control that cannot work.
    expect(row.identity).toBe('unverified')
  })

  it('reads an installed tool as verified and a damaged one as a mismatch', () => {
    expect(identityOf('installed', 'a'.repeat(64))).toBe('verified')
    expect(identityOf('damaged', 'a'.repeat(64))).toBe('mismatch')
  })

  it('draws a withdrawn tool still on disk so it can be removed', () => {
    // A file this app wrote and can no longer name is a file nobody has any
    // other way to delete.
    const rows = readToolListings(readStoreListings({ view: { tools: [] }, orphans: ['old-tool'] }))
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ id: 'old-tool', installed: true, identity: 'unknown' })
  })

  it('is empty rather than broken on an answer it cannot read', () => {
    expect(readStoreListings(null)).toEqual([])
    expect(readStoreListings({ view: 'nope' })).toEqual([])
  })
})

/* -------------------------------------------------------------- one string -- */

describe('the grant words are the same words on both sides', () => {
  it('matches GRANT_WORDS in the main process', () => {
    /*
     * The renderer's tsconfig does not include `src/main`, so a user-visible
     * string that has to be identical on both sides is duplicated and pinned by
     * reading the other one off disk — the arrangement `NEW_TAB_LABEL` already
     * uses. Two copies of one string stay one string only because of this test.
     */
    const source = readFileSync(join(__dirname, '..', '..', 'main', 'browser-store-recipe.ts'), 'utf8')
    const block = source.slice(source.indexOf('GRANT_WORDS'))
    for (const [grant, words] of Object.entries(GRANT_WORDS)) {
      expect(block.slice(0, block.indexOf('})'))).toContain(`'${grant}': '${words}'`)
    }
  })
})

/* -------------------------------------------------------- nothing invented -- */

describe('a build with none of the lanes on it', () => {
  it('adapts nothing at all', () => {
    expect(adaptScrapingApi({}, { viewId: () => 'tab-1' })).toEqual({})
    expect(resolveScrapingApi({}, { viewId: () => 'tab-1' })).toEqual({})
  })

  it('offers neither half of enrolling when only one is there', () => {
    const api = resolveScrapingApi({ browserWorkerRegister: async () => view() })
    expect(workersAvailable(api)).toBe(false)
  })

  it('offers no store that can install but not remove', () => {
    const api = resolveScrapingApi({
      browserStore: async () => ({ view: { tools: [] } }),
      browserStoreInstall: async () => ({ ok: true, message: '' }),
    })
    expect(storeAvailable(api)).toBe(false)
  })
})
