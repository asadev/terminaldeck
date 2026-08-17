/**
 * The one trigger that is genuinely a clock.
 *
 * Asad's standing rule is *events, not polling — webhooks, APIs and push over
 * crons and timers, they make the system heavier*, and every other trigger in
 * `format.ts` honours it by subscribing to something the app already emits. A
 * schedule cannot: there is no event anywhere in this machine that means
 * "02:30 happened". So a schedule is one entry in the trigger list rather than
 * the foundation of it, and the implementation is written to be the smallest
 * possible violation of the rule:
 *
 *  - This module computes **the next instant a schedule is due** and nothing
 *    else. It holds no timer and reads no clock of its own — `from` is always a
 *    parameter, which is also what makes the whole thing testable without
 *    waiting.
 *  - The engine arms **one** `setTimeout` for the earliest due routine across
 *    all of them, and re-arms it when that one fires. Not one timer per
 *    routine, and emphatically not an interval that wakes up to ask whether
 *    anything is due — which is the exact shape the rule objects to.
 *
 * ## Why `every` has a floor and `at` does not
 *
 * `schedule every 30s` would be a poll wearing a costume, and it would spend
 * money doing it, so the parser refuses anything under {@link MIN_INTERVAL_MS}.
 * A daily time needs no floor: there is only one 09:00 a day.
 *
 * ## Local time, and what that costs
 *
 * `schedule 09:00` means nine in the morning where the person is, which is the
 * only reading anybody expects, so the arithmetic below builds `Date`s from
 * local calendar components rather than adding 86,400,000 milliseconds. That is
 * what makes it right across a daylight-saving change — adding a day's worth of
 * milliseconds on the last Sunday of October produces 08:00. The one case it
 * cannot be right about is a time that does not exist locally, which happens for
 * an hour once a year in spring: `new Date(y, m, d, 2, 30)` resolves forward to
 * 03:30, so a 02:30 routine runs an hour late on that one day. Skipping it
 * entirely was the alternative and is worse.
 */

/** `schedule every 5m` is the fastest a routine may be asked to repeat. */
export const MIN_INTERVAL_MS = 5 * 60 * 1000
/** And a routine that repeats less often than this should be a daily time. */
export const MAX_INTERVAL_MS = 7 * 24 * 60 * 60 * 1000

export type Schedule =
  /** A local time of day, on `days` (0 = Sunday) or every day when null. */
  | { kind: 'at'; minutes: number; days: number[] | null }
  /** Every `intervalMs`, counted from whenever the routine was last due. */
  | { kind: 'every'; intervalMs: number }

const DAY_NAMES = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'] as const

function parseDays(text: string): number[] | { problem: string } {
  const parts = text
    .split(/[,\s]+/)
    .map((part) => part.trim().toLowerCase())
    .filter((part) => part !== '')
  const days: number[] = []
  for (const part of parts) {
    // `weekdays` and `weekends` earn their place: they are what people actually
    // mean, and spelling out `mon,tue,wed,thu,fri` is the sort of thing that
    // gets one day wrong and is never noticed.
    if (part === 'weekdays') {
      days.push(1, 2, 3, 4, 5)
      continue
    }
    if (part === 'weekends') {
      days.push(0, 6)
      continue
    }
    const index = DAY_NAMES.indexOf(part.slice(0, 3) as (typeof DAY_NAMES)[number])
    if (index === -1) return { problem: `\`${part}\` is not a day of the week.` }
    days.push(index)
  }
  if (days.length === 0) return { problem: 'No days were named.' }
  return [...new Set(days)].sort((a, b) => a - b)
}

