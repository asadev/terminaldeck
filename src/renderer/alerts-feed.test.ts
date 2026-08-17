import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  BLOCKED_CRITICAL_MS,
  BLOCKED_WARNING_MS,
  createScanGate,
  MIN_SCAN_GAP_MS,
  nextBlockedDeadline,
  scanDelayMs,
} from './alerts-feed'

const SRC = join(__dirname, '..')
const read = (rel: string): string => readFileSync(join(SRC, rel), 'utf8')

const NOW = Date.parse('2026-08-17T09:00:00.000Z')

describe('createScanGate', () => {
  it('lets the newest scan write and silences the one it superseded', () => {
    // Regression: switching project started a second scan while the first was
    // still in flight, and whichever finished last won. A slow project handed
    // its alerts to a different project's panel — naming sessions that were no
    // longer in front of the user.
    const gate = createScanGate()
    const first = gate.begin()
    const second = gate.begin()

    expect(gate.isCurrent(first)).toBe(false)
    expect(gate.isCurrent(second)).toBe(true)

    // The stale one finishing last must still lose.
    gate.end()
    expect(gate.isCurrent(first)).toBe(false)
  })

  it('reports busy until every scan has finished, so refreshes cannot stack', () => {
    // Each scan reads every transcript in the project, so two in flight is not
    // merely untidy.
    const gate = createScanGate()
    expect(gate.isBusy()).toBe(false)

    gate.begin()
    expect(gate.isBusy()).toBe(true)

    gate.begin()
    gate.end()
    // One of the two is still running.
    expect(gate.isBusy()).toBe(true)

    gate.end()
    expect(gate.isBusy()).toBe(false)
  })

  it('never lets a completed scan write after an unmount', () => {
    const gate = createScanGate()
    const token = gate.begin()
    gate.invalidate()
    expect(gate.isCurrent(token)).toBe(false)
  })

  it('does not go negative when end is called more than begin', () => {
    const gate = createScanGate()
    gate.end()
    gate.end()
    expect(gate.isBusy()).toBe(false)
    gate.begin()
    expect(gate.isBusy()).toBe(true)
  })
})

describe('scanDelayMs', () => {
  it('does not make the first look at a project wait', () => {
    expect(scanDelayMs(null, NOW)).toBe(0)
  })

  it('coalesces a burst into one scan at the end of the floor', () => {
    // Five agents finishing a turn within a second of each other is one scan,
    // not five, and it runs when the burst has settled rather than on its first
    // frame.
    expect(scanDelayMs(NOW, NOW + 1_000)).toBe(MIN_SCAN_GAP_MS - 1_000)
    expect(scanDelayMs(NOW, NOW + 1_500)).toBe(MIN_SCAN_GAP_MS - 1_500)
  })

  it('is due again once the floor has passed', () => {
    expect(scanDelayMs(NOW, NOW + MIN_SCAN_GAP_MS)).toBe(0)
    expect(scanDelayMs(NOW, NOW + MIN_SCAN_GAP_MS + 1)).toBe(0)
  })

  it('treats a clock that went backwards as due rather than parking the feed', () => {
    // An NTP step or a manual change would otherwise silence the bell for up to
    // a whole gap, with nothing on screen to say why.
    expect(scanDelayMs(NOW, NOW - 60_000)).toBe(0)
  })
})

describe('nextBlockedDeadline', () => {
  it('has nothing to wake for when nothing is blocked', () => {
    expect(nextBlockedDeadline([], NOW)).toBeNull()
  })

  it('arms the warning threshold first, then the critical one', () => {
    const since = NOW
    expect(nextBlockedDeadline([since], NOW)).toBe(since + BLOCKED_WARNING_MS)
    // Standing where the first wake-up ran, the next one is the escalation.
    const afterWarning = since + BLOCKED_WARNING_MS
    expect(nextBlockedDeadline([since], afterWarning)).toBe(since + BLOCKED_CRITICAL_MS)
  })

  it('stops arming once a session has crossed both thresholds', () => {
    const since = NOW
    expect(nextBlockedDeadline([since], since + BLOCKED_CRITICAL_MS)).toBeNull()
  })

  it('gives a session that blocked later its own wake-up', () => {
    // The failure without this: an agent blocks at 09:00, another at 09:20, and
    // the second one's ten-minute alert never gets a wake-up because the first
    // one's deadlines are all in the past.
    const first = NOW
    const second = NOW + 20 * 60 * 1000
    expect(nextBlockedDeadline([first, second], NOW + 12 * 60 * 1000)).toBe(
      second + BLOCKED_WARNING_MS,
    )
  })
})

