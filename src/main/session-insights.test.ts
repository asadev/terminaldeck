import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { emptyUsage, type TokenUsage } from './cost'
import {
  buildSessionInsights,
  downsampleContext,
  mcpServerOf,
  parseInsightLine,
  readInsightLines,
  readSessionInsights,
  shortToolName,
  COSTLIEST_COUNT,
  DEFAULT_MAX_CONTEXT_POINTS,
  type ContextPoint,
  type InsightLine,
} from './session-insights'

/* ------------------------------------------------------------------ fixtures */

const T0 = Date.UTC(2026, 7, 12, 10, 0, 0)

function iso(offsetMs: number): string {
  return new Date(T0 + offsetMs).toISOString()
}

interface UsageInput {
  input?: number
  output?: number
  write5m?: number
  write1h?: number
  read?: number
  speed?: 'standard' | 'fast'
}

function rawUsage(usage: UsageInput): Record<string, unknown> {
  const write5m = usage.write5m ?? 0
  const write1h = usage.write1h ?? 0
  return {
    input_tokens: usage.input ?? 0,
    output_tokens: usage.output ?? 0,
    cache_creation_input_tokens: write5m + write1h,
    cache_creation: {
      ephemeral_5m_input_tokens: write5m,
      ephemeral_1h_input_tokens: write1h,
    },
    cache_read_input_tokens: usage.read ?? 0,
    speed: usage.speed ?? 'standard',
  }
}

interface AssistantInput {
  id: string
  offset: number
  model?: string
  usage?: UsageInput
  /** One content block per line, exactly as the CLI writes them. */
  block?: Record<string, unknown>
  stopReason?: string
  sidechain?: boolean
}

/** An assistant JSONL line, shaped like the ones in ~/.claude/projects. */
function assistantLine(input: AssistantInput): string {
  return JSON.stringify({
    type: 'assistant',
    uuid: `${input.id}-${input.offset}`,
    requestId: `req_${input.id}`,
    sessionId: 'sess-1',
    cwd: '/Users/apple/Projects/terminaldeck',
    isSidechain: input.sidechain ?? false,
    timestamp: iso(input.offset),
    message: {
      id: input.id,
      type: 'message',
      role: 'assistant',
      model: input.model ?? 'claude-opus-5',
      stop_reason: input.stopReason ?? 'tool_use',
      content: [input.block ?? { type: 'text', text: 'hello' }],
      usage: rawUsage(input.usage ?? {}),
    },
  })
}

/** A user JSONL line carrying one tool result. */
function toolResultLine(id: string, offset: number, failed = false): string {
  return JSON.stringify({
    type: 'user',
    uuid: `res-${id}`,
    sessionId: 'sess-1',
    timestamp: iso(offset),
    isSidechain: false,
    message: {
      role: 'user',
      content: [{ tool_use_id: id, type: 'tool_result', content: 'ok', is_error: failed }],
    },
  })
}

function compactionLine(offset: number, preTokens: number, postTokens: number): string {
  return JSON.stringify({
    type: 'system',
    subtype: 'compact_boundary',
    uuid: `compact-${offset}`,
    timestamp: iso(offset),
    isSidechain: false,
    compactMetadata: { trigger: 'auto', preTokens, postTokens, durationMs: 139_787 },
  })
}

function parseAll(lines: string[]): InsightLine[] {
  const parsed: InsightLine[] = []
  for (const line of lines) {
    const one = parseInsightLine(line)
    if (one) parsed.push(one)
  }
  return parsed
}

function insightsFor(lines: string[], max?: number) {
  return buildSessionInsights(parseAll(lines), {
    transcriptPath: '/tmp/sess-1.jsonl',
    maxTimelineEntries: max,
    now: T0,
  })
}

/* -------------------------------------------------------------- line parsing */

