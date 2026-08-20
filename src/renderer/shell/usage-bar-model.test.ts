import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  STALE_WINDOW_FRACTION,
  alertReading,
  chipReset,
  formatResetInstant,
  primaryReading,
  readContextReading,
  readUsageReport,
  shortWindowName,
  usageReadout,
  type UsageWindowReading,
} from './usage-bar-model'

/**
 * The rules the usage bar was nearly cancelled for not having.
 *
 * Every case below is one of the three promises made when it was put back on
 * screen: a bar only where both halves are real, "not reported" as a state of
 * its own rather than a zero, and nothing at all from the cached block in
 * `~/.claude.json`. They are asserted here, away from React, because they are
 * decisions rather than markup — and because this project's test setup has no
 * DOM, so a decision that lived inside a component could not be checked at all.
 *
 * The Codex numbers are not invented. They are the record this machine actually
 * holds — `~/.codex/sessions/2026/06/04/rollout-…jsonl`, read back through the
 * running app's own `usage:read` — which is why the expiry case below is the
 * ordinary one rather than a contrived one.
 */

const NOW = Date.parse('2026-08-17T01:00:00.000Z')
const MINUTE = 60_000

function reading(over: Partial<UsageWindowReading> = {}): UsageWindowReading {
  return {
    id: 'claude/system:claude/five-hour',
    account: {
      provider: 'claude',
      id: 'system:claude',
      name: 'Default',
      configDir: '/Users/apple/.claude',
    },
    window: 'five-hour',
    windowMinutes: null,
    label: 'Current session',
    used: { state: 'reported', fraction: 0.05 },
    resets: { state: 'described', text: '4am (Asia/Dubai)' },
    observedAt: NOW,
    reportedAt: NOW - MINUTE,
    source: 'claude-usage-panel',
    ...over,
  }
}

describe('a bar is drawn only when both halves are real', () => {
  it('draws one for a fresh reading with a renewal time', () => {
    const readout = usageReadout(reading(), NOW)
    expect(readout.state).toBe('live')
    expect(readout.bar).toBe(true)
    expect(readout.value).toBe('5%')
    expect(readout.caveat).toBe('resets 4am')
  })

  it('draws one for a percentage with no renewal time, and says nothing about the missing half', () => {
    /*
     * Claude Code prints "You've used 85% of your weekly limit" with no reset
     * clause. This used to withhold the bar and print a sentence explaining the
     * withholding, which is the line Asad read off the copilot page — *"current
     * session 0% of 5 hours. This long description is not required."*
     *
     * The percentage is the proven half and the bar draws exactly it. What is
     * absent is the renewal clause, and it is absent rather than accounted for.
     */
    const readout = usageReadout(
      reading({ used: { state: 'reported', fraction: 0.85 }, resets: { state: 'not-reported' } }),
      NOW,
    )
    expect(readout.state).toBe('no-reset')
    expect(readout.bar).toBe(true)
    expect(readout.percent).toBe(85)
    expect(readout.value).toBe('85%')
    expect(readout.caveat).toBe('no reset time reported')
    // The same facts, in the same order, as every other window — minus the
    // renewal clause the source never gave, and minus any account of its
    // absence. Spoken only: a row with a bar prints its facts line instead.
    expect(readout.detail).toBe('85% used · read just now')
    expect(readout.detail).not.toContain('no bar')
  })

  it('refuses one for a limit named without a figure, keeping the reset it did give', () => {
    const readout = usageReadout(reading({ used: { state: 'not-reported' } }), NOW)
    expect(readout.state).toBe('unmeasured')
    expect(readout.bar).toBe(false)
    expect(readout.value).toBe('Not reported')
    expect(readout.caveat).toBe('resets 4am')
  })

  it('shortens only the chip’s copy of a reset, never the record of it', () => {
    /*
     * `4am (Asia/Dubai)` is what Claude Code printed and it is what the panel
     * and the hover label say. The chip drops the parenthetical because on a
     * one-line bar the timezone is the longest part of the phrase and the least
     * informative — it is the machine's own zone — and capped rather than
     * dropped it drew as `resets 8:50am (…`, an ellipsis where a fact belongs.
     */
    const readout = usageReadout(reading(), NOW)
    expect(readout.caveat).toBe('resets 4am')
    expect(readout.detail).toContain('renews 4am (Asia/Dubai)')
    expect(chipReset('Aug 14 at 2pm (Asia/Dubai)')).toBe('Aug 14 at 2pm')
    // Nothing but a trailing parenthetical is ever removed.
    expect(chipReset('Current week (all models) tomorrow')).toBe('Current week (all models) tomorrow')
    expect(chipReset('(Asia/Dubai)')).toBe('(Asia/Dubai)')
  })
})

