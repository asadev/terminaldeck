import { describe, expect, it } from 'vitest'
import type { UsageReport, UsageWindowReading } from './usage-bar-model'
import { extraAlert, leadIsLive, usageLines } from './usage-stack'

/**
 * Which window ends up on which line, and what happens when one is missing.
 *
 * The whole point of this module is that the answer does **not** depend on what
 * was reported — the five-hour window is the top line whether or not anything
 * has said a word about it, and the weekly window is the bottom line on the same
 * terms. The bar Asad was looking at when he asked for this did the opposite: it
 * drew whichever window happened to be shortest among those that had reported,
 * so with no five-hour figure the weekly one was promoted into its place and the
 * single element on the bar read `Week 81% resets Aug 21 at 2pm`.
 *
 * So most of what is asserted here is a *shape*, not a value.
 */

const NOW = Date.parse('2026-08-17T01:00:00.000Z')
const MINUTE = 60_000

function reading(over: Partial<UsageWindowReading> = {}): UsageWindowReading {
  return {
    id: 'claude/system/five-hour',
    account: { provider: 'claude', id: 'system', name: 'Default', configDir: '/Users/apple/.claude' },
    window: 'five-hour',
    windowMinutes: null,
    label: 'Current session',
    used: { state: 'reported', fraction: 0.18 },
    resets: { state: 'described', text: '4am (Asia/Dubai)' },
    observedAt: NOW,
    reportedAt: NOW - MINUTE,
    source: 'claude-usage-panel',
    ...over,
  }
}

const WEEK = reading({
  id: 'claude/system/weekly',
  window: 'weekly',
  label: 'Current week (all models)',
  used: { state: 'reported', fraction: 0.55 },
  resets: { state: 'described', text: 'Aug 21 at 2pm (Asia/Dubai)' },
})

function report(readings: UsageWindowReading[], reason: string | null = null): UsageReport {
  return { sessionId: 'pty-1', readings, reason, account: readings[0]?.account ?? null, assembledAt: NOW }
}

describe('the two fixed lines', () => {
  it('puts the five-hour window above the weekly one', () => {
    // His words: *"Upper one for five hours and down one for weekly."* Order is
    // the assertion — it is the only thing that tells the two apart once the
    // weekly line has given up its name.
    const lines = usageLines(report([WEEK, reading()]), NOW)
    expect(lines.map((line) => line.slot)).toEqual(['five-hour', 'weekly'])
  })

  it('keeps the order even when the report arrives in the other one', () => {
    // The main process sorts shortest-window-first, and this must not depend on
    // that continuing to be true: a sort order is a convention, and two files
    // agreeing about a convention is how a bar comes to draw the wrong window.
    const lines = usageLines(report([reading(), WEEK]), NOW)
    expect(lines.map((line) => line.slot)).toEqual(['five-hour', 'weekly'])
  })

  it('names the five-hour line and leaves the weekly one unnamed', () => {
    // *"For weekly it will show the 55% and no need to say week here."*
    const [five, week] = usageLines(report([reading(), WEEK]), NOW)
    expect(five.name).toBe('5h')
    expect(week.name).toBe('')
  })

  it('puts the renewal time on the five-hour line only', () => {
    // *"…and no even need to show the dates. For the five-hour window it will
    // also show the percentage and it will show the time of reset."*
    const [five, week] = usageLines(report([reading(), WEEK]), NOW)
    expect(five.showReset).toBe(true)
    expect(week.showReset).toBe(false)
  })

  it('still draws both lines when only one window has reported', () => {
    /*
     * The exact screen he was looking at: nothing for the five-hour window and
     * 81% for the week. The old bar promoted the weekly reading into the one
     * slot it had and printed `Week 81% resets Aug 21 at 2pm`; this keeps the
     * empty five-hour line, so the reader can see which window is silent rather
     * than having to notice that the label changed.
     */
    const lines = usageLines(report([{ ...WEEK, used: { state: 'reported', fraction: 0.81 } }]), NOW)
    expect(lines.map((line) => line.slot)).toEqual(['five-hour', 'weekly'])
    expect(lines[0].readout).toBeNull()
    expect(lines[1].readout?.value).toBe('81%')
  })
})

