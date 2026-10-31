import { describe, expect, it } from 'vitest'
import {
  cleanPace,
  createWorkerPool,
  DEFAULT_HOLD_MS,
  jitteredDelay,
  leaseRefusalLine,
  MAX_PACE_MS,
  MAX_WORKERS,
  paceNote,
  type PaceSettings,
  type PoolWorker,
} from './browser-worker-pool'

/**
 * A fake clock, because the alternative is a test that sleeps.
 *
 * The rule this whole file exists to pin is *the delay is real*, and the only
 * honest way to assert that without waiting is to lie to the code about the
 * time. Nothing here spins a CPU: a previous agent in this workspace "tested"
 * timing with `while :; do :; done` and took the machine's load average to 836,
 * which is the reason `now` and `random` are arguments in the first place.
 */
function harness(
  workers: PoolWorker[],
  pace: Partial<PaceSettings> = {},
  random = 0,
) {
  let clock = 1_000_000
  const settings = cleanPace({ maxConcurrent: 8, minDelayMs: 0, jitterMs: 0, ...pace })
  const changes: number[] = []
  const pool = createWorkerPool({
    workers: () => workers,
    pace: () => settings,
    now: () => clock,
    random: () => random,
    changed: () => changes.push(clock),
  })
  return {
    pool,
    settings,
    changes,
    tick: (ms: number) => {
      clock += ms
    },
    at: () => clock,
  }
}

const THREE: PoolWorker[] = [
  { profileId: 'a', name: 'Worker 1' },
  { profileId: 'b', name: 'Worker 2' },
  { profileId: 'c', name: 'Worker 3' },
]

describe('the pace a person types', () => {
  it('is clamped rather than refused, and the sum can never break a tool call', () => {
    /*
     * The ceiling is not decoration. A lease is handed out by a tool call that
     * awaits the wait, and an MCP client gives a call sixty seconds — so a pace
     * above the ceiling would turn a correct delay into a timeout, which reads
     * to a model as a broken tool worth retrying immediately.
     */
    const pace = cleanPace({ maxConcurrent: 999, minDelayMs: 60_000, jitterMs: 60_000 })
    expect(pace.maxConcurrent).toBe(MAX_WORKERS)
    expect(pace.minDelayMs).toBe(MAX_PACE_MS)
    expect(pace.minDelayMs + pace.jitterMs).toBeLessThanOrEqual(MAX_PACE_MS)
  })

  it('never lets the jitter push the sum past the ceiling', () => {
    const pace = cleanPace({ minDelayMs: 25_000, jitterMs: 25_000 })
    expect(pace.minDelayMs).toBe(25_000)
    expect(pace.jitterMs).toBe(MAX_PACE_MS - 25_000)
  })

  it('falls back rather than storing NaN', () => {
    const pace = cleanPace({ maxConcurrent: 'lots', minDelayMs: null, jitterMs: undefined })
    expect(Number.isFinite(pace.maxConcurrent)).toBe(true)
    expect(Number.isFinite(pace.minDelayMs)).toBe(true)
    expect(Number.isFinite(pace.jitterMs)).toBe(true)
  })

  it('says so when the stored number is not the one that was typed', () => {
    // A field that stores a different number from the one it shows is a control
    // that lies quietly, which is the whole complaint this round is about.
    const typed = { maxConcurrent: 999, minDelayMs: 1_000, jitterMs: 0 }
    expect(paceNote(typed, cleanPace(typed))).toContain('at most')
    const honest = { maxConcurrent: 2, minDelayMs: 1_000, jitterMs: 0 }
    expect(paceNote(honest, cleanPace(honest))).toBe('')
  })
})

describe('the wait between one worker’s turns', () => {
  it('is the floor at the bottom of the jitter and the floor plus it at the top', () => {
    const pace = cleanPace({ minDelayMs: 1_000, jitterMs: 500 })
    expect(jitteredDelay(pace, 0)).toBe(1_000)
    expect(jitteredDelay(pace, 1)).toBe(1_500)
  })

  it('is zero the first time a worker is used, and served every time after', () => {
    // The first request has nothing to be polite *after*. Making the caller wait
    // before it has done anything is a delay that buys nothing and reads, from
    // the outside, exactly like a slow app.
    const { pool, tick } = harness(THREE, { minDelayMs: 2_000 })
    const first = pool.lease({ holder: 'h' })
    expect(first.ok && first.waitMs).toBe(0)
    if (!first.ok) throw new Error('unreachable')
    pool.release({ holder: 'h', profileId: first.lease.profileId })

    tick(500)
    const again = pool.lease({ holder: 'h', profileId: first.lease.profileId })
    // 2000 owed, 500 already elapsed.
    expect(again.ok && again.waitMs).toBe(1_500)
  })

  it('is per worker, so a pool of three is not one slow worker', () => {
    /*
     * The whole point of N workers. A *global* gate would make eight profiles
     * behave like one, which is the shape the pipeline already had and the
     * reason it took as long as it did.
     */
    const { pool, tick } = harness(THREE, { minDelayMs: 5_000 })
    const a = pool.lease({ holder: 'h', profileId: 'a' })
    expect(a.ok).toBe(true)
    if (!a.ok) throw new Error('unreachable')
    pool.release({ holder: 'h', profileId: 'a' })
    tick(10)
    const b = pool.lease({ holder: 'h', profileId: 'b' })
    expect(b.ok && b.waitMs).toBe(0)
  })
})

