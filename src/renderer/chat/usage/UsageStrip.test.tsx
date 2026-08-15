import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { UsageStripView } from './UsageStrip'
import type { PlanLimitSnapshot, SessionSummary, TokenUsage } from './types'

/**
 * No DOM in this project's test setup, so these render to static markup. That
 * is enough for what matters here: the strip's whole job is to say true things,
 * and every rule about what it says or refuses to say is visible in the markup.
 */

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
    requests: 12,
    usage: usage({ input: 1200, output: 3400, cacheRead: 1_200_000, cacheWrite1h: 88_000 }),
    cost: {
      cost: { input: 0.01, output: 0.05, cacheWrite: 0.7, cacheRead: 0.07, total: 0.83 },
      byModel: {},
      unpricedModels: [],
      usedLegacyRate: false,
    },
    context: { tokens: 142_000, window: 200_000, percent: 71, remaining: 58_000, level: 'warning' },
    warnings: [{ kind: 'context-window', level: 'warning', percent: 71, message: 'Context 71% full.' }],
    preContextTokens: 20_000,
    compactions: 0,
    sidechainRequests: 0,
    startedAt: NOW - 3600_000,
    lastActivityAt: NOW,
    ...overrides,
  }
}

const NO_SPEND = { total: 0, sessions: 0, carriedOver: 0, hasUnpriced: false }
const TODAY = { total: 4.1, sessions: 3, carriedOver: 0, hasUnpriced: false }

function render(props: Partial<Parameters<typeof UsageStripView>[0]> = {}): string {
  return renderToStaticMarkup(
    <UsageStripView session={session()} today={TODAY} plan={null} scanning={false} now={NOW} {...props} />,
  )
}

describe('what the strip reports', () => {
  it('shows context, session spend, project spend today and the token split', () => {
    const html = render()
    expect(html).toContain('142k / 200k · 71%')
    expect(html).toContain('$0.83')
    expect(html).toContain('$4.10')
    expect(html).toContain('in 1.2k')
    expect(html).toContain('out 3.4k')
    // Cache dominates the bill, so it is on screen, not only in a tooltip.
    expect(html).toContain('cache 1.2M read / 88k write')
  })

  it('carries the main process&apos;s own context warning', () => {
    expect(render()).toContain('Context 71% full.')
  })

  it('reports occupancy past 100% instead of clamping it away', () => {
    const html = render({
      session: session({
        context: { tokens: 208_000, window: 200_000, percent: 104, remaining: 0, level: 'critical' },
      }),
    })
    expect(html).toContain('104%')
    expect(html).toContain('over')
    // The bar itself cannot exceed its track.
    expect(html).toContain('width:100%')
  })

  it('marks a compacted session and stays quiet about one that was not', () => {
    expect(render({ session: session({ compactions: 2 }) })).toContain('×2')
    expect(render()).not.toContain('Compacted')
  })

  it('says a spend is a floor when a model has no published rate', () => {
    const html = render({
      session: session({
        cost: {
          cost: { input: 0, output: 0, cacheWrite: 0, cacheRead: 0, total: 0.5 },
          byModel: {},
          unpricedModels: ['mystery-model'],
          usedLegacyRate: false,
        },
      }),
    })
    expect(html).toContain('Spend is a floor')
    expect(html).toContain('mystery-model')
    // On the figure itself, not only in a note: notes are capped at two and this
    // one is third in line behind a refusal and a context warning.
    expect(html).toContain('≥ $0.50')
  })

  it('keeps the floor mark on the figure when the note is crowded out', () => {
    const html = render({
      refreshReason: 'The session is working — try again once it is idle.',
      session: session({
        cost: {
          cost: { input: 0, output: 0, cacheWrite: 0, cacheRead: 0, total: 0.5 },
          byModel: {},
          unpricedModels: ['mystery-model'],
          usedLegacyRate: false,
        },
      }),
      canRefreshPlan: true,
      onRefreshPlan: () => {},
    })
    // The refusal and the context warning fill both note slots…
    expect(html).not.toContain('Spend is a floor')
    // …so the caveat has to survive on the number.
    expect(html).toContain('≥ $0.50')
  })

  it('marks today as an upper bound when a session began before today', () => {
    const html = render({ today: { ...TODAY, carriedOver: 2 } })
    expect(html).toContain('counted in full')
  })
})

describe('empty states', () => {
  it('separates "still reading" from "nothing recorded"', () => {
    expect(render({ session: null, today: NO_SPEND, scanning: true })).toContain('Reading transcripts…')
    expect(render({ session: null, today: NO_SPEND })).toContain('No usage recorded for this project yet.')
  })

  it('says so when the bridge is missing rather than showing zeros', () => {
    expect(render({ unwired: true })).toContain('not wired into this build')
  })

  it('shows a dash for a session that has not made a request yet', () => {
    const html = render({ session: session({ context: null, warnings: [] }) })
    expect(html).toContain('Context')
    expect(html).not.toContain('% used')
  })
})

describe('the plan limit', () => {
  const plan: PlanLimitSnapshot = {
    sessionId: 'pty-1',
    available: true,
    source: 'usage-panel',
    message: null,
    capturedAt: NOW - 60_000,
    reason: null,
    limits: [
      { id: 'session', label: 'Current session', scope: 'session', percent: 5, resetsAt: '4am (Asia/Dubai)' },
      { id: 'week', label: 'Current week (all models)', scope: 'week', percent: 80, resetsAt: 'Aug 14 at 2pm' },
    ],
  }

  it('shows each limit the CLI reported, with its reset time', () => {
    const html = render({ plan })
    expect(html).toContain('Session')
    expect(html).toContain('5%')
    expect(html).toContain('80%')
    expect(html).toContain('resets 4am (Asia/Dubai)')
  })

  it('says plainly that it is unavailable rather than estimating one', () => {
    const html = render({ plan: null })
    expect(html).toContain('not available')
    // No limit chip at all — not a 0%, and not a guess dressed as a reading.
    expect(html).not.toContain('us-plan-limit')
  })

  it('does not render a Check button that cannot run', () => {
    // A control that silently does nothing is worse than its absence: without
    // the refresh method on the bridge, there is no button at all.
    expect(render({ plan: null })).not.toContain('us-refresh')
    expect(render({ plan: null, canRefreshPlan: true })).not.toContain('us-refresh')
  })

  it('offers the Check button once it can actually type /usage', () => {
    const html = render({ plan: null, canRefreshPlan: true, onRefreshPlan: () => {} })
    expect(html).toContain('us-refresh')
    expect(html).toContain('Types /usage into this session')
  })

  it('explains a refusal instead of appearing to do nothing', () => {
    const html = render({
      plan: null,
      canRefreshPlan: true,
      onRefreshPlan: () => {},
      refreshReason: 'The session is working — try again once it is idle.',
    })
    expect(html).toContain('try again once it is idle')
  })

  it('reports a limit the CLI named without a number as such', () => {
    const html = render({
      plan: {
        ...plan,
        source: 'warning',
        message: 'Approaching weekly limit',
        limits: [{ id: 'week', label: 'weekly limit', scope: 'week', percent: null, resetsAt: null }],
      },
    })
    expect(html).toContain('near limit')
    expect(html).not.toContain('0%')
  })
})