describe('parseInsightLine', () => {
  it('reads usage, model, speed and stop reason off an assistant line', () => {
    const line = parseInsightLine(
      assistantLine({
        id: 'msg_1',
        offset: 0,
        usage: { input: 10, output: 20, write1h: 30, read: 40, speed: 'fast' },
        stopReason: 'end_turn',
      }),
    )
    expect(line?.request).toEqual({
      messageId: 'msg_1',
      requestId: 'req_msg_1',
      uuid: 'msg_1-0',
      model: 'claude-opus-5',
      usage: { input: 10, output: 20, cacheWrite5m: 0, cacheWrite1h: 30, cacheRead: 40 },
      speed: 'fast',
      stopReason: 'end_turn',
    })
    expect(line?.at).toBe(T0)
    expect(line?.cwd).toBe('/Users/apple/Projects/terminaldeck')
  })

  it('reads a tool call and its result', () => {
    const use = parseInsightLine(
      assistantLine({
        id: 'msg_1',
        offset: 0,
        block: { type: 'tool_use', id: 'toolu_a', name: 'Bash', input: { command: 'ls' } },
      }),
    )
    expect(use?.toolUses).toEqual([{ id: 'toolu_a', name: 'Bash' }])

    const ok = parseInsightLine(toolResultLine('toolu_a', 1000))
    expect(ok?.toolResults).toEqual([{ id: 'toolu_a', failed: false }])

    const bad = parseInsightLine(toolResultLine('toolu_a', 1000, true))
    expect(bad?.toolResults).toEqual([{ id: 'toolu_a', failed: true }])
  })

  it('reads compaction metadata', () => {
    expect(parseInsightLine(compactionLine(500, 1_000_571, 13_697))?.compaction).toEqual({
      preTokens: 1_000_571,
      postTokens: 13_697,
      trigger: 'auto',
      durationMs: 139_787,
    })
  })

  it('ignores lines that hold nothing to report', () => {
    expect(parseInsightLine('')).toBeNull()
    expect(parseInsightLine('   ')).toBeNull()
    expect(parseInsightLine('{"type":"assistant"')).toBeNull() // torn trailing line
    expect(parseInsightLine('[1,2,3]')).toBeNull()
    expect(parseInsightLine('{"uuid":"x"}')).toBeNull() // no type
    expect(parseInsightLine(JSON.stringify({ type: 'attachment', content: 'blob' }))).toBeNull()
    expect(parseInsightLine(JSON.stringify({ type: 'queue-operation', operation: 'add' }))).toBeNull()
  })

  it('keeps a user line that carries a tool result but no usage', () => {
    expect(parseInsightLine(toolResultLine('toolu_a', 0))).not.toBeNull()
  })

  it('survives a line with no timestamp', () => {
    const line = parseInsightLine(
      JSON.stringify({
        type: 'assistant',
        message: { id: 'm', model: 'claude-opus-5', content: [], usage: rawUsage({ output: 5 }) },
      }),
    )
    expect(line?.at).toBe(0)
    expect(line?.request?.usage.output).toBe(5)
  })
})

describe('mcp tool naming', () => {
  it('splits on the double underscore, not the first single one', () => {
    // `ccd_session` would be cut in half by a greedy split; verified names.
    expect(mcpServerOf('mcp__ccd_session__mark_chapter')).toBe('ccd_session')
    expect(shortToolName('mcp__ccd_session__mark_chapter')).toBe('mark_chapter')
    expect(mcpServerOf('mcp__computer-use__computer_batch')).toBe('computer-use')
    expect(shortToolName('mcp__Claude_Browser__javascript_tool')).toBe('javascript_tool')
  })

  it('leaves built-in tools alone', () => {
    expect(mcpServerOf('Bash')).toBeNull()
    expect(shortToolName('Bash')).toBe('Bash')
  })
})

/* --------------------------------------------------------------- aggregation */

describe('buildSessionInsights — request grouping', () => {
  // A request that thinks, speaks and calls two tools is written as four lines
  // that all repeat the same usage object. This is the whole ball game.
  const multiLine = [
    assistantLine({ id: 'msg_1', offset: 0, usage: { input: 100, output: 200, write1h: 5000 }, block: { type: 'thinking', thinking: '…' } }),
    assistantLine({ id: 'msg_1', offset: 2000, usage: { input: 100, output: 200, write1h: 5000 }, block: { type: 'text', text: 'doing it' } }),
    assistantLine({ id: 'msg_1', offset: 4000, usage: { input: 100, output: 200, write1h: 5000 }, block: { type: 'tool_use', id: 'toolu_a', name: 'Bash' } }),
    assistantLine({ id: 'msg_1', offset: 6000, usage: { input: 100, output: 200, write1h: 5000 }, block: { type: 'tool_use', id: 'toolu_b', name: 'Read' } }),
  ]

  it('counts one request and its tokens once', () => {
    const insights = insightsFor(multiLine)
    expect(insights.requests).toBe(1)
    expect(insights.timeline).toHaveLength(1)
    expect(insights.usage).toEqual({
      input: 100,
      output: 200,
      cacheWrite5m: 0,
      cacheWrite1h: 5000,
      cacheRead: 0,
    })
    // Summing per line instead would report 4x — the failure mode this guards.
    expect(insights.timeline[0].promptTokens).toBe(5100)
  })

  it('still collects every tool call across the request lines', () => {
    const insights = insightsFor(multiLine)
    expect(insights.timeline[0].tools).toEqual(['Bash', 'Read'])
    expect(insights.toolCalls).toBe(2)
  })

  it('spans the request from its first line to its last', () => {
    const entry = insightsFor(multiLine).timeline[0]
    expect(entry.at).toBe(T0)
    expect(entry.endedAt).toBe(T0 + 6000)
    expect(entry.streamMs).toBe(6000)
  })

  it('falls back to the request id, then the uuid, when there is no message id', () => {
    const noMessageId = JSON.stringify({
      type: 'assistant',
      uuid: 'u-1',
      requestId: 'req_x',
      timestamp: iso(0),
      message: { model: 'claude-opus-5', content: [], usage: rawUsage({ output: 10 }) },
    })
    const insights = insightsFor([noMessageId, noMessageId])
    expect(insights.requests).toBe(1)
    expect(insights.timeline[0].key).toBe('req_x')
  })

  it('measures the gap between requests, never negative', () => {
    const insights = insightsFor([
      assistantLine({ id: 'msg_1', offset: 0, usage: { output: 10 } }),
      assistantLine({ id: 'msg_1', offset: 3000, usage: { output: 10 } }),
      assistantLine({ id: 'msg_2', offset: 20_000, usage: { output: 10 } }),
    ])
    expect(insights.timeline[0].sinceLastMs).toBe(0)
    expect(insights.timeline[1].sinceLastMs).toBe(17_000)
    expect(insights.generatingMs).toBe(3000)
  })

  it('numbers the timeline chronologically from one', () => {
    const insights = insightsFor([
      assistantLine({ id: 'a', offset: 0, usage: { output: 1 } }),
      assistantLine({ id: 'b', offset: 10, usage: { output: 1 } }),
      assistantLine({ id: 'c', offset: 20, usage: { output: 1 } }),
    ])
    expect(insights.timeline.map((entry) => entry.index)).toEqual([1, 2, 3])
    expect(insights.startedAt).toBe(T0)
    expect(insights.lastActivityAt).toBe(T0 + 20)
    expect(insights.durationMs).toBe(20)
  })
})

