import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import * as costModule from './cost'
import {
  addUsage,
  cacheHitRate,
  contextLevel,
  contextUsage,
  contextWarning,
  contextWindowFor,
  CONTEXT_CRITICAL_PERCENT,
  CONTEXT_WARNING_PERCENT,
  DEFAULT_CONTEXT_WINDOW,
  effectiveContextWindow,
  emptyUsage,
  formatTokens,
  isBillableModel,
  normalizeModelId,
  preContextWarning,
  promptTokens,
  sumUsage,
  totalTokens,
  type TokenUsage,
} from './cost'

/** Shorthand for building usage in tests. */
function usage(partial: Partial<TokenUsage>): TokenUsage {
  return { ...emptyUsage(), ...partial }
}

describe('token arithmetic', () => {
  it('starts at zero', () => {
    expect(emptyUsage()).toEqual({
      input: 0,
      output: 0,
      cacheWrite5m: 0,
      cacheWrite1h: 0,
      cacheRead: 0,
    })
  })

  it('adds every column without mutating its inputs', () => {
    const a = usage({ input: 1, output: 2, cacheWrite5m: 3, cacheWrite1h: 4, cacheRead: 5 })
    const b = usage({ input: 10, output: 20, cacheWrite5m: 30, cacheWrite1h: 40, cacheRead: 50 })
    expect(addUsage(a, b)).toEqual({
      input: 11,
      output: 22,
      cacheWrite5m: 33,
      cacheWrite1h: 44,
      cacheRead: 55,
    })
    expect(a.input).toBe(1)
    expect(b.input).toBe(10)
  })

  it('sums an empty list to zero', () => {
    expect(sumUsage([])).toEqual(emptyUsage())
  })

  it('sums a list', () => {
    const total = sumUsage([usage({ input: 5 }), usage({ input: 7, output: 2 })])
    expect(total.input).toBe(12)
    expect(total.output).toBe(2)
  })

  it('counts the cached prefix as part of the prompt', () => {
    // The real trap: input_tokens is only the *uncached remainder*. This is a
    // genuine record from a live transcript — a 52k-token prompt that reports
    // input_tokens: 2.
    const u = usage({ input: 2, cacheWrite1h: 21_857, cacheRead: 30_415, output: 2540 })
    expect(promptTokens(u)).toBe(52_274)
    expect(totalTokens(u)).toBe(54_814)
  })

  it('reports cache hit rate, and is zero-safe', () => {
    expect(cacheHitRate(usage({ input: 250, cacheRead: 750 }))).toBeCloseTo(0.75, 10)
    expect(cacheHitRate(emptyUsage())).toBe(0)
    // Output tokens are not part of the prompt and must not dilute the rate.
    expect(cacheHitRate(usage({ cacheRead: 100, output: 9999 }))).toBe(1)
  })
})

describe('normalizeModelId', () => {
  it('passes a plain id through', () => {
    expect(normalizeModelId('claude-opus-5')).toBe('claude-opus-5')
  })

  it('strips a dated snapshot suffix', () => {
    // Seen verbatim in transcripts on this machine.
    expect(normalizeModelId('claude-haiku-4-5-20251001')).toBe('claude-haiku-4-5')
  })

  it('strips Bedrock and regional prefixes', () => {
    expect(normalizeModelId('anthropic.claude-opus-5')).toBe('claude-opus-5')
    expect(normalizeModelId('us.anthropic.claude-opus-4-8')).toBe('claude-opus-4-8')
  })

  it('strips Vertex and Bedrock version pins', () => {
    expect(normalizeModelId('claude-opus-4-5@20251101')).toBe('claude-opus-4-5')
    expect(normalizeModelId('anthropic.claude-sonnet-4-5-v1:0')).toBe('claude-sonnet-4-5')
  })

  it('strips the long-context beta tag', () => {
    expect(normalizeModelId('claude-sonnet-4-6[1m]')).toBe('claude-sonnet-4-6')
  })

  it('normalises case and whitespace', () => {
    expect(normalizeModelId('  Claude-Opus-5 ')).toBe('claude-opus-5')
  })
})

