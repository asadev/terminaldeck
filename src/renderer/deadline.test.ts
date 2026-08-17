import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { describeMs, isOverdue, Overdue, readFailure, withDeadline } from './deadline'

describe('withDeadline', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  /**
   * The whole reason this module exists. Four pages in this app printed a
   * sentence and waited on a promise that never settled, and every one of them
   * was reported as the app being stuck. A read that cannot fail is a page that
   * cannot recover.
   */
  it('rejects a read that never answers', async () => {
    const forever = new Promise<string>(() => {})
    const guarded = withDeadline(forever, 'Reading the repository', 5000)
    const caught = guarded.catch((error: unknown) => error)

    await vi.advanceTimersByTimeAsync(5000)
    const error = await caught

    expect(isOverdue(error)).toBe(true)
    expect((error as Error).message).toBe(
      'Reading the repository did not answer within 5 seconds.',
    )
  })

  it('passes the value through when the read answers in time', async () => {
    const guarded = withDeadline(Promise.resolve('ready'), 'Reading the repository', 5000)
    await vi.advanceTimersByTimeAsync(1)
    await expect(guarded).resolves.toBe('ready')
  })

  it('passes the original rejection through rather than replacing it', async () => {
    const failure = new Error('not a git repository')
    const guarded = withDeadline(Promise.reject(failure), 'Reading the repository', 5000)
    await expect(guarded).rejects.toBe(failure)
  })

  /**
   * A read that answered must not go on to reject a second later. Both halves
   * write to the same promise, and a rejection after a resolution is silent —
   * so the guard is a flag rather than a `clearTimeout` alone.
   */
  it('does not fire the deadline after the read has already answered', async () => {
    const guarded = withDeadline(Promise.resolve('ready'), 'Reading the repository', 5000)
    await expect(guarded).resolves.toBe('ready')
    await vi.advanceTimersByTimeAsync(60_000)
    await expect(guarded).resolves.toBe('ready')
  })

  it('treats a non-positive deadline as no deadline at all', async () => {
    const work = Promise.resolve('ready')
    expect(withDeadline(work, 'anything', 0)).toBe(work)
  })
})

describe('describeMs', () => {
  it('reads as a duration at every scale a deadline is set at', () => {
    expect(describeMs(800)).toBe('800 ms')
    expect(describeMs(1000)).toBe('1 second')
    expect(describeMs(1500)).toBe('1.5 seconds')
    expect(describeMs(15_000)).toBe('15 seconds')
  })
})

describe('readFailure', () => {
  /**
   * Electron names the channel in every IPC rejection. A person reading a page
   * did not ask for `artifacts:list` and the prefix is noise in a sentence they
   * are meant to act on.
   */
  it('strips the channel Electron staples onto an IPC rejection', () => {
    expect(
      readFailure(new Error("Error invoking remote method 'artifacts:list': boom")),
    ).toBe('boom')
  })

  it('keeps an overdue message exactly as it was written', () => {
    expect(readFailure(new Overdue('Reading the changes', 15_000))).toBe(
      'Reading the changes did not answer within 15 seconds.',
    )
  })

  it('survives something thrown that was never an Error', () => {
    expect(readFailure('plain string')).toBe('plain string')
  })
})
