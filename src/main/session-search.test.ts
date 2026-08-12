import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { encodeProjectPath } from './transcript'
import {
  buildSnippet,
  condense,
  DEADLINE_CHECK_LINES,
  DEFAULT_ROLES,
  hasNestedRepeat,
  parseQuery,
  parseSearchLine,
  scoreHit,
  searchSessions,
  tokenizeQuery,
  type SearchHit,
  type SearchResult,
} from './session-search'

/* ------------------------------------------------------------------ setup -- */

const PROJECT = '/Users/apple/Projects/pawl'
const OTHER_PROJECT = '/Users/apple/Projects/other'
const NOW = Date.parse('2026-08-12T12:00:00.000Z')

const temps: string[] = []

afterAll(async () => {
  await Promise.all(temps.map((dir) => rm(dir, { recursive: true, force: true })))
})

/** A config dir laid out exactly like `~/.claude`, so the real locator is exercised. */
async function makeConfigDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'pawl-session-search-'))
  temps.push(dir)
  await mkdir(join(dir, 'projects'), { recursive: true })
  return dir
}

async function writeTranscript(
  configDir: string,
  cwd: string,
  sessionId: string,
  lines: unknown[],
): Promise<string> {
  const dir = join(configDir, 'projects', encodeProjectPath(cwd))
  await mkdir(dir, { recursive: true })
  const path = join(dir, `${sessionId}.jsonl`)
  await writeFile(path, lines.map((line) => JSON.stringify(line)).join('\n') + '\n', 'utf8')
  return path
}

/** Shapes copied from the field layout of real transcripts, not from any source. */
function userLine(text: string, at: string, extra: Record<string, unknown> = {}): unknown {
  return {
    type: 'user',
    sessionId: 'sess',
    cwd: PROJECT,
    isSidechain: false,
    timestamp: at,
    message: { role: 'user', content: text },
    ...extra,
  }
}

function assistantLine(text: string, at: string, extra: Record<string, unknown> = {}): unknown {
  return {
    type: 'assistant',
    sessionId: 'sess',
    cwd: PROJECT,
    isSidechain: false,
    timestamp: at,
    message: { role: 'assistant', model: 'claude-opus-5', content: [{ type: 'text', text }] },
    ...extra,
  }
}