describe('buildSessionInsights — tool usage', () => {
  it('counts calls by name, sorted by call count', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, block: { type: 'tool_use', id: 't1', name: 'Bash' } }),
      assistantLine({ id: 'm2', offset: 10, block: { type: 'tool_use', id: 't2', name: 'Edit' } }),
      assistantLine({ id: 'm3', offset: 20, block: { type: 'tool_use', id: 't3', name: 'Bash' } }),
      assistantLine({ id: 'm4', offset: 30, block: { type: 'tool_use', id: 't4', name: 'Bash' } }),
    ])
    expect(insights.tools.map((tool) => [tool.name, tool.calls])).toEqual([
      ['Bash', 3],
      ['Edit', 1],
    ])
    expect(insights.tools[0].share).toBeCloseTo(0.75, 6)
    expect(insights.toolCalls).toBe(4)
  })

  it('deduplicates tool ids replayed across a compaction boundary', () => {
    // 75 of 3,074 ids in the largest real transcript appear twice; counting
    // them raw inflates calls and failures alike.
    const call = assistantLine({
      id: 'm1',
      offset: 0,
      block: { type: 'tool_use', id: 'toolu_dup', name: 'Bash' },
    })
    const result = toolResultLine('toolu_dup', 5000, true)
    const insights = insightsFor([call, result, call, result])
    expect(insights.toolCalls).toBe(1)
    expect(insights.toolFailures).toBe(1)
    expect(insights.tools[0].timedCalls).toBe(1)
  })

  it('times a call from its use to its result', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, block: { type: 'tool_use', id: 't1', name: 'Bash' } }),
      toolResultLine('t1', 4000),
      assistantLine({ id: 'm2', offset: 5000, block: { type: 'tool_use', id: 't2', name: 'Bash' } }),
      toolResultLine('t2', 7000),
    ])
    const bash = insights.tools[0]
    expect(bash.timedCalls).toBe(2)
    expect(bash.totalMs).toBe(6000)
    expect(bash.maxMs).toBe(4000)
    expect(bash.avgMs).toBe(3000)
    expect(insights.toolMs).toBe(6000)
  })

  it('counts a call with no result, but does not time it', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, block: { type: 'tool_use', id: 't1', name: 'Bash' } }),
    ])
    expect(insights.tools[0].calls).toBe(1)
    expect(insights.tools[0].timedCalls).toBe(0)
    expect(insights.tools[0].avgMs).toBe(0)
    expect(insights.toolMs).toBe(0)
  })

  it('ignores a result whose call was never seen', () => {
    const insights = insightsFor([toolResultLine('toolu_orphan', 1000, true)])
    expect(insights.tools).toEqual([])
    expect(insights.toolCalls).toBe(0)
    expect(insights.toolFailures).toBe(0)
  })

  it('does not time a result that precedes its call', () => {
    const insights = buildSessionInsights([
      {
        at: T0 + 5000,
        isSidechain: false,
        request: null,
        toolUses: [{ id: 't1', name: 'Bash' }],
        toolResults: [],
        compaction: null,
      },
      {
        at: T0,
        isSidechain: false,
        request: null,
        toolUses: [],
        toolResults: [{ id: 't1', failed: false }],
        compaction: null,
      },
    ])
    expect(insights.tools[0].calls).toBe(1)
    expect(insights.tools[0].timedCalls).toBe(0)
    expect(insights.toolMs).toBe(0)
  })

  it('labels MCP tools with their server', () => {
    const insights = insightsFor([
      assistantLine({
        id: 'm1',
        offset: 0,
        block: { type: 'tool_use', id: 't1', name: 'mcp__computer-use__screenshot' },
      }),
    ])
    expect(insights.tools[0].server).toBe('computer-use')
  })
})

