import { describe, expect, it } from 'vitest'
import {
  fractionFromPercent,
  isDrawable,
  nominalWindowMinutes,
  readingId,
  resetAtEpoch,
  resetDescribed,
  sortReadings,
  STALE_WINDOW_FRACTION,
  usageFreshness,
  usageReport,
  windowFromMinutes,
  type UsageAccountRef,
  type UsageWindowReading,
} from './usage-window'

const account: UsageAccountRef = {
  provider: 'codex',
  id: 'system:codex',
  name: 'Default (Codex)',
  configDir: '/Users/apple/.codex',
}

function reading(patch: Partial<UsageWindowReading> = {}): UsageWindowReading {
  return {
    id: 'codex/system:codex/five-hour',
    account,
    window: 'five-hour',
    windowMinutes: 300,
    label: '5-hour limit',
    used: { state: 'reported', fraction: 0.33 },
    resets: { state: 'at', at: 1_777_519_084_000 },
    observedAt: 1_777_519_000_000,
    reportedAt: 1_777_518_500_000,
    source: 'codex-rollout',
    ...patch,
  }
}

/*
 * The rule the whole feature turns on. A percentage that was never reported
 * must not become a zero anywhere along the way — the cached block in
 * `~/.claude.json` looked exactly like a real reading and was not one.
 */
describe('unknown is not zero', () => {
  it('reports nothing for a percentage that was never given', () => {
    expect(fractionFromPercent(null)).toEqual({ state: 'not-reported' })
    expect(fractionFromPercent(undefined)).toEqual({ state: 'not-reported' })
    expect(fractionFromPercent(Number.NaN)).toEqual({ state: 'not-reported' })
  })

  it('keeps a genuine zero as a reported zero', () => {
    expect(fractionFromPercent(0)).toEqual({ state: 'reported', fraction: 0 })
  })

  it('never lets the two share a representation', () => {
    expect(fractionFromPercent(0)).not.toEqual(fractionFromPercent(null))
  })

  it('carries an exhausted limit through and refuses a mis-parse', () => {
    expect(fractionFromPercent(100)).toEqual({ state: 'reported', fraction: 1 })
    expect(fractionFromPercent(120)).toEqual({ state: 'reported', fraction: 1.2 })
    expect(fractionFromPercent(4000)).toEqual({ state: 'not-reported' })
    expect(fractionFromPercent(-1)).toEqual({ state: 'not-reported' })
  })

  it('refuses to draw a bar from an amount nobody reported', () => {
    expect(isDrawable(reading({ used: { state: 'not-reported' } }), reading().observedAt)).toBe(false)
  })
})

describe('reset times', () => {
  it('reads the seconds Codex writes as an instant in milliseconds', () => {
    // 1777519084 is 2026-04-30T05:58:04Z, eight minutes after the rollout that
    // carried it — checked against that file's own name.
    expect(resetAtEpoch(1_777_519_084)).toEqual({ state: 'at', at: 1_777_519_084_000 })
  })

  it('leaves a value already in milliseconds alone', () => {
    expect(resetAtEpoch(1_777_519_084_000)).toEqual({ state: 'at', at: 1_777_519_084_000 })
  })

  it('reports nothing rather than 1970 for a missing reset', () => {
    expect(resetAtEpoch(null)).toEqual({ state: 'not-reported' })
    expect(resetAtEpoch(0)).toEqual({ state: 'not-reported' })
  })

  it("keeps Claude's wording rather than guessing an instant from it", () => {
    expect(resetDescribed('Aug 14 at 2pm (Asia/Dubai)')).toEqual({
      state: 'described',
      text: 'Aug 14 at 2pm (Asia/Dubai)',
    })
    expect(resetDescribed('   ')).toEqual({ state: 'not-reported' })
  })
})