function toolUseLine(name: string, input: unknown, at: string): unknown {
  return {
    type: 'assistant',
    sessionId: 'sess',
    cwd: PROJECT,
    isSidechain: false,
    timestamp: at,
    message: { role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_1', name, input }] },
  }
}

function toolResultLine(content: unknown, at: string): unknown {
  return {
    type: 'user',
    sessionId: 'sess',
    cwd: PROJECT,
    isSidechain: false,
    timestamp: at,
    message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_1', content }] },
  }
}

function ok(result: SearchResult | { error: string; message: string }): SearchResult {
  if ('error' in result) throw new Error(`expected a result, got ${result.error}: ${result.message}`)
  return result
}

function highlighted(hit: SearchHit): string[] {
  return hit.snippet.ranges.map((range) => hit.snippet.text.slice(range.start, range.start + range.length))
}

/* -------------------------------------------------------------- tokenizer -- */

describe('tokenizeQuery', () => {
  it('splits on whitespace', () => {
    expect(tokenizeQuery('context bloat')).toEqual([
      { text: 'context', negated: false, phrase: false },
      { text: 'bloat', negated: false, phrase: false },
    ])
  })

  it('keeps a quoted phrase together', () => {
    expect(tokenizeQuery('"context window" full')).toEqual([
      { text: 'context window', negated: false, phrase: true },
      { text: 'full', negated: false, phrase: false },
    ])
  })

  it('reads a leading dash as an exclusion, including on a phrase', () => {
    expect(tokenizeQuery('deploy -"dry run" -staging')).toEqual([
      { text: 'deploy', negated: false, phrase: false },
      { text: 'dry run', negated: true, phrase: true },
      { text: 'staging', negated: true, phrase: false },
    ])
  })

  it('treats an unterminated quote as a phrase to end of input, so typing does not error', () => {
    expect(tokenizeQuery('"half a phrase')).toEqual([
      { text: 'half a phrase', negated: false, phrase: true },
    ])
  })

  it('drops a bare dash', () => {
    expect(tokenizeQuery('alpha - beta')).toEqual([
      { text: 'alpha', negated: false, phrase: false },
      { text: 'beta', negated: false, phrase: false },
    ])
  })
})

describe('parseQuery', () => {
  it('refuses a one-character query', () => {
    const parsed = parseQuery('a')
    expect(parsed.ok).toBe(false)
    if (!parsed.ok) expect(parsed.error).toBe('query-too-short')
  })

  it('refuses a query that is only exclusions', () => {
    const parsed = parseQuery('-staging')
    expect(parsed.ok).toBe(false)
    if (!parsed.ok) expect(parsed.error).toBe('query-too-short')
  })

  it('reports an invalid regular expression instead of throwing', () => {
    const parsed = parseQuery('foo(', { regex: true })
    expect(parsed.ok).toBe(false)
    if (!parsed.ok) expect(parsed.error).toBe('invalid-regex')
  })

  it('escapes regex metacharacters in plain-text mode', () => {
    const parsed = parseQuery('cost.ts')
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.query.include[0].pattern.test('cost.ts')).toBe(true)
    parsed.query.include[0].pattern.lastIndex = 0
    expect(parsed.query.include[0].pattern.test('costXts')).toBe(false)
  })

  it('refuses a regex that repeats inside a repeat', () => {
    // Regression: `RegExp.exec` cannot be interrupted, so a pattern like this
    // one froze the whole main process. Measured before the guard, against a
    // transcript line of n `a`s: n=22 0.6s, n=26 0.9s, n=30 14.4s. The abort
    // signal and the time budget were both powerless — nothing else runs.
    const parsed = parseQuery('(a+)+$', { regex: true })
    expect(parsed.ok).toBe(false)
    if (!parsed.ok) expect(parsed.error).toBe('unsafe-regex')
  })

  it('still accepts ordinary regular expressions', () => {
    for (const source of ['v\\d+\\.\\d+', '(foo|bar)+', 'TODO.*', '^\\s*import', '(a{2,3})+']) {
      const parsed = parseQuery(source, { regex: true })
      expect(parsed.ok, source).toBe(true)
    }
  })

  it('only prefilters on a term JSON escaping cannot alter', () => {
    const safe = parseQuery('registerAlertsIpc')
    expect(safe.ok && safe.query.prefilter).not.toBeNull()
    // A quote or a space could be written escaped in the file, so a raw-line
    // test on it risks a false negative — the one error a search must not make.
    const risky = parseQuery('"needs input"')
    expect(risky.ok && risky.query.prefilter).toBeNull()
    const unicode = parseQuery('café')
    expect(unicode.ok && unicode.query.prefilter).toBeNull()
  })
})

describe('hasNestedRepeat', () => {
  it('spots an unbounded repeat wrapped in another one', () => {
    for (const source of ['(a+)+', '(a*)*', '(\\s+)+$', '([a-z]+)*x', '(?:\\d+)+', '((a+))+', '(\\d{2,})+']) {
      expect(hasNestedRepeat(source), source).toBe(true)
    }
  })

  it('leaves ordinary patterns alone', () => {
    for (const source of [
      '(foo|bar)+',
      'v\\d+\\.\\d+\\.\\d+',
      '(a{2,3})+',
      '(abc)+',
      '\\[[^\\]]*\\]+',
      'a+b+c+',
      '(a+)',
      '[+*]+',
    ]) {
      expect(hasNestedRepeat(source), source).toBe(false)
    }
  })

  it('does not read a quantifier out of a character class or an escape', () => {
    // `[*+]` is two literals, and `\(` is not a group — misreading either would
    // reject patterns that are perfectly safe.
    expect(hasNestedRepeat('(x[*+])+')).toBe(false)
    expect(hasNestedRepeat('(\\+)+')).toBe(false)
  })
})

/* ------------------------------------------------------------ line parsing -- */

