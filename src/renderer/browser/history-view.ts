import type { HistoryVisit } from './accounts-bridge'

/**
 * How a list of visits is read: what each row says, and where the days break.
 *
 * A separate file from the panel that draws it for the reason `served-mark.ts`
 * gives about the same panel — this project's test run has no DOM, so a rule
 * living inside a render tree is a rule nothing can hold. Everything here is a
 * pure function of a list and a clock, which is what makes the awkward cases
 * (midnight, a row with no title, the same address seen twice) testable at all.
 */

/**
 * The host, as it is worth reading on a row.
 *
 * `www.` comes off for the reason it comes off in the address bar's matching:
 * nobody thinks of the site they are going back to as `www.` anything, and four
 * identical characters at the start of forty rows are four characters of noise.
 * A URL that will not parse is handed back whole rather than dropped — it came
 * out of a real navigation, so it is a real place, and printing it as it is
 * beats printing nothing.
 */
export function visitHost(url: string): string {
  try {
    return new URL(url).host.replace(/^www\./i, '')
  } catch {
    return url
  }
}

/**
 * The name of the row.
 *
 * The page's own title where there is one, and the address where there is not —
 * never a placeholder. A page that never announced a title is usually a raw
 * file or a dev server's index, and its URL is the most useful thing that could
 * be written on the row anyway.
 */
export function visitLabel(entry: HistoryVisit): string {
  const title = entry.title.trim()
  return title === '' ? entry.url : title
}

/** Midnight before `at`, in the machine's own timezone. */
function startOfDay(at: number): number {
  const date = new Date(at)
  date.setHours(0, 0, 0, 0)
  return date.getTime()
}

/**
 * Which day a visit belongs under.
 *
 * Today and Yesterday by name, everything else by date. Local midnight rather
 * than a rolling 24 hours: a page opened at 23:50 and one opened at 00:10 are
 * on either side of a heading a person recognises, and "22 hours ago" is not a
 * thing anybody scans a history for.
 */
export function dayHeading(at: number, now: number): string {
  const day = startOfDay(at)
  const today = startOfDay(now)
  if (day === today) return 'Today'
  if (day === today - 86400000) return 'Yesterday'
  return new Date(at).toLocaleDateString(undefined, {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    // The year only when it is not this one — printing 2026 on every row of a
    // list that is mostly this week is the kind of filler he strikes out.
    ...(new Date(at).getFullYear() === new Date(now).getFullYear() ? {} : { year: 'numeric' }),
  })
}

/** The time of day a visit happened, as the row prints it. */
export function timeLabel(at: number): string {
  return new Date(at).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
}

export interface HistoryDay {
  /** `Today`, `Yesterday`, or a date. */
  heading: string
  /** Local midnight of that day — a stable key for the section. */
  day: number
  visits: HistoryVisit[]
}

/**
 * A list of visits, cut into days, newest first.
 *
 * The list is sorted here rather than trusted, because it arrives over IPC from
 * a store that sorts on its own and a heading out of order is the kind of defect
 * that is only visible on the one day it happens.
 */
export function byDay(visits: readonly HistoryVisit[], now: number): HistoryDay[] {
  const days: HistoryDay[] = []
  for (const visit of [...visits].sort((a, b) => b.visitedAt - a.visitedAt)) {
    const day = startOfDay(visit.visitedAt)
    const last = days[days.length - 1]
    if (last && last.day === day) last.visits.push(visit)
    else days.push({ heading: dayHeading(visit.visitedAt, now), day, visits: [visit] })
  }
  return days
}

/**
 * What the address bar should put in the field for the top suggestion, or null.
 *
 * Chrome fills the rest of the address in for you and selects what it added, so
 * one more keystroke replaces the guess instead of fighting it. The completion
 * has to be a form the person could plausibly have been typing — `git` becomes
 * `github.com`, never `https://github.com` — which is why the forms are tried
 * shortest-first and the whole URL is the last resort.
 *
 * Null for the cases where completing would be wrong rather than merely
 * unhelpful:
 *
 *  - nothing typed, or only spaces;
 *  - a typed string containing a space, which is a search and not an address;
 *  - a candidate that does not start with what was typed;
 *  - a candidate equal to what was typed, where there is nothing to add.
 *
 * The completion keeps the characters the person actually typed at the front,
 * so their capitals are not rewritten under the cursor.
 */
export function completionFor(typed: string, url: string): string | null {
  if (typed.trim() === '' || /\s/.test(typed)) return null
  const bare = url.replace(/^https?:\/\//i, '')
  const noWww = bare.replace(/^www\./i, '')
  const lower = typed.toLowerCase()
  for (const candidate of [noWww, bare, url]) {
    // A bare host completes without its trailing slash: somebody typing `goo`
    // means `google.com`, and `google.com/` reads as a path they did not ask for.
    const trimmed = candidate.endsWith('/') && candidate.indexOf('/') === candidate.length - 1
      ? candidate.slice(0, -1)
      : candidate
    if (trimmed.toLowerCase().startsWith(lower) && trimmed.length > typed.length) {
      return typed + trimmed.slice(typed.length)
    }
  }
  return null
}