/* ---------------------------------------------------------------- cost */

describe('buildSessionInsights — cost', () => {
  it('prices each request against its own rate card', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { input: 100, output: 200, write1h: 5000 } }),
      assistantLine({ id: 'm2', offset: 1000, usage: { input: 50, output: 300, write5m: 1000, read: 5000 } }),
    ])
    // Opus 5 at $5/$25 per M: writes are 2x (1h) and 1.25x (5m), reads 0.1x.
    expect(insights.timeline[0].costUsd).toBeCloseTo(0.0555, 8)
    expect(insights.timeline[1].costUsd).toBeCloseTo(0.0165, 8)
    expect(insights.cost.cost.total).toBeCloseTo(0.072, 8)
  })

  it('makes the total the sum of the rows even across a rate change', () => {
    // Sonnet 5's introductory $2/$10 runs out on 2026-09-01. Pricing the whole
    // session at its last activity would bill the August request at September
    // rates and silently disagree with the row the user is reading.
    const august = Date.UTC(2026, 7, 15) - T0
    const september = Date.UTC(2026, 8, 15) - T0
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: august, model: 'claude-sonnet-5', usage: { output: 1000 } }),
      assistantLine({ id: 'm2', offset: september, model: 'claude-sonnet-5', usage: { output: 1000 } }),
    ])
    expect(insights.timeline[0].costUsd).toBeCloseTo(0.01, 8)
    expect(insights.timeline[1].costUsd).toBeCloseTo(0.015, 8)
    expect(insights.cost.cost.total).toBeCloseTo(0.025, 8)
    const summed = insights.timeline.reduce((total, entry) => total + (entry.costUsd ?? 0), 0)
    expect(insights.cost.cost.total).toBeCloseTo(summed, 10)
  })

  it('keeps fast mode on its own rate card', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { output: 1000, speed: 'fast' } }),
      assistantLine({ id: 'm2', offset: 10, usage: { output: 1000 } }),
    ])
    expect(insights.models.map((model) => model.model).sort()).toEqual([
      'claude-opus-5',
      'claude-opus-5-fast',
    ])
    // $50/M fast against $25/M standard.
    expect(insights.timeline[0].costUsd).toBeCloseTo(0.05, 8)
    expect(insights.timeline[1].costUsd).toBeCloseTo(0.025, 8)
  })

  it('breaks cost down per model with shares that sum to one', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { output: 1000 } }),
      assistantLine({ id: 'm2', offset: 10, model: 'claude-haiku-4-5', usage: { output: 1000 } }),
      assistantLine({ id: 'm3', offset: 20, model: 'claude-haiku-4-5', usage: { output: 1000 } }),
    ])
    const [first, second] = insights.models
    expect(first.model).toBe('claude-opus-5')
    expect(first.requests).toBe(1)
    expect(first.costUsd).toBeCloseTo(0.025, 8)
    expect(second.model).toBe('claude-haiku-4-5')
    expect(second.requests).toBe(2)
    expect(second.costUsd).toBeCloseTo(0.01, 8)
    expect(first.share + second.share).toBeCloseTo(1, 10)
    expect(insights.models.reduce((n, model) => n + model.requests, 0)).toBe(insights.requests)
  })

  it('reports an unknown model as unpriced rather than free', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, model: 'some-other-llm', usage: { output: 1000 } }),
    ])
    expect(insights.timeline[0].cost).toBeNull()
    expect(insights.timeline[0].costUsd).toBeNull()
    expect(insights.cost.unpricedModels).toEqual(['some-other-llm'])
    expect(insights.cost.cost.total).toBe(0)
  })

  it('keeps a request with tokens but no model id visible', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, model: '', usage: { output: 1000 } }),
    ])
    expect(insights.requests).toBe(1)
    expect(insights.cost.unpricedModels).toEqual(['unknown'])
  })

  it('does not flag synthetic messages as unpriced', () => {
    // The CLI writes `<synthetic>` for interrupts and API errors. They carry no
    // tokens, so treating them as unknown models would caveat almost every
    // session that ever errored.
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { output: 1000 } }),
      assistantLine({ id: 'm2', offset: 10, model: '<synthetic>', usage: {} }),
    ])
    expect(insights.requests).toBe(2)
    expect(insights.cost.unpricedModels).toEqual([])
    expect(insights.cost.cost.total).toBeCloseTo(0.025, 8)
  })

  it('flags a legacy rate on the model that used it', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, model: 'claude-opus-4-1', usage: { output: 1000 } }),
    ])
    expect(insights.models[0].legacyRate).toBe(true)
    expect(insights.cost.usedLegacyRate).toBe(true)
  })

  it('reports the cache hit rate over the whole session', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { input: 100, read: 900 } }),
    ])
    expect(insights.cacheHitRate).toBeCloseTo(0.9, 8)
  })
})

