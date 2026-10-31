import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The channels the Scraping panel had none of.
 *
 * Four capabilities shipped as finished engines that took their configuration on
 * every call and stored nothing, so the panel drew four sections as
 * named-and-unavailable. These are the doors, and the assertions here are about
 * the two things a door must not do: report a number nobody measured, and answer
 * an act with a success that carries no count.
 */

const box = vi.hoisted(() => {
  const { mkdtempSync: make } = require('node:fs') as typeof import('node:fs')
  const { tmpdir: tmp } = require('node:os') as typeof import('node:os')
  const { join: j } = require('node:path') as typeof import('node:path')
  return { dir: make(j(tmp(), 'td-scraping-ipc-')), revealed: [] as string[] }
})

vi.mock('electron', () => {
  const made = new Map<string, unknown>()
  return {
    app: { getPath: () => box.dir, userAgentFallback: 'test' },
    shell: { showItemInFolder: (path: string) => box.revealed.push(path) },
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
  SCRAPING_CHANGED_CHANNEL,
  registerBrowserScrapingIpc,
  resetScrapingIpcForTests,
} = await import('./browser-scraping-ipc')
const { resetScrapeSettingsForTests } = await import('./browser-scrape-settings')
const { resetScrapeStatusForTests, noteRunProfile } = await import('./browser-scrape-status')
const { resetWorkersForTests, registerWorker, pool } = await import('./browser-workers')
const { resetProfilesForTests, createProfile } = await import('./browser-profiles')
const { captureRoot } = await import('./browser-capture-store')
const { ledgerPath, runDir } = await import('./browser-scrape-paths')

type Handler = (event: unknown, ...args: unknown[]) => unknown

function wire(): {
  handlers: Map<string, Handler>
  sent: { channel: string; args: unknown[] }[]
} {
  const handlers = new Map<string, Handler>()
  const ipcMain = {
    handle: (channel: string, handler: Handler) => handlers.set(channel, handler),
  } as unknown as IpcMain
  const sent: { channel: string; args: unknown[] }[] = []
  registerBrowserScrapingIpc(ipcMain, {
    send: (channel, ...args) => sent.push({ channel, args }),
    userData: () => box.dir,
  })
  return { handlers, sent }
}

beforeEach(() => {
  box.revealed.length = 0
  rmSync(box.dir, { recursive: true, force: true })
  mkdirSync(box.dir, { recursive: true })
  resetScrapingIpcForTests()
  resetScrapeSettingsForTests()
  resetScrapeStatusForTests()
  resetWorkersForTests()
  resetProfilesForTests()
})

afterEach(() => {
  resetScrapingIpcForTests()
  resetWorkersForTests()
})

describe('the channels', () => {
  it('registers exactly the six the panel calls', () => {
    const { handlers } = wire()
    expect([...handlers.keys()].sort()).toEqual([
      'browser-scraping:capture-clear',
      'browser-scraping:capture-reveal',
      'browser-scraping:config',
      'browser-scraping:config-set',
      'browser-scraping:ledger-clear',
      'browser-scraping:status',
    ])
  })
})

describe('reading a configuration', () => {
  it('answers every group at once, and every setting unset', async () => {
    const { handlers } = wire()
    const config = (await handlers.get('browser-scraping:config')?.(null, 'work')) as {
      fleet: { profileIds: string[]; concurrency: number; delayMs: number }
      requests: Record<string, unknown>
      capture: { on: boolean | null; directory: string; keepMB: number | null }
      assets: { upgrade: { on: boolean | null } }
      checks: { screenshotOnBlock: boolean | null }
    }
    expect(config.requests).toEqual({})
    expect(config.capture.on).toBeNull()
    expect(config.capture.keepMB).toBeNull()
    expect(config.assets.upgrade.on).toBeNull()
    expect(config.checks.screenshotOnBlock).toBeNull()
    // The folder is derived from the profile rather than stored, so it cannot
    // disagree with where a run actually writes.
    expect(config.capture.directory).toBe(join(captureRoot(box.dir), 'work'))
    // The fleet is the browser's one answer, read from the worker store.
    expect(config.fleet.profileIds).toEqual([])
    expect(config.fleet.concurrency).toBeGreaterThan(0)
  })

  it('lists the workers that exist, so the panel’s rows are not all orphans', async () => {
    const profile = createProfile(box.dir, 'Worker 1')
    registerWorker(box.dir, profile.id)
    const { handlers } = wire()
    const config = (await handlers.get('browser-scraping:config')?.(null, 'work')) as {
      fleet: { profileIds: string[] }
    }
    expect(config.fleet.profileIds).toEqual([profile.id])
  })
})

describe('storing a change', () => {
  it('answers with what is stored rather than with a boolean', async () => {
    const { handlers } = wire()
    const stored = (await handlers.get('browser-scraping:config-set')?.(null, 'work', {
      capture: { keepMB: 999_999_999 },
    })) as { capture: { keepMB: number } }
    // Clamped, and the clamp is what comes back — so the field on screen shows
    // what is in force instead of what was typed.
    expect(stored.capture.keepMB).toBeLessThan(999_999_999)
  })

  it('sends the fleet half to the worker store', async () => {
    const { handlers } = wire()
    const stored = (await handlers.get('browser-scraping:config-set')?.(null, 'work', {
      fleet: { concurrency: 5 },
    })) as { fleet: { concurrency: number; delayMs: number } }
    expect(stored.fleet.concurrency).toBe(5)
  })

  it('leaves the jitter alone, because no control on that screen edits it', async () => {
    const { handlers } = wire()
    const before = (await handlers.get('browser-scraping:config')?.(null, 'work')) as {
      fleet: { delayMs: number }
    }
    await handlers.get('browser-scraping:config-set')?.(null, 'work', { fleet: { concurrency: 2 } })
    const after = (await handlers.get('browser-scraping:config')?.(null, 'work')) as {
      fleet: { delayMs: number }
    }
    expect(after.fleet.delayMs).toBe(before.fleet.delayMs)
  })
})

describe('reading what happened', () => {
  it('never counts a worker’s requests, because nothing counts them', async () => {
    const profile = createProfile(box.dir, 'Worker 1')
    registerWorker(box.dir, profile.id)
    const { handlers } = wire()
    const status = (await handlers.get('browser-scraping:status')?.(null, 'work')) as {
      workers: { profileId: string; state: string; requests: number | null; lastAt: number | null }[]
      capture: unknown
      assets: unknown
      lastCheck: unknown
    }
    expect(status.workers).toHaveLength(1)
    expect(status.workers[0].state).toBe('idle')
    // `null`, not `0`: the pool knows which workers are leased and nothing
    // anywhere counts what a worker asked for.
    expect(status.workers[0].requests).toBeNull()
    // Never let go, so never — not the first second of 1970.
    expect(status.workers[0].lastAt).toBeNull()
    expect(status.capture).toBeNull()
    expect(status.assets).toBeNull()
    expect(status.lastCheck).toBeNull()
  })

  it('reports busy as a measured fact once a lease is out', async () => {
    const profile = createProfile(box.dir, 'Worker 1')
    registerWorker(box.dir, profile.id)
    const { handlers } = wire()
    expect(pool.lease({ holder: 'session-1' }).ok).toBe(true)
    const status = (await handlers.get('browser-scraping:status')?.(null, 'work')) as {
      workers: { state: string }[]
    }
    expect(status.workers[0].state).toBe('busy')
  })
})

describe('the push', () => {
  it('sends a whole status when a lease is taken, for the profile last asked about', async () => {
    const profile = createProfile(box.dir, 'Worker 1')
    registerWorker(box.dir, profile.id)
    const { handlers, sent } = wire()
    await handlers.get('browser-scraping:status')?.(null, 'work')
    sent.length = 0
    pool.lease({ holder: 'session-1' })
    await new Promise((resolve) => setImmediate(resolve))
    expect(sent).toHaveLength(1)
    expect(sent[0].channel).toBe(SCRAPING_CHANGED_CHANNEL)
    const status = sent[0].args[0] as { workers: { state: string }[] }
    expect(status.workers[0].state).toBe('busy')
  })

  it('folds several changes in one tick into one send', async () => {
    const first = createProfile(box.dir, 'Worker 1')
    const second = createProfile(box.dir, 'Worker 2')
    registerWorker(box.dir, first.id)
    registerWorker(box.dir, second.id)
    const { sent } = wire()
    sent.length = 0
    pool.lease({ holder: 'a', profileId: first.id })
    pool.lease({ holder: 'b', profileId: second.id })
    await new Promise((resolve) => setImmediate(resolve))
    expect(sent).toHaveLength(1)
  })
})

describe('the two acts', () => {
  it('says how many capture runs went, and never says done with no count', async () => {
    const folder = join(captureRoot(box.dir), 'work', 'run-1')
    mkdirSync(folder, { recursive: true })
    writeFileSync(join(folder, 'capture.jsonl'), '')
    const { handlers } = wire()
    const outcome = (await handlers.get('browser-scraping:capture-clear')?.(null, 'work')) as {
      ok: boolean
      count: number | null
      message: string
    }
    expect(outcome).toEqual({
      ok: true,
      count: 1,
      message: '1 capture run thrown away.',
    })
    expect(existsSync(folder)).toBe(false)
  })

  it('says nothing was there rather than claiming something went', async () => {
    const { handlers } = wire()
    const outcome = (await handlers.get('browser-scraping:ledger-clear')?.(null, 'work')) as {
      ok: boolean
      count: number
    }
    expect(outcome.count).toBe(0)
  })

  it('empties the ledgers of this profile’s runs only', async () => {
    noteRunProfile(box.dir, 'run-a', 'work')
    noteRunProfile(box.dir, 'run-b', 'personal')
    mkdirSync(runDir(box.dir, 'run-a'), { recursive: true })
    mkdirSync(runDir(box.dir, 'run-b'), { recursive: true })
    writeFileSync(ledgerPath(box.dir, 'run-a'), '')
    writeFileSync(ledgerPath(box.dir, 'run-b'), '')
    const { handlers } = wire()
    const outcome = (await handlers.get('browser-scraping:ledger-clear')?.(null, 'work')) as {
      count: number
    }
    expect(outcome.count).toBe(1)
    expect(existsSync(ledgerPath(box.dir, 'run-a'))).toBe(false)
    expect(existsSync(ledgerPath(box.dir, 'run-b'))).toBe(true)
  })

  it('refuses both acts when no profile was named', async () => {
    const { handlers } = wire()
    for (const channel of ['browser-scraping:capture-clear', 'browser-scraping:ledger-clear']) {
      const outcome = (await handlers.get(channel)?.(null, 42)) as { ok: boolean; count: null }
      expect(outcome.ok).toBe(false)
      expect(outcome.count).toBeNull()
    }
  })
})

describe('showing the capture folder', () => {
  it('opens the profile’s own folder, making it first so the button is not a no-op', async () => {
    const { handlers } = wire()
    await handlers.get('browser-scraping:capture-reveal')?.(null, 'work')
    const folder = join(captureRoot(box.dir), 'work')
    expect(existsSync(folder)).toBe(true)
    expect(box.revealed).toEqual([folder])
  })

  it('cannot be talked into a path outside the capture root', async () => {
    const { handlers } = wire()
    await handlers.get('browser-scraping:capture-reveal')?.(null, '../../../etc')
    // `safeSegment` flattened it to one component under the root; nothing
    // outside was opened and nothing outside was created.
    expect(box.revealed).toEqual([join(captureRoot(box.dir), 'etc')])
    await handlers.get('browser-scraping:capture-reveal')?.(null, 42)
    expect(box.revealed).toHaveLength(1)
  })
})
