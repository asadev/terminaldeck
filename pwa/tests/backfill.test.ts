/**
 * The phone client holds a session's replay off the screen — using the
 * desktop's module, not a copy of it.
 *
 * ## Why this test exists at all
 *
 * `main.ts` imports `holdUntilFilled` from `src/renderer/components/`, which is
 * a **directory this client does not own**. That import is deliberate: the
 * policy is subtle (xterm yields to the renderer every 12 ms while a large write
 * drains, so every intermediate scroll position is painted), it was worked out
 * once on the desktop, and a second copy here is how one of the two surfaces
 * ends up fixed and the other does not — which is precisely the review item this
 * came from: *"app mobile app is also doing the same thing… make sure this is
 * also aligned and fixed."*
 *
 * The price of borrowing a module is that somebody moving it breaks a client
 * they were not thinking about. Nothing else in this suite would notice: vitest
 * does not build the browser bundle, so the failure would surface at
 * `vite build` on a deploy, or — worse — as a phone that quietly went back to
 * scrolling through history. This test is the tripwire. It is also the only
 * assertion anywhere that the *phone's* terminal is covered by that policy.
 *
 * It pins behaviour rather than shape. A module that still exports the name but
 * no longer hides the surface would pass a smoke test and fail here.
 */

import { describe, expect, it, vi } from 'vitest'
import { holdUntilFilled, HOLD_LIMIT_MS, QUIET_MS } from '../../src/renderer/components/terminal-backfill'

/** The two structural types the module wants, with a log of what was done to them. */
function surface() {
  const written: string[] = []
  let scrolled = 0
  const style = { opacity: '' }
  const term = {
    write(data: string, done?: () => void) {
      written.push(data)
      // The real one calls back when xterm has *parsed* the write. Synchronous
      // here, because what is being tested is the ordering rather than the wait.
      done?.()
    },
    scrollToBottom() {
      scrolled += 1
    },
  }
  return { term, host: { style }, written, style, scrolls: () => scrolled }
}

describe('the phone client borrows the desktop backfill', () => {
  it('hides the surface, holds the backlog, and reveals it once at the bottom', () => {
    vi.useFakeTimers()
    const screen = surface()
    const hold = holdUntilFilled(screen.term, screen.host, { quiet: QUIET_MS })

    expect(screen.style.opacity).toBe('0')

    hold.push('one')
    hold.push('two')
    expect(screen.written).toEqual([])

    // Silence is what says a far machine has finished replaying: there is no
    // end-of-replay marker on the wire.
    vi.advanceTimersByTime(QUIET_MS)

    expect(screen.written).toEqual(['onetwo'])
    expect(screen.scrolls()).toBe(1)
    expect(screen.style.opacity).toBe('')
    vi.useRealTimers()
  })

  it('writes what was held before the live frame that ended the hold', () => {
    vi.useFakeTimers()
    const screen = surface()
    const hold = holdUntilFilled(screen.term, screen.host, { quiet: QUIET_MS })

    hold.push('history')
    // `main.ts` releases on the first frame that is not a replay, then pushes
    // it — so the older bytes cannot land after the newer ones.
    hold.release()
    hold.push('$ now')

    expect(screen.written).toEqual(['history', '$ now'])
    expect(screen.style.opacity).toBe('')
    vi.useRealTimers()
  })

  it('can only ever delay a terminal, never hide one', () => {
    vi.useFakeTimers()
    const screen = surface()
    const hold = holdUntilFilled(screen.term, screen.host, { quiet: QUIET_MS })

    hold.push('half a backlog')
    // Nothing else ever arrives — a machine that stopped mid-replay, a socket
    // that went quiet without closing. The ceiling is the promise.
    vi.advanceTimersByTime(HOLD_LIMIT_MS)

    expect(screen.style.opacity).toBe('')
    expect(screen.written).toEqual(['half a backlog'])
    vi.useRealTimers()
  })
})