export function parseSchedule(text: string): { schedule: Schedule } | { problem: string } {
  const trimmed = text.trim().toLowerCase()
  if (trimmed === '') {
    return { problem: '`when: schedule` needs a time, like `schedule 09:00` or `schedule every 2h`.' }
  }

  if (trimmed.startsWith('every')) {
    const rest = trimmed.slice('every'.length).trim()
    const match = /^(\d{1,5})(s|m|h|d)$/.exec(rest)
    if (!match) return { problem: `\`schedule every ${rest}\` needs a duration, like \`every 2h\`.` }
    const unit = { s: 1000, m: 60_000, h: 3_600_000, d: 86_400_000 }[match[2]] as number
    const intervalMs = Number(match[1]) * unit
    if (intervalMs < MIN_INTERVAL_MS) {
      return {
        problem: `\`schedule every ${rest}\` is faster than this app will run a routine unattended (5m).`,
      }
    }
    if (intervalMs > MAX_INTERVAL_MS) {
      return { problem: `\`schedule every ${rest}\` is longer than a week — use a time of day.` }
    }
    return { schedule: { kind: 'every', intervalMs } }
  }

  const space = trimmed.indexOf(' ')
  const clock = space === -1 ? trimmed : trimmed.slice(0, space)
  const dayText = space === -1 ? '' : trimmed.slice(space + 1)

  const match = /^(\d{1,2}):(\d{2})$/.exec(clock)
  if (!match) return { problem: `\`schedule ${clock}\` should be a 24-hour time, like \`09:00\`.` }
  const hours = Number(match[1])
  const mins = Number(match[2])
  if (hours > 23 || mins > 59) return { problem: `\`schedule ${clock}\` is not a real time.` }

  if (dayText === '') return { schedule: { kind: 'at', minutes: hours * 60 + mins, days: null } }
  const days = parseDays(dayText)
  if ('problem' in days) return days
  return { schedule: { kind: 'at', minutes: hours * 60 + mins, days } }
}

export function serializeSchedule(schedule: Schedule): string {
  if (schedule.kind === 'every') {
    const ms = schedule.intervalMs
    for (const [unit, size] of [['d', 86_400_000], ['h', 3_600_000], ['m', 60_000]] as const) {
      if (ms >= size && ms % size === 0) return `every ${ms / size}${unit}`
    }
    return `every ${Math.round(ms / 1000)}s`
  }
  const clock = `${String(Math.floor(schedule.minutes / 60)).padStart(2, '0')}:${String(
    schedule.minutes % 60,
  ).padStart(2, '0')}`
  if (schedule.days === null) return clock
  return `${clock} ${schedule.days.map((day) => DAY_NAMES[day]).join(',')}`
}

/**
 * The next instant this schedule is due, strictly after `from`.
 *
 * Strictly after matters: the engine calls this again from inside the fire it
 * just performed, and a schedule that answered "now" would re-arm a zero-length
 * timer and run forever. `anchor` is the previous due time for an interval
 * schedule; when there is none — first arm, or the first arm after a restart —
 * the interval is counted from `from`, which is deliberately a *drift* rather
 * than a stored cron state. A routine set to run every two hours runs every two
 * hours from whenever the app started, and nothing on disk has to be kept
 * consistent with a clock the app was not running for.
 */
export function nextDue(schedule: Schedule, from: number, anchor: number | null = null): number {
  if (schedule.kind === 'every') {
    if (anchor === null) return from + schedule.intervalMs
    // Catch up rather than fire once per missed interval: an app that was
    // closed overnight should run the routine once when it comes back, not
    // eleven times in a row. This is the same decision `missedRuns` reports.
    let next = anchor + schedule.intervalMs
    if (next <= from) {
      const missed = Math.ceil((from - anchor) / schedule.intervalMs)
      next = anchor + missed * schedule.intervalMs
      if (next <= from) next += schedule.intervalMs
    }
    return next
  }

  const start = new Date(from)
  for (let ahead = 0; ahead <= 8; ahead++) {
    const day = new Date(
      start.getFullYear(),
      start.getMonth(),
      start.getDate() + ahead,
      Math.floor(schedule.minutes / 60),
      schedule.minutes % 60,
      0,
      0,
    )
    if (day.getTime() <= from) continue
    if (schedule.days !== null && !schedule.days.includes(day.getDay())) continue
    return day.getTime()
  }
  // Unreachable for any schedule this module can produce — eight days always
  // contains every weekday — but a function that returns a time must return
  // one, and a week from now is the answer that fails quietly rather than
  // producing a NaN somebody has to trace back to here.
  return from + 7 * 86_400_000
}

/**
 * How many times this schedule came due while nobody was running.
 *
 * The honest answer to "the app was closed all weekend": not a burst of catch-up
 * runs, and not silence either. The engine runs the routine **once** and says
 * this number, so a person opening the app on Monday is told that Saturday's
 * and Sunday's sweeps did not happen rather than discovering it from a gap in a
 * log. Capped, because a laptop shut for a month should not report 720.
 */
export function missedRuns(schedule: Schedule, since: number, now: number, cap = 99): number {
  if (since >= now) return 0
  let count = 0
  let cursor = since
  while (count < cap) {
    const due = nextDue(schedule, cursor, schedule.kind === 'every' ? cursor : null)
    if (due > now) break
    count += 1
    cursor = due
  }
  return count
}