describe('nothing reported is not nothing used', () => {
  it('says "Not reported", never 0%', () => {
    const readout = usageReadout(reading({ used: { state: 'not-reported' } }), NOW)
    expect(readout.value).toBe('Not reported')
    expect(readout.percent).toBeNull()
    expect(readout.value).not.toContain('0')
  })

  it('and draws a real zero as a real zero', () => {
    // The other half of the same rule, and the one that proves the first is not
    // just a spelling: a source that says 0% has measured something, and its bar
    // is an empty bar rather than an absent one.
    const readout = usageReadout(reading({ used: { state: 'reported', fraction: 0 } }), NOW)
    expect(readout.state).toBe('live')
    expect(readout.bar).toBe(true)
    expect(readout.value).toBe('0%')
  })

  it('will not read a bare number as a measurement', () => {
    // An older main process, or a payload from anywhere else, sending
    // `used: 0.4` is not this app's `{ state: 'reported' }` — and guessing what
    // it meant is exactly how the zero gets in.
    const report = readUsageReport({
      sessionId: 's',
      assembledAt: NOW,
      reason: null,
      account: null,
      readings: [{ ...reading(), used: 0.4 }],
    })
    expect(report?.readings[0].used).toEqual({ state: 'not-reported' })
  })
})

describe('a window that has rolled over is not a reading', () => {
  /*
   * The real record on this machine: Codex last wrote a rate limit on 4 June,
   * for a 30-day window that reset on 4 July. The number is exact and it is
   * about a period that no longer exists — which is the same failure as the
   * cached block in `~/.claude.json`, arriving by a different route.
   */
  const codex = reading({
    id: 'codex/system:codex/monthly',
    account: {
      provider: 'codex',
      id: 'system:codex',
      name: 'Default (Codex CLI)',
      configDir: '/Users/apple/.codex',
    },
    window: 'monthly',
    windowMinutes: 43200,
    label: '30-day limit',
    used: { state: 'reported', fraction: 0.05 },
    resets: { state: 'at', at: 1783130065000 },
    reportedAt: 1780538073460,
    observedAt: NOW,
    source: 'codex-rollout',
  })

  it('drops the bar and the number', () => {
    const readout = usageReadout(codex, NOW)
    expect(readout.state).toBe('expired')
    expect(readout.bar).toBe(false)
    expect(readout.value).toBe('Not reported')
    expect(readout.caveat).toBe('window has reset')
  })

  it('still says what was last seen, and when, in facts rather than in a sentence', () => {
    /*
     * Dropping the number is not the same as pretending nothing was ever read.
     * What went is the prose around it: the clause explaining that nothing has
     * been reported since, and the source sentence naming Codex. Both were
     * true; neither is something this panel prints any more.
     */
    const readout = usageReadout(codex, NOW)
    expect(readout.detail).toContain('Last 5%')
    expect(readout.detail).toContain('reset ')
    expect(readout.detail).not.toContain('nothing has been reported since')
    expect(readout.detail).not.toContain('Codex')
  })
})

