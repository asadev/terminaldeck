import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  ContextTab,
  CostTab,
  TimelineTab,
  ToolsTab,
  downsample,
  formatPercent,
  isoOrUndefined,
  type ContextPoint,
  type SessionInsights,
  type TimelineEntry,
  type ToolStat,
} from './SessionInspector'

/**
 * There is no DOM environment in this project's test setup, so these render the
 * tab panels to static markup — the same arrangement `ReadinessPanel.test.tsx`
 * uses. That reaches the parts worth pinning: which rows a panel chooses, and
 * what it publishes as machine-readable data. The container itself renders
 * through `Modal`'s portal and needs a real document, so its state is exercised
 * through the exported pieces instead.
 */

/* ---------------------------------------------------------------- fixtures */

const T0 = Date.UTC(2026, 7, 12, 10, 0, 0)

function entry(partial: Partial<TimelineEntry> & { index: number }): TimelineEntry {
  return {
    key: `msg_${partial.index}`,
    at: T0 + partial.index * 1000,
    endedAt: T0 + partial.index * 1000 + 500,
    streamMs: 500,
    sinceLastMs: 500,
    model: 'claude-opus-5',
    speed: 'standard',
    usage: { input: 10, output: 20, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0 },
    promptTokens: 10,
    outputTokens: 20,
    cost: { input: 0, output: 0.0005, cacheWrite: 0, cacheRead: 0, total: 0.0005 },
    costUsd: 0.0005,
    contextPercent: 1,
    isSidechain: false,
    stopReason: 'end_turn',
    tools: [],
    ...partial,
  }
}

function tool(partial: Partial<ToolStat> & { name: string }): ToolStat {
  return {
    server: null,
    calls: 1,
    failures: 0,
    timedCalls: 1,
    totalMs: 1000,
    maxMs: 1000,
    avgMs: 1000,
    share: 1,
    ...partial,
  }
}

function insightsFor(partial: Partial<SessionInsights> = {}): SessionInsights {
  return {
    sessionId: 'sess-1',
    transcriptPath: '/tmp/sess-1.jsonl',
    cwd: '/Users/apple/Projects/terminaldeck',
    startedAt: T0,
    lastActivityAt: T0 + 60_000,
    durationMs: 60_000,
    generatingMs: 5000,
    toolMs: 4000,
    requests: 1,
    sidechainRequests: 0,
    timeline: [],
    omittedRequests: 0,
    costliest: [],
    tools: [],
    toolCalls: 0,
    toolFailures: 0,
    models: [],
    usage: { input: 10, output: 20, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0 },
    cost: {
      cost: { input: 0, output: 0.0005, cacheWrite: 0, cacheRead: 0, total: 0.0005 },
      byModel: {},
      unpricedModels: [],
      usedLegacyRate: false,
    },
    cacheHitRate: 0,
    context: null,
    contextSeries: [],
    compactions: [],
    warnings: [],
    preContextTokens: 0,
    generatedAt: T0,
    ...partial,
  }
}

/* ------------------------------------------------------------------- <time> */

describe('isoOrUndefined', () => {
  it('publishes nothing for a line that carried no timestamp', () => {
    // The main module reports `at: 0` for a line with no usable timestamp, and
    // the visible text correctly reads "—". Emitting the epoch as the
    // machine-readable value stated 1 January 1970 as fact.
    expect(isoOrUndefined(0)).toBeUndefined()
  })

  it('survives a non-finite value instead of throwing the dialog away', () => {
    // The insights object crosses the IPC bridge as an unchecked cast, and
    // `new Date(NaN).toISOString()` throws a RangeError — which would unmount
    // the whole panel rather than blank one cell.
    expect(() => isoOrUndefined(Number.NaN)).not.toThrow()
    expect(isoOrUndefined(Number.NaN)).toBeUndefined()
    expect(isoOrUndefined(Number.POSITIVE_INFINITY)).toBeUndefined()
    expect(isoOrUndefined(8.64e15 + 1)).toBeUndefined()
  })

  it('still publishes a real timestamp', () => {
    expect(isoOrUndefined(T0)).toBe('2026-08-12T10:00:00.000Z')
  })
})

describe('TimelineTab', () => {
  it('omits the datetime attribute rather than claiming the epoch', () => {
    const html = renderToStaticMarkup(
      <TimelineTab insights={insightsFor({ timeline: [entry({ index: 1, at: 0 })], requests: 1 })} />,
    )
    expect(html).toContain('<time>')
    expect(html).not.toContain('1970-01-01')
  })

  it('keeps the datetime attribute when there is a real timestamp', () => {
    const html = renderToStaticMarkup(
      <TimelineTab insights={insightsFor({ timeline: [entry({ index: 1, at: T0 })], requests: 1 })} />,
    )
    // React's server renderer spells the attribute as it was written in JSX;
    // HTML attribute names are case-insensitive, so match it that way.
    expect(html.toLowerCase()).toContain('datetime="2026-08-12t10:00:00.000z"')
  })

  it('renders a row with a corrupt timestamp instead of unmounting the dialog', () => {
    // `new Date(NaN).toISOString()` throws a RangeError. The insights object
    // arrives through the bridge as an unchecked cast, so one bad number in one
    // row used to take the entire panel down.
    expect(() =>
      renderToStaticMarkup(
        <TimelineTab
          insights={insightsFor({ timeline: [entry({ index: 1, at: Number.NaN })], requests: 1 })}
        />,
      ),
    ).not.toThrow()
  })

  it('says how many requests were trimmed out of the payload entirely', () => {
    const html = renderToStaticMarkup(
      <TimelineTab
        insights={insightsFor({
          timeline: [entry({ index: 2001 })],
          requests: 2001,
          omittedRequests: 2000,
        })}
      />,
    )
    expect(html).toContain('2000')
  })

  it('has an empty state instead of a bare list', () => {
    expect(renderToStaticMarkup(<TimelineTab insights={insightsFor()} />)).toContain('si-empty')
  })
})

