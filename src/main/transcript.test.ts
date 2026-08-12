import { afterEach, describe, expect, it } from 'vitest'
import { promptTokens } from './cost'
import {
  claudeConfigDir,
  encodeProjectPath,
  parseEventLine,
  parseUsage,
  SessionAggregator,
  transcriptDir,
  UNKNOWN_MODEL,
} from './transcript'

describe('encodeProjectPath', () => {
  // Every case below was checked against a real directory in
  // ~/.claude/projects and the `cwd` recorded inside that transcript.
  it('replaces separators with hyphens', () => {
    expect(encodeProjectPath('/Users/apple/ClaudeAsad')).toBe('-Users-apple-ClaudeAsad')
    expect(encodeProjectPath('/Users/apple/Projects/pawl')).toBe('-Users-apple-Projects-pawl')
  })

  it('collapses a dot-directory into a double hyphen', () => {
    expect(encodeProjectPath('/Users/apple/ClaudeImza/.claude/worktrees/focused-lumiere-5424d6')).toBe(
      '-Users-apple-ClaudeImza--claude-worktrees-focused-lumiere-5424d6',
    )
  })

  it('rewrites every non-alphanumeric character, including tildes and spaces', () => {
    expect(
      encodeProjectPath(
        '/Users/apple/Library/Mobile Documents/com~apple~CloudDocs/OpenClaw/workspace',
      ),
    ).toBe('-Users-apple-Library-Mobile-Documents-com-apple-CloudDocs-OpenClaw-workspace')
  })

  it('normalises a trailing slash away', () => {
    expect(encodeProjectPath('/Users/apple/ClaudeAsad/')).toBe(
      encodeProjectPath('/Users/apple/ClaudeAsad'),
    )
  })

  it('is lossy — distinct paths can collide, so never decode a directory name', () => {
    expect(encodeProjectPath('/a/b')).toBe(encodeProjectPath('/a.b'))
  })
})

describe('transcriptDir', () => {
  const original = process.env.CLAUDE_CONFIG_DIR
  afterEach(() => {
    if (original === undefined) delete process.env.CLAUDE_CONFIG_DIR
    else process.env.CLAUDE_CONFIG_DIR = original
  })

  it('lives under <config>/projects', () => {
    expect(transcriptDir('/Users/apple/ClaudeAsad', '/tmp/cfg')).toBe(
      '/tmp/cfg/projects/-Users-apple-ClaudeAsad',
    )
  })

  it('honours CLAUDE_CONFIG_DIR, which is how Claude profiles stay isolated', () => {
    process.env.CLAUDE_CONFIG_DIR = '/tmp/work-profile'
    expect(claudeConfigDir()).toBe('/tmp/work-profile')
    expect(transcriptDir('/x')).toBe('/tmp/work-profile/projects/-x')
  })

  it('ignores an empty override', () => {
    process.env.CLAUDE_CONFIG_DIR = '   '
    expect(claudeConfigDir()).toMatch(/\.claude$/)
  })
})

