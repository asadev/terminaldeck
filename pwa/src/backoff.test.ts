import { describe, expect, it } from 'vitest'
import { Backoff, RECONNECT_BACKOFF, backoffDelay } from './backoff'

/** Jitter off, so the schedule itself is what is being asserted. */
const noJitter = (): number => 0

describe('reconnect backoff', () => {
  it('starts fast enough that a blip is invisible', () => {
    expect(backoffDelay(0, noJitter)).toBe(RECONNECT_BACKOFF.firstMs)
    expect(backoffDelay(0, noJitter)).toBeLessThan(1000)
  })

  it('grows by the factor', () => {
    expect(backoffDelay(1, noJitter)).toBe(720)
    expect(backoffDelay(2, noJitter)).toBe(1296)
    expect(backoffDelay(3, noJitter)).toBe(2333)
  })

  it('caps, so the app never looks broken for longer than the cap', () => {
    expect(backoffDelay(20, noJitter)).toBe(RECONNECT_BACKOFF.maxMs)
    expect(backoffDelay(200, noJitter)).toBe(RECONNECT_BACKOFF.maxMs)
  })

  it('never exceeds the cap once jitter is applied', () => {
    // Subtractive jitter is the whole reason: additive jitter would let a wait
    // run past a ceiling the UI has already promised the user.
    for (let attempt = 0; attempt < 30; attempt++) {
      expect(backoffDelay(attempt, () => 1)).toBeLessThanOrEqual(RECONNECT_BACKOFF.maxMs)
      expect(backoffDelay(attempt, Math.random)).toBeLessThanOrEqual(RECONNECT_BACKOFF.maxMs)
    }
  })

  it('spreads each delay by at most the jitter fraction', () => {
    const full = backoffDelay(5, noJitter)
    const jittered = backoffDelay(5, () => 1)
    expect(jittered).toBe(Math.round(full * (1 - RECONNECT_BACKOFF.jitter)))
    expect(jittered).toBeGreaterThan(0)
  })

  it('treats a negative or fractional attempt as the first one', () => {
    expect(backoffDelay(-3, noJitter)).toBe(RECONNECT_BACKOFF.firstMs)
    expect(backoffDelay(0.7, noJitter)).toBe(RECONNECT_BACKOFF.firstMs)
  })
})

describe('the schedule object', () => {
  it('walks the sequence and counts attempts', () => {
    const backoff = new Backoff(RECONNECT_BACKOFF, noJitter)
    expect(backoff.attempts).toBe(0)
    expect(backoff.next()).toBe(400)
    expect(backoff.next()).toBe(720)
    expect(backoff.attempts).toBe(2)
  })

  it('goes back to the top on reset', () => {
    const backoff = new Backoff(RECONNECT_BACKOFF, noJitter)
    backoff.next()
    backoff.next()
    backoff.next()
    backoff.reset()
    expect(backoff.attempts).toBe(0)
    expect(backoff.next()).toBe(400)
  })

  it('honours its own options rather than the defaults', () => {
    const backoff = new Backoff({ firstMs: 100, maxMs: 250, factor: 2, jitter: 0 }, noJitter)
    expect(backoff.next()).toBe(100)
    expect(backoff.next()).toBe(200)
    expect(backoff.next()).toBe(250)
    expect(backoff.next()).toBe(250)
  })
})
