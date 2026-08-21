import { describe, expect, it } from 'vitest'
import {
  liftAvailable,
  liftRequestsAvailable,
  readCount,
  readLiftRequests,
  readOutcome,
  readRequestRule,
  readScrapingConfig,
  readScrapingStatus,
  readToolListings,
  resolveScrapingApi,
  scrapingConfigAvailable,
  scrapingStatusAvailable,
  storeAvailable,
  workersAvailable,
} from './scraping-bridge'

/**
 * The seam, and the discipline on everything that comes through it.
 *
 * Nothing here is wired yet — this module is the contract four parallel lanes
 * fill — so what is worth pinning is the half that is already load-bearing: a
 * build missing a lane loses that section and not the panel, and no answer this
 * side cannot read is ever allowed to become a number on screen or a success
 * somebody acts on.
 */

describe('binding whatever this build has', () => {
  it('takes the methods that are there and nothing else', () => {
    const api = resolveScrapingApi({
      browserScrapingConfig: async () => ({}),
      browserScrapingTools: 'not a function',
      unrelated: () => 1,
    })
    expect(typeof api.browserScrapingConfig).toBe('function')
    expect(api.browserScrapingTools).toBeUndefined()
    expect(Object.keys(api)).toEqual(['browserScrapingConfig'])
  })

  it('keeps the preload as the receiver, so a bound method still works', () => {
    const host = {
      answer: 7,
      async browserScrapingStatus(this: { answer: number }): Promise<unknown> {
        return { workers: [], token: this.answer }
      },
    }
    const api = resolveScrapingApi(host)
    return expect(api.browserScrapingStatus?.('default')).resolves.toEqual({
      workers: [],
      token: 7,
    })
  })

  it('is empty rather than broken on a host that is not an object', () => {
    expect(resolveScrapingApi(null)).toEqual({})
    expect(resolveScrapingApi('deck')).toEqual({})
  })
})

describe('what a half-wired build is allowed to offer', () => {
  it('needs the read and the write before it shows a setting at all', () => {
    expect(scrapingConfigAvailable({ browserScrapingConfig: async () => ({}) })).toBe(false)
    expect(
      scrapingConfigAvailable({
        browserScrapingConfig: async () => ({}),
        browserScrapingConfigSet: async () => ({}),
      }),
    ).toBe(true)
  })

  it('needs the pull and the push before it shows a measured number', () => {
    // With only the pull, every count on screen is as old as the last time the
    // panel was opened — the same lie with a timestamp on it.
    expect(scrapingStatusAvailable({ browserScrapingStatus: async () => ({}) })).toBe(false)
    expect(
      scrapingStatusAvailable({
        browserScrapingStatus: async () => ({}),
        onBrowserScrapingStatus: () => () => {},
      }),
    ).toBe(true)
  })

  it('needs both halves of enrolling before it offers either', () => {
    expect(workersAvailable({ browserScrapingWorkerAdd: async () => ({}) })).toBe(false)
    expect(
      workersAvailable({
        browserScrapingWorkerAdd: async () => ({}),
        browserScrapingWorkerRemove: async () => ({}),
      }),
    ).toBe(true)
  })

  it('will not show an inbox it cannot answer', () => {
    // Listing asks with no way to refuse one leaves an agent's request sitting
    // on screen as a demand.
    expect(liftRequestsAvailable({ browserScrapingLiftRequests: async () => [] })).toBe(false)
    expect(
      liftRequestsAvailable({
        browserScrapingLiftRequests: async () => [],
        browserScrapingLiftAnswer: async () => ({}),
        onBrowserScrapingLiftRequest: () => () => {},
      }),
    ).toBe(true)
  })

  it('treats the lift itself as its own capability', () => {
    expect(liftAvailable({})).toBe(false)
    expect(liftAvailable({ browserScrapingLift: async () => ({}) })).toBe(true)
  })

  it('will not open a store that can install but not remove', () => {
    expect(
      storeAvailable({
        browserScrapingTools: async () => [],
        browserScrapingToolInstall: async () => ({}),
      }),
    ).toBe(false)
    expect(
      storeAvailable({
        browserScrapingTools: async () => [],
        browserScrapingToolInstall: async () => ({}),
        browserScrapingToolRemove: async () => ({}),
      }),
    ).toBe(true)
  })
})