describe('parseUsage', () => {
  it('reads the full modern shape', () => {
    const parsed = parseUsage({
      input_tokens: 2,
      output_tokens: 2540,
      cache_creation_input_tokens: 21_857,
      cache_read_input_tokens: 30_415,
      cache_creation: { ephemeral_1h_input_tokens: 21_857, ephemeral_5m_input_tokens: 0 },
      service_tier: 'standard',
      speed: 'standard',
    })
    expect(parsed).toEqual({
      input: 2,
      output: 2540,
      cacheWrite5m: 0,
      cacheWrite1h: 21_857,
      cacheRead: 30_415,
    })
  })

  it('attributes an unexplained cache write to the cheaper 5-minute rate', () => {
    // Older transcripts carry only the flat total. Guessing 1-hour would
    // inflate the bill; 5-minute is the documented default TTL.
    const parsed = parseUsage({ cache_creation_input_tokens: 1000 })
    expect(parsed?.cacheWrite5m).toBe(1000)
    expect(parsed?.cacheWrite1h).toBe(0)
  })

  it('reconciles a partial breakdown against the declared total', () => {
    const parsed = parseUsage({
      cache_creation_input_tokens: 1000,
      cache_creation: { ephemeral_1h_input_tokens: 600 },
    })
    expect(parsed?.cacheWrite1h).toBe(600)
    expect(parsed?.cacheWrite5m).toBe(400)
    expect(promptTokens(parsed!)).toBe(1000)
  })

  it('never invents negative tokens when the breakdown exceeds the total', () => {
    const parsed = parseUsage({
      cache_creation_input_tokens: 100,
      cache_creation: { ephemeral_1h_input_tokens: 500 },
    })
    expect(parsed?.cacheWrite5m).toBe(0)
    expect(parsed?.cacheWrite1h).toBe(500)
  })

  it('treats missing fields as zero and non-objects as absent', () => {
    expect(parseUsage({})).toEqual({
      input: 0,
      output: 0,
      cacheWrite5m: 0,
      cacheWrite1h: 0,
      cacheRead: 0,
    })
    expect(parseUsage(null)).toBeNull()
    expect(parseUsage('nope')).toBeNull()
    expect(parseUsage([1, 2])).toBeNull()
  })
})

/** Build an `assistant` JSONL line in the exact shape Claude Code writes. */
function assistantLine(options: {
  messageId: string
  model?: string
  input?: number
  output?: number
  write1h?: number
  read?: number
  uuid?: string
  timestamp?: string
  sidechain?: boolean
  speed?: string
}): string {
  return JSON.stringify({
    parentUuid: 'parent',
    isSidechain: options.sidechain ?? false,
    type: 'assistant',
    uuid: options.uuid ?? `${options.messageId}-${Math.random()}`,
    requestId: `req_${options.messageId}`,
    timestamp: options.timestamp ?? '2026-08-11T11:33:22.579Z',
    cwd: '/Users/apple/ClaudeAsad',
    sessionId: 'sess-1',
    message: {
      id: options.messageId,
      model: options.model ?? 'claude-opus-5',
      role: 'assistant',
      type: 'message',
      content: [{ type: 'text', text: 'hi' }],
      usage: {
        input_tokens: options.input ?? 0,
        output_tokens: options.output ?? 0,
        cache_creation_input_tokens: options.write1h ?? 0,
        cache_read_input_tokens: options.read ?? 0,
        cache_creation: {
          ephemeral_1h_input_tokens: options.write1h ?? 0,
          ephemeral_5m_input_tokens: 0,
        },
        service_tier: 'standard',
        speed: options.speed ?? 'standard',
      },
    },
  })
}

describe('parseEventLine', () => {
  it('extracts an assistant request', () => {
    const event = parseEventLine(
      assistantLine({ messageId: 'msg_1', input: 2, output: 2540, write1h: 21_857, read: 30_415 }),
    )
    expect(event?.type).toBe('assistant')
    expect(event?.messageId).toBe('msg_1')
    expect(event?.model).toBe('claude-opus-5')
    expect(event?.usage?.cacheWrite1h).toBe(21_857)
    expect(event?.sessionId).toBe('sess-1')
    expect(event?.cwd).toBe('/Users/apple/ClaudeAsad')
    expect(event?.timestamp).toBe(Date.parse('2026-08-11T11:33:22.579Z'))
  })

  it('flags fast-mode requests so they can be priced at the premium rate', () => {
    expect(parseEventLine(assistantLine({ messageId: 'm', speed: 'fast' }))?.speed).toBe('fast')
    expect(parseEventLine(assistantLine({ messageId: 'm' }))?.speed).toBeUndefined()
  })

  it('flags sub-agent work', () => {
    expect(parseEventLine(assistantLine({ messageId: 'm', sidechain: true }))?.isSidechain).toBe(
      true,
    )
  })

  it('extracts a compaction boundary and the prompt size that triggered it', () => {
    const line = JSON.stringify({
      type: 'system',
      subtype: 'compact_boundary',
      content: 'Conversation compacted',
      timestamp: '2026-06-06T13:16:47.913Z',
      uuid: 'u1',
      compactMetadata: { trigger: 'auto', preTokens: 984_388, durationMs: 119_071 },
    })
    const event = parseEventLine(line)
    expect(event?.type).toBe('system')
    expect(event?.compactedFrom).toBe(984_388)
  })

  it('ignores everything that costs nothing', () => {
    expect(parseEventLine('')).toBeNull()
    expect(parseEventLine('   ')).toBeNull()
    expect(
      parseEventLine(JSON.stringify({ type: 'queue-operation', operation: 'enqueue' })),
    ).toBeNull()
    expect(
      parseEventLine(JSON.stringify({ type: 'user', message: { role: 'user', content: 'hi' } })),
    ).toBeNull()
    expect(parseEventLine(JSON.stringify({ type: 'system', subtype: 'api_error' }))).toBeNull()
  })

  it('survives a torn trailing line without throwing', () => {
    // The file is being appended to while we read it; a half-written last line
    // is normal, not an error.
    expect(parseEventLine('{"type":"assistant","message":{"id":"m","usa')).toBeNull()
    expect(parseEventLine('not json at all')).toBeNull()
    expect(parseEventLine('[1,2,3]')).toBeNull()
  })
})

