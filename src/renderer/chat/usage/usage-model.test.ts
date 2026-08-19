import { describe, expect, it } from 'vitest'
import type { PlanLimit, SessionSummary, TokenUsage, UsageRefreshOutcome } from './types'
import {
  contextReadout,
  describeAge,
  formatPercent,
  formatTokens,
  isStale,
  levelOfPercent,
  pickSession,
  planLabel,
  readPlanSnapshot,
  readProjectSummary,
  refreshOutcomeMessage,
  sameProject,
  startOfDay,
  tokenTotals,
  usageToday,
} from './usage-model'

const DAY = 24 * 60 * 60 * 1000
const NOW = Date.parse('2026-08-12T15:00:00.000Z')

function usage(overrides: Partial<TokenUsage> = {}): TokenUsage {
  return { input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, ...overrides }
}

function session(overrides: Partial<SessionSummary> = {}): SessionSummary {
  return {
    sessionId: 's1',
    transcriptPath: '/t/s1.jsonl',
    cwd: '/p',
    models: ['claude-opus-5'],
    requests: 4,
    usage: usage({ output: 1000 }),
    context: null,
    warnings: [],
    preContextTokens: 0,
    compactions: 0,
    sidechainRequests: 0,
    startedAt: NOW,
    lastActivityAt: NOW,
    ...overrides,
  }
}

describe('reading what the bridge sent', () => {
  it('refuses a payload that is not a project summary', () => {
    expect(readProjectSummary(null)).toBeNull()
    expect(readProjectSummary('nope')).toBeNull()
    expect(readProjectSummary({ cwd: '/p' })).toBeNull()
  })

  it('keeps a missing context as null rather than as zero', () => {
    // "0% of the context window" is a claim; the absence of a first request is
    // not the same as an empty window.
    const summary = readProjectSummary({ cwd: '/p', sessions: [{ sessionId: 'a' }] })
    expect(summary?.sessions[0].context).toBeNull()
  })

  it('reads the fields the strip depends on', () => {
    const summary = readProjectSummary({
      cwd: '/p',
      activeSessionId: 'a',
      scanning: true,
      sessions: [
        {
          sessionId: 'a',
          transcriptPath: '/t/a.jsonl',
          requests: 3,
          compactions: 2,
          usage: { input: 10, output: 5, cacheRead: 900, cacheWrite5m: 3, cacheWrite1h: 7 },
          context: { tokens: 10, window: 100, percent: 10, remaining: 90, level: 'ok' },
          warnings: [{ kind: 'context-window', level: 'warning', percent: 72, message: 'Context 72% full.' }],
        },
      ],
    })
    expect(summary?.scanning).toBe(true)
    expect(summary?.sessions[0].usage.cacheRead).toBe(900)
    expect(summary?.sessions[0].compactions).toBe(2)
    expect(summary?.sessions[0].warnings[0].message).toBe('Context 72% full.')
  })

  it('keeps a plan limit with no number as null, never as 0%', () => {
    const snapshot = readPlanSnapshot({
      sessionId: 's',
      available: true,
      source: 'warning',
      limits: [{ id: 'week', label: 'weekly limit', scope: 'week', percent: null, resetsAt: null }],
    })
    expect(snapshot?.limits[0].percent).toBeNull()
  })
})

describe('picking the session the strip is about', () => {
  const summary = readProjectSummary({
    cwd: '/p',
    activeSessionId: 'live',
    sessions: [
      { sessionId: 'live', transcriptPath: '/t/live.jsonl' },
      { sessionId: 'old', transcriptPath: '/t/old.jsonl' },
    ],
  })

  it('prefers the transcript actually open', () => {
    // Reading back an older session must show that session's numbers, not the
    // live one's.
    expect(pickSession(summary, { transcriptPath: '/t/old.jsonl' })?.sessionId).toBe('old')
  })

  it('falls back to the active session, then to the newest', () => {
    // Only for a caller that expressed no preference. `UsageStrip` is the one
    // that must not take this answer for a session of its own that has written
    // nothing yet — it guards on `scoped` before ever calling in, because from
    // here "no path" and "a session with no transcript" are the same argument.
    expect(pickSession(summary)?.sessionId).toBe('live')
    expect(pickSession(summary, { transcriptPath: '/t/gone.jsonl' })?.sessionId).toBe('live')
  })

  it('has nothing to say without a summary', () => {
    expect(pickSession(null)).toBeNull()
  })
})

describe('today’s usage', () => {
  const dayStart = startOfDay(NOW)

  it('counts only sessions active today', () => {
    const summary = {
      cwd: '/p',
      sessions: [
        session({ sessionId: 'a', lastActivityAt: NOW }),
        session({ sessionId: 'b', lastActivityAt: dayStart - 1, startedAt: dayStart - DAY }),
      ],
      usage: usage(),
      usageByModel: {},
      requests: 8,
      activeSessionId: 'a',
      scanning: false,
      truncated: false,
      updatedAt: NOW,
    }
    const today = usageToday(summary, NOW)
    expect(today.tokens).toBe(1000)
    expect(today.sessions).toBe(1)
  })

  it('flags sessions that began before today, because they are counted whole', () => {
    const summary = {
      cwd: '/p',
      sessions: [session({ startedAt: dayStart - DAY, lastActivityAt: NOW })],
      usage: usage(),
      usageByModel: {},
      requests: 4,
      activeSessionId: null,
      scanning: false,
      truncated: false,
      updatedAt: NOW,
    }
    expect(usageToday(summary, NOW).carriedOver).toBe(1)
  })

  it('is zero, not a crash, with nothing to add up', () => {
    expect(usageToday(null, NOW)).toEqual({ tokens: 0, sessions: 0, carriedOver: 0 })
  })
})

