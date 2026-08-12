import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  cancelQuietly,
  formatBytes,
  groupHits,
  HighlightedSnippet,
  relativeTime,
  SearchPanel,
  snippetSegments,
  summarize,
  type SearchBridge,
  type SearchHit,
  type SearchResult,
  type Snippet,
} from './SearchPanel'

/**
 * There is no DOM environment in this project's test setup, so these render to
 * static markup. That covers the highlighting maths and the accessible
 * structure — the parts most likely to rot in a refactor. The debounced query
 * path is state, and is exercised through the main-process search tests.
 */

const NOW = Date.parse('2026-08-12T12:00:00.000Z')

function snippet(text: string, ranges: Array<[number, number]>): Snippet {
  return {
    text,
    ranges: ranges.map(([start, length]) => ({ start, length })),
    truncatedStart: false,
    truncatedEnd: false,
  }
}

function hit(overrides: Partial<SearchHit> & { sessionId: string }): SearchHit {
  return {
    transcriptPath: `/tmp/${overrides.sessionId}.jsonl`,
    cwd: '/Users/apple/Projects/terminaldeck',
    projectName: 'terminaldeck',
    at: NOW - 60_000,
    role: 'user',
    isSidechain: false,
    score: 5,
    matches: 1,
    snippet: snippet('alerts panel', [[0, 6]]),
    ...overrides,
  }
}

describe('snippetSegments', () => {
  it('splits into plain and matched runs', () => {
    const segments = snippetSegments(snippet('find the needle here', [[9, 6]]))
    expect(segments).toEqual([
      { text: 'find the ', match: false },
      { text: 'needle', match: true },
      { text: ' here', match: false },
    ])
  })

  it('merges overlapping ranges instead of emitting a negative slice', () => {
    // "session" and "sessions" both match, and their ranges overlap.
    const segments = snippetSegments(snippet('sessions here', [[0, 7], [0, 8]]))
    expect(segments).toEqual([
      { text: 'sessions', match: true },
      { text: ' here', match: false },
    ])
    expect(segments.map((segment) => segment.text).join('')).toBe('sessions here')
  })

  it('never loses or duplicates a character', () => {
    const text = 'alpha beta gamma beta delta'
    const segments = snippetSegments(
      snippet(text, [[6, 4], [17, 4], [0, 5]]),
    )
    expect(segments.map((segment) => segment.text).join('')).toBe(text)
  })

  it('ignores a range that points past the end of the text', () => {
    const segments = snippetSegments(snippet('short', [[99, 4]]))
    expect(segments).toEqual([{ text: 'short', match: false }])
  })

  it('handles a snippet with no matches at all', () => {
    expect(snippetSegments(snippet('nothing here', []))).toEqual([
      { text: 'nothing here', match: false },
    ])
  })
})

describe('HighlightedSnippet', () => {
  it('marks the matched run and escapes everything else', () => {
    const markup = renderToStaticMarkup(
      <HighlightedSnippet snippet={snippet('run <script>alert(1)</script> now', [[0, 3]])} />,
    )
    expect(markup).toContain('<mark class="search-mark">run</mark>')
    // React escapes text children, so a transcript full of markup cannot inject
    // anything — this panel never touches dangerouslySetInnerHTML.
    expect(markup).toContain('&lt;script&gt;')
    expect(markup).not.toContain('<script>')
  })

  it('shows an ellipsis on a clipped edge', () => {
    const markup = renderToStaticMarkup(
      <HighlightedSnippet
        snippet={{ ...snippet('middle of a sentence', [[0, 6]]), truncatedStart: true, truncatedEnd: true }}
      />,
    )
    expect(markup.match(/…/g)).toHaveLength(2)
  })
})

describe('groupHits', () => {
  it('keeps ranking order and collects a session\'s hits together', () => {
    const groups = groupHits([
      hit({ sessionId: 'b' }),
      hit({ sessionId: 'a' }),
      hit({ sessionId: 'b', at: NOW }),
    ])
    expect(groups.map((group) => group.sessionId)).toEqual(['b', 'a'])
    expect(groups[0].hits).toHaveLength(2)
  })

  it('dates a group by its most recent hit', () => {
    const groups = groupHits([hit({ sessionId: 'a', at: NOW - 5000 }), hit({ sessionId: 'a', at: NOW })])
    expect(groups[0].at).toBe(NOW)
  })
})