describe('parseSearchLine', () => {
  it('reads a typed prompt from a string content field', () => {
    const parsed = parseSearchLine(JSON.stringify(userLine('rebuild the alerts panel', '2026-08-01T10:00:00Z')))
    expect(parsed?.blocks).toEqual([{ role: 'user', text: 'rebuild the alerts panel' }])
  })

  it('reads assistant text and thinking as separate roles', () => {
    const line = {
      type: 'assistant',
      timestamp: '2026-08-01T10:00:00Z',
      isSidechain: false,
      message: {
        content: [
          { type: 'thinking', thinking: 'weighing two designs' },
          { type: 'text', text: 'here is the plan' },
        ],
      },
    }
    const parsed = parseSearchLine(JSON.stringify(line))
    expect(parsed?.blocks.map((block) => block.role)).toEqual(['thinking', 'assistant'])
  })

  it('indexes a tool call by name and arguments', () => {
    const parsed = parseSearchLine(JSON.stringify(toolUseLine('Read', { file_path: '/tmp/x.ts' }, '2026-08-01T10:00:00Z')))
    expect(parsed?.blocks[0].role).toBe('tool')
    expect(parsed?.blocks[0].tool).toBe('Read')
    expect(parsed?.blocks[0].text).toContain('/tmp/x.ts')
  })

  it('flattens a tool result whether its content is a string or an array', () => {
    const asString = parseSearchLine(JSON.stringify(toolResultLine('exit code 0', '2026-08-01T10:00:00Z')))
    expect(asString?.blocks[0].text).toBe('exit code 0')

    const asArray = parseSearchLine(
      JSON.stringify(
        toolResultLine([{ type: 'text', text: 'first' }, { type: 'image', source: {} }, { type: 'text', text: 'second' }], '2026-08-01T10:00:00Z'),
      ),
    )
    // Both real shapes occur in one transcript here: 1,346 strings, 1,829 arrays.
    expect(asArray?.blocks[0].text).toBe('first\nsecond')
  })

  it('skips the CLI-injected meta lines nobody typed', () => {
    const parsed = parseSearchLine(
      JSON.stringify(userLine('<local-command-caveat>…</local-command-caveat>', '2026-08-01T10:00:00Z', { isMeta: true })),
    )
    expect(parsed).toBeNull()
  })

  it('skips bookkeeping line types that carry no conversation', () => {
    for (const type of ['attachment', 'queue-operation', 'mode', 'last-prompt', 'pr-link', 'ai-title']) {
      expect(parseSearchLine(JSON.stringify({ type, timestamp: '2026-08-01T10:00:00Z' }))).toBeNull()
    }
  })

  it('survives a torn final line', () => {
    expect(parseSearchLine('{"type":"user","message":{"content":"half a li')).toBeNull()
  })

  it('caps a single block so one dumped file cannot dominate a search', () => {
    const huge = userLine('x'.repeat(200_000), '2026-08-01T10:00:00Z')
    const parsed = parseSearchLine(JSON.stringify(huge))
    expect(parsed?.blocks[0].text.length).toBe(120_000)
  })
})

/* ----------------------------------------------------------------- snippet -- */

describe('condense', () => {
  it('collapses whitespace and moves the highlight offsets with it', () => {
    const text = 'alpha\n\n   beta   gamma'
    const start = text.indexOf('beta')
    const out = condense(text, [{ start, length: 4 }])
    expect(out.text).toBe('alpha beta gamma')
    expect(out.text.slice(out.ranges[0].start, out.ranges[0].start + out.ranges[0].length)).toBe('beta')
  })

  it('drops leading whitespace rather than starting the snippet with a space', () => {
    expect(condense('   padded', []).text).toBe('padded')
  })
})

describe('buildSnippet', () => {
  it('centres the window on the first match and marks both edges truncated', () => {
    const text = `${'a '.repeat(400)}needle${' b'.repeat(400)}`
    const snippet = buildSnippet(text, [{ start: text.indexOf('needle'), length: 6 }])
    expect(snippet.truncatedStart).toBe(true)
    expect(snippet.truncatedEnd).toBe(true)
    expect(snippet.text.slice(snippet.ranges[0].start, snippet.ranges[0].start + 6)).toBe('needle')
  })

  it('never returns a range pointing past the end of the text it trimmed', () => {
    const text = `needle${' filler'.repeat(200)}needle`
    const ranges = [
      { start: 0, length: 6 },
      { start: text.lastIndexOf('needle'), length: 6 },
    ]
    const snippet = buildSnippet(text, ranges)
    for (const range of snippet.ranges) {
      expect(range.start + range.length).toBeLessThanOrEqual(snippet.text.length)
    }
  })
})

/* ------------------------------------------------------------------ score -- */

describe('scoreHit', () => {
  const base = {
    termsMatched: 1,
    termsTotal: 1,
    matches: 1,
    phraseHit: false,
    wordBoundaryHit: false,
    at: NOW,
    now: NOW,
    isSidechain: false,
  }

  it('ranks a prompt above the tool output that answered it', () => {
    expect(scoreHit({ ...base, role: 'user' })).toBeGreaterThan(scoreHit({ ...base, role: 'tool' }))
  })

  it('ranks a recent hit above an identical one from months ago', () => {
    const old = scoreHit({ ...base, role: 'user', at: NOW - 120 * 24 * 60 * 60 * 1000 })
    expect(scoreHit({ ...base, role: 'user' })).toBeGreaterThan(old)
  })

  it('rewards a phrase match over a loose word match', () => {
    expect(scoreHit({ ...base, role: 'user', phraseHit: true })).toBeGreaterThan(
      scoreHit({ ...base, role: 'user' }),
    )
  })

  it('discounts sub-agent chatter', () => {
    expect(scoreHit({ ...base, role: 'user', isSidechain: true })).toBeLessThan(
      scoreHit({ ...base, role: 'user' }),
    )
  })
})