describe('isBillableModel', () => {
  it('rejects synthetic and empty ids', () => {
    // Claude Code writes <synthetic> for locally generated messages such as
    // API errors. They carry zero usage and must not count as "unpriced".
    expect(isBillableModel('<synthetic>')).toBe(false)
    expect(isBillableModel('')).toBe(false)
    expect(isBillableModel('   ')).toBe(false)
  })

  it('accepts real models', () => {
    expect(isBillableModel('claude-opus-5')).toBe(true)
    expect(isBillableModel('claude-haiku-4-5-20251001')).toBe(true)
  })
})

describe('context windows', () => {
  it('knows the per-model window', () => {
    expect(contextWindowFor('claude-opus-5')).toBe(1_000_000)
    expect(contextWindowFor('claude-haiku-4-5')).toBe(200_000)
  })

  it('falls back to 200k for an unknown model', () => {
    expect(contextWindowFor('claude-unknown-7')).toBe(DEFAULT_CONTEXT_WINDOW)
    expect(DEFAULT_CONTEXT_WINDOW).toBe(200_000)
  })

  it('keeps the table window when observations fit inside it', () => {
    expect(effectiveContextWindow(1_000_000, 500_000)).toBe(1_000_000)
    expect(effectiveContextWindow(200_000, 200_000)).toBe(200_000)
  })

  it('promotes to the next real tier when a prompt exceeds the table window', () => {
    // A 900k prompt against a 200k-pinned model means the long-context beta is
    // on; reporting "450% full" would be useless.
    expect(effectiveContextWindow(200_000, 900_000)).toBe(1_000_000)
  })

  it('falls back to the observed size when it exceeds every known tier', () => {
    expect(effectiveContextWindow(200_000, 2_500_000)).toBe(2_500_000)
  })
})

describe('contextUsage', () => {
  it('computes percent and remaining', () => {
    const ctx = contextUsage(500_000, 'claude-opus-5')
    expect(ctx.window).toBe(1_000_000)
    expect(ctx.percent).toBeCloseTo(50, 10)
    expect(ctx.remaining).toBe(500_000)
    expect(ctx.level).toBe('ok')
  })

  it('honours an explicit window override', () => {
    const ctx = contextUsage(100_000, 'claude-opus-5', 200_000)
    expect(ctx.window).toBe(200_000)
    expect(ctx.percent).toBeCloseTo(50, 10)
  })

  it('ignores a nonsensical override', () => {
    expect(contextUsage(1000, 'claude-opus-5', 0).window).toBe(1_000_000)
    expect(contextUsage(1000, 'claude-opus-5', -5).window).toBe(1_000_000)
  })

  it('reports over 100% honestly and never goes negative on remaining', () => {
    // Real observation: auto-compaction fired at preTokens 1,001,209 against a
    // 1M window, so the last request before it genuinely tipped over.
    const ctx = contextUsage(1_001_209, 'claude-opus-5')
    expect(ctx.percent).toBeGreaterThan(100)
    expect(ctx.remaining).toBe(0)
    expect(ctx.level).toBe('critical')
  })

  it('clamps negative token counts', () => {
    expect(contextUsage(-10, 'claude-opus-5').tokens).toBe(0)
  })
})

describe('contextLevel thresholds', () => {
  it('is ok below the warning threshold', () => {
    expect(contextLevel(0)).toBe('ok')
    expect(contextLevel(CONTEXT_WARNING_PERCENT - 0.01)).toBe('ok')
  })

  it('warns at the threshold, not after it', () => {
    expect(contextLevel(CONTEXT_WARNING_PERCENT)).toBe('warning')
    expect(contextLevel(CONTEXT_CRITICAL_PERCENT - 0.01)).toBe('warning')
  })

  it('is critical at the threshold and beyond', () => {
    expect(contextLevel(CONTEXT_CRITICAL_PERCENT)).toBe('critical')
    expect(contextLevel(140)).toBe('critical')
  })
})