/* ------------------------------------------------------------------ context */

describe('buildSessionInsights — context', () => {
  it('tracks occupancy from the latest prompt, not a running total', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { read: 100_000, output: 10 } }),
      assistantLine({ id: 'm2', offset: 10, usage: { read: 250_000, output: 10 } }),
    ])
    expect(insights.context?.tokens).toBe(250_000)
    expect(insights.context?.window).toBe(1_000_000)
    expect(insights.context?.percent).toBeCloseTo(25, 8)
    expect(insights.contextSeries.map((point) => point.tokens)).toEqual([100_000, 250_000])
  })

  it('reports true occupancy past 100% rather than clamping', () => {
    const insights = insightsFor([
      assistantLine({
        id: 'm1',
        offset: 0,
        model: 'claude-haiku-4-5',
        usage: { read: 210_000, output: 10 },
      }),
    ])
    // Haiku's window is 200k and the observed prompt beats it, so the window is
    // promoted to the next real tier rather than reporting 105%.
    expect(insights.context?.window).toBe(1_000_000)
    expect(insights.context?.percent).toBeCloseTo(21, 8)
  })

  it('does not let a sub-agent masquerade as the main thread', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { read: 50_000, output: 10 } }),
      assistantLine({ id: 'm2', offset: 10, usage: { read: 900_000, output: 10 }, sidechain: true }),
    ])
    expect(insights.sidechainRequests).toBe(1)
    expect(insights.context?.tokens).toBe(50_000)
    expect(insights.timeline[1].contextPercent).toBeNull()
    expect(insights.contextSeries).toHaveLength(1)
  })

  it('measures the pre-context prefix from the first main-thread request', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { write1h: 40_000, output: 10 } }),
      assistantLine({ id: 'm2', offset: 10, usage: { read: 60_000, output: 10 } }),
    ])
    expect(insights.preContextTokens).toBe(40_000)
  })

  it('warns when the window fills and when the prefix is bloated', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { write1h: 300_000, output: 10 } }),
      assistantLine({ id: 'm2', offset: 10, usage: { read: 950_000, output: 10 } }),
    ])
    expect(insights.warnings.map((warning) => warning.kind)).toEqual([
      'context-window',
      'pre-context',
    ])
    expect(insights.warnings[0].level).toBe('critical')
  })

  it('has no context before the first request', () => {
    const insights = insightsFor([toolResultLine('toolu_x', 0)])
    expect(insights.context).toBeNull()
    expect(insights.warnings).toEqual([])
    expect(insights.requests).toBe(0)
  })

  it('records what each compaction reclaimed and where it landed', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { read: 500_000, output: 10 } }),
      compactionLine(1000, 1_000_571, 13_697),
      assistantLine({ id: 'm2', offset: 2000, usage: { write1h: 13_697, output: 10 } }),
    ])
    expect(insights.compactions).toEqual([
      {
        at: T0 + 1000,
        afterRequest: 1,
        preTokens: 1_000_571,
        postTokens: 13_697,
        reclaimedTokens: 986_874,
        trigger: 'auto',
        durationMs: 139_787,
      },
    ])
  })

  it('lets a compaction boundary widen the window it proves', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, model: 'claude-haiku-4-5', usage: { read: 150_000, output: 10 } }),
      compactionLine(1000, 900_000, 20_000),
    ])
    expect(insights.context?.window).toBe(1_000_000)
  })
})

/* ------------------------------------------------------------------ trimming */

describe('buildSessionInsights — payload bounds', () => {
  it('keeps the newest requests and says how many it dropped', () => {
    const lines = Array.from({ length: 5 }, (_unused, i) =>
      assistantLine({ id: `m${i}`, offset: i * 10, usage: { output: 10 } }),
    )
    const insights = insightsFor(lines, 2)
    expect(insights.requests).toBe(5)
    expect(insights.timeline.map((entry) => entry.index)).toEqual([4, 5])
    expect(insights.omittedRequests).toBe(3)
    // Totals still cover everything, not just the visible rows.
    expect(insights.usage.output).toBe(50)
    expect(insights.cost.cost.total).toBeCloseTo(0.00125, 8)
  })

  it('leaves a short timeline alone', () => {
    const insights = insightsFor([assistantLine({ id: 'm1', offset: 0, usage: { output: 10 } })], 100)
    expect(insights.omittedRequests).toBe(0)
  })

  it('handles an empty transcript', () => {
    const insights = buildSessionInsights([])
    expect(insights).toMatchObject({
      requests: 0,
      toolCalls: 0,
      timeline: [],
      tools: [],
      models: [],
      context: null,
      durationMs: 0,
    })
    expect(insights.usage).toEqual(emptyUsage())
    expect(insights.cacheHitRate).toBe(0)
  })
})