describe('taking a worker', () => {
  it('refuses at the concurrency limit with a different sentence from all-busy', () => {
    /*
     * "Raise the limit" and "wait for one to finish" are different actions, and
     * a caller told the wrong one either spins or edits a setting that was not
     * the problem. Collapsing the two refusals is the more compact code and the
     * worse answer.
     */
    const { pool, settings } = harness(THREE, { maxConcurrent: 2 })
    expect(pool.lease({ holder: 'h' }).ok).toBe(true)
    expect(pool.lease({ holder: 'h' }).ok).toBe(true)
    const third = pool.lease({ holder: 'h' })
    expect(third.ok).toBe(false)
    if (third.ok) throw new Error('unreachable')
    expect(third.reason).toBe('at-capacity')
    expect(leaseRefusalLine(third.reason, settings)).toContain('limit')

    const all = harness(THREE, { maxConcurrent: 8 })
    all.pool.lease({ holder: 'h' })
    all.pool.lease({ holder: 'h' })
    all.pool.lease({ holder: 'h' })
    const none = all.pool.lease({ holder: 'h' })
    expect(none.ok).toBe(false)
    if (none.ok) throw new Error('unreachable')
    expect(none.reason).toBe('all-busy')
  })

  it('says there are none, rather than saying they are all busy, when there are none', () => {
    const { pool } = harness([])
    const answer = pool.lease({ holder: 'h' })
    expect(answer.ok).toBe(false)
    if (answer.ok) throw new Error('unreachable')
    expect(answer.reason).toBe('no-workers')
    expect(leaseRefusalLine(answer.reason, cleanPace({}))).toContain('Workers')
  })

  it('hands out the one that has been idle longest, not the first free one', () => {
    /*
     * Round-robin is the reason a pool beats a profile. Taking the
     * lowest-numbered free worker every time means worker 1 does most of the
     * traffic and the rest stay cold, which is both slower and a more
     * recognisable pattern than spreading it.
     */
    const { pool, tick } = harness(THREE)
    for (const id of ['a', 'b', 'c']) {
      pool.lease({ holder: 'h', profileId: id })
      tick(10)
      pool.release({ holder: 'h', profileId: id })
    }
    // `a` was let go first, so `a` has been idle longest.
    const next = pool.lease({ holder: 'h' })
    expect(next.ok && next.lease.profileId).toBe('a')
  })

  it('refuses a named worker somebody else has, without pretending it is missing', () => {
    const { pool } = harness(THREE)
    pool.lease({ holder: 'one', profileId: 'a' })
    const answer = pool.lease({ holder: 'two', profileId: 'a' })
    expect(answer.ok).toBe(false)
    if (answer.ok) throw new Error('unreachable')
    expect(answer.reason).toBe('busy')
    expect(pool.lease({ holder: 'two', profileId: 'nope' })).toEqual({
      ok: false,
      reason: 'unknown-worker',
    })
  })
})

describe('letting one go', () => {
  it('is refused for a holder that is not the one holding it', () => {
    /*
     * The check that makes a pool shared between several agents safe. Without
     * it, agent B releasing `Worker 3` frees a worker agent A is mid-page on,
     * and the two then drive the same cookie jar.
     */
    const { pool } = harness(THREE)
    pool.lease({ holder: 'one', profileId: 'a' })
    expect(pool.release({ holder: 'two', profileId: 'a' })).toBe(false)
    expect(pool.outstanding()).toBe(1)
    expect(pool.release({ holder: 'one', profileId: 'a' })).toBe(true)
    expect(pool.outstanding()).toBe(0)
  })

  it('happens on its own when the holder stops renewing', () => {
    // An agent can stop existing between one tool call and the next. A lease
    // that only ended on release would be a worker busy forever after one crash.
    const { pool, tick } = harness(THREE)
    pool.lease({ holder: 'gone', profileId: 'a', holdMs: 5_000 })
    tick(4_999)
    expect(pool.outstanding()).toBe(1)
    tick(2)
    expect(pool.outstanding()).toBe(0)
    expect(pool.status().find((row) => row.profileId === 'a')?.busy).toBe(false)
  })

  it('is pushed back by a renew, and only by the holder', () => {
    const { pool, tick } = harness(THREE)
    pool.lease({ holder: 'one', profileId: 'a', holdMs: 5_000 })
    tick(4_000)
    expect(pool.renew({ holder: 'two', profileId: 'a' })).toBe(false)
    expect(pool.renew({ holder: 'one', profileId: 'a', holdMs: 5_000 })).toBe(true)
    tick(4_000)
    expect(pool.outstanding()).toBe(1)
  })

  it('lets a whole holder go at once, for a session that ended', () => {
    const { pool } = harness(THREE)
    pool.lease({ holder: 'one', profileId: 'a' })
    pool.lease({ holder: 'one', profileId: 'b' })
    pool.lease({ holder: 'two', profileId: 'c' })
    expect(pool.releaseAll('one')).toBe(2)
    expect(pool.outstanding()).toBe(1)
  })
})