describe('reading a configuration', () => {
  it('is null when there is nothing readable in it', () => {
    expect(readScrapingConfig(null)).toBeNull()
    expect(readScrapingConfig({})).toBeNull()
    expect(readScrapingConfig({ fleet: 'yes' })).toBeNull()
  })

  it('reads a group without inventing the others', () => {
    const config = readScrapingConfig({ capture: { on: true, directory: '/tmp/c', keepMB: 200 } })
    expect(config?.capture).toEqual({ on: true, directory: '/tmp/c', keepMB: 200 })
    expect(config?.requests).toBeNull()
    expect(config?.fleet).toBeNull()
  })

  it('leaves a rule unset rather than defaulting it to allow', () => {
    // A default written on this side is a claim about an engine written on the
    // other. Unset draws as nothing pressed.
    const config = readScrapingConfig({ requests: { image: 'fulfill', script: 'nonsense' } })
    expect(config?.requests?.image).toBe('fulfill')
    expect(config?.requests?.script).toBeNull()
    expect(config?.requests?.font).toBeNull()
  })

  it('reads only the three rules that exist', () => {
    expect(readRequestRule('allow')).toBe('allow')
    expect(readRequestRule('fulfill')).toBe('fulfill')
    expect(readRequestRule('Allow')).toBeNull()
  })

  it('refuses a count that is not one', () => {
    expect(readCount(12)).toBe(12)
    expect(readCount(0)).toBe(0)
    expect(readCount(-1)).toBeNull()
    expect(readCount('12')).toBeNull()
    expect(readCount(Number.NaN)).toBeNull()
    expect(readCount(Number.POSITIVE_INFINITY)).toBeNull()
  })
})

describe('reading what happened', () => {
  it('drops a worker with no profile and keeps its counts nullable', () => {
    const status = readScrapingStatus({
      workers: [{ id: 'a', state: 'busy' }, { id: 'b', profileId: 'w1', state: 'busy' }],
    })
    expect(status?.workers).toHaveLength(1)
    expect(status?.workers[0].requests).toBeNull()
  })

  it('calls an unreadable worker state stopped rather than idle', () => {
    // Idle says a worker is up and waiting. Stopped is the safe half of the
    // truth in every case where the engine's word could not be read.
    const status = readScrapingStatus({ workers: [{ profileId: 'w1', state: 'humming' }] })
    expect(status?.workers[0].state).toBe('stopped')
  })

  it('keeps an uncounted capture uncounted', () => {
    const status = readScrapingStatus({ capture: { recorded: 'lots' } })
    expect(status?.capture).toEqual({ recorded: null, bytes: null, dropped: null, droppedReason: '' })
  })

  it('has no last check when the answer names no page', () => {
    expect(readScrapingStatus({ lastCheck: { stated: 10, got: 10 } })?.lastCheck).toBeNull()
  })
})

describe('reading a request somebody has to answer', () => {
  it('drops one nothing could be wired to', () => {
    const asks = readLiftRequests([
      { id: '', fromProfileId: 'default', intoProfileIds: ['w1'] },
      { id: 'r1', fromProfileId: '', intoProfileIds: ['w1'] },
      { id: 'r2', fromProfileId: 'default', intoProfileIds: [] },
      { id: 'r3', fromProfileId: 'default', intoProfileIds: ['w1'], askedBy: 'session 4' },
    ])
    expect(asks.map((ask) => ask.id)).toEqual(['r3'])
    expect(asks[0].askedBy).toBe('session 4')
  })
})

describe('reading a store listing', () => {
  it('cannot be talked into verified by an answer it does not understand', () => {
    const [tool] = readToolListings([{ id: 't1', identity: 'probably fine' }])
    expect(tool.identity).toBe('unknown')
  })

  it('takes installed only from a literal true', () => {
    const [tool] = readToolListings([{ id: 't1', installed: 'yes' }])
    expect(tool.installed).toBe(false)
  })

  it('falls back to the id for a listing with no name, and drops one with no id', () => {
    expect(readToolListings([{ id: 't1' }])[0].name).toBe('t1')
    expect(readToolListings([{ name: 'Nameless' }])).toEqual([])
  })
})

describe('an answer that did not say it worked', () => {
  /*
   * The rule this panel exists for, enforced at the door: a tool that skipped
   * 48,473 assets and exited reporting success is what a truthy read of a reply
   * looks like from the outside. Only `true` is true here.
   */
  it('is not a success when there is no answer at all', () => {
    const outcome = readOutcome(undefined)
    expect(outcome.ok).toBe(false)
    expect(outcome.count).toBeNull()
    expect(outcome.message).toContain('nothing here is confirmed')
  })

  it('is not a success when ok is merely truthy', () => {
    expect(readOutcome({ ok: 'yes' }).ok).toBe(false)
    expect(readOutcome({ ok: 1 }).ok).toBe(false)
  })

  it('carries a measured count when there is one, and null when there is not', () => {
    expect(readOutcome({ ok: true, count: 42 }).count).toBe(42)
    expect(readOutcome({ ok: true }).count).toBeNull()
  })

  it('always has a sentence, even when the engine sent none', () => {
    expect(readOutcome({ ok: true }).message).not.toBe('')
    expect(readOutcome({ ok: false }).message).not.toBe('')
  })
})