describe('bloat warnings', () => {
  it('stays quiet while context is healthy', () => {
    expect(contextWarning(contextUsage(100_000, 'claude-opus-5'))).toBeNull()
  })

  it('warns and escalates on context growth', () => {
    const warn = contextWarning(contextUsage(750_000, 'claude-opus-5'))
    expect(warn?.kind).toBe('context-window')
    expect(warn?.level).toBe('warning')

    const critical = contextWarning(contextUsage(950_000, 'claude-opus-5'))
    expect(critical?.level).toBe('critical')
    expect(critical?.message).toMatch(/compaction/i)
  })

  it('ignores a small fixed prefix', () => {
    expect(preContextWarning(20_000, 200_000)).toBeNull() // 10%
  })

  it('warns once the fixed prefix passes 15% of the window', () => {
    const warn = preContextWarning(30_000, 200_000) // exactly 15%
    expect(warn?.kind).toBe('pre-context')
    expect(warn?.level).toBe('warning')
    expect(warn?.percent).toBeCloseTo(15, 10)
  })

  it('escalates a prefix that eats a third of the window', () => {
    expect(preContextWarning(60_000, 200_000)?.level).toBe('critical') // 30%
  })

  it('says nothing without data', () => {
    expect(preContextWarning(0, 200_000)).toBeNull()
    expect(preContextWarning(10_000, 0)).toBeNull()
  })
})


describe('formatting', () => {
  it('abbreviates token counts', () => {
    expect(formatTokens(0)).toBe('0')
    expect(formatTokens(999)).toBe('999')
    expect(formatTokens(1200)).toBe('1.2k')
    expect(formatTokens(31_400)).toBe('31.4k')
    expect(formatTokens(52_274)).toBe('52.3k')
    expect(formatTokens(1_001_209)).toBe('1M')
    expect(formatTokens(1_250_000)).toBe('1.25M')
  })

  it('does not render a token count as "1000k"', () => {
    // Regression: the k branch rounded 999,999 to 1000.0 and printed "1000k".
    expect(formatTokens(999_999)).toBe('1M')
    expect(formatTokens(999_400)).toBe('999.4k')
    expect(formatTokens(-999_999)).toBe('-1M')
  })

  it('handles negative and fractional counts without crashing', () => {
    expect(formatTokens(-1500)).toBe('-1.5k')
    expect(formatTokens(0.4)).toBe('0')
  })
})

/* ------------------------------------------------ the app shows no prices -- */

/**
 * This app shows no cost, no spend and no dollar figure, and these are the
 * tests that keep it that way.
 *
 * The Overview tile carried two figures at once — `$100–200 on plan` beside the
 * API total — and then, once the plan half went, a single `$4558 at API rates`.
 * Asad on the survivor: *"people are using subscription and we are showing API
 * price. So if we cannot show the both, let's not show any of them
 * completely."* One figure is misleading (a subscription is a flat fee, and
 * nobody on one spent that) and the other is unknowable (Anthropic publishes no
 * token allowance and no per-token value for any plan), so there is no honest
 * pair and no honest single. The full argument is at the bottom of `cost.ts`.
 *
 * What is asserted here is an absence — by name, because the failure mode is
 * somebody re-adding a tile and reaching for the table that used to feed it,
 * and deleting the symbols is what makes that reach fail at the import rather
 * than at code review.
 */