/* ------------------------------------------------------- regressions (fixes) */

describe('out-of-order transcript lines', () => {
  // Lines are appended in completion order, so a sub-agent's lines land after
  // the main-thread lines they ran under and carry earlier timestamps. Taking
  // the first line seen as the start put `startedAt` after `lastActivityAt`,
  // and `durationMs` then collapsed to 0: a two-hour session read as instant.
  it('starts the session at the earliest timestamp, not the first line seen', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 60_000, usage: { output: 10 } }),
      assistantLine({ id: 'm2', offset: 0, usage: { output: 10 }, sidechain: true }),
      assistantLine({ id: 'm3', offset: 90_000, usage: { output: 10 } }),
    ])
    expect(insights.startedAt).toBe(T0)
    expect(insights.lastActivityAt).toBe(T0 + 90_000)
    expect(insights.durationMs).toBe(90_000)
  })

  it('widens a request span downwards when a later line is timestamped earlier', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 5000, usage: { output: 10 }, block: { type: 'text', text: 'a' } }),
      assistantLine({ id: 'm1', offset: 1000, usage: { output: 10 }, block: { type: 'text', text: 'b' } }),
      assistantLine({ id: 'm1', offset: 9000, usage: { output: 10 }, block: { type: 'text', text: 'c' } }),
    ])
    expect(insights.requests).toBe(1)
    expect(insights.timeline[0].at).toBe(T0 + 1000)
    expect(insights.timeline[0].endedAt).toBe(T0 + 9000)
    expect(insights.timeline[0].streamMs).toBe(8000)
  })
})

describe('corrupt token counts', () => {
  function usageLine(usage: Record<string, unknown>): string {
    return JSON.stringify({
      type: 'assistant',
      uuid: 'u-1',
      timestamp: iso(0),
      isSidechain: false,
      message: { id: 'm1', model: 'claude-opus-5', content: [], usage },
    })
  }

  it('clamps a negative count instead of subtracting it from the session', () => {
    // A negative count is never real, and it does not merely look odd: it
    // subtracts from the session total and drives `cacheHitRate` below zero,
    // which the meter renders as a negative width.
    const insights = insightsFor([
      usageLine({ input_tokens: -5_000_000, output_tokens: 100, cache_read_input_tokens: -10 }),
    ])
    expect(insights.usage.input).toBe(0)
    expect(insights.usage.cacheRead).toBe(0)
    expect(insights.usage.output).toBe(100)
    expect(insights.cacheHitRate).toBe(0)
    expect(insights.cost.cost.total).toBeGreaterThanOrEqual(0)
  })

  it('keeps the cost finite when a count is absurdly large', () => {
    // `cost.ts` prices with `tokens * rate / 1e6` — it multiplies first, so a
    // finite 1e308 overflows to Infinity and every figure in the panel renders
    // as "$Infinity".
    const insights = insightsFor([usageLine({ output_tokens: 1e308, input_tokens: 1e308 })])
    expect(Number.isFinite(insights.cost.cost.total)).toBe(true)
    expect(Number.isFinite(insights.timeline[0].costUsd ?? 0)).toBe(true)
    expect(Number.isFinite(insights.usage.output)).toBe(true)
  })

  it('drops a non-numeric or fractional count to something countable', () => {
    const insights = insightsFor([
      usageLine({ output_tokens: 'lots', input_tokens: 12.7, cache_read_input_tokens: Number.NaN }),
    ])
    expect(insights.usage).toEqual({
      input: 12,
      output: 0,
      cacheWrite5m: 0,
      cacheWrite1h: 0,
      cacheRead: 0,
    })
  })

  it('clamps compaction metadata, which defines the window everything else is measured against', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { read: 50_000, output: 10 } }),
      JSON.stringify({
        type: 'system',
        subtype: 'compact_boundary',
        timestamp: iso(1000),
        compactMetadata: { trigger: 'auto', preTokens: 1e308, postTokens: -40, durationMs: -1 },
      }),
    ])
    expect(Number.isFinite(insights.compactions[0].preTokens)).toBe(true)
    expect(insights.compactions[0].postTokens).toBe(0)
    expect(insights.compactions[0].durationMs).toBe(0)
    expect(Number.isFinite(insights.context?.percent ?? 0)).toBe(true)
  })
})