describe('an ageing reading keeps its bar and admits its age', () => {
  it('is live inside a twelfth of its window and aged past it', () => {
    // Twenty-five minutes of five hours. The bar survives, drawn back, because
    // dropping it twenty-five minutes after a /usage run teaches a reader that
    // the feature is broken rather than that the number is old.
    expect(usageReadout(reading({ reportedAt: NOW - 20 * MINUTE }), NOW).state).toBe('live')
    const aged = usageReadout(reading({ reportedAt: NOW - 40 * MINUTE }), NOW)
    expect(aged.state).toBe('aged')
    expect(aged.bar).toBe(true)
    expect(aged.caveat).toBe('read 40m ago')
  })

  it('uses the twelfth the main process uses', () => {
    /*
     * The renderer cannot import `src/main/usage-window.ts` — `tsconfig.web.json`
     * does not include it — so the fraction is restated in the model and pinned
     * here. Two copies that can drift is a bug; two copies where one fails the
     * build when they differ is a boundary.
     */
    const main = readFileSync(join(__dirname, '../../main/usage-window.ts'), 'utf8')
    expect(main).toContain('export const STALE_WINDOW_FRACTION = 1 / 12')
    expect(STALE_WINDOW_FRACTION).toBe(1 / 12)
  })
})

describe('which window is on the bar', () => {
  const week = reading({
    id: 'claude/system:claude/weekly',
    window: 'weekly',
    label: 'Current week (all models)',
    used: { state: 'reported', fraction: 0.92 },
    resets: { state: 'described', text: 'Aug 20 at 2pm (Asia/Dubai)' },
  })

  it('is the shortest one, which is the one he asked for', () => {
    const report = readUsageReport({
      sessionId: 's',
      assembledAt: NOW,
      reason: null,
      account: null,
      readings: [reading(), week],
    })
    expect(shortWindowName(primaryReading(report)!)).toBe('5h')
  })

  it('puts a second window beside it when that one is in trouble', () => {
    // A weekly limit at 92% behind a five-hour bar reading 5% is a screen that
    // says "you are fine" to somebody who is not.
    const report = readUsageReport({
      sessionId: 's',
      assembledAt: NOW,
      reason: null,
      account: null,
      readings: [reading(), week],
    })
    const alert = alertReading(report, primaryReading(report), NOW)
    expect(alert?.short).toBe('Week')
    expect(alert?.value).toBe('92%')
    expect(alert?.level).toBe('critical')
  })

  it('stays quiet when every other window is quiet', () => {
    const report = readUsageReport({
      sessionId: 's',
      assembledAt: NOW,
      reason: null,
      account: null,
      readings: [reading(), { ...week, used: { state: 'reported', fraction: 0.11 } }],
    })
    expect(alertReading(report, primaryReading(report), NOW)).toBeNull()
  })
})

describe('the words', () => {
  it('names a window after its period rather than after either vendor’s word', () => {
    // Claude Code calls the five hours "Current session" and Codex calls it
    // "primary". A reader should not have to learn both to know that one bar is
    // the other bar.
    expect(shortWindowName(reading())).toBe('5h')
    expect(shortWindowName(reading({ window: 'weekly' }))).toBe('Week')
    expect(shortWindowName(reading({ window: 'monthly' }))).toBe('30d')
  })

  it('falls back to the length the source stated for a period it does not know', () => {
    expect(shortWindowName(reading({ window: 'other', windowMinutes: 2880 }))).toBe('2d')
    expect(shortWindowName(reading({ window: 'other', windowMinutes: 90 }))).toBe('90m')
  })

  it('writes a nearby reset as a time and a distant one with its date', () => {
    const soon = formatResetInstant(NOW + 3 * 3_600_000, NOW)
    const later = formatResetInstant(NOW + 20 * 24 * 3_600_000, NOW)
    expect(soon).not.toMatch(/[A-Za-z]{3,}/)
    expect(later).toMatch(/[A-Za-z]{3}/)
  })
})

