import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  compareCoverage,
  coverageSummary,
  readCoverage,
  readTotal,
  recordCoverage,
  statedTotal,
} from './browser-asset-coverage'

/**
 * The 7%.
 *
 * A page said *"showing 12 of 340 units"* and the run shipped what it had. The
 * arithmetic that would have caught it is trivial; what is not trivial is
 * refusing to call a run complete when the total could not be read, which is the
 * case most of these tests are about.
 */

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'asset-coverage-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('reading a number', () => {
  it('reads a plain count and a grouped one', () => {
    expect(readTotal('340')).toBe(340)
    expect(readTotal('16,498')).toBe(16498)
    expect(readTotal('16.498')).toBe(16498)
    expect(readTotal('1 234')).toBe(1234)
  })

  it('refuses a number it cannot read as a count, rather than guessing', () => {
    // `1.23` is a decimal in one locale and nothing in the other; a total this
    // cannot read has to arrive as "unknown", which is loud.
    expect(readTotal('1.23')).toBeNull()
    expect(readTotal('12.3456')).toBeNull()
    expect(readTotal('1,234.567')).toBeNull()
    expect(readTotal('')).toBeNull()
  })
})

describe('the page’s own total', () => {
  it('reads it with the caller’s pattern', () => {
    const read = statedTotal('Showing 12 of 340 units', { pattern: 'of\\s+([\\d,]+)\\s+units' })
    expect(read.total).toBe(340)
    expect(read.matched).toBe('of 340 units')
  })

  it('falls back to generic shapes when no pattern was given', () => {
    expect(statedTotal('Showing 12 of 340 units').total).toBe(340)
    expect(statedTotal('16,498 results').total).toBe(16498)
  })

  it('answers null when two generic shapes disagree, rather than picking one', () => {
    /*
     * The rule that stops the fallback being a guess. A page carrying both
     * *"of 340"* and *"1,200 results"* is stating two different things and this
     * cannot know which bounds the run.
     */
    const read = statedTotal('Page 2 of 340 — 1,200 results in total')
    expect(read.total).toBeNull()
    expect(read.reason).toContain('more than one total')
  })

  it('says why when nothing reads as a total', () => {
    const read = statedTotal('A quiet page with no counts on it.')
    expect(read.total).toBeNull()
    expect(read.reason).toContain('Give a pattern')
  })

  it('does not let a broken pattern take the check down', () => {
    const read = statedTotal('of 340', { pattern: '([' })
    expect(read.total).toBeNull()
    expect(read.reason).toContain('not a valid expression')
  })

  it('never lets the caller’s pattern be overruled by a generic one', () => {
    // The caller has looked at the page; the fallbacks have not.
    const read = statedTotal('Showing 12 of 340 units — 99 results', {
      pattern: 'of\\s+([\\d,]+)',
    })
    expect(read.total).toBe(340)
  })
})

describe('the verdict', () => {
  it('is short, loudly, with the percentage he actually shipped', () => {
    const check = compareCoverage({ stated: 340, captured: 24, what: 'units', now: 1 })
    expect(check.verdict).toBe('short')
    expect(check.missing).toBe(316)
    expect(check.loud).toBe(true)
    expect(check.line).toContain('7%')
    expect(check.line).toContain('This is not complete')
  })

  it('is unknown, and loud, when the page never stated a total', () => {
    const check = compareCoverage({ stated: null, captured: 12, now: 1 })
    expect(check.verdict).toBe('unknown')
    expect(check.loud).toBe(true)
    expect(check.line).toContain('cannot be called complete')
  })

  it('is over, and loud, when more was captured than the page says exists', () => {
    const check = compareCoverage({ stated: 340, captured: 400, now: 1 })
    expect(check.verdict).toBe('over')
    expect(check.loud).toBe(true)
    expect(check.line).toContain('counted twice')
  })

  it('is complete, and quiet, only when the two agree', () => {
    const check = compareCoverage({ stated: 340, captured: 340, now: 1 })
    expect(check.verdict).toBe('complete')
    expect(check.loud).toBe(false)
  })

  it('takes a tolerance as a count, because a percentage of 340 is seventeen floor plans', () => {
    expect(compareCoverage({ stated: 340, captured: 339, tolerance: 1, now: 1 }).verdict).toBe('complete')
    expect(compareCoverage({ stated: 340, captured: 338, tolerance: 1, now: 1 }).verdict).toBe('short')
  })
})

describe('the record', () => {
  it('writes each check into the run and reads them back', () => {
    const path = join(dir, 'run', 'coverage.jsonl')
    expect(recordCoverage(path, compareCoverage({ stated: 340, captured: 24, now: 1 }))).toBe(true)
    expect(recordCoverage(path, compareCoverage({ stated: 10, captured: 10, now: 2 }))).toBe(true)
    const back = readCoverage(path)
    expect(back.map((check) => check.verdict)).toEqual(['short', 'complete'])
  })

  it('summarises a run that came up short with the total that is missing', () => {
    const summary = coverageSummary([
      compareCoverage({ stated: 340, captured: 24, now: 1 }),
      compareCoverage({ stated: 100, captured: 100, now: 2 }),
      compareCoverage({ stated: null, captured: 5, now: 3 }),
    ])
    expect(summary.ok).toBe(false)
    expect(summary.short).toBe(1)
    expect(summary.unknown).toBe(1)
    expect(summary.line).toContain('316 items')
    expect(summary.line).toContain('cannot be called complete')
  })

  it('refuses to call a run with no checks a clean run', () => {
    /*
     * "No problems found" and "nobody looked" are the two things this module
     * exists to keep apart.
     */
    const summary = coverageSummary([])
    expect(summary.ok).toBe(false)
    expect(summary.line).toContain('No coverage check was made')
  })

  it('is ok only when every check matched', () => {
    const summary = coverageSummary([compareCoverage({ stated: 5, captured: 5, now: 1 })])
    expect(summary.ok).toBe(true)
  })
})