describe('payload bounds beyond the timeline', () => {
  function manyRequests(count: number): string[] {
    return Array.from({ length: count }, (_unused, i) =>
      assistantLine({ id: `m${i}`, offset: i * 10, usage: { read: (i + 1) * 100, output: 10 } }),
    )
  }

  it('caps the context series too — it rides the same bridge as the timeline', () => {
    const insights = insightsFor(manyRequests(3000))
    expect(insights.requests).toBe(3000)
    expect(insights.contextSeries.length).toBeLessThanOrEqual(DEFAULT_MAX_CONTEXT_POINTS)
    expect(insights.contextSeries.length).toBeGreaterThan(1)
  })

  it('keeps the peak through the reduction, because the peak is the point', () => {
    const insights = buildSessionInsights(
      parseAll([
        ...manyRequests(600),
        assistantLine({ id: 'spike', offset: 6100, usage: { read: 900_000, output: 10 } }),
        ...manyRequests(600).map((_unused, i) =>
          assistantLine({ id: `t${i}`, offset: 7000 + i * 10, usage: { read: 1000, output: 10 } }),
        ),
      ]),
      { maxContextPoints: 50 },
    )
    expect(insights.contextSeries).toHaveLength(50)
    const peak = insights.contextSeries.reduce((a, b) => (b.tokens > a.tokens ? b : a))
    expect(peak.tokens).toBe(900_000)
  })

  it('treats a cap of zero as a cap, not as unlimited', () => {
    // Reading `max > 0` as "no limit" handed the whole timeline to exactly the
    // caller asking for the smallest possible payload.
    const insights = insightsFor(manyRequests(40), 0)
    expect(insights.timeline).toEqual([])
    expect(insights.omittedRequests).toBe(40)
    expect(insights.requests).toBe(40)
    // Totals still cover everything.
    expect(insights.usage.output).toBe(400)
  })

  it('refuses a negative cap as well', () => {
    expect(insightsFor(manyRequests(10), -5).timeline).toEqual([])
  })
})

describe('downsampleContext', () => {
  const point = (i: number, percent: number): ContextPoint => ({
    index: i,
    at: T0 + i,
    tokens: percent * 1000,
    percent,
  })

  it('leaves a short series alone', () => {
    const points = [point(1, 10), point(2, 20)]
    expect(downsampleContext(points, 50)).toBe(points)
  })

  it('returns nothing for a cap of zero', () => {
    expect(downsampleContext([point(1, 10), point(2, 20)], 0)).toEqual([])
  })

  it('keeps chronological order and never emits a hole', () => {
    const points = Array.from({ length: 977 }, (_unused, i) => point(i + 1, (i % 37) + 1))
    const out = downsampleContext(points, 100)
    expect(out).toHaveLength(100)
    expect(out.every((entry) => entry !== undefined)).toBe(true)
    expect(out.map((entry) => entry.index)).toEqual([...out.map((entry) => entry.index)].sort((a, b) => a - b))
  })

  it('reduces by peak rather than by mean', () => {
    const points = [point(1, 1), point(2, 99), point(3, 2), point(4, 3)]
    expect(downsampleContext(points, 2).map((entry) => entry.percent)).toEqual([99, 3])
  })
})

describe('costliest requests', () => {
  it('ranks across the whole session, not just the rows that survived trimming', () => {
    // The expensive request is #1 and the timeline only keeps the last five, so
    // ranking the timeline reported a request that cost a rounding error.
    const lines = [
      assistantLine({ id: 'whale', offset: 0, usage: { input: 2_000_000, output: 2_000_000 } }),
      ...Array.from({ length: 30 }, (_unused, i) =>
        assistantLine({ id: `m${i}`, offset: (i + 1) * 10, usage: { output: 10 } }),
      ),
    ]
    const insights = insightsFor(lines, 5)
    expect(insights.timeline.map((entry) => entry.key)).not.toContain('whale')
    expect(insights.costliest[0].key).toBe('whale')
    expect(insights.costliest[0].costUsd).toBeCloseTo(60, 6)
    expect(insights.costliest).toHaveLength(COSTLIEST_COUNT)
    // Descending, and every row genuinely priced.
    const costs = insights.costliest.map((entry) => entry.costUsd ?? 0)
    expect([...costs].sort((a, b) => b - a)).toEqual(costs)
    expect(insights.costliest.every((entry) => entry.costUsd !== null)).toBe(true)
  })

  it('omits unpriced requests rather than ranking them as free', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, model: 'some-other-llm', usage: { output: 9_000_000 } }),
      assistantLine({ id: 'm2', offset: 10, usage: { output: 10 } }),
    ])
    expect(insights.costliest.map((entry) => entry.key)).toEqual(['m2'])
  })

  it('does not reorder the timeline while ranking', () => {
    // When nothing is trimmed, `timeline` and the array `costliest` is derived
    // from are the same reference — sorting it in place would scramble the
    // chronology the whole panel is read in.
    const insights = insightsFor([
      assistantLine({ id: 'cheap', offset: 0, usage: { output: 1 } }),
      assistantLine({ id: 'whale', offset: 10, usage: { output: 1_000_000 } }),
      assistantLine({ id: 'mid', offset: 20, usage: { output: 100 } }),
    ])
    expect(insights.omittedRequests).toBe(0)
    expect(insights.timeline.map((entry) => entry.key)).toEqual(['cheap', 'whale', 'mid'])
    expect(insights.timeline.map((entry) => entry.index)).toEqual([1, 2, 3])
    expect(insights.costliest.map((entry) => entry.key)).toEqual(['whale', 'mid', 'cheap'])
  })

  it('is empty for a session with nothing priced', () => {
    expect(buildSessionInsights([]).costliest).toEqual([])
  })
})

