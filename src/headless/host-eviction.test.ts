import { describe, expect, it } from 'vitest'
import {
  cmdlineIsOurHost,
  evictStaleHost,
  type EvictionDeps,
} from './host-eviction'

/**
 * A fake host whose liveness the test drives. It counts `alive` polls after each
 * signal and dies once the configured number of polls has passed, so a whole
 * SIGTERM→wait→SIGKILL sequence runs without a real second elapsing.
 */
function fakeHost(opts: {
  ours?: boolean
  deadAtStart?: boolean
  diesOnTermAfter?: number | null
  diesOnKillAfter?: number | null
}): { deps: EvictionDeps; signals: NodeJS.Signals[] } {
  const signals: NodeJS.Signals[] = []
  let dead = opts.deadAtStart ?? false
  let termPolls = -1
  let killPolls = -1
  const deps: EvictionDeps = {
    alive: () => {
      if (dead) return false
      if (killPolls >= 0) {
        if (opts.diesOnKillAfter != null && killPolls >= opts.diesOnKillAfter) {
          dead = true
          return false
        }
        killPolls++
      } else if (termPolls >= 0) {
        if (opts.diesOnTermAfter != null && termPolls >= opts.diesOnTermAfter) {
          dead = true
          return false
        }
        termPolls++
      }
      return true
    },
    isOurHost: () => opts.ours ?? true,
    signal: (_pid, sig) => {
      signals.push(sig)
      if (sig === 'SIGTERM') termPolls = 0
      if (sig === 'SIGKILL') killPolls = 0
    },
    wait: async () => {
      /* no real delay */
    },
  }
  return { deps, signals }
}

describe('evictStaleHost', () => {
  it('does nothing when the pid is already gone', async () => {
    const { deps, signals } = fakeHost({ deadAtStart: true })
    expect(await evictStaleHost(4242, deps)).toBe('gone')
    expect(signals).toEqual([])
  })

  it('never signals a live pid that is not one of our hosts (a reused number)', async () => {
    const { deps, signals } = fakeHost({ ours: false })
    expect(await evictStaleHost(4242, deps)).toBe('not-ours')
    expect(signals).toEqual([])
  })

  it('takes over with SIGTERM alone when the host leaves politely', async () => {
    const { deps, signals } = fakeHost({ diesOnTermAfter: 2 })
    expect(await evictStaleHost(4242, deps)).toBe('terminated')
    expect(signals).toEqual(['SIGTERM'])
  })

  it('escalates to SIGKILL when SIGTERM is ignored', async () => {
    const { deps, signals } = fakeHost({ diesOnTermAfter: null, diesOnKillAfter: 1 })
    expect(await evictStaleHost(4242, deps)).toBe('killed')
    expect(signals).toEqual(['SIGTERM', 'SIGKILL'])
  })

  it('reports stuck when the host survives even SIGKILL', async () => {
    const { deps, signals } = fakeHost({ diesOnTermAfter: null, diesOnKillAfter: null })
    expect(await evictStaleHost(4242, deps)).toBe('stuck')
    expect(signals).toEqual(['SIGTERM', 'SIGKILL'])
  })

  it('swallows a signal that races the process to exit', async () => {
    let dead = false
    const deps: EvictionDeps = {
      alive: () => !dead,
      isOurHost: () => true,
      signal: () => {
        // The process exited between the alive check and the signal.
        dead = true
        const err = new Error('no such process') as NodeJS.ErrnoException
        err.code = 'ESRCH'
        throw err
      },
      wait: async () => {},
    }
    expect(await evictStaleHost(4242, deps)).toBe('terminated')
  })
})

describe('cmdlineIsOurHost', () => {
  it('is false for a pid that cannot be read', () => {
    // A pid far above any real one: /proc has no entry, so it cannot be ours.
    expect(cmdlineIsOurHost(2_000_000_000)).toBe(false)
  })
})