describe('the source this feature refuses to use', () => {
  it('is not read anywhere in the renderer', () => {
    /*
     * `~/.claude.json` carries a `cachedUsageUtilization` block with exactly the
     * fields a bar wants. Measured on this machine it was 21.3 hours stale and
     * described a window that had ended 17 hours earlier, and it did not move
     * across a day of use. It has been rediscovered and rejected more than once,
     * so the rejection is now a test rather than a paragraph.
     */
    const files = ['usage-bar-model.ts', 'useUsageBar.ts', 'UsageBar.tsx'].map((name) =>
      readFileSync(join(__dirname, name), 'utf8'),
    )
    // Named in prose, in every file that could be tempted by it, and read in
    // none: a property access or a bracket lookup is the thing being forbidden,
    // not the word. A ban on the word would only delete the warning.
    for (const source of files) {
      expect(source).not.toMatch(/[.[]\s*['"]?cachedUsageUtilization/)
    }
    expect(files.some((source) => source.includes('cachedUsageUtilization'))).toBe(true)
  })
})

/**
 * The context reading, as it comes off the bridge.
 *
 * The renderer cannot import `src/main/context-window.ts` — `tsconfig.web.json`
 * does not include `src/main`, which is the same wall every other shape in this
 * module is mirrored across — so the payload is parsed defensively here and the
 * refusals are the interesting part. A bar drawn from a half-read payload is
 * worse than a bar with nothing on it, because only one of the two is honest
 * about what it knows.
 */
describe('reading a context payload', () => {
  const PAYLOAD = {
    provider: 'claude',
    state: 'ok',
    tokens: 154_057,
    window: 1_000_000,
    percent: 15.4057,
    windowBasis: 'model',
    model: 'claude-opus-5',
    modelLabel: 'Opus 5',
    source: {
      path: '/Users/apple/.claude/projects/-Users-apple-ClaudeAsad/92b0e6db.jsonl',
      sessionId: '92b0e6db-0f92-4cbb-bae9-0aa67f9a6868',
      chosen: 'inferred',
      rivals: 2,
    },
    reportedAt: 1_000,
    observedAt: 2_000,
    detail: '154,057 of 1,000,000 tokens — 15% of the context window.',
  }

  it('flattens the source onto the reading, and keeps the path in the main process', () => {
    const reading = readContextReading(PAYLOAD)
    expect(reading).toMatchObject({
      provider: 'claude',
      state: 'ok',
      tokens: 154_057,
      window: 1_000_000,
      sessionId: '92b0e6db-0f92-4cbb-bae9-0aa67f9a6868',
      chosen: 'inferred',
      rivals: 2,
    })
    // The file that was read is a debugging fact, not something to draw.
    expect(JSON.stringify(reading)).not.toContain('/Users/apple/.claude')
    // And the friendly name arrives beside the id rather than being derived a
    // second time here: `labelModelId` is the main process's table and the model
    // chip on the same bar reads through it, so there is one answer to what
    // `claude-opus-5` is called.
    expect(reading?.modelLabel).toBe('Opus 5')
    // A build whose main process predates the field says nothing rather than
    // guessing — the panel falls back to the id it does have.
    const older = readContextReading({ ...PAYLOAD, modelLabel: undefined })
    expect(older?.modelLabel).toBeNull()
    expect(older?.model).toBe('claude-opus-5')
  })

  it('refuses a payload with no state, which is what an older build answers', () => {
    expect(readContextReading(undefined)).toBeNull()
    expect(readContextReading({})).toBeNull()
    expect(readContextReading({ state: 'fine' })).toBeNull()
  })

  it('keeps null a null rather than turning it into zero', () => {
    /*
     * The distinction the whole feature rests on. `?? 0` here would draw an
     * empty meter for an agent that has never written a token count down, and an
     * empty meter and an absent one are opposite claims.
     */
    const blank = readContextReading({
      provider: 'gemini',
      state: 'not-reported',
      tokens: null,
      window: null,
      percent: null,
      detail: 'Gemini does not record how full its context window is.',
    })
    expect(blank).toMatchObject({ tokens: null, window: null, percent: null, sessionId: null })
  })

  it('dates an unstamped figure by the look that found it, not by “just now”', () => {
    // The same conservative reading of an absence `readReading` takes above.
    const reading = readContextReading({ ...PAYLOAD, reportedAt: 0 })
    expect(reading?.reportedAt).toBe(2_000)
  })
})