/**
 * The two constants are copies of main-process ones, because the renderer
 * tsconfig does not include `src/main` and there is no import to write. A copy
 * can drift, and the drift is silent — a wake-up armed for a threshold that
 * moved means the bell lights minutes late with nothing on screen looking
 * wrong. So the source of truth is read and compared.
 */
describe('the blocked thresholds still match src/main/alerts.ts', () => {
  const main = read('main/alerts.ts')

  const constant = (name: string): number => {
    const match = main.match(new RegExp(`export const ${name} = ([^\\n]+)`))
    if (!match) throw new Error(`${name} is no longer declared in src/main/alerts.ts`)
    // The declarations are arithmetic on literals (`10 * 60 * 1000`), which is
    // the readable form and the reason this cannot be a string compare.
    return Number(new Function(`return (${match[1]})`)())
  }

  it('warning', () => {
    expect(BLOCKED_WARNING_MS).toBe(constant('BLOCKED_WARNING_MS'))
  })

  it('critical', () => {
    expect(BLOCKED_CRITICAL_MS).toBe(constant('BLOCKED_CRITICAL_MS'))
  })
})

/**
 * The design decision this file exists to hold, asserted against the source.
 *
 * The bell's count was left unwired because the only thing that knew the number
 * was a scan of every transcript in the project, and running that on a timer
 * was a cost the window would not pay. This feed is the answer, and it is only
 * an answer while it stays event-driven — an `every(` or a `setInterval` here
 * would quietly reinstate exactly what was refused.
 */
describe('the feed keeps no clock of its own', () => {
  const source = read('renderer/alerts-feed.ts')
  /**
   * Prose stripped before the check. This file argues about `useEvery` and
   * about timers at length, and a rule that fired on the argument for a
   * decision as though it were the decision would have to be weakened until it
   * caught nothing.
   */
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')

  it('subscribes rather than polls', () => {
    expect(code).not.toMatch(/\bsetInterval\(/)
    expect(code).not.toMatch(/\bevery\(/)
  })

  it('drives itself from session events', () => {
    expect(source).toContain('onSessionStatus')
    expect(source).toContain('onSessionCreated')
    expect(source).toContain('onSessionExit')
  })

  it('costs no more than the panel it replaced', () => {
    // The panel polled itself every 60s while it was open. This feed is always
    // on, so a shorter floor would mean spending more to show less — measured
    // at two scans a minute, indefinitely, with a 30s floor and eleven live
    // sessions.
    expect(MIN_SCAN_GAP_MS).toBeGreaterThanOrEqual(60_000)
  })

  it('lets the blocked deadline past the floor, since that one is the clock', () => {
    // The floor exists to cap cost on a busy machine. Applying it to the
    // deadline wake-up would round the only genuinely time-critical alert up to
    // the next minute — and it is the alert the floor is least entitled to
    // delay, because nothing else in the report is late by design.
    const deadlineEffect = code.slice(code.indexOf('if (deadline === null) return'))
    expect(deadlineEffect).toContain('scanNow()')
    expect(deadlineEffect.slice(0, deadlineEffect.indexOf('}, [deadline'))).not.toContain('request()')
  })

  it('uses the shared scheduler for the two moments that are genuinely a clock', () => {
    // `at()` is a one-shot on the app's single timer, disarmed behind a hidden
    // window. A bare `setTimeout` would be a wake-up nobody coalesces.
    expect(code).toContain("from './schedule'")
    expect(code).not.toMatch(/\bsetTimeout\(/)
  })
})
