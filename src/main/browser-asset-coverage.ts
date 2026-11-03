import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname } from 'node:path'

/**
 * Comparing what a run captured against the number the page itself printed.
 *
 * ## The loss
 *
 * A listing page said *"showing 12 of 340 units"*. The run captured what was on
 * the page. **7% of the dataset was shipped as complete**, because nothing in
 * the pipeline ever read the 340 and put it beside the 12.
 *
 * The number was on the screen the whole time. This module is about the
 * arithmetic nobody did.
 *
 * ## What is configurable, and what is refused
 *
 * No site's wording is written down here. Not one phrase from a real portal, not
 * one selector. A caller supplies the pattern, or the text, or both, because the
 * moment this file contains *"showing … of …"* for a named site it becomes a
 * thing that keeps working until that site changes its copy, and then reports
 * `complete` for ever.
 *
 * {@link GENERIC_TOTAL_PATTERNS} is the concession, and its limits are the point
 * of it. The three shapes in it are grammar, not a site: *of N*, *N results*, *N
 * total*. They are tried only when the caller gave no pattern of their own, the
 * one that matched is named in the result, and — this is the part that makes it
 * safe — when two different candidate patterns extract two different numbers the
 * answer is `null`, not the first one. A guess that cannot be checked is not
 * better than no answer; it is the same failure with more confidence.
 *
 * ## Never "complete" by default
 *
 * {@link compareCoverage} has four verdicts and `unknown` is one of them. A page
 * whose total could not be read is not complete, is not short, and must not be
 * quietly treated as either. It is `unknown`, it is `loud`, and the sentence
 * says so in words — because "we couldn't find the total" degrading into
 * "finished" is precisely how 7% became a delivery.
 */

/* ------------------------------------------------------- reading a number -- */

/**
 * The grammar-shaped fallbacks, tried only when the caller supplied no pattern.
 *
 * Each has exactly one capture group and it is the number. In this order,
 * because *of N* is the most specific — it needs the word `of` in front — and
 * the bare-count shapes are the ones most likely to catch a price or a page
 * number by accident.
 */
export const GENERIC_TOTAL_PATTERNS: readonly string[] = Object.freeze([
  String.raw`\bof\s+([\d][\d.,\u202f\u00a0 ]*\d|\d)\b`,
  String.raw`\b([\d][\d.,\u202f\u00a0 ]*\d|\d)\s+(?:results?|items?|listings?|records?|entries)\b`,
  String.raw`\b([\d][\d.,\u202f\u00a0 ]*\d|\d)\s+total\b`,
])

/**
 * Turn a matched run of digits and separators into a number, or `null`.
 *
 * Thousands separators are the whole difficulty and they are genuinely
 * ambiguous: `1.234` is one thousand two hundred and thirty-four in German and
 * one point two three four in English. The rule taken here is structural rather
 * than linguistic — a separator is a thousands separator **only** when every
 * group after the first is exactly three digits and the first is one to three.
 * `1.234` therefore reads as 1234, `1.23` reads as nothing, and `12.3456` reads
 * as nothing.
 *
 * `null` rather than a best guess. A total this cannot read confidently must
 * arrive at {@link compareCoverage} as "unknown", which is loud, rather than as
 * a number that happens to be wrong, which is silent.
 */
export function readTotal(raw: string): number | null {
  const text = raw.trim().replace(/[\u202f\u00a0]/g, ' ')
  if (/^\d+$/.test(text)) {
    const plain = Number(text)
    return Number.isSafeInteger(plain) ? plain : null
  }
  const grouped = /^(\d{1,3})(([.,\s])\d{3})+$/.exec(text)
  if (grouped === null) return null
  const separator = grouped[3]
  // One separator throughout: `1,234.567` is not a count.
  if (new Set(text.replace(/\d/g, '').split('')).size !== 1) return null
  const digits = text.split(separator).join('')
  if (!/^\d+$/.test(digits)) return null
  const value = Number(digits)
  return Number.isSafeInteger(value) ? value : null
}

export interface TotalProbe {
  /**
   * The caller's own pattern. First capture group is the number.
   *
   * When this is given it is the only thing tried:
   * {@link GENERIC_TOTAL_PATTERNS} is a fallback for a caller who has not looked
   * at the page, never a second opinion overruling one who has.
   */
  pattern?: string
  flags?: string
}

export interface StatedTotal {
  total: number | null
  /** The pattern that produced it, so a wrong reading can be traced. */
  pattern: string
  /** The text it matched, for the same reason. */
  matched: string
  /** Empty when a total was read. Otherwise why it was not. */
  reason: string
}

/** Anything longer is not a pattern somebody wrote. */
const MAX_PATTERN_CHARS = 300