describe('classifying a window by its stated length', () => {
  it('names the three lengths seen in real rollouts', () => {
    expect(windowFromMinutes(300)).toBe('five-hour')
    expect(windowFromMinutes(10080)).toBe('weekly')
    expect(windowFromMinutes(43200)).toBe('monthly')
  })

  it('refuses to round an unfamiliar length into a familiar bucket', () => {
    expect(windowFromMinutes(360)).toBe('other')
    expect(windowFromMinutes(null)).toBe('other')
  })

  it('has no nominal length for a window it could not classify', () => {
    expect(nominalWindowMinutes('other')).toBeNull()
    expect(nominalWindowMinutes('five-hour')).toBe(300)
  })
})

describe('freshness', () => {
  const now = 2_000_000_000_000

  it('ages a reading by when the source produced it, not by when we looked', () => {
    const fresh = usageFreshness(
      reading({ reportedAt: now - 60_000, observedAt: now, resets: { state: 'not-reported' } }),
      now,
    )
    expect(fresh.ageMs).toBe(60_000)
    expect(fresh.stale).toBe(false)
  })

  it('calls a five-hour reading stale once a twelfth of the window has passed', () => {
    const limit = 300 * 60_000 * STALE_WINDOW_FRACTION
    const at = (age: number) =>
      usageFreshness(reading({ reportedAt: now - age, resets: { state: 'not-reported' } }), now)
    expect(at(limit - 1_000).stale).toBe(false)
    expect(at(limit + 1_000).stale).toBe(true)
  })

  it('holds a weekly reading fresh far longer than a five-hour one', () => {
    const age = 3 * 60 * 60_000
    const weekly = usageFreshness(
      reading({ window: 'weekly', windowMinutes: 10080, reportedAt: now - age, resets: { state: 'not-reported' } }),
      now,
    )
    expect(weekly.stale).toBe(false)
  })

  /*
   * The `~/.claude.json` failure, reproduced: a percentage for a window that
   * ended seventeen hours ago reads as current unless something checks.
   */
  it('marks a reading whose window has already rolled over as expired', () => {
    const expired = usageFreshness(
      reading({ reportedAt: now - 21 * 60 * 60_000, resets: { state: 'at', at: now - 17 * 60 * 60_000 } }),
      now,
    )
    expect(expired.expired).toBe(true)
    expect(isDrawable(reading({ resets: { state: 'at', at: now - 1 } }), now)).toBe(false)
  })

  it('does not claim a described reset has expired, because it cannot know', () => {
    const fresh = usageFreshness(
      reading({ reportedAt: now - 1_000, resets: { state: 'described', text: '4am (Asia/Dubai)' } }),
      now,
    )
    expect(fresh.expired).toBe(false)
  })

  it('hands over the age bare for a window whose length nobody stated', () => {
    const fresh = usageFreshness(
      reading({ window: 'other', windowMinutes: null, reportedAt: now - 86_400_000, resets: { state: 'not-reported' } }),
      now,
    )
    expect(fresh.ageMs).toBe(86_400_000)
    expect(fresh.stale).toBe(false)
  })
})

describe('assembling a report', () => {
  it('carries a reason exactly when there is nothing to show', () => {
    expect(usageReport('s1', [], 'nothing yet').reason).toBe('nothing yet')
    expect(usageReport('s1', [reading()], 'nothing yet').reason).toBeNull()
  })

  it('puts the shortest window first, which is the one that moves', () => {
    const ordered = sortReadings([
      reading({ id: 'a', window: 'weekly' }),
      reading({ id: 'b', window: 'five-hour' }),
      reading({ id: 'c', window: 'monthly' }),
    ])
    expect(ordered.map((entry) => entry.window)).toEqual(['five-hour', 'weekly', 'monthly'])
  })

  it('keys a reading on its account so two logins cannot collide', () => {
    const other: UsageAccountRef = { ...account, id: 'work', configDir: '/tmp/work' }
    expect(readingId(account, 'five-hour')).not.toBe(readingId(other, 'five-hour'))
  })

  it('keeps a model-scoped weekly limit apart from the plain one', () => {
    expect(readingId(account, 'weekly', 'opus')).not.toBe(readingId(account, 'weekly'))
  })
})
