import { describe, expect, it } from 'vitest'
import {
  liftAvailable,
  readInjectAnswer,
  readLift,
  readLiftAnswer,
  readPace,
  readWorkersView,
  resolveWorkersApi,
  workersAvailable,
  type WorkersApi,
} from './workers-bridge'

const FULL: Record<string, unknown> = {
  browserWorkers: () => undefined,
  browserWorkersEnsure: () => undefined,
  browserWorkerRegister: () => undefined,
  browserWorkerUnregister: () => undefined,
  browserWorkerPace: () => undefined,
  browserWorkerLift: () => undefined,
  browserWorkerInject: () => undefined,
  browserWorkerForgetLift: () => undefined,
}

describe('what this build can actually do', () => {
  it('takes only the methods the preload really has', () => {
    // Method by method rather than handed over whole, so a preload older than
    // this feature contributes what it has and the panel is simply not offered.
    const api = resolveWorkersApi({ browserWorkers: () => undefined, browserWorkersEnsure: 4 })
    expect(typeof api.browserWorkers).toBe('function')
    expect(api.browserWorkersEnsure).toBeUndefined()
    expect(resolveWorkersApi(null)).toEqual({})
  })

  it('is all-or-nothing for the panel, and separately so for the lift', () => {
    /*
     * A panel that can list workers but not make one is a screen that cannot
     * act — the single most repeated complaint in the review this feature comes
     * from. The lift is checked apart from it because a build with workers and
     * no lift is still a useful panel: it just draws no Lift button, rather than
     * drawing one that resolves to nothing.
     */
    expect(workersAvailable(resolveWorkersApi(FULL))).toBe(true)
    const half: WorkersApi = resolveWorkersApi({ browserWorkers: FULL.browserWorkers })
    expect(workersAvailable(half)).toBe(false)
    expect(liftAvailable(half)).toBe(false)
    expect(liftAvailable(resolveWorkersApi({ browserWorkerLift: () => undefined }))).toBe(false)
    expect(liftAvailable(resolveWorkersApi(FULL))).toBe(true)
  })
})

describe('reading what the main process sent', () => {
  it('drops a worker row with no id, because nothing could be done to it', () => {
    const view = readWorkersView({ workers: [{ name: 'Ghost' }, { profileId: 'w1', name: 'Worker 1' }] })
    expect(view?.workers.map((row) => row.name)).toEqual(['Worker 1'])
  })

  it('answers null for a shape it cannot use, rather than half a screen', () => {
    expect(readWorkersView(null)).toBeNull()
    expect(readWorkersView({ pace: {} })).toBeNull()
  })

  it('reads a pace with holes in it into numbers', () => {
    expect(readPace({ maxConcurrent: 3 })).toEqual({ maxConcurrent: 3, minDelayMs: 0, jitterMs: 0 })
    expect(readPace('nonsense')).toEqual({ maxConcurrent: 0, minDelayMs: 0, jitterMs: 0 })
  })

  it('turns an ok with nothing usable in it into an honest failure', () => {
    /*
     * Drawing a blank success is worse than saying so. `ok: true` with no
     * summary is a state only a mismatched build produces, and the panel has to
     * put something on the screen either way.
     */
    expect(readLiftAnswer({ ok: true }).ok).toBe(false)
    expect(readLiftAnswer(null).ok).toBe(false)
    expect(readLiftAnswer({ ok: false, reason: 'no' })).toEqual({ ok: false, reason: 'no' })
    expect(readLiftAnswer({ ok: false }).ok).toBe(false)
  })

  it('reads a real lift, names and all, and never expects a value', () => {
    const lift = readLift({
      id: 'l1',
      host: 'shop.example.com',
      sourceProfileName: 'Main',
      cookieCount: 2,
      cookieNames: ['sessionid', 4, 'cf_clearance'],
      localKeys: 1,
    })
    expect(lift?.cookieNames).toEqual(['sessionid', 'cf_clearance'])
    expect(lift?.localKeys).toBe(1)
    expect(readLift({ host: 'x' })).toBeNull()
  })

  it('reads an injection report per worker', () => {
    const answer = readInjectAnswer({
      ok: true,
      line: 'done',
      reports: [{ profileId: 'w1', name: 'Worker 1', cookiesSet: 2, storageQueued: 1 }, 'junk'],
    })
    expect(answer.ok && answer.reports).toHaveLength(1)
    expect(readInjectAnswer({ ok: false }).ok).toBe(false)
  })
})