describe('a worker that leaves the pool', () => {
  it('takes its lease with it, rather than leaving one nothing can see', () => {
    /*
     * The fault this exists to stop: a lease on a worker that no longer appears
     * in `status()` is invisible **and still counts against `maxConcurrent`**.
     * A limit that silently shrinks by one every time a row is removed gets
     * diagnosed as "the app is slow" months later.
     */
    const workers = [...THREE]
    let clock = 0
    const pool = createWorkerPool({
      workers: () => workers,
      pace: () => cleanPace({ maxConcurrent: 3 }),
      now: () => clock,
      random: () => 0,
    })
    pool.lease({ holder: 'one', profileId: 'a' })
    expect(pool.outstanding()).toBe(1)
    workers.splice(0, 1)
    expect(pool.status().some((row) => row.profileId === 'a')).toBe(false)
    expect(pool.outstanding()).toBe(1)
    pool.forget('a')
    expect(pool.outstanding()).toBe(0)
    clock += 1
  })
})

describe('what a screen is told', () => {
  it('names the holder and how long they have had it', () => {
    const { pool, tick } = harness(THREE)
    pool.lease({ holder: 'session:x', profileId: 'b', holdMs: DEFAULT_HOLD_MS })
    tick(3_000)
    const row = pool.status().find((one) => one.profileId === 'b')
    expect(row?.busy).toBe(true)
    expect(row?.holder).toBe('session:x')
    expect(row?.heldMs).toBe(3_000)
  })

  it('shows a steady number for the wait rather than a fresh jitter each read', () => {
    // A number that changed every time it was read would be unreadable. The
    // jitter is added at the moment a lease is granted, not when it is drawn.
    const { pool, tick } = harness(THREE, { minDelayMs: 4_000, jitterMs: 4_000 }, 1)
    pool.lease({ holder: 'h', profileId: 'a' })
    pool.release({ holder: 'h', profileId: 'a' })
    tick(1_000)
    const first = pool.status().find((one) => one.profileId === 'a')?.readyInMs
    const second = pool.status().find((one) => one.profileId === 'a')?.readyInMs
    expect(first).toBe(3_000)
    expect(second).toBe(3_000)
  })
})

describe('saying so when something changed', () => {
  /*
   * The panel's fleet line read "4 workers · busy not measured" on a build where
   * this pool knew exactly which of them were busy — because nothing in the
   * process emitted an event and the panel refuses to print a number it has not
   * been told. This is that event.
   */
  it('announces a lease taken and a lease let go', () => {
    const { pool, changes } = harness(THREE)
    pool.lease({ holder: 'a-session' })
    expect(changes).toHaveLength(1)
    pool.release({ holder: 'a-session', profileId: 'a' })
    expect(changes).toHaveLength(2)
  })

  it('says nothing about a refusal, a renewal, or a release by the wrong holder', () => {
    const { pool, changes } = harness(THREE, { maxConcurrent: 1 })
    pool.lease({ holder: 'first' })
    changes.length = 0
    // Refused: nothing changed, so nothing is announced.
    expect(pool.lease({ holder: 'second' }).ok).toBe(false)
    // A renewal moves a deadline and no worker's state.
    expect(pool.renew({ holder: 'first', profileId: 'a' })).toBe(true)
    // And a release from somebody who is not holding it does nothing at all.
    expect(pool.release({ holder: 'second', profileId: 'a' })).toBe(false)
    expect(changes).toEqual([])
  })

  it('never announces from status, which is what would re-enter the reader', () => {
    const { pool, changes, tick } = harness(THREE)
    pool.lease({ holder: 'a-session', holdMs: 1_000 })
    changes.length = 0
    tick(2_000)
    // The lease has expired and `status()` sweeps it — but a sweep noticed while
    // somebody is building an answer is already in the answer they are reading,
    // and announcing it would re-enter whatever asked.
    expect(pool.status()[0].busy).toBe(false)
    expect(changes).toEqual([])
  })

  it('announces a worker leaving the pool while it is held', () => {
    const { pool, changes } = harness(THREE)
    pool.lease({ holder: 'a-session', profileId: 'b' })
    changes.length = 0
    pool.forget('b')
    expect(changes).toHaveLength(1)
    // …and nothing at all for a worker the pool never had a fact about.
    pool.forget('nobody')
    expect(changes).toHaveLength(1)
  })
})
