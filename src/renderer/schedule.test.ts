import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { at, COALESCE_MS, every, pending } from './schedule'

/**
 * The scheduler's whole reason for existing is the wake-up count, so that is
 * what these count. `setTimeout` is spied on rather than inferred, because "one
 * timer for N jobs" is a claim about the host, not about the callbacks.
 */

describe('the shared tick', () => {
  const cancels: Array<() => void> = []
  const keep = (cancel: () => void): (() => void) => {
    cancels.push(cancel)
    return cancel
  }

  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    for (const cancel of cancels.splice(0)) cancel()
    vi.useRealTimers()
    expect(pending()).toBe(0)
  })

  it('registers no timer until a job asks for one', () => {
    const timers = vi.spyOn(globalThis, 'setTimeout')
    expect(pending()).toBe(0)
    expect(timers).not.toHaveBeenCalled()
    timers.mockRestore()
  })

  it('runs a periodic job on its period, repeatedly', async () => {
    const run = vi.fn()
    keep(every(1000, run))

    await vi.advanceTimersByTimeAsync(999)
    expect(run).toHaveBeenCalledTimes(0)
    await vi.advanceTimersByTimeAsync(1)
    expect(run).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(3000)
    expect(run).toHaveBeenCalledTimes(4)
  })

  it('wakes once for several jobs due at the same moment', async () => {
    const a = vi.fn()
    const b = vi.fn()
    const c = vi.fn()
    keep(every(1000, a))
    keep(every(1000, b))
    keep(every(1000, c))

    // One armed timer, not three: the count is the point of the module.
    const timers = vi.spyOn(globalThis, 'setTimeout')
    await vi.advanceTimersByTimeAsync(1000)

    expect(a).toHaveBeenCalledTimes(1)
    expect(b).toHaveBeenCalledTimes(1)
    expect(c).toHaveBeenCalledTimes(1)
    // Exactly one re-arm for the whole batch.
    expect(timers).toHaveBeenCalledTimes(1)
    timers.mockRestore()
  })

  it('folds a job that is nearly due into the same wake-up', async () => {
    const early = vi.fn()
    const late = vi.fn()
    keep(every(1000, early))
    keep(every(1000 + COALESCE_MS - 1, late))

    await vi.advanceTimersByTimeAsync(1000)
    expect(early).toHaveBeenCalledTimes(1)
    expect(late).toHaveBeenCalledTimes(1)
  })

  it('does not fold a job that is genuinely later', async () => {
    const early = vi.fn()
    const later = vi.fn()
    keep(every(1000, early))
    keep(every(5000, later))

    await vi.advanceTimersByTimeAsync(1000)
    expect(early).toHaveBeenCalledTimes(1)
    expect(later).toHaveBeenCalledTimes(0)
  })

  it('runs a one-shot once and forgets it', async () => {
    const run = vi.fn()
    at(Date.now() + 500, run)

    await vi.advanceTimersByTimeAsync(500)
    expect(run).toHaveBeenCalledTimes(1)
    expect(pending()).toBe(0)

    await vi.advanceTimersByTimeAsync(10_000)
    expect(run).toHaveBeenCalledTimes(1)
  })

  it('runs a one-shot whose moment has already passed', async () => {
    const run = vi.fn()
    at(Date.now() - 60_000, run)
    await vi.advanceTimersByTimeAsync(0)
    expect(run).toHaveBeenCalledTimes(1)
  })

  it('cancelling the last job leaves nothing armed', async () => {
    const run = vi.fn()
    const cancel = every(1000, run)
    cancel()
    expect(pending()).toBe(0)
    await vi.advanceTimersByTimeAsync(10_000)
    expect(run).not.toHaveBeenCalled()
  })

  it('cancelling one job does not disturb another', async () => {
    const kept = vi.fn()
    const dropped = vi.fn()
    keep(every(1000, kept))
    every(1000, dropped)()

    await vi.advanceTimersByTimeAsync(1000)
    expect(kept).toHaveBeenCalledTimes(1)
    expect(dropped).not.toHaveBeenCalled()
  })

  it('a job that throws does not stop the ones beside it', async () => {
    const noise = vi.spyOn(console, 'error').mockImplementation(() => {})
    const after = vi.fn()
    keep(
      every(1000, () => {
        throw new Error('bad job')
      }),
    )
    keep(every(1000, after))

    await vi.advanceTimersByTimeAsync(1000)
    expect(after).toHaveBeenCalledTimes(1)
    expect(noise).toHaveBeenCalled()
    noise.mockRestore()
  })

  it('a job may cancel itself from inside its own run', async () => {
    const run = vi.fn()
    let cancel = (): void => {}
    cancel = every(1000, () => {
      run()
      cancel()
    })

    await vi.advanceTimersByTimeAsync(5000)
    expect(run).toHaveBeenCalledTimes(1)
    expect(pending()).toBe(0)
  })

  it('a late run does not fire repeatedly to catch up', async () => {
    const run = vi.fn()
    keep(every(1000, run))

    // One advance across many periods is the shape of a window that was hidden
    // or a main thread that was blocked. The label moved once; it does not owe
    // the user ten renders of a value nobody was looking at.
    await vi.advanceTimersByTimeAsync(10_000)
    expect(run).toHaveBeenCalledTimes(10)

    const before = run.mock.calls.length
    await vi.advanceTimersByTimeAsync(500)
    expect(run.mock.calls.length).toBe(before)
  })

  it('ignores a period that is not a period', () => {
    expect(pending()).toBe(0)
    every(0, vi.fn())
    every(-1, vi.fn())
    every(Number.NaN, vi.fn())
    at(Number.NaN, vi.fn())
    expect(pending()).toBe(0)
  })
})