describe('the app shows no prices', () => {
  it('exports no pricing arithmetic', () => {
    const gone = [
      // The rate card and everything that read it.
      'priceFor',
      'costOf',
      'addCost',
      'emptyCost',
      'aggregateCost',
      'mergeAggregates',
      'formatUsd',
      'RATES_VERIFIED_ON',
      // The subscription block, deleted one round earlier.
      'SUBSCRIPTION_PLANS',
      'PlanPrice',
      'subscriptionCost',
      'billingMonths',
      'MS_PER_BILLING_MONTH',
      'PLAN_LABELS',
      'normalizePlanId',
      'planLabel',
    ]
    for (const name of gone) {
      expect({ name, exported: name in costModule }).toEqual({ name, exported: false })
    }
  })

  it('carries no rate, no multiplier and no currency in the module itself', () => {
    // The stronger version of the check above: a re-added price would probably
    // arrive under a new name. Comments are stripped first, because the
    // argument for *not* having prices necessarily talks about them at length.
    const code = stripComments(readFileSync(join(__dirname, 'cost.ts'), 'utf8'))
    expect(code).not.toMatch(MONEY_SIGN)
    expect(code).not.toMatch(/\b(?:usd|price|rate|fee|monthly|perMonth|multiplier)\s*:/i)
  })

  it('leaves no dollar figure in any renderer that used to draw one', () => {
    /*
     * Three hand copies of `formatUsd` lived in the renderer — the tsconfig
     * there cannot see `src/main`, so each surface that showed money carried
     * its own. All three files still exist and still draw token counts, which
     * is exactly why this is checked by content rather than by their absence.
     *
     * Comments are stripped for the same reason as above: each of these files
     * explains, in prose, what was deleted and why.
     */
    const files = [
      join(__dirname, '..', 'renderer', 'chat', 'usage', 'usage-model.ts'),
      join(__dirname, '..', 'renderer', 'components', 'SessionInspector.tsx'),
      join(__dirname, '..', 'renderer', 'dashboard', 'widgets.tsx'),
      join(__dirname, '..', 'renderer', 'dashboard', 'board.ts'),
      join(__dirname, '..', 'renderer', 'dashboard', 'SessionBoard.tsx'),
      join(__dirname, '..', 'renderer', 'chat', 'usage', 'UsageStrip.tsx'),
    ]
    for (const file of files) {
      const code = stripComments(readFileSync(file, 'utf8'))
      expect({ file, hasFormatUsd: /formatUsd/.test(code) }).toEqual({ file, hasFormatUsd: false })
      expect({ file, hasDollar: MONEY_SIGN.test(code) }).toEqual({ file, hasDollar: false })
    }
  })

  it('computes no cost in the main process either', () => {
    // Dead cost arithmetic is still wrong arithmetic and it still goes stale,
    // so the deletion had to reach the producers as well as the drawers.
    const files = ['cost-ipc.ts', 'transcript.ts', 'session-insights.ts', 'alerts.ts']
    for (const name of files) {
      const code = stripComments(readFileSync(join(__dirname, name), 'utf8'))
      expect({ name, priced: /\b(?:formatUsd|aggregateCost|mergeAggregates|costOf|priceFor|costUsd)\b/.test(code) })
        .toEqual({ name, priced: false })
    }
  })
})

/**
 * Strip block and line comments so a source check reads the code alone.
 *
 * Every file this is pointed at documents the deletion in prose, and the prose
 * necessarily names the things that are gone — `formatUsd`, `$4558`, the rate
 * card. A check that could not tell an argument from an implementation would
 * fail on the very comments that exist to stop the implementation coming back.
 */
function stripComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, '')
}

/**
 * A dollar sign that is *printed*, as opposed to one that is syntax.
 *
 * A bare `/\$/` cannot be used: `$` ends a regex in `normalizeModelId`, and
 * `${` opens an interpolation in every template literal in the codebase. What
 * money looks like is narrower and all three shapes are covered — `` `$${n}` ``
 * (a doubled `$` before the brace), `'$0.00'` (a digit after it), and a `$`
 * sitting on its own next to a quote or a space, which is how a currency symbol
 * gets glued to a value.
 *
 * Not a shared `const` regex object with a `g` flag anywhere near it: `test`
 * on a global regex carries `lastIndex` between calls and would skip files.
 */
const MONEY_SIGN = /\$\$\{|\$\d|\$['"`\s]/
