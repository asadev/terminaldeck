import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { UsageStripView } from './UsageStrip'
import type { SessionSummary, TokenUsage } from './types'

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

const NOTHING_TODAY = { tokens: 0, sessions: 0, carriedOver: 0 }
const TODAY = { tokens: 4_100_000, sessions: 3, carriedOver: 0 }

function render(props: Partial<Parameters<typeof UsageStripView>[0]> = {}): string {
  return renderToStaticMarkup(
    <UsageStripView session={session()} today={TODAY} scanning={false} {...props} />,
  )
}

describe('what the strip reports', () => {
  it('shows context, requests, the project’s tokens today and the token split', () => {
    const html = render()
    expect(html).toContain('142k / 200k · 71%')
    expect(html).toContain('>12<')
    expect(html).toContain('4.1M')
    expect(html).toContain('in 1.2k')
    expect(html).toContain('out 3.4k')
    // Cache dominates the traffic, so it is on screen, not only in a tooltip.
    expect(html).toContain('cache 1.2M read / 88k write')
  })

  it('prints no dollar figure anywhere', () => {
    /*
     * Two items on this strip were money — "Session" showed what the session
     * had cost and "Today" what the project had, both with a `≥` variant for
     * an unpriced model. Both are gone; the argument is at the bottom of
     * `src/main/cost.ts`. Rendered rather than grepped for, because the point
     * is what reaches the screen.
     */
    expect(render()).not.toMatch(/[$]/)
    expect(render({ today: { ...TODAY, carriedOver: 2 } })).not.toMatch(/[$]/)
    expect(render({ session: session({ compactions: 3 }) })).not.toMatch(/[$]/)
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

  it('marks today as an upper bound when a session began before today', () => {
    const html = render({ today: { ...TODAY, carriedOver: 2 } })
    expect(html).toContain('counted in full')
  })
})

describe('empty states', () => {
  it('separates "still reading" from "nothing recorded"', () => {
    expect(render({ session: null, today: NOTHING_TODAY, scanning: true })).toContain('Reading transcripts…')
    expect(render({ session: null, today: NOTHING_TODAY })).toContain('No usage recorded for this project yet.')
  })

  it('says so when the bridge is missing rather than showing zeros', () => {
    expect(render({ unwired: true })).toContain('not wired into this build')
  })

  /*
   * "No usage recorded for this project yet" is false on the screen that shows
   * it: the project has plenty, this session simply has none. The strip is
   * about one session there, so the sentence has to be about one session.
   */
  it('blames the session, not the project, when the strip is about one session', () => {
    const html = render({ session: null, today: NOTHING_TODAY, scoped: true })
    expect(html).toContain('Nothing recorded for this session yet.')
    expect(html).not.toContain('this project yet')
  })

  it('still says "still reading" first, whatever the strip is about', () => {
    // Scanning outranks both sentences: neither "no usage" claim is known yet.
    expect(render({ session: null, today: NOTHING_TODAY, scoped: true, scanning: true })).toContain(
      'Reading transcripts…',
    )
  })

  it('shows a dash for a session that has not made a request yet', () => {
    const html = render({ session: session({ context: null, warnings: [] }) })
    expect(html).toContain('Context')
    expect(html).not.toContain('% used')
  })
})

describe('the subscription limit is not on this strip any more', () => {
  /*
   * It used to be here: a "Plan" item reading `Session 5% Week 80% · resets
   * 4am`, and the Check button that types `/usage`. Both moved to the session's
   * own chrome — `shell/UsageBar.tsx`, beside the account chip — because that is
   * where Asad asked for the bar twice, and because from here it could not be
   * reached at all by a session drawn as a terminal.
   *
   * These guard the *other* half of that decision, which is the half that is
   * easy to undo by accident: it did not stay in both places. Two readings of
   * one subscription, from two channels with two different rules about stale
   * numbers, is how a person ends up with two answers on one screen and no way
   * to tell which is true.
   */
  it('draws no limit chip, no "not available" and no Check button', () => {
    const html = render()
    expect(html).not.toContain('us-plan-limit')
    expect(html).not.toContain('us-refresh')
    expect(html).not.toContain('not available')
    expect(html).not.toMatch(/>Plan</)
  })

  it('says in the source where the reading went, so it is not quietly re-added', () => {
    // A deleted feature with no forwarding address is a feature somebody
    // rebuilds. The note at the top of the file is that address, and this is
    // what keeps it there.
    const source = readFileSync(join(__dirname, 'UsageStrip.tsx'), 'utf8')
    expect(source).toContain('shell/UsageBar.tsx')
  })

  it('no longer asks the bridge for plan limits at all', () => {
    // The subscription channels are gone from `UsageBridge`, not merely unused
    // by the view: an optional method nobody calls is how a bridge comes to
    // describe a feature that does not exist.
    const hook = readFileSync(join(__dirname, 'useUsage.ts'), 'utf8')
    expect(hook).not.toContain('watchPlanLimits')
    expect(hook).not.toContain('refreshPlanLimits')
  })
})