describe('relativeTime', () => {
  it('steps through minutes, hours and days', () => {
    expect(relativeTime(NOW - 30_000, NOW)).toBe('just now')
    expect(relativeTime(NOW - 5 * 60_000, NOW)).toBe('5m ago')
    expect(relativeTime(NOW - 3 * 3_600_000, NOW)).toBe('3h ago')
    expect(relativeTime(NOW - 4 * 86_400_000, NOW)).toBe('4d ago')
  })

  it('falls back to a date past a month', () => {
    expect(relativeTime(NOW - 200 * 86_400_000, NOW)).toMatch(/\d{4}/)
  })

  it('renders nothing for a hit with no timestamp', () => {
    expect(relativeTime(0, NOW)).toBe('')
  })
})

describe('formatBytes', () => {
  it('picks a unit that suits the magnitude', () => {
    expect(formatBytes(512)).toBe('512 B')
    expect(formatBytes(2_400)).toBe('2 KB')
    expect(formatBytes(118_900_000)).toBe('119 MB')
    expect(formatBytes(1_400_000_000)).toBe('1.4 GB')
  })
})

describe('summarize', () => {
  const base: SearchResult = {
    query: 'alerts',
    scope: 'project',
    hits: [],
    sessionsScanned: 3,
    sessionsSkipped: 0,
    bytesScanned: 1_000_000,
    totalHits: 0,
    truncated: false,
    cancelled: false,
    tookMs: 42,
  }

  it('says how much was looked at when nothing matched', () => {
    expect(summarize(base, 0)).toBe('No matches in 3 sessions.')
  })

  it('counts hits and sessions, and warns when the list was cut', () => {
    const line = summarize({ ...base, hits: [hit({ sessionId: 'a' })], truncated: true }, 1)
    expect(line).toContain('1 hit in 1 session')
    expect(line).toContain('narrow the query')
  })
})

describe('cancelQuietly', () => {
  it('asks the main process to drop the scan', () => {
    // Regression: closing the panel left the search running. `runId` stops a
    // stale result being shown; it does not stop the main process streaming
    // every transcript in every project for a panel nobody is looking at.
    let asked = 0
    const bridge = {
      searchSessions: async () => ({ ok: false as const, error: 'x', message: 'x' }),
      cancelSessionSearch: async () => {
        asked += 1
      },
    }
    cancelQuietly(bridge)
    expect(asked).toBe(1)
  })

  it('survives a bridge with no cancel channel and a null bridge', () => {
    expect(() => cancelQuietly(null)).not.toThrow()
    const old = { searchSessions: async () => ({ ok: false as const, error: 'x', message: 'x' }) }
    expect(() => cancelQuietly(old as unknown as SearchBridge)).not.toThrow()
  })

  it('swallows a rejection rather than leaving one unhandled', async () => {
    // A window that is closing rejects every in-flight invoke, and the caller
    // is a cleanup function with nowhere to report it.
    const closing = {
      searchSessions: async () => ({ ok: false as const, error: 'x', message: 'x' }),
      cancelSessionSearch: async () => {
        throw new Error('render frame was disposed')
      },
    }
    expect(() => cancelQuietly(closing)).not.toThrow()
    // Let the rejection settle; an unhandled one would fail the run.
    await new Promise((resolve) => setTimeout(resolve, 0))
  })
})

describe('SearchPanel', () => {
  it('explains itself when the bridge is missing rather than rendering an empty box', () => {
    const markup = renderToStaticMarkup(<SearchPanel projectPath="/Users/apple/Projects/terminaldeck" />)
    expect(markup).toContain('not connected to the main process')
  })

  it('exposes the scope and filter toggles as pressed-state buttons', () => {
    const markup = renderToStaticMarkup(<SearchPanel projectPath="/Users/apple/Projects/terminaldeck" />)
    expect(markup).toContain('aria-label="Search past sessions"')
    expect(markup).toContain('aria-pressed="true"')
    expect(markup).toContain('This project')
    expect(markup).toContain('Everywhere')
  })
})