describe('an agent that reports neither of those windows', () => {
  it('gets one line carrying what it does report', () => {
    /*
     * Codex records a 30-day limit and nothing else. Two empty slots labelled
     * for windows it can never fill would be two dead readings on the bar of a
     * session that can do nothing about either — *"they should not see something
     * they cannot do something about it."*
     */
    const monthly = reading({
      id: 'codex/system/monthly',
      window: 'monthly',
      windowMinutes: 43200,
      label: '30-day limit',
      used: { state: 'reported', fraction: 0.05 },
      resets: { state: 'at', at: NOW + 6 * 24 * 3_600_000 },
      source: 'codex-rollout',
    })
    const lines = usageLines(report([monthly]), NOW)
    expect(lines).toHaveLength(1)
    expect(lines[0].slot).toBe('single')
    expect(lines[0].name).toBe('30d')
    expect(lines[0].showReset).toBe(true)
  })

  it('and a session with nothing at all still gets a line to say so on', () => {
    // Drawing nothing would make "not reported yet" and "this feature is not
    // installed" look identical, which is the distinction the whole feature is
    // arranged around.
    const lines = usageLines(report([], 'Nothing yet.'), NOW)
    expect(lines).toHaveLength(1)
    expect(lines[0].name).toBe('Usage')
    expect(lines[0].readout).toBeNull()
  })

  it('and so does a session whose report has not arrived', () => {
    expect(usageLines(null, NOW)).toHaveLength(1)
  })
})

describe('a window that is on neither line and is near its limit', () => {
  it('comes back as an alert', () => {
    /*
     * Claude Code prints `Current week (all models)` and `Current week (Opus)`.
     * Only the first can have the weekly line, so without this the second would
     * leave the bar altogether — a limit at 97% off screen, which is the
     * confidently-wrong reading this feature was nearly cancelled for twice.
     */
    const opus = reading({
      id: 'claude/system/weekly-opus',
      window: 'other',
      windowMinutes: 10080,
      label: 'Current week (Opus)',
      used: { state: 'reported', fraction: 0.97 },
    })
    const readings = [reading(), WEEK, opus]
    const lines = usageLines(report(readings), NOW)
    expect(extraAlert(report(readings), lines, NOW)?.value).toBe('97%')
  })

  it('says nothing when every undrawn window is comfortable', () => {
    const quiet = reading({ id: 'x', window: 'other', windowMinutes: 10080, used: { state: 'reported', fraction: 0.1 } })
    const readings = [reading(), WEEK, quiet]
    expect(extraAlert(report(readings), usageLines(report(readings), NOW), NOW)).toBeNull()
  })

  it('never repeats a window that already has a line', () => {
    // The five-hour window at 99% is alarming and is already the top line. An
    // alert repeating it would be the same fact twice on a control 40 pixels
    // tall — the "one fact printed twice" this app's account chip was corrected
    // for.
    const readings = [reading({ used: { state: 'reported', fraction: 0.99 } }), WEEK]
    expect(extraAlert(report(readings), usageLines(report(readings), NOW), NOW)).toBeNull()
  })
})

describe('whether the leading window needs fetching', () => {
  it('is live only when the figure is fresh', () => {
    expect(leadIsLive(usageLines(report([reading(), WEEK]), NOW))).toBe(true)
  })

  it('is not live when nothing has been reported', () => {
    expect(leadIsLive(usageLines(report([]), NOW))).toBe(false)
  })

  it('is not live for a reading that has aged past a twelfth of its window', () => {
    /*
     * Aged readings are still *drawn* — dropping the bar twenty-five minutes
     * after a `/usage` run teaches people the feature is broken. They are simply
     * not a reason to skip the fetch that would replace them, which is the whole
     * of what this answer is used for.
     */
    const stale = usageLines(report([reading({ reportedAt: NOW - 40 * MINUTE })]), NOW)
    expect(stale[0].readout?.state).toBe('aged')
    expect(leadIsLive(stale)).toBe(false)
  })

  it('is not live for a window that has already reset', () => {
    const gone = usageLines(
      report([reading({ resets: { state: 'at', at: NOW - 60 * MINUTE } })]),
      NOW,
    )
    expect(leadIsLive(gone)).toBe(false)
  })
})