/* --------------------------------------------------------------- end to end -- */

describe('searchSessions', () => {
  it('finds a prompt across a project and highlights the match', async () => {
    const config = await makeConfigDir()
    await writeTranscript(config, PROJECT, 'sess-a', [
      userLine('please wire the alerts panel into the sidebar', '2026-08-10T09:00:00Z'),
      assistantLine('wiring it now', '2026-08-10T09:00:10Z'),
    ])

    const result = ok(await searchSessions(PROJECT, 'alerts panel', { configDir: config, now: NOW }))
    expect(result.hits).toHaveLength(1)
    expect(result.hits[0].sessionId).toBe('sess-a')
    expect(result.hits[0].role).toBe('user')
    expect(result.hits[0].cwd).toBe(PROJECT)
    expect(highlighted(result.hits[0])).toEqual(['alerts', 'panel'])
  })

  it('requires every term inside one block, not merely inside one session', async () => {
    const config = await makeConfigDir()
    await writeTranscript(config, PROJECT, 'sess-split', [
      userLine('let us talk about alerts', '2026-08-10T09:00:00Z'),
      userLine('and separately about the panel', '2026-08-10T09:01:00Z'),
    ])

    const result = ok(await searchSessions(PROJECT, 'alerts panel', { configDir: config, now: NOW }))
    expect(result.hits).toHaveLength(0)
  })

  it('honours an exclusion term', async () => {
    const config = await makeConfigDir()
    await writeTranscript(config, PROJECT, 'sess-b', [
      userLine('deploy to production now', '2026-08-10T09:00:00Z'),
      userLine('deploy to staging first', '2026-08-10T09:01:00Z'),
    ])

    const result = ok(await searchSessions(PROJECT, 'deploy -staging', { configDir: config, now: NOW }))
    expect(result.hits).toHaveLength(1)
    expect(result.hits[0].snippet.text).toContain('production')
  })

  it('is case-insensitive by default and exact when asked', async () => {
    const config = await makeConfigDir()
    await writeTranscript(config, PROJECT, 'sess-c', [
      userLine('check the Readiness score', '2026-08-10T09:00:00Z'),
    ])

    const loose = ok(await searchSessions(PROJECT, 'readiness', { configDir: config, now: NOW }))
    expect(loose.hits).toHaveLength(1)

    const strict = ok(
      await searchSessions(PROJECT, 'readiness', { configDir: config, now: NOW, caseSensitive: true }),
    )
    expect(strict.hits).toHaveLength(0)
  })

  it('searches tool calls only when the tool role is asked for', async () => {
    const config = await makeConfigDir()
    await writeTranscript(config, PROJECT, 'sess-d', [
      toolUseLine('Bash', { command: 'npm run typecheck' }, '2026-08-10T09:00:00Z'),
    ])

    const conversation = ok(await searchSessions(PROJECT, 'typecheck', { configDir: config, now: NOW }))
    expect(conversation.hits).toHaveLength(0)

    const withTools = ok(
      await searchSessions(PROJECT, 'typecheck', {
        configDir: config,
        now: NOW,
        roles: [...DEFAULT_ROLES, 'tool'],
      }),
    )
    expect(withTools.hits).toHaveLength(1)
    expect(withTools.hits[0].tool).toBe('Bash')
  })

  it('supports regex mode', async () => {
    const config = await makeConfigDir()
    await writeTranscript(config, PROJECT, 'sess-e', [
      userLine('bump version to v2.14.3 please', '2026-08-10T09:00:00Z'),
    ])

    const result = ok(
      await searchSessions(PROJECT, 'v\\d+\\.\\d+\\.\\d+', { configDir: config, now: NOW, regex: true }),
    )
    expect(highlighted(result.hits[0])).toEqual(['v2.14.3'])
  })

  it('returns a query error rather than throwing on a bad regex', async () => {
    const config = await makeConfigDir()
    const result = await searchSessions(PROJECT, 'foo(', { configDir: config, regex: true })
    expect('error' in result && result.error).toBe('invalid-regex')
  })

  it('stays inside one project by default and reaches every project on request', async () => {
    const config = await makeConfigDir()
    await writeTranscript(config, PROJECT, 'sess-here', [
      userLine('the widget grid needs work', '2026-08-10T09:00:00Z'),
    ])
    await writeTranscript(config, OTHER_PROJECT, 'sess-there', [
      {
        type: 'user',
        sessionId: 'sess-there',
        cwd: OTHER_PROJECT,
        isSidechain: false,
        timestamp: '2026-08-09T09:00:00Z',
        message: { role: 'user', content: 'the widget grid is fine over here' },
      },
    ])

    const scoped = ok(await searchSessions(PROJECT, 'widget grid', { configDir: config, now: NOW }))
    expect(scoped.hits.map((hit) => hit.sessionId)).toEqual(['sess-here'])

    const everywhere = ok(
      await searchSessions(PROJECT, 'widget grid', { configDir: config, now: NOW, scope: 'all' }),
    )
    expect(everywhere.hits.map((hit) => hit.sessionId).sort()).toEqual(['sess-here', 'sess-there'])
    // The directory encoding is one-way, so `cwd` has to come out of the file.
    expect(everywhere.hits.find((hit) => hit.sessionId === 'sess-there')?.cwd).toBe(OTHER_PROJECT)
  })

  it('caps the result list and says so', async () => {
    const config = await makeConfigDir()
    const lines = Array.from({ length: 40 }, (_, i) =>
      userLine(`repeat the marker number ${i}`, '2026-08-10T09:00:00Z'),
    )
    await writeTranscript(config, PROJECT, 'sess-many', lines)

    const result = ok(await searchSessions(PROJECT, 'marker', { configDir: config, now: NOW, maxHits: 3 }))
    expect(result.hits).toHaveLength(3)
    expect(result.truncated).toBe(true)
  })

  it('caps hits per session so one noisy transcript cannot crowd out the rest', async () => {
    const config = await makeConfigDir()
    await writeTranscript(
      config,
      PROJECT,
      'sess-noisy',
      Array.from({ length: 50 }, (_, i) => userLine(`marker ${i}`, '2026-08-10T09:00:00Z')),
    )
    await writeTranscript(config, PROJECT, 'sess-quiet', [
      userLine('marker mentioned once', '2026-08-11T09:00:00Z'),
    ])

    const result = ok(await searchSessions(PROJECT, 'marker', { configDir: config, now: NOW }))
    const sessions = new Set(result.hits.map((hit) => hit.sessionId))
    expect(sessions.has('sess-quiet')).toBe(true)
    expect(result.hits.filter((hit) => hit.sessionId === 'sess-noisy').length).toBeLessThanOrEqual(6)
  })

  it('returns nothing, quietly, when the project has never been used', async () => {
    const config = await makeConfigDir()
    const result = ok(await searchSessions('/Users/apple/Projects/never-opened', 'anything', {
      configDir: config,
      now: NOW,
    }))
    expect(result.hits).toEqual([])
    expect(result.sessionsScanned).toBe(0)
    expect(result.truncated).toBe(false)
  })

  it('reports cancellation instead of a partial result pretending to be complete', async () => {
    const config = await makeConfigDir()
    await writeTranscript(config, PROJECT, 'sess-cancel', [
      userLine('a marker to find', '2026-08-10T09:00:00Z'),
    ])
    const controller = new AbortController()
    controller.abort()

    const result = ok(
      await searchSessions(PROJECT, 'marker', { configDir: config, now: NOW, signal: controller.signal }),
    )
    expect(result.cancelled).toBe(true)
    expect(result.hits).toEqual([])
  })

  it('ignores a transcript older than the age window', async () => {
    const config = await makeConfigDir()
    await writeTranscript(config, PROJECT, 'sess-old', [
      userLine('an ancient marker', '2020-01-01T09:00:00Z'),
    ])

    // The cutoff is by file mtime, which is "now" for a file just written, so a
    // one-millisecond window is what proves the filter is applied at all.
    const result = ok(
      await searchSessions(PROJECT, 'marker', { configDir: config, now: NOW + 60_000, maxAgeMs: 1 }),
    )
    expect(result.hits).toEqual([])
  })

  it('centres the snippet on the rare term, not the common one', async () => {
    const config = await makeConfigDir()
    // Regression: `the` matched 200 times and took the entire highlight budget,
    // so `needle` was neither recorded nor visible — the snippet came back as
    // "the the the the…" and the word the user searched for was off the edge.
    await writeTranscript(config, PROJECT, 'sess-common', [
      userLine(`${'the '.repeat(200)}needle at the end`, '2026-08-10T09:00:00Z'),
    ])

    const result = ok(await searchSessions(PROJECT, 'the needle', { configDir: config, now: NOW }))
    expect(result.hits).toHaveLength(1)
    expect(result.hits[0].snippet.text).toContain('needle')
    expect(highlighted(result.hits[0])).toContain('needle')
  })

  it('refuses an exponential regex instead of freezing the process', async () => {
    const config = await makeConfigDir()
    await writeTranscript(config, PROJECT, 'sess-redos', [
      userLine(`${'a'.repeat(40)}!`, '2026-08-10T09:00:00Z'),
    ])

    const startedAt = Date.now()
    const result = await searchSessions(PROJECT, '(a+)+$', { configDir: config, now: NOW, regex: true })
    // 40 characters is roughly a thousand times the 14 seconds measured at 30.
    expect(Date.now() - startedAt).toBeLessThan(2_000)
    expect('error' in result && result.error).toBe('unsafe-regex')
  })

  it('stops at the time budget partway through one huge transcript', async () => {
    const config = await makeConfigDir()
    // Regression: the budget was only checked *between* files, so a single
    // transcript ran to completion however long it took — and then reported
    // `truncated: false`, claiming a complete answer.
    await writeTranscript(
      config,
      PROJECT,
      'sess-endless',
      Array.from({ length: DEADLINE_CHECK_LINES * 3 }, (_, i) =>
        userLine(`marker ${i}`, '2026-08-10T09:00:00Z'),
      ),
    )

    // A clock that stays at zero long enough for the file to be opened and then
    // runs away, so the budget can only bite *inside* the transcript. Asserting
    // on real elapsed time would make this test a race against the machine.
    let ticks = 0
    const clock = (): number => {
      ticks += 1
      // 1: startedAt. 2: the between-files check, which must pass.
      return ticks <= 2 ? 0 : 1_000_000
    }

    const result = ok(
      await searchSessions(PROJECT, 'marker', {
        configDir: config,
        now: NOW,
        clock,
        timeBudgetMs: 10,
        maxHits: 5_000,
        maxHitsPerSession: 5_000,
      }),
    )
    expect(result.truncated).toBe(true)
    // It got into the file...
    expect(result.sessionsScanned).toBe(1)
    // ...and stopped partway rather than reading all three batches of lines.
    expect(result.hits.length).toBeGreaterThan(0)
    expect(result.hits.length).toBeLessThan(DEADLINE_CHECK_LINES * 3)
  })

  it('does not enumerate every project when the search was already cancelled', async () => {
    const config = await makeConfigDir()
    for (let i = 0; i < 5; i += 1) {
      await writeTranscript(config, `/Users/apple/Projects/p${i}`, `sess-p${i}`, [
        userLine('a marker somewhere', '2026-08-10T09:00:00Z'),
      ])
    }
    const controller = new AbortController()
    controller.abort()

    const result = ok(
      await searchSessions(PROJECT, 'marker', {
        configDir: config,
        now: NOW,
        scope: 'all',
        signal: controller.signal,
      }),
    )
    expect(result.cancelled).toBe(true)
    expect(result.sessionsScanned).toBe(0)
    // Regression: enumeration used to run to completion before anything checked
    // the signal, so an all-projects search paid for a stat per transcript in
    // every project that has ever run — once per keystroke — after the user had
    // already moved on. Nothing collected means nothing was walked.
    expect(result.sessionsSkipped).toBe(0)
  })

  it('reads a line split across a chunk boundary without losing it', async () => {
    const config = await makeConfigDir()
    // Padding pushes the marker well past a 4 MB read boundary.
    const padding = Array.from({ length: 400 }, (_, i) =>
      userLine(`${'filler '.repeat(1500)}${i}`, '2026-08-10T09:00:00Z'),
    )
    await writeTranscript(config, PROJECT, 'sess-big', [
      ...padding,
      userLine('the needle is at the very end', '2026-08-10T09:30:00Z'),
    ])

    const result = ok(await searchSessions(PROJECT, 'needle', { configDir: config, now: NOW }))
    expect(result.hits).toHaveLength(1)
    expect(result.bytesScanned).toBeGreaterThan(4 * 1024 * 1024)
  })
})
