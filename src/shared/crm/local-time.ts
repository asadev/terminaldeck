/**
 * The reference CRM's task clock, on this Mac's own time.
 *
 * The CRM decides every calendar day and every time of day in one fixed office
 * zone, because its server and its people sit in different zones. Here the
 * task, the person and the computer are one place, so each function below keeps
 * the CRM's name-for-name job and shape but reads this computer's local clock
 * instead.
 *
 * One deliberate difference: the CRM's office works six days with one day off.
 * A product for anyone uses the common week — Monday to Friday are working
 * days and Saturday and Sunday are the days off — so the "weekdays" repeat,
 * "Skip weekends" on a routine and "This weekend" all follow that.
 *
 * Calendar dates ("YYYY-MM-DD") are plain dates, counted with UTC arithmetic
 * so no zone can shift them; only an instant (a moment in time) is read
 * through the local clock.
 */

export const MONTH_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
export const DAY_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

/** 0 = Sunday … 6 = Saturday: the days off in a Monday-to-Friday week. */
export const DAYS_OFF: readonly number[] = [0, 6]

/** How the days off read in a label: "Skip weekends", "This weekend". */
export const DAYS_OFF_LABEL = 'weekend'

const YMD = /^\d{4}-\d{2}-\d{2}$/

export function isYmd(s: unknown): s is string {
  return typeof s === 'string' && YMD.test(s)
}

function ymdParts(ymd: string): { y: number; m: number; d: number } {
  const [y, m, d] = ymd.split('-').map(Number)
  return { y, m, d }
}

function ymdOfUtc(date: Date): string {
  return date.toISOString().slice(0, 10)
}

function pad(n: number): string {
  return String(n).padStart(2, '0')
}

/** "YYYY-MM-DD" + n days. */
export function ymdAddDays(ymd: string, n: number): string {
  const { y, m, d } = ymdParts(ymd)
  return ymdOfUtc(new Date(Date.UTC(y, m - 1, d + n)))
}

/** Whole days from a to b (b − a), both "YYYY-MM-DD". */
export function ymdDiff(a: string, b: string): number {
  const pa = ymdParts(a)
  const pb = ymdParts(b)
  return Math.round((Date.UTC(pb.y, pb.m - 1, pb.d) - Date.UTC(pa.y, pa.m - 1, pa.d)) / 86_400_000)
}

/** 0 = Sunday … 6 = Saturday, of a "YYYY-MM-DD". */
export function ymdWeekday(ymd: string): number {
  const { y, m, d } = ymdParts(ymd)
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay()
}

/** Today's date on this computer, "YYYY-MM-DD". */
export function localToday(now: Date = new Date()): string {
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

/** Today's date on this computer, "YYYY-MM-DD" — the CRM's other name for it. */
export function todayYmd(now: Date = new Date()): string {
  return localToday(now)
}

/** When today began on this computer, in epoch milliseconds. */
export function localDayStartMs(now: Date = new Date()): number {
  return new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
}

export type LocalParts = { y: number; m: number; d: number; weekday: number; hh: number; mm: number; ymd: string }

/** An instant's local wall clock; null for anything unparseable. */
export function localParts(at: Date | string | number): LocalParts | null {
  const t = typeof at === 'number' ? at : at instanceof Date ? at.getTime() : new Date(at).getTime()
  if (!Number.isFinite(t)) return null
  const x = new Date(t)
  return {
    y: x.getFullYear(),
    m: x.getMonth() + 1,
    d: x.getDate(),
    weekday: x.getDay(),
    hh: x.getHours(),
    mm: x.getMinutes(),
    ymd: localToday(x),
  }
}

/** "6:55 pm" (or "6:55 PM"), local. */
export function localClock(at: Date | string | number, upper = false): string {
  const p = localParts(at)
  if (!p) return ''
  const s = `${p.hh % 12 === 0 ? 12 : p.hh % 12}:${pad(p.mm)} ${p.hh < 12 ? 'am' : 'pm'}`
  return upper ? s.toUpperCase() : s
}

/** "15 Sep 2026, 6:55 pm" — a hover title's full local time. */
export function localStamp(at: Date | string | number): string {
  const p = localParts(at)
  return p ? `${p.d} ${MONTH_SHORT[p.m - 1]} ${p.y}, ${localClock(at)}` : ''
}

/** The instant a local wall-clock time happens on a calendar day. */
export function localInstantAt(ymd: string, hh: number, mm = 0): Date {
  const { y, m, d } = ymdParts(ymd)
  return new Date(y, m - 1, d, hh, mm)
}

/** A stored time of day, "16:00" → "4:00 pm". */
export function hmLabel(hm: string | null | undefined): string {
  if (!hm || !/^\d{2}:\d{2}/.test(hm)) return ''
  const [h, m] = hm.slice(0, 5).split(':').map(Number)
  return `${h % 12 === 0 ? 12 : h % 12}:${pad(m)} ${h < 12 ? 'am' : 'pm'}`
}

/** The quick due dates (slash commands, menus): today, tomorrow, next Monday, in 2 weeks. */
export function localQuickDates(now: Date = new Date()): { today: string; tomorrow: string; nextMonday: string; twoWeeks: string } {
  const today = todayYmd(now)
  return {
    today,
    tomorrow: ymdAddDays(today, 1),
    nextMonday: ymdAddDays(today, (8 - ymdWeekday(today)) % 7 || 7),
    twoWeeks: ymdAddDays(today, 14),
  }
}

/** A datetime-local value ("2026-09-16T09:30") as the local instant it names; null if malformed. */
export function localFromInput(value: string): Date | null {
  const m = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})$/.exec(value)
  return m ? localInstantAt(m[1], Number(m[2]), Number(m[3])) : null
}

/** The local time of day now, "HH:MM". */
export function localNowHm(now: Date = new Date()): string {
  return `${pad(now.getHours())}:${pad(now.getMinutes())}`
}

/** Is this calendar date a day off (Saturday or Sunday)? */
export function isLocalDayOff(ymd: string): boolean {
  return DAYS_OFF.includes(ymdWeekday(ymd))
}

/** The date itself on a working day, else the next working day (Saturday → Monday). */
export function nextWorkingDay(ymd: string): string {
  let d = ymd
  for (let i = 0; i < 7 && isLocalDayOff(d); i++) d = ymdAddDays(d, 1)
  return d
}

/** The next day off on or after `ymd` (the date itself when it is one) — "This weekend". */
export function nextDayOff(ymd: string): string {
  let d = ymd
  for (let i = 0; i < 7 && !isLocalDayOff(d); i++) d = ymdAddDays(d, 1)
  return d
}