/**
 * Pull the page's own stated total out of a piece of its text.
 *
 * The text comes from the caller — `browser.read` already returns the page's
 * prose, and re-reading it here would mean this module owning a second route
 * into a page that is under a baton (`browser-cdp.ts`). What arrives is a string
 * and what leaves is a number or an honest `null`.
 */
export function statedTotal(text: string, probe: TotalProbe = {}): StatedTotal {
  const none = (reason: string): StatedTotal => ({ total: null, pattern: '', matched: '', reason })
  if (typeof text !== 'string' || text.trim() === '') return none('there was no text to read')

  const flags = typeof probe.flags === 'string' ? probe.flags : ''
  if (!/^[imsuy]*$/.test(flags)) return none('those are not flags a total pattern may carry')

  if (typeof probe.pattern === 'string' && probe.pattern !== '') {
    if (probe.pattern.length > MAX_PATTERN_CHARS) {
      return none(`the pattern is longer than ${MAX_PATTERN_CHARS} characters`)
    }
    let expression: RegExp
    try {
      expression = new RegExp(probe.pattern, flags)
    } catch (error) {
      return none(
        `the pattern is not a valid expression: ${
          error instanceof Error ? error.message : 'unknown reason'
        }`,
      )
    }
    const found = expression.exec(text)
    if (found === null) return none('the pattern matched nothing in that text')
    const captured = found[1] ?? found[0]
    const total = readTotal(captured)
    if (total === null) {
      return none(`the pattern matched "${clip(captured)}", which is not a number this can read`)
    }
    return { total, pattern: probe.pattern, matched: clip(found[0]), reason: '' }
  }

  /*
   * No pattern. The generic shapes, and a disagreement is an answer of `null`.
   *
   * The disagreement rule is what stops this being a guess: if *of 340* and *12
   * results* both appear, the two shapes disagree about what the page's total
   * is, and this cannot tell which of them the caller meant. Refusing there is
   * one extra argument in a tool call; picking one is a silent 7%.
   */
  const readings: { total: number; pattern: string; matched: string }[] = []
  for (const source of GENERIC_TOTAL_PATTERNS) {
    const found = new RegExp(source, 'i').exec(text)
    if (found === null) continue
    const total = readTotal(found[1] ?? '')
    if (total === null) continue
    readings.push({ total, pattern: source, matched: clip(found[0]) })
  }
  if (readings.length === 0) {
    return none(
      'nothing in that text reads as a stated total. Give a pattern, or a selector’s text, that does.',
    )
  }
  const distinct = new Set(readings.map((reading) => reading.total))
  if (distinct.size > 1) {
    return none(
      `that text states more than one total — ${[...distinct].join(' and ')} — so which one bounds ` +
        'this run has to be said with a pattern.',
    )
  }
  return { ...readings[0], reason: '' }
}

function clip(text: string): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  return flat.length > 80 ? `${flat.slice(0, 80)}…` : flat
}

/* -------------------------------------------------------------- comparing -- */

export type CoverageVerdict = 'complete' | 'short' | 'over' | 'unknown'

export interface CoverageCheck {
  verdict: CoverageVerdict
  /** What the page said. `null` when it could not be read. */
  stated: number | null
  captured: number
  /** `stated - captured`, or `null` when there is no stated total. */
  missing: number | null
  /** `captured / stated`, or `null`. */
  ratio: number | null
  /**
   * Does somebody need to look at this?
   *
   * True for everything except a clean `complete`. The field exists so that the
   * caller cannot accidentally treat "unknown" as good news by checking
   * `verdict !== 'short'`.
   */
  loud: boolean
  line: string
  at: number
  /** What was being counted, for the record. Free text from the caller. */
  what: string
  url: string
}

/**
 * Compare, and say plainly which of the four situations this is.
 *
 * `tolerance` is a count, not a fraction, and defaults to zero. A listing that
 * says 340 and yields 339 is short by one and the run should say so; the caller
 * who knows their page double-counts a header row can allow for it explicitly.
 * A percentage tolerance was the other option and it is the wrong shape — 5% of
 * 340 is 17 assets, and 17 floor plans is not a rounding error.
 */
