import { describe, expect, it } from 'vitest'
import type { HubClock } from '../deck-control/notify-hub'
import { MAX_WAIT_MS, TaskClock } from './task-clock'

/**
 * The task clock with a fake clock: no real timer runs. It must wait for
 * exactly the next due moment, set no timer at all when nothing is due, aim
 * again when told something changed, catch up at once when the Mac wakes, and
 * reach a far moment in steps.
 */

function rig(due: { at: number | null }) {
  let time = 1_000_000
  const timers: Array<{ at: number; run: () => void; id: number }> = []
  let ids = 0
  const clock: HubClock = {
    now: () => time,
    setTimeout: (run, ms) => {
      const id = ++ids
      timers.push({ at: time + ms, run, id })
      return id
    },
    clearTimeout: (handle) => {
      const i = timers.findIndex((t) => t.id === handle)
      if (i >= 0) timers.splice(i, 1)
    },
  }
  const runs: number[] = []
  const taskClock = new TaskClock({
    clock,
    nextDueAt: () => due.at,
    runDue: async () => {
      runs.push(time)
      due.at = null
    },
  })
  /** Move the clock on, firing every timer that comes due, and let their runs finish. */
  const advance = async (ms: number): Promise<void> => {
    const until = time + ms
    for (;;) {
      timers.sort((a, b) => a.at - b.at)
      const next = timers[0]
      if (next === undefined || next.at > until) break
      timers.shift()
      time = next.at
      next.run()
      await new Promise((resolve) => setImmediate(resolve))
    }
    time = until
  }
  const settle = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))
  return { taskClock, timers, runs, advance, settle, now: () => time, set: (t: number) => void (time = t) }
}

describe('the task clock', () => {
  it('sets no timer when nothing is due, and one for exactly the next moment when something is', async () => {
    const due: { at: number | null } = { at: null }
    const r = rig(due)
    r.taskClock.start()
    await r.settle()
    expect(r.timers).toEqual([])
    due.at = r.now() + 90_000
    r.taskClock.poke()
    expect(r.timers.map((t) => t.at - r.now())).toEqual([90_000])
    await r.advance(89_999)
    expect(r.runs).toEqual([])
    await r.advance(1)
    expect(r.runs).toHaveLength(1)
    // Done, and nothing else due: no timer left behind.
    expect(r.timers).toEqual([])
  })

  it('a far moment is reached in steps of at most an hour, and only run when it has come', async () => {
    const due: { at: number | null } = { at: null }
    const r = rig(due)
    due.at = r.now() + 5 * MAX_WAIT_MS + 1_000
    r.taskClock.start()
    await r.settle()
    expect(r.timers.map((t) => t.at - r.now())).toEqual([MAX_WAIT_MS])
    await r.advance(5 * MAX_WAIT_MS)
    expect(r.runs).toEqual([])
    expect(r.timers).toHaveLength(1)
    await r.advance(1_000)
    expect(r.runs).toHaveLength(1)
  })

  it('a wake runs what came due while asleep at once, and a stopped clock does nothing', async () => {
    const due: { at: number | null } = { at: null }
    const r = rig(due)
    r.taskClock.start()
    due.at = r.now() + 3_600_000
    r.taskClock.poke()
    // The Mac slept through it: no timer fired, but the wall clock moved on.
    r.set(r.now() + 8 * 3_600_000)
    r.taskClock.wake()
    await r.settle()
    expect(r.runs).toHaveLength(1)

    r.taskClock.stop()
    due.at = r.now() + 1_000
    r.taskClock.poke()
    r.taskClock.wake()
    await r.advance(10_000)
    expect(r.runs).toHaveLength(1)
    expect(r.timers).toEqual([])
  })

  it('one run at a time: a wake during a run waits for it, and the run aims again when it ends', async () => {
    const due: { at: number | null } = { at: 0 }
    let release: () => void = () => undefined
    let started = 0
    const time = 5_000
    const timers: Array<() => void> = []
    const taskClock = new TaskClock({
      clock: { now: () => time, setTimeout: (run) => (timers.push(run), timers.length), clearTimeout: () => undefined },
      nextDueAt: () => due.at,
      runDue: () => {
        started += 1
        return new Promise<void>((resolve) => {
          release = () => {
            due.at = null
            resolve()
          }
        })
      },
    })
    taskClock.start()
    await new Promise((resolve) => setImmediate(resolve))
    taskClock.wake()
    taskClock.poke()
    expect(started).toBe(1)
    release()
    await new Promise((resolve) => setImmediate(resolve))
    expect(started).toBe(1)
    expect(timers).toEqual([])
  })
})