describe('SessionAggregator', () => {
  function feed(aggregator: SessionAggregator, lines: string[]): void {
    for (const line of lines) {
      const event = parseEventLine(line)
      if (event) aggregator.add(event)
    }
  }

  it('counts a multi-block request exactly once', () => {
    // This is the whole ballgame. One API request emits one JSONL line per
    // content block (thinking, text, each tool_use) and every line repeats the
    // same usage object verbatim. Verified across 133 real transcripts: 2,801
    // multi-line requests, all byte-identical, up to 19 lines for one request.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'msg_1', uuid: 'a', input: 2, output: 2540, write1h: 21_857, read: 30_415 }),
      assistantLine({ messageId: 'msg_1', uuid: 'b', input: 2, output: 2540, write1h: 21_857, read: 30_415 }),
      assistantLine({ messageId: 'msg_1', uuid: 'c', input: 2, output: 2540, write1h: 21_857, read: 30_415 }),
    ])

    const summary = aggregator.summary()
    expect(summary.requests).toBe(1)
    expect(summary.usage.output).toBe(2540)
    expect(summary.usage.cacheWrite1h).toBe(21_857)
    expect(summary.cost.cost.total).toBeCloseTo(0.2972875, 10)
  })

  it('accumulates genuinely distinct requests', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'msg_1', output: 1000 }),
      assistantLine({ messageId: 'msg_2', output: 1000 }),
    ])
    const summary = aggregator.summary()
    expect(summary.requests).toBe(2)
    expect(summary.usage.output).toBe(2000)
  })

  it('is idempotent when the same lines are replayed', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    const lines = [assistantLine({ messageId: 'msg_1', uuid: 'a', output: 1000 })]
    feed(aggregator, lines)
    feed(aggregator, lines)
    expect(aggregator.summary().requests).toBe(1)
  })

  it('splits usage per model and prices each on its own card', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-opus-5', output: 1_000_000 }),
      assistantLine({ messageId: 'm2', model: 'claude-haiku-4-5-20251001', output: 1_000_000 }),
    ])
    const summary = aggregator.summary()
    expect(summary.models).toContain('claude-opus-5')
    expect(summary.models).toContain('claude-haiku-4-5')
    expect(summary.cost.cost.total).toBeCloseTo(30, 6)
  })

  it('takes context from the latest prompt, never the running total', () => {
    // Summing prompts counts the same cached prefix once per turn and reports
    // an occupancy many times the real one.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', read: 100_000, output: 10 }),
      assistantLine({ messageId: 'm2', read: 150_000, output: 10 }),
      assistantLine({ messageId: 'm3', read: 200_000, output: 10 }),
    ])
    const summary = aggregator.summary()
    expect(summary.context?.tokens).toBe(200_000)
    expect(summary.context?.window).toBe(1_000_000)
    expect(summary.context?.percent).toBeCloseTo(20, 10)
  })

  it('treats the first prompt as the fixed prefix and warns when it is bloated', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-haiku-4-5', write1h: 60_000, output: 10 }),
      assistantLine({ messageId: 'm2', model: 'claude-haiku-4-5', read: 65_000, output: 10 }),
    ])
    const summary = aggregator.summary()
    expect(summary.preContextTokens).toBe(60_000) // 30% of Haiku's 200k window
    expect(summary.warnings.some((w) => w.kind === 'pre-context')).toBe(true)
  })

  it('keeps tokens from a request with no model id, flagged as unpriced', () => {
    // Regression: every bucket is keyed on the model id, so a usage record with
    // no model silently dropped its tokens out of the session total while still
    // counting as a request.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    const line = JSON.stringify({
      type: 'assistant',
      uuid: 'u1',
      timestamp: '2026-08-11T10:00:00.000Z',
      isSidechain: false,
      message: { id: 'm1', role: 'assistant', usage: { input_tokens: 500, output_tokens: 700 } },
    })
    const event = parseEventLine(line)
    expect(event?.model).toBeUndefined()
    aggregator.add(event!)

    const summary = aggregator.summary()
    expect(summary.usage.input).toBe(500)
    expect(summary.usage.output).toBe(700)
    expect(summary.cost.unpricedModels).toEqual([UNKNOWN_MODEL])
    // Unpriced, not free: the money stays at zero and the UI is told why.
    expect(summary.cost.cost.total).toBe(0)
  })

  it('still ignores synthetic messages entirely', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    aggregator.add(
      parseEventLine(
        JSON.stringify({
          type: 'assistant',
          uuid: 'u1',
          isSidechain: false,
          message: {
            id: 'm1',
            model: '<synthetic>',
            role: 'assistant',
            usage: { input_tokens: 0, output_tokens: 0 },
          },
        }),
      )!,
    )
    expect(aggregator.summary().cost.unpricedModels).toEqual([])
  })

  it('charges a fast-mode request at the premium rate', () => {
    // Regression: `speed: fast` was parsed off the wire and then dropped on the
    // floor by the aggregator, so an Opus fast session billed at $25/M output
    // instead of $50/M — half price.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-opus-5', output: 1_000_000, speed: 'fast' }),
    ])
    expect(aggregator.summary().cost.cost.total).toBeCloseTo(50, 6)
  })

  it('keeps fast and standard requests to one model on separate rate cards', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-opus-5', output: 1_000_000 }),
      assistantLine({ messageId: 'm2', model: 'claude-opus-5', output: 1_000_000, speed: 'fast' }),
    ])
    const summary = aggregator.summary()
    expect(summary.cost.cost.total).toBeCloseTo(75, 6) // $25 standard + $50 fast
    expect(summary.usage.output).toBe(2_000_000)
    expect(summary.cost.unpricedModels).toEqual([])
  })

  it('does not let a sub-agent model pick the context window', () => {
    // Regression: the window came from whichever model spoke last, including a
    // sidechain. A Haiku Task finishing after an Opus turn pinned a 200k window
    // onto the main thread's 1M-token conversation and reported a 150k prompt
    // as "75% full" with a critical bloat warning.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-opus-5', read: 100_000, output: 10 }),
      assistantLine({
        messageId: 'm2',
        model: 'claude-haiku-4-5',
        read: 20_000,
        output: 10,
        sidechain: true,
      }),
    ])
    const summary = aggregator.summary()
    expect(summary.context?.window).toBe(1_000_000)
    expect(summary.context?.tokens).toBe(100_000)
    expect(summary.context?.percent).toBeCloseTo(10, 10)
    expect(summary.context?.level).toBe('ok')
    expect(summary.warnings).toEqual([])
  })

  it('does not let a sub-agent prompt widen the main thread window', () => {
    // The high-water mark only promotes a window when the *main thread* proves
    // it is bigger; a 900k sub-agent prompt lives in its own context.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-haiku-4-5', read: 50_000, output: 10 }),
      assistantLine({
        messageId: 'm2',
        model: 'claude-opus-5',
        read: 900_000,
        output: 10,
        sidechain: true,
      }),
    ])
    const summary = aggregator.summary()
    expect(summary.context?.window).toBe(200_000)
    expect(summary.context?.percent).toBeCloseTo(25, 10)
  })

  it('still resolves a window when every request is a sub-agent one', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-opus-5', read: 1000, output: 10, sidechain: true }),
    ])
    const summary = aggregator.summary()
    // No main-thread prompt, so no context reading — but the spend still counts.
    expect(summary.context).toBeNull()
    expect(summary.requests).toBe(1)
    expect(summary.cost.cost.total).toBeGreaterThan(0)
  })

  it('does not let a sub-agent prompt masquerade as the main thread context', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', read: 500_000, output: 10 }),
      assistantLine({ messageId: 'm2', read: 20_000, output: 10, sidechain: true }),
    ])
    const summary = aggregator.summary()
    expect(summary.context?.tokens).toBe(500_000)
    expect(summary.sidechainRequests).toBe(1)
    // Sub-agent spend is still real spend and still counted.
    expect(summary.requests).toBe(2)
  })

  it('counts compactions and lets them widen an understated window', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-haiku-4-5', read: 1000, output: 10 }),
      JSON.stringify({
        type: 'system',
        subtype: 'compact_boundary',
        timestamp: '2026-06-06T13:16:47.913Z',
        compactMetadata: { trigger: 'auto', preTokens: 984_388 },
      }),
      assistantLine({ messageId: 'm2', model: 'claude-haiku-4-5', read: 50_000, output: 10 }),
    ])
    const summary = aggregator.summary()
    expect(summary.compactions).toBe(1)
    // Haiku's table window is 200k, but a 984k prompt proves otherwise.
    expect(summary.context?.window).toBe(1_000_000)
    // Post-compaction the live prompt is small again.
    expect(summary.context?.tokens).toBe(50_000)
  })

  it('records the session id, cwd and activity span', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', timestamp: '2026-08-11T10:00:00.000Z' }),
      assistantLine({ messageId: 'm2', timestamp: '2026-08-11T11:00:00.000Z' }),
    ])
    const summary = aggregator.summary()
    expect(summary.sessionId).toBe('sess-1')
    expect(summary.cwd).toBe('/Users/apple/ClaudeAsad')
    expect(summary.startedAt).toBe(Date.parse('2026-08-11T10:00:00.000Z'))
    expect(summary.lastActivityAt).toBe(Date.parse('2026-08-11T11:00:00.000Z'))
  })

  it('prices against when the work ran, not when the panel was opened', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({
        messageId: 'm1',
        model: 'claude-sonnet-5',
        output: 1_000_000,
        timestamp: '2026-08-11T10:00:00.000Z',
      }),
    ])
    // Sonnet 5's introductory $10/M output rate was live on that date.
    expect(aggregator.summary().cost.cost.total).toBeCloseTo(10, 6)
  })

  it('starts empty and reports no context before the first request', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    expect(aggregator.isEmpty).toBe(true)
    const summary = aggregator.summary()
    expect(summary.context).toBeNull()
    expect(summary.cost.cost.total).toBe(0)
    expect(summary.warnings).toEqual([])
  })

  it('clears everything on reset, so a replaced file cannot double-count', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [assistantLine({ messageId: 'm1', output: 1000 })])
    aggregator.reset()
    expect(aggregator.isEmpty).toBe(true)
    // The dedup set is cleared too, so the same ids can be re-read.
    feed(aggregator, [assistantLine({ messageId: 'm1', output: 1000 })])
    expect(aggregator.summary().requests).toBe(1)
  })

  it('derives a session id from the filename when the transcript has none', () => {
    const aggregator = new SessionAggregator('/tmp/749c33cd-a336.jsonl')
    expect(aggregator.summary().sessionId).toBe('749c33cd-a336')
  })
})
