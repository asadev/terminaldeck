import { describe, expect, it } from 'vitest'
import { MIN_INTERVAL_MS, missedRuns, nextDue, parseSchedule, serializeSchedule } from './schedule'

/**
 * The schedule trigger.
 *
 * The interesting cases here are all about time being awkward rather than about
 * parsing: a time that has already passed today, a day-of-week list, and a
 * machine that was asleep. Everything takes `from` as a parameter, so none of
 * these tests waits for anything.
 */

/** A local `Date`, so the assertions read in the same timezone the code works in. */
function at(year: number, month: number, day: number, hour: number, minute = 0): number {
  return new Date(year, month - 1, day, hour, minute, 0, 0).getTime()
}

describe('parseSchedule', () => {
  it('reads a time of day', () => {
    expect(parseSchedule('09:00')).toEqual({ schedule: { kind: 'at', minutes: 540, days: null } })
    expect(parseSchedule('02:30')).toEqual({ schedule: { kind: 'at', minutes: 150, days: null } })
  })

  it('reads days, including the words people actually use', () => {
    expect(parseSchedule('09:00 mon,wed,fri')).toEqual({
      schedule: { kind: 'at', minutes: 540, days: [1, 3, 5] },
    })
    expect(parseSchedule('18:00 weekdays')).toEqual({
      schedule: { kind: 'at', minutes: 1080, days: [1, 2, 3, 4, 5] },
    })
    expect(parseSchedule('10:00 weekends')).toEqual({
      schedule: { kind: 'at', minutes: 600, days: [0, 6] },
    })
  })

  it('reads an interval and refuses one that is really a poll', () => {
    expect(parseSchedule('every 2h')).toEqual({ schedule: { kind: 'every', intervalMs: 7_200_000 } })
    const tooFast = parseSchedule('every 30s')
    expect('problem' in tooFast).toBe(true)
    expect(parseSchedule(`every ${MIN_INTERVAL_MS / 60000}m`)).toEqual({
      schedule: { kind: 'every', intervalMs: MIN_INTERVAL_MS },
    })
  })

  it('refuses a time that is not a time', () => {
    expect('problem' in parseSchedule('25:00')).toBe(true)
    expect('problem' in parseSchedule('9am')).toBe(true)
    expect('problem' in parseSchedule('')).toBe(true)
    expect('problem' in parseSchedule('09:00 funday')).toBe(true)
  })

  it('round-trips', () => {
    for (const text of ['09:00', '02:30 mon,fri', 'every 2h', 'every 30m']) {
      const parsed = parseSchedule(text)
      expect('schedule' in parsed).toBe(true)
      if (!('schedule' in parsed)) continue
      expect(serializeSchedule(parsed.schedule)).toBe(text)
    }
  })
})

describe('nextDue', () => {
  it('is today when the time has not passed, and tomorrow when it has', () => {
    const nine = { kind: 'at' as const, minutes: 540, days: null }
    expect(nextDue(nine, at(2026, 8, 17, 8))).toBe(at(2026, 8, 17, 9))
    expect(nextDue(nine, at(2026, 8, 17, 10))).toBe(at(2026, 8, 18, 9))
  })

  it('is never now, so a fire cannot re-arm a zero-length timer', () => {
    const nine = { kind: 'at' as const, minutes: 540, days: null }
    expect(nextDue(nine, at(2026, 8, 17, 9))).toBe(at(2026, 8, 18, 9))
  })

  it('skips to the next named day', () => {
    // 2026-08-17 is a Monday.
    const friday = { kind: 'at' as const, minutes: 540, days: [5] }
    expect(nextDue(friday, at(2026, 8, 17, 10))).toBe(at(2026, 8, 21, 9))
  })

  it('counts an interval from the last time it was due, not from now', () => {
    const hourly = { kind: 'every' as const, intervalMs: 3_600_000 }
    const anchor = at(2026, 8, 17, 9)
    expect(nextDue(hourly, at(2026, 8, 17, 9, 30), anchor)).toBe(at(2026, 8, 17, 10))
  })

  it('catches up to one run rather than firing once per missed interval', () => {
    const hourly = { kind: 'every' as const, intervalMs: 3_600_000 }
    const anchor = at(2026, 8, 17, 9)
    // The app was closed for five hours. The next due time is the next one
    // *after now*, not the four that went by.
    expect(nextDue(hourly, at(2026, 8, 17, 14, 10), anchor)).toBe(at(2026, 8, 17, 15))
  })

  it('does not add a day of milliseconds, so it survives a clock change', () => {
    // 2026-10-25 is when most of Europe puts its clocks back. Adding 86400000
    // to 09:00 on the 24th gives 08:00 on the 25th in a zone that observes it;
    // building the date from calendar components gives 09:00 either way. On a
    // machine with no such change this simply asserts the ordinary answer.
    const nine = { kind: 'at' as const, minutes: 540, days: null }
    const due = nextDue(nine, at(2026, 10, 24, 10))
    expect(new Date(due).getHours()).toBe(9)
    expect(new Date(due).getDate()).toBe(25)
  })
})

describe('missedRuns', () => {
  it('counts the times it came due while nothing was running', () => {
    const nine = { kind: 'at' as const, minutes: 540, days: null }
    // Ran Friday morning; the app comes back on Monday. Saturday, Sunday and
    // Monday all came due.
    expect(missedRuns(nine, at(2026, 8, 14, 9), at(2026, 8, 17, 10))).toBe(3)
  })

  it('is zero when nothing was missed', () => {
    const nine = { kind: 'at' as const, minutes: 540, days: null }
    expect(missedRuns(nine, at(2026, 8, 17, 9), at(2026, 8, 17, 10))).toBe(0)
  })

  it('is capped, so a laptop shut for a month does not report 720', () => {
    const hourly = { kind: 'every' as const, intervalMs: 3_600_000 }
    expect(missedRuns(hourly, at(2026, 7, 1, 0), at(2026, 8, 17, 0), 10)).toBe(10)
  })
})