describe('token split', () => {
  it('keeps cache reads and writes beside fresh input rather than folded in', () => {
    // `input` is only the uncached remainder: on a warm session it is a handful
    // of tokens against a 900k prompt, and the cache columns are the bill.
    const totals = tokenTotals(usage({ input: 12, output: 400, cacheRead: 900_000, cacheWrite5m: 1000, cacheWrite1h: 2000 }))
    expect(totals).toEqual({
      input: 12,
      output: 400,
      cacheRead: 900_000,
      cacheWrite: 3000,
      prompt: 903_012,
      total: 903_412,
    })
  })
})

describe('context readout', () => {
  it('reports occupancy over 100 honestly and clamps only the bar', () => {
    const readout = contextReadout({ tokens: 208_000, window: 200_000, percent: 104, remaining: 0, level: 'critical' })
    expect(readout?.width).toBe(100)
    expect(readout?.label).toContain('104%')
    expect(readout?.over).toBe(true)
    expect(readout?.title).toContain('over the limit')
  })

  it('says nothing before the first request', () => {
    expect(contextReadout(null)).toBeNull()
  })

  it('never rounds a live window down to nothing', () => {
    expect(formatPercent(0.4)).toBe('<1%')
    expect(formatPercent(71.4)).toBe('71%')
  })
})

describe('formatting', () => {
  it('has a billion tier, which long sessions reach on cache reads alone', () => {
    expect(formatTokens(1_500_000_000)).toBe('1.5B')
    expect(formatTokens(903_012)).toBe('903k')
    expect(formatTokens(1_050_000)).toBe('1.05M')
  })
})

describe('plan limits', () => {
  const limit = (over: Partial<PlanLimit>): PlanLimit => ({
    id: 'week',
    label: 'Current week (all models)',
    scope: 'week',
    percent: 80,
    resetsAt: 'Aug 14 at 2pm',
    ...over,
  })

  it('shortens the CLI labels without inventing new ones', () => {
    expect(planLabel(limit({}))).toBe('Week')
    expect(planLabel(limit({ id: 'session' }))).toBe('Session')
    expect(planLabel(limit({ id: 'week:opus' }))).toBe('Week (Opus)')
    expect(planLabel(limit({ id: 'other:usage-credit', label: 'usage credit limit' }))).toBe('usage credit limit')
  })

  it('uses the context meter thresholds rather than making plan-specific ones up', () => {
    expect(levelOfPercent(69)).toBe('ok')
    expect(levelOfPercent(70)).toBe('warning')
    expect(levelOfPercent(100)).toBe('critical')
    expect(levelOfPercent(null)).toBe('ok')
  })

  it('ages a reading, because a plan limit moves under it', () => {
    expect(describeAge(NOW - 30_000, NOW)).toBe('just now')
    expect(describeAge(NOW - 20 * 60_000, NOW)).toBe('20m ago')
    expect(isStale(NOW - 20 * 60_000, NOW)).toBe(true)
    expect(isStale(NOW - 60_000, NOW)).toBe(false)
    expect(describeAge(0, NOW)).toBe('')
  })
})

describe('project identity', () => {
  it('treats a trailing slash as the same project and an empty path as none', () => {
    expect(sameProject('/a/b/', '/a/b')).toBe(true)
    expect(sameProject('', '')).toBe(false)
  })
})

describe('what a refresh is allowed to say', () => {
  it('does not call an account with no subscription a missing report', () => {
    const said = refreshOutcomeMessage('no-limits')
    /*
     * The wording is the point of this one, so it is asserted rather than left
     * to a reviewer. An account billed through the Claude API has no rolling
     * subscription window at all — there is nothing late, nothing coming, and
     * nothing anybody can do about it — so a sentence in the vocabulary of a
     * failed reading would be describing an event that did not happen.
     */
    expect(said).toContain('no subscription limits')
    expect(said).not.toMatch(/not reported|could not|failed|did not/i)
    // And the remembered form of the same fact says the same thing, because it
    // is the same fact — one read from an account this app asked once already.
    expect(refreshOutcomeMessage('settled')).toBe(said)
  })

  it('never claims a session was typed into, in any outcome', () => {
    /*
     * The sentence-level half of the 2026-08-18 change, and the one a rewrite
     * would silently undo. Every one of these used to be the aftermath of
     * `/usage` going into somebody's prompt — *"clear the prompt"*, *"press Esc
     * in the session"*, *"Claude Code did not show its usage panel"* — and not
     * one of them is true of a refresh any more. A build that starts saying so
     * again is a build that has started doing it again.
     */
    const outcomes: UsageRefreshOutcome[] = [
      'ok',
      'cached',
      'no-limits',
      'settled',
      'signed-out',
      'no-binary',
      'unreadable',
      'unwatched',
    ]
    for (const outcome of outcomes) {
      expect(refreshOutcomeMessage(outcome)).not.toMatch(/prompt|panel|Esc|typed?\b/i)
    }
  })

  it('says what the two free paths cost, which is nothing', () => {
    // The two that never start a process, and the reason the bar can be honest
    // about being cheap: one is a file the CLI already wrote, the other is this
    // app's own process rather than the reader's session.
    expect(refreshOutcomeMessage('cached')).toContain('nothing was started')
    expect(refreshOutcomeMessage('ok')).toContain('no session was touched')
  })
})