/* -------------------------------------------------------------------- reader */

describe('readInsightLines', () => {
  const dirs: string[] = []

  afterAll(async () => {
    for (const dir of dirs) await rm(dir, { recursive: true, force: true })
  })

  async function fixture(contents: string): Promise<string> {
    const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-insights-'))
    dirs.push(dir)
    const path = join(dir, 'sess-1.jsonl')
    await writeFile(path, contents, 'utf8')
    return path
  }

  it('reads a transcript end to end', async () => {
    const path = await fixture(
      [
        assistantLine({ id: 'm1', offset: 0, usage: { input: 100, output: 200, write1h: 5000 }, block: { type: 'tool_use', id: 't1', name: 'Bash' } }),
        toolResultLine('t1', 3000),
        assistantLine({ id: 'm2', offset: 4000, usage: { input: 10, output: 50, read: 5100 } }),
        '',
      ].join('\n'),
    )
    const insights = await readSessionInsights(path)
    expect(insights.requests).toBe(2)
    expect(insights.sessionId).toBe('sess-1')
    expect(insights.transcriptPath).toBe(path)
    expect(insights.cwd).toBe('/Users/apple/Projects/terminaldeck')
    expect(insights.tools[0]).toMatchObject({ name: 'Bash', calls: 1, totalMs: 3000 })
  })

  it('parses a final line with no trailing newline', async () => {
    const path = await fixture(assistantLine({ id: 'm1', offset: 0, usage: { output: 10 } }))
    expect(await readInsightLines(path)).toHaveLength(1)
  })

  it('skips junk without losing the lines around it', async () => {
    const path = await fixture(
      [
        'not json at all',
        JSON.stringify({ type: 'attachment', content: 'x'.repeat(200) }),
        assistantLine({ id: 'm1', offset: 0, usage: { output: 10 } }),
        '{"type":"assistant","message":{"id":"torn"',
      ].join('\n'),
    )
    const insights = await readSessionInsights(path)
    expect(insights.requests).toBe(1)
  })

  it('returns nothing for a file that is not there', async () => {
    expect(await readInsightLines('/nope/missing.jsonl')).toEqual([])
  })

  it('returns nothing for a directory rather than throwing EISDIR', async () => {
    // `open(dir, 'r')` succeeds on macOS and Linux and only fails at the first
    // `read()`. A directory named `<x>.jsonl` inside the transcript store
    // passes the IPC path check, so this reached the renderer as a raw errno.
    const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-insights-'))
    dirs.push(dir)
    const asTranscript = join(dir, 'looks-like-one.jsonl')
    await mkdir(asTranscript)
    await expect(readInsightLines(asTranscript)).resolves.toEqual([])
  })

  it('survives a line that straddles a read boundary', async () => {
    // The reader pulls 4 MB at a time, so a padded line here is guaranteed to
    // be split across two chunks and rejoined through the decoder.
    const padded = JSON.stringify({
      type: 'assistant',
      uuid: 'u',
      timestamp: iso(0),
      isSidechain: false,
      message: {
        id: 'big',
        model: 'claude-opus-5',
        content: [{ type: 'text', text: 'é'.repeat(3 * 1024 * 1024) }],
        usage: rawUsage({ output: 42 }),
      },
    })
    const path = await fixture(
      [padded, assistantLine({ id: 'after', offset: 1000, usage: { output: 7 } })].join('\n'),
    )
    const insights = await readSessionInsights(path)
    expect(insights.requests).toBe(2)
    expect(insights.usage.output).toBe(49)
  })
})

/* --------------------------------------------------------- shape sanity check */

describe('token accounting invariants', () => {
  it('keeps per-model usage adding up to the session usage', () => {
    const insights = insightsFor([
      assistantLine({ id: 'm1', offset: 0, usage: { input: 5, output: 11, write5m: 7, write1h: 13, read: 17 } }),
      assistantLine({ id: 'm2', offset: 10, model: 'claude-haiku-4-5', usage: { input: 3, output: 2, read: 19 } }),
    ])
    const summed = insights.models.reduce<TokenUsage>(
      (total, model) => ({
        input: total.input + model.usage.input,
        output: total.output + model.usage.output,
        cacheWrite5m: total.cacheWrite5m + model.usage.cacheWrite5m,
        cacheWrite1h: total.cacheWrite1h + model.usage.cacheWrite1h,
        cacheRead: total.cacheRead + model.usage.cacheRead,
      }),
      emptyUsage(),
    )
    expect(summed).toEqual(insights.usage)
  })
})
