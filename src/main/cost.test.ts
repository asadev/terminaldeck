import { describe, expect, it } from 'vitest'
import {
  addCost,
  addUsage,
  aggregateCost,
  cacheHitRate,
  contextLevel,
  contextUsage,
  contextWarning,
  contextWindowFor,
  costOf,
  CONTEXT_CRITICAL_PERCENT,
  CONTEXT_WARNING_PERCENT,
  DEFAULT_CONTEXT_WINDOW,
  effectiveContextWindow,
  emptyCost,
  emptyUsage,
  formatTokens,
  formatUsd,
  isBillableModel,
  mergeAggregates,
  normalizeModelId,
  preContextWarning,
  priceFor,
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

describe('priceFor', () => {
  it('returns null for an unknown model rather than guessing', () => {
    expect(priceFor('claude-nonexistent-9')).toBeNull()
    expect(priceFor('<synthetic>')).toBeNull()
  })

  it('prices Opus at $5 / $25 per million', () => {
    const price = priceFor('claude-opus-5')
    expect(price?.input).toBe(5)
    expect(price?.output).toBe(25)
  })

  it('prices Sonnet 4.6 at $3 / $15 and Haiku 4.5 at $1 / $5', () => {
    expect(priceFor('claude-sonnet-4-6')?.input).toBe(3)
    expect(priceFor('claude-sonnet-4-6')?.output).toBe(15)
    expect(priceFor('claude-haiku-4-5')?.input).toBe(1)
    expect(priceFor('claude-haiku-4-5')?.output).toBe(5)
  })

  it('derives cache rates from the input rate', () => {
    const opus = priceFor('claude-opus-5')
    expect(opus).not.toBeNull()
    // read 0.1x, 5-minute write 1.25x, 1-hour write 2x
    expect(opus?.cacheRead).toBeCloseTo(0.5, 10)
    expect(opus?.cacheWrite5m).toBeCloseTo(6.25, 10)
    expect(opus?.cacheWrite1h).toBeCloseTo(10, 10)
  })

  it('keeps cache reads an order of magnitude below fresh input', () => {
    for (const model of ['claude-opus-5', 'claude-sonnet-4-6', 'claude-haiku-4-5']) {
      const price = priceFor(model)
      expect(price).not.toBeNull()
      expect(price!.cacheRead).toBeCloseTo(price!.input / 10, 10)
      expect(price!.cacheWrite1h).toBeGreaterThan(price!.input)
      expect(price!.cacheWrite5m).toBeGreaterThan(price!.input)
      expect(price!.cacheWrite5m).toBeLessThan(price!.cacheWrite1h)
    }
  })

  it('applies Sonnet 5 introductory pricing only inside its window', () => {
    const during = priceFor('claude-sonnet-5', { at: Date.UTC(2026, 7, 12) })
    expect(during?.input).toBe(2)
    expect(during?.output).toBe(10)
    // Rates are time-boxed on purpose: the same session re-priced after the
    // promotion ends must not silently change what it cost.
    const after = priceFor('claude-sonnet-5', { at: Date.UTC(2026, 8, 1) })
    expect(after?.input).toBe(3)
    expect(after?.output).toBe(15)
  })

  it('derives cache rates from the promotional input rate while it applies', () => {
    const during = priceFor('claude-sonnet-5', { at: Date.UTC(2026, 7, 12) })
    expect(during?.cacheRead).toBeCloseTo(0.2, 10)
    expect(during?.cacheWrite1h).toBeCloseTo(4, 10)
  })

  it('charges the fast-mode premium when the request ran fast', () => {
    expect(priceFor('claude-opus-5', { speed: 'fast' })?.input).toBe(10)
    expect(priceFor('claude-opus-5', { speed: 'fast' })?.output).toBe(50)
    expect(priceFor('claude-opus-5', { speed: 'standard' })?.input).toBe(5)
    // Some deployments encode speed in the model string instead.
    expect(priceFor('claude-opus-5-fast')?.input).toBe(10)
  })

  it('falls back to the standard rate when a model has no published fast rate', () => {
    expect(priceFor('claude-opus-4-8', { speed: 'fast' })?.input).toBe(5)
  })

  it('flags historical rates', () => {
    expect(priceFor('claude-opus-5')?.legacy).toBe(false)
    expect(priceFor('claude-opus-4-1')?.legacy).toBe(true)
  })

  it('resolves a dated snapshot to its rate card', () => {
    expect(priceFor('claude-haiku-4-5-20251001')?.model).toBe('claude-haiku-4-5')
  })
})

describe('costOf', () => {
  it('prices a real transcript record exactly', () => {
    // Verbatim from ~/.claude/projects: opus-5, one request.
    const cost = costOf(
      usage({ input: 2, cacheWrite1h: 21_857, cacheRead: 30_415, output: 2540 }),
      'claude-opus-5',
    )
    expect(cost).not.toBeNull()
    expect(cost!.input).toBeCloseTo(0.00001, 10) // 2 @ $5/M
    expect(cost!.output).toBeCloseTo(0.0635, 10) // 2540 @ $25/M
    expect(cost!.cacheWrite).toBeCloseTo(0.21857, 10) // 21857 @ $10/M (2x input)
    expect(cost!.cacheRead).toBeCloseTo(0.0152075, 10) // 30415 @ $0.50/M
    expect(cost!.total).toBeCloseTo(0.2972875, 10)
  })

  it('sums the breakdown to the total', () => {
    const cost = costOf(
      usage({ input: 111, output: 222, cacheWrite5m: 333, cacheWrite1h: 444, cacheRead: 555 }),
      'claude-sonnet-4-6',
    )!
    expect(cost.total).toBeCloseTo(cost.input + cost.output + cost.cacheWrite + cost.cacheRead, 12)
  })

  it('charges a 1-hour cache write more than a 5-minute one', () => {
    const tokens = 100_000
    const short = costOf(usage({ cacheWrite5m: tokens }), 'claude-opus-5')!
    const long = costOf(usage({ cacheWrite1h: tokens }), 'claude-opus-5')!
    expect(short.cacheWrite).toBeCloseTo(0.625, 10)
    expect(long.cacheWrite).toBeCloseTo(1.0, 10)
    // Getting this wrong under-reports a Claude Code session by 37.5% of its
    // cache-write spend, which is most of the bill on a long session.
    expect(short.cacheWrite / long.cacheWrite).toBeCloseTo(0.625, 10)
  })

  it('charges a cache read a tenth of fresh input', () => {
    const tokens = 1_000_000
    const fresh = costOf(usage({ input: tokens }), 'claude-opus-5')!
    const cached = costOf(usage({ cacheRead: tokens }), 'claude-opus-5')!
    expect(fresh.input).toBeCloseTo(5, 10)
    expect(cached.cacheRead).toBeCloseTo(0.5, 10)
  })

  it('returns null for an unknown model instead of a misleading zero', () => {
    expect(costOf(usage({ input: 1000 }), 'claude-unknown-7')).toBeNull()
  })

  it('costs nothing for zero usage', () => {
    expect(costOf(emptyUsage(), 'claude-opus-5')!.total).toBe(0)
  })

  it('adds breakdowns', () => {
    const a = costOf(usage({ output: 1000 }), 'claude-opus-5')!
    const b = costOf(usage({ output: 1000 }), 'claude-opus-5')!
    expect(addCost(a, b).total).toBeCloseTo(0.05, 10)
  })
})

describe('aggregateCost', () => {
  it('prices each model against its own rate card', () => {
    const result = aggregateCost([
      ['claude-opus-5', usage({ output: 1_000_000 })], // $25
      ['claude-haiku-4-5', usage({ output: 1_000_000 })], // $5
    ])
    expect(result.cost.total).toBeCloseTo(30, 10)
    expect(result.byModel['claude-opus-5'].total).toBeCloseTo(25, 10)
    expect(result.byModel['claude-haiku-4-5'].total).toBeCloseTo(5, 10)
    expect(result.unpricedModels).toEqual([])
  })

  it('merges duplicate keys that normalise to the same model', () => {
    const result = aggregateCost([
      ['claude-haiku-4-5', usage({ output: 1_000_000 })],
      ['claude-haiku-4-5-20251001', usage({ output: 1_000_000 })],
    ])
    expect(Object.keys(result.byModel)).toEqual(['claude-haiku-4-5'])
    expect(result.cost.total).toBeCloseTo(10, 10)
  })

  it('counts unknown models as unpriced without dropping the rest', () => {
    const result = aggregateCost([
      ['claude-opus-5', usage({ output: 1_000_000 })],
      ['claude-mystery-1', usage({ output: 1_000_000 })],
    ])
    expect(result.cost.total).toBeCloseTo(25, 10)
    expect(result.unpricedModels).toEqual(['claude-mystery-1'])
  })

  it('ignores synthetic messages entirely', () => {
    // Otherwise every session that ever hit an API error would be flagged as
    // "pricing incomplete".
    const result = aggregateCost([
      ['claude-opus-5', usage({ output: 1_000_000 })],
      ['<synthetic>', emptyUsage()],
    ])
    expect(result.unpricedModels).toEqual([])
    expect(result.cost.total).toBeCloseTo(25, 10)
  })

  it('flags when a historical rate contributed', () => {
    expect(aggregateCost([['claude-opus-5', usage({ output: 10 })]]).usedLegacyRate).toBe(false)
    expect(aggregateCost([['claude-opus-4-1', usage({ output: 10 })]]).usedLegacyRate).toBe(true)
  })

  it('handles an empty input', () => {
    const result = aggregateCost([])
    expect(result.cost.total).toBe(0)
    expect(result.unpricedModels).toEqual([])
  })
})

describe('mergeAggregates', () => {
  it('adds the money and keeps the per-model split', () => {
    const merged = mergeAggregates([
      aggregateCost([['claude-opus-5', usage({ output: 1_000_000 })]]),
      aggregateCost([
        ['claude-opus-5', usage({ output: 1_000_000 })],
        ['claude-haiku-4-5', usage({ output: 1_000_000 })],
      ]),
    ])
    expect(merged.cost.total).toBeCloseTo(55, 10)
    expect(merged.byModel['claude-opus-5'].total).toBeCloseTo(50, 10)
    expect(merged.byModel['claude-haiku-4-5'].total).toBeCloseTo(5, 10)
  })

  it('unions unpriced models without duplicating them, and keeps them sorted', () => {
    const merged = mergeAggregates([
      aggregateCost([['claude-mystery-1', usage({ output: 10 })]]),
      aggregateCost([
        ['claude-mystery-1', usage({ output: 10 })],
        ['claude-mystery-0', usage({ output: 10 })],
      ]),
    ])
    expect(merged.unpricedModels).toEqual(['claude-mystery-0', 'claude-mystery-1'])
  })

  it('carries the legacy-rate flag through', () => {
    const clean = aggregateCost([['claude-opus-5', usage({ output: 10 })]])
    const old = aggregateCost([['claude-opus-4-1', usage({ output: 10 })]])
    expect(mergeAggregates([clean, clean]).usedLegacyRate).toBe(false)
    expect(mergeAggregates([clean, old]).usedLegacyRate).toBe(true)
  })

  it('merges nothing into zero', () => {
    const merged = mergeAggregates([])
    expect(merged.cost).toEqual(emptyCost())
    expect(merged.unpricedModels).toEqual([])
    expect(merged.byModel).toEqual({})
  })

  it('preserves each part’s own pricing date instead of re-pricing the pool', () => {
    // Regression: a project total used to be computed by pooling every
    // session's raw tokens and pricing them at *now*, so the total disagreed
    // with the sessions it was made of the moment a time-boxed rate expired.
    const tokens = usage({ output: 1_000_000 })
    const duringIntro = aggregateCost([['claude-sonnet-5', tokens]], { at: Date.UTC(2026, 7, 12) })
    const afterIntro = aggregateCost([['claude-sonnet-5', tokens]], { at: Date.UTC(2026, 9, 1) })
    expect(duringIntro.cost.total).toBeCloseTo(10, 10)
    expect(afterIntro.cost.total).toBeCloseTo(15, 10)

    const merged = mergeAggregates([duringIntro, afterIntro])
    expect(merged.cost.total).toBeCloseTo(25, 10)
    // Pooling the tokens and re-pricing would have produced 20 or 30, never 25.
    expect(merged.cost.total).not.toBeCloseTo(
      aggregateCost([['claude-sonnet-5', usage({ output: 2_000_000 })]], {
        at: Date.UTC(2026, 9, 1),
      }).cost.total,
      6,
    )
  })

  it('does not mutate the parts it merges', () => {
    const part = aggregateCost([['claude-opus-5', usage({ output: 1_000_000 })]])
    mergeAggregates([part, part])
    expect(part.cost.total).toBeCloseTo(25, 10)
    expect(part.byModel['claude-opus-5'].total).toBeCloseTo(25, 10)
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
  /**
   * Two places, always — the way money is written.
   *
   * Three places is what this used to print below ten dollars, and on screen
   * "$2.101" read as two thousand one hundred and one to anybody whose
   * thousands separator is a full stop. The precision was never the point; the
   * point is that a spend too small to show must not read as nothing, which is
   * why the sub-cent case says so in words instead of rounding to $0.00.
   */
  it('writes money the way money is written', () => {
    expect(formatUsd(0)).toBe('$0.00')
    expect(formatUsd(0.2972875)).toBe('$0.30')
    expect(formatUsd(2.1013)).toBe('$2.10')
    expect(formatUsd(12.3456)).toBe('$12.35')
  })

  it('says "less than a cent" rather than rounding a real spend to nothing', () => {
    expect(formatUsd(0.0004)).toBe('<$0.01')
    // Half a cent is the boundary: what rounds *to* a cent prints as one.
    expect(formatUsd(0.006)).toBe('$0.01')
    expect(formatUsd(-0.0004)).toBe('-<$0.01')
  })

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