/* -------------------------------------------------------------------- cost */

describe('CostTab', () => {
  it('ranks the priciest requests from the session, not from the visible rows', () => {
    // The expensive request is request #1 of 3,000 and has been trimmed out of
    // `timeline`. Ranking `timeline` locally reported a request that cost a
    // rounding error and labelled it "most expensive".
    const whale = entry({ index: 1, key: 'whale', costUsd: 60, promptTokens: 2_000_000 })
    const html = renderToStaticMarkup(
      <CostTab
        insights={insightsFor({
          timeline: [entry({ index: 2999 }), entry({ index: 3000 })],
          costliest: [whale],
          omittedRequests: 2998,
          requests: 3000,
        })}
      />,
    )
    expect(html).toContain('Most expensive requests')
    expect(html).toContain('#1')
    expect(html).toContain('$60.00')
    expect(html).not.toContain('#3000')
  })

  it('drops the section when nothing in the session was priced', () => {
    const html = renderToStaticMarkup(
      <CostTab insights={insightsFor({ timeline: [entry({ index: 1, costUsd: null, cost: null })] })} />,
    )
    expect(html).not.toContain('Most expensive requests')
  })

  it('tolerates an insights payload from a main process that predates costliest', () => {
    // The bridge hands the renderer an unchecked cast, so a stale main process
    // means `costliest` is simply absent — that must not throw.
    const stale = insightsFor({ timeline: [entry({ index: 1 })] }) as SessionInsights
    delete (stale as Partial<SessionInsights>).costliest
    expect(() => renderToStaticMarkup(<CostTab insights={stale} />)).not.toThrow()
  })
})

/* ------------------------------------------------------------------- tools */

describe('ToolsTab', () => {
  it('reports a zero failure rate without dividing by zero', () => {
    const html = renderToStaticMarkup(
      <ToolsTab
        insights={insightsFor({ tools: [tool({ name: 'Bash' })], toolCalls: 0, toolFailures: 0 })}
      />,
    )
    expect(html).toContain('0.0%')
    expect(html).not.toContain('NaN')
  })

  it('has an empty state for a session that called nothing', () => {
    expect(renderToStaticMarkup(<ToolsTab insights={insightsFor()} />)).toContain('si-empty')
  })
})

/* ----------------------------------------------------------------- context */

describe('downsample', () => {
  const point = (i: number, percent: number): ContextPoint => ({
    index: i,
    at: T0 + i,
    tokens: percent * 1000,
    percent,
  })

  it('never emits a hole, whatever the bucket arithmetic rounds to', () => {
    // `points[from]` was read without a guard and its `.percent` dereferenced
    // immediately; any bucket that rounded empty would have thrown.
    for (const length of [161, 199, 320, 321, 977, 1601]) {
      const out = downsample(
        Array.from({ length }, (_unused, i) => point(i + 1, (i % 41) + 1)),
        160,
      )
      expect(out).toHaveLength(160)
      expect(out.every((p) => p !== undefined && Number.isFinite(p.percent))).toBe(true)
    }
  })

  it('keeps the peak, which is the only feature the chart is for', () => {
    const points = Array.from({ length: 1000 }, (_unused, i) => point(i + 1, 5))
    points[617] = point(618, 98)
    expect(downsample(points, 160).some((p) => p.percent === 98)).toBe(true)
  })

  it('leaves a series that already fits alone', () => {
    const points = [point(1, 10), point(2, 20)]
    expect(downsample(points, 160)).toBe(points)
  })
})

describe('ContextTab', () => {
  it('renders the chart from a capped series', () => {
    const series = Array.from({ length: 400 }, (_unused, i) => ({
      index: i * 8 + 1,
      at: T0 + i * 1000,
      tokens: (i + 1) * 100,
      percent: (i + 1) / 10,
    }))
    const html = renderToStaticMarkup(
      <ContextTab
        insights={insightsFor({
          contextSeries: series,
          context: { tokens: 40_000, window: 1_000_000, percent: 4, remaining: 960_000, level: 'ok' },
        })}
      />,
    )
    expect(html).toContain('si-chart')
    expect(html).toContain('peak 40.0%')
    expect(html).not.toContain('NaN')
  })

  it('does not draw a chart from a single point', () => {
    const html = renderToStaticMarkup(
      <ContextTab
        insights={insightsFor({
          contextSeries: [{ index: 1, at: T0, tokens: 100, percent: 1 }],
        })}
      />,
    )
    expect(html).not.toContain('si-chart')
  })

  it('says so when no request has reported a prompt size', () => {
    expect(renderToStaticMarkup(<ContextTab insights={insightsFor()} />)).toContain(
      'No request has reported a prompt size yet.',
    )
  })
})

describe('formatPercent', () => {
  it('refuses to print NaN% at the user', () => {
    expect(formatPercent(Number.NaN)).toBe('—')
    expect(formatPercent(Number.POSITIVE_INFINITY)).toBe('—')
    expect(formatPercent(42.44)).toBe('42.4%')
    expect(formatPercent(104.2)).toBe('104.2%')
  })
})