export function compareCoverage(input: {
  stated: number | null
  captured: number
  tolerance?: number
  what?: string
  url?: string
  now?: number
}): CoverageCheck {
  const captured = Number.isFinite(input.captured) && input.captured > 0 ? Math.trunc(input.captured) : 0
  const tolerance = Number.isFinite(input.tolerance ?? 0) ? Math.max(0, Math.trunc(input.tolerance ?? 0)) : 0
  const what = (input.what ?? '').trim()
  const url = input.url ?? ''
  const at = input.now ?? Date.now()
  const subject = what === '' ? 'this page' : what

  if (input.stated === null || !Number.isFinite(input.stated)) {
    return {
      verdict: 'unknown',
      stated: null,
      captured,
      missing: null,
      ratio: null,
      loud: true,
      line:
        `${captured} captured from ${subject}, and nothing on the page said how many there should be. ` +
        'This run cannot be called complete — read the page for its own total, or say so explicitly.',
      at,
      what,
      url,
    }
  }

  const stated = Math.trunc(input.stated)
  const missing = stated - captured
  const ratio = stated === 0 ? null : captured / stated

  if (missing > tolerance) {
    const percent = ratio === null ? '' : ` — ${Math.round(ratio * 100)}% of what the page states`
    return {
      verdict: 'short',
      stated,
      captured,
      missing,
      ratio,
      loud: true,
      line: `${captured} of ${stated} captured from ${subject}${percent}. ${missing} are missing. This is not complete.`,
      at,
      what,
      url,
    }
  }
  if (missing < -tolerance) {
    return {
      verdict: 'over',
      stated,
      captured,
      missing,
      ratio,
      loud: true,
      line:
        `${captured} captured from ${subject} against a stated ${stated}. More than the page says exist, ` +
        'which usually means the same items were counted twice — check before treating this as a win.',
      at,
      what,
      url,
    }
  }
  return {
    verdict: 'complete',
    stated,
    captured,
    missing,
    ratio,
    loud: false,
    line: `${captured} of ${stated} captured from ${subject}.`,
    at,
    what,
    url,
  }
}

/* ------------------------------------------------------------- the record -- */

/**
 * Append a check to the run's coverage log.
 *
 * Written down rather than only returned, because the number that matters is
 * read at the *end* of a run — *"did any page come up short?"* — and by then the
 * tool result that carried it is thousands of lines back in a transcript, or in
 * a transcript nobody kept.
 *
 * Best effort. A log line that will not write is not a reason to fail a check
 * that has already been made correctly; the answer is returned either way.
 */
export function recordCoverage(path: string, check: CoverageCheck): boolean {
  try {
    mkdirSync(dirname(path), { recursive: true })
    appendFileSync(path, `${JSON.stringify(check)}\n`)
    return true
  } catch {
    return false
  }
}

/** Every check a run has recorded, oldest first. Unreadable lines are dropped. */
export function readCoverage(path: string): CoverageCheck[] {
  if (!existsSync(path)) return []
  let text: string
  try {
    text = readFileSync(path, 'utf8')
  } catch {
    return []
  }
  const checks: CoverageCheck[] = []
  for (const line of text.split('\n')) {
    const trimmed = line.trim()
    if (trimmed === '') continue
    try {
      const parsed = JSON.parse(trimmed) as CoverageCheck
      if (typeof parsed === 'object' && parsed !== null && typeof parsed.verdict === 'string') {
        checks.push(parsed)
      }
    } catch {
      // One line, not the log.
    }
  }
  return checks
}

/**
 * The one sentence a run should end on.
 *
 * Deliberately refuses to say a run is complete on no evidence: a run that
 * checked nothing gets a line saying it checked nothing, because *"no problems
 * found"* and *"nobody looked"* are the two things this whole module exists to
 * keep apart.
 */
export function coverageSummary(checks: readonly CoverageCheck[]): {
  ok: boolean
  line: string
  short: number
  unknown: number
  over: number
  complete: number
} {
  const count = (verdict: CoverageVerdict): number =>
    checks.filter((check) => check.verdict === verdict).length
  const short = count('short')
  const unknown = count('unknown')
  const over = count('over')
  const complete = count('complete')
  if (checks.length === 0) {
    return {
      ok: false,
      line: 'No coverage check was made, so nothing here says this run captured everything it should have.',
      short,
      unknown,
      over,
      complete,
    }
  }
  if (short === 0 && unknown === 0 && over === 0) {
    return {
      ok: true,
      line: `${complete} coverage checks, all of them matching the totals the pages stated.`,
      short,
      unknown,
      over,
      complete,
    }
  }
  const missing = checks
    .filter((check) => check.verdict === 'short')
    .reduce((sum, check) => sum + (check.missing ?? 0), 0)
  const parts: string[] = []
  if (short > 0) parts.push(`${short} pages came up short by ${missing} items in total`)
  if (unknown > 0) parts.push(`${unknown} pages never stated a total, so they cannot be called complete`)
  if (over > 0) parts.push(`${over} pages yielded more than they state, which usually means duplicates`)
  return {
    ok: false,
    line: `${complete} of ${checks.length} coverage checks matched. ${parts.join('; ')}.`,
    short,
    unknown,
    over,
    complete,
  }
}
