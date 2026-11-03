import { describe, expect, it } from 'vitest'
import {
  basenameStart,
  clampRanges,
  fuzzyMatch,
  fuzzyMatchPath,
  rankMatches,
  segmentByRanges,
  SCORES,
  type MatchRange,
} from './fuzzy'

/** Score or throw — most assertions here are about a match that must exist. */
function score(text: string, query: string): number {
  const result = fuzzyMatch(text, query)
  if (!result) throw new Error(`expected "${query}" to match "${text}"`)
  return result.score
}

function pathScore(path: string, query: string): number {
  const result = fuzzyMatchPath(path, query)
  if (!result) throw new Error(`expected "${query}" to match path "${path}"`)
  return result.score
}

/** The matched characters, as a string — easier to read than index pairs. */
function hits(text: string, query: string): string {
  const result = fuzzyMatch(text, query)
  if (!result) throw new Error(`expected "${query}" to match "${text}"`)
  return result.ranges.map((r) => text.slice(r.start, r.end)).join('|')
}

function order(paths: readonly string[], query: string): string[] {
  return rankMatches(paths, query, (p) => p, { path: true }).map((r) => r.item)
}

describe('fuzzyMatch — basics', () => {
  it('matches an exact string', () => {
    expect(fuzzyMatch('readme', 'readme')?.ranges).toEqual([{ start: 0, end: 6 }])
  })

  it('matches a subsequence', () => {
    expect(hits('CommandPalette', 'cmplt')).toBe('C|m|P|l|t')
  })

  it('returns null when a character is missing', () => {
    expect(fuzzyMatch('abc', 'abd')).toBeNull()
  })

  it('returns null when the characters are present but out of order', () => {
    expect(fuzzyMatch('abc', 'cab')).toBeNull()
  })

  it('treats an empty query as a neutral match', () => {
    expect(fuzzyMatch('anything', '')).toEqual({ score: 0, ranges: [] })
    expect(fuzzyMatch('anything', '   ')).toEqual({ score: 0, ranges: [] })
  })

  it('returns null when the query is longer than the text', () => {
    expect(fuzzyMatch('ab', 'abc')).toBeNull()
  })

  it('matches non-ASCII text', () => {
    expect(hits('café-menu.ts', 'café')).toBe('café')
  })
})

describe('fuzzyMatch — highlight ranges', () => {
  it('reports the ranges that produced the score, not the first ones found', () => {
    // A greedy scanner takes the `c` of `components` and highlights the wrong
    // characters. The optimal alignment is the CamelCase initials.
    expect(hits('src/components/CommandPalette.tsx', 'cp')).toBe('C|P')
  })

  it('merges adjacent matches into one range', () => {
    expect(fuzzyMatch('app.css', 'app')?.ranges).toEqual([{ start: 0, end: 3 }])
  })

  it('keeps separated matches as separate ranges', () => {
    expect(fuzzyMatch('a-b', 'ab')?.ranges).toEqual([
      { start: 0, end: 1 },
      { start: 2, end: 3 },
    ])
  })

  it('always returns exactly as many matched characters as the query has', () => {
    const query = 'rndst'
    const result = fuzzyMatch('src/renderer/state/store.tsx', query)
    const matched = result?.ranges.reduce((sum, r) => sum + (r.end - r.start), 0)
    expect(matched).toBe(query.length)
  })

  it('returns ranges in ascending, non-overlapping order', () => {
    const result = fuzzyMatch('src/main/session-activity.test.ts', 'sat')
    const ranges = result?.ranges ?? []
    for (let i = 1; i < ranges.length; i++) {
      expect(ranges[i].start).toBeGreaterThanOrEqual(ranges[i - 1].end)
    }
  })
})

describe('fuzzyMatch — consecutive characters win', () => {
  it('prefers a contiguous run over the same characters spread out', () => {
    expect(score('abc.txt', 'abc')).toBeGreaterThan(score('a_b_c.txt', 'abc'))
  })

  it('prefers a contiguous run even when the spread version hits boundaries', () => {
    // Three word boundaries would otherwise cancel out three consecutive
    // bonuses exactly; the run inherits its start bonus so it stays ahead.
    expect(score('abc', 'abc')).toBeGreaterThan(score('a-b-c', 'abc'))
  })

  it('scores a longer run higher than a shorter one', () => {
    const two = score('ab-cd', 'abc')
    const three = score('abc-d', 'abc')
    expect(three).toBeGreaterThan(two)
  })

  it('charges more for a wider gap', () => {
    expect(score('ab', 'ab')).toBeGreaterThan(score('a_b', 'ab'))
    expect(score('axb', 'ab')).toBeGreaterThan(score('axxxxb', 'ab'))
  })
})

describe('fuzzyMatch — word boundaries win', () => {
  it('prefers the start of a word over the middle of one', () => {
    expect(score('my-store.ts', 'store')).toBeGreaterThan(score('restore.ts', 'store'))
  })

  it('prefers the start of the string', () => {
    expect(score('index.ts', 'index')).toBeGreaterThan(score('reindex.ts', 'index'))
  })

  it('treats a camelCase hump as a boundary', () => {
    expect(score('parseValue', 'value')).toBeGreaterThan(score('parsevalue', 'value'))
  })

  it('treats the first digit of a number as a boundary', () => {
    // The `2` that opens a number beats the `2` sitting inside one.
    expect(score('v2.sql', '2')).toBeGreaterThan(score('v12.sql', '2'))
  })

  it('weighs the first query character double', () => {
    // Both alignments are one gap apart; only the start position differs.
    expect(score('a-xb', 'ab')).toBeGreaterThan(score('xa-b', 'ab'))
  })

  it('ranks camelCase initials above a mid-word run of the same length', () => {
    expect(score('CommandPalette', 'cp')).toBeGreaterThan(score('occupy', 'cp'))
  })
})

describe('fuzzyMatch — case handling', () => {
  it('is case-insensitive for an all-lowercase query', () => {
    expect(fuzzyMatch('README.md', 'readme')).not.toBeNull()
  })

  it('rewards an exact-case hit over a case-folded one', () => {
    expect(score('abc', 'abc')).toBeGreaterThan(score('ABC', 'abc'))
    expect(score('abc', 'abc') - score('ABC', 'abc')).toBe(SCORES.caseMatch * 3)
  })

  it('goes case-sensitive as soon as the query has a capital', () => {
    expect(fuzzyMatch('palette.ts', 'Palette')).toBeNull()
    expect(fuzzyMatch('CommandPalette.tsx', 'Palette')).not.toBeNull()
  })

  it('can be told to ignore case entirely', () => {
    expect(fuzzyMatch('palette.ts', 'Palette', { smartCase: false })).not.toBeNull()
  })
})

describe('fuzzyMatch — multiple terms', () => {
  it('requires every whitespace-separated term to match', () => {
    expect(fuzzyMatch('Git: Show status', 'git status')).not.toBeNull()
    expect(fuzzyMatch('Show status bar', 'git status')).toBeNull()
  })

  it('matches terms in any order', () => {
    expect(fuzzyMatch('Git: Show status', 'status git')).not.toBeNull()
  })

  it('reports the union of every term’s ranges', () => {
    const result = fuzzyMatch('git status', 'status git')
    expect(result?.ranges).toEqual([
      { start: 0, end: 3 },
      { start: 4, end: 10 },
    ])
  })

  it('sums the terms, so matching two words beats matching one', () => {
    expect(score('git status', 'git status')).toBeGreaterThan(score('git status', 'git'))
  })

  it('can be told to treat the whole query as one term', () => {
    expect(fuzzyMatch('git status', 'git status', { splitTerms: false })).not.toBeNull()
    expect(fuzzyMatch('gitstatus', 'git status', { splitTerms: false })).toBeNull()
  })
})

describe('fuzzyMatchPath', () => {
  it('finds the start of a path segment', () => {
    expect(basenameStart('src/renderer/fuzzy.ts')).toBe(13)
    expect(basenameStart('fuzzy.ts')).toBe(0)
  })

  it('prefers a hit in the filename over one in a directory', () => {
    expect(pathScore('src/router.ts', 'router')).toBeGreaterThan(
      pathScore('src/router/legacy/adapter.ts', 'router'),
    )
  })

  it('prefers the start of a path segment over the middle of one', () => {
    expect(pathScore('app/store.ts', 'store')).toBeGreaterThan(pathScore('app/restore.ts', 'store'))
  })

  it('still matches across directory separators', () => {
    expect(fuzzyMatchPath('src/main/file-search.ts', 'srcfs')).not.toBeNull()
  })

  it('does not let a deep directory match beat a shallow filename match', () => {
    expect(pathScore('src/fuzzy.ts', 'fuzzy')).toBeGreaterThan(
      pathScore('src/fuzzy/internal/tables/generated.ts', 'fuzzy'),
    )
  })
})

describe('rankMatches — ordering', () => {
  const files = [
    'src/main/pty-manager.ts',
    'src/main/file-search.ts',
    'src/renderer/components/CommandPalette.tsx',
    'src/renderer/components/CommandPalette.css',
    'src/renderer/components/TabBar.tsx',
    'src/renderer/fuzzy.ts',
    'src/renderer/fuzzy.test.ts',
    'src/shared/types.ts',
    'package.json',
  ]

  it('puts the exact filename first', () => {
    expect(order(files, 'fuzzy.ts')[0]).toBe('src/renderer/fuzzy.ts')
  })

  it('ranks camelCase initials to the right component', () => {
    expect(order(files, 'cmdpal')[0]).toBe('src/renderer/components/CommandPalette.tsx')
  })

  it('ranks the extension the user typed above its sibling', () => {
    const ranked = order(files, 'palette.css')
    expect(ranked[0]).toBe('src/renderer/components/CommandPalette.css')
  })

  it('prefers the shorter of two otherwise equal names', () => {
    const ranked = order(files, 'fuzzy')
    expect(ranked.indexOf('src/renderer/fuzzy.ts')).toBeLessThan(
      ranked.indexOf('src/renderer/fuzzy.test.ts'),
    )
  })

  it('drops non-matches entirely', () => {
    expect(order(files, 'zzzz')).toEqual([])
  })

  it('honours the limit', () => {
    expect(rankMatches(files, 's', (f) => f, { path: true, limit: 3 })).toHaveLength(3)
  })

  it('returns the input order, capped, for an empty query', () => {
    const ranked = rankMatches(files, '', (f) => f, { path: true, limit: 4 })
    expect(ranked.map((r) => r.item)).toEqual(files.slice(0, 4))
  })

  it('is deterministic — the same input ranks the same way twice', () => {
    expect(order(files, 'src')).toEqual(order(files, 'src'))
  })

  it('breaks ties on text length, then on input order', () => {
    const items = ['ab', 'ab-longer', 'ab-longest']
    expect(rankMatches(items, 'ab', (t) => t).map((r) => r.item)).toEqual([
      'ab',
      'ab-longer',
      'ab-longest',
    ])
  })
})

describe('rankMatches — command palette ordering', () => {
  const commands = [
    'New Session',
    'New Session in Folder',
    'Close Session',
    'Split Pane Right',
    'Toggle Sidebar',
    'Preferences: Open Settings',
    'Git: Commit All',
    'Git: Checkout Branch',
  ]

  it('finds a command by its initials', () => {
    expect(rankMatches(commands, 'ns', (c) => c)[0].item).toBe('New Session')
  })

  it('narrows with a second term', () => {
    expect(rankMatches(commands, 'git check', (c) => c).map((r) => r.item)).toEqual([
      'Git: Checkout Branch',
    ])
  })

  it('prefers a word-start match over a buried one', () => {
    expect(rankMatches(commands, 'set', (c) => c)[0].item).toBe('Preferences: Open Settings')
  })

  it('prefers the shorter command when both start the same way', () => {
    expect(rankMatches(commands, 'new session', (c) => c)[0].item).toBe('New Session')
  })
})

describe('segmentByRanges', () => {
  it('splits text into plain and matched runs', () => {
    expect(segmentByRanges('abcdef', [{ start: 1, end: 3 }])).toEqual([
      { text: 'a', matched: false },
      { text: 'bc', matched: true },
      { text: 'def', matched: false },
    ])
  })

  it('handles a match at the very start and end', () => {
    expect(segmentByRanges('ab', [{ start: 0, end: 2 }])).toEqual([{ text: 'ab', matched: true }])
  })

  it('returns the whole text when there are no ranges', () => {
    expect(segmentByRanges('abc', [])).toEqual([{ text: 'abc', matched: false }])
  })

  it('ignores ranges past the end of the text', () => {
    expect(segmentByRanges('ab', [{ start: 1, end: 9 }])).toEqual([
      { text: 'a', matched: false },
      { text: 'b', matched: true },
    ])
  })

  it('round-trips: the segments always rebuild the original text', () => {
    const text = 'src/renderer/components/CommandPalette.tsx'
    const result = fuzzyMatch(text, 'cmdpal')
    const rebuilt = segmentByRanges(text, result?.ranges ?? [])
      .map((s) => s.text)
      .join('')
    expect(rebuilt).toBe(text)
  })
})

describe('clampRanges', () => {
  const ranges: MatchRange[] = [
    { start: 2, end: 4 },
    { start: 8, end: 10 },
  ]

  it('re-bases ranges onto a slice', () => {
    expect(clampRanges(ranges, 8, 12)).toEqual([{ start: 0, end: 2 }])
  })

  it('trims a range that straddles the slice boundary', () => {
    expect(clampRanges(ranges, 3, 12)).toEqual([
      { start: 0, end: 1 },
      { start: 5, end: 7 },
    ])
  })

  it('drops ranges outside the slice', () => {
    expect(clampRanges(ranges, 20, 30)).toEqual([])
  })
})

describe('long input', () => {
  const deep = `${'nested/'.repeat(60)}target.ts`

  it('still matches a path far longer than the scoring window', () => {
    expect(fuzzyMatchPath(deep, 'target')).not.toBeNull()
  })

  it('reports ranges as indices into the original text', () => {
    const result = fuzzyMatchPath(deep, 'target')
    const range = result?.ranges[0]
    expect(deep.slice(range?.start, range?.end)).toBe('target')
  })

  it('does not blow up on a pasted essay as a query', () => {
    expect(fuzzyMatch('short.ts', 'x'.repeat(5000))).toBeNull()
  })

  // Regression: the length cap alone left a pasted *paragraph* uncapped. Each
  // whitespace-separated word is its own DP pass over every candidate, so a
  // few thousand of them blocked the renderer for seconds on one keystroke.
  it('bounds the number of terms a pasted paragraph can create', () => {
    const files: string[] = []
    for (let i = 0; i < 2000; i++) files.push(`src/dir${i % 30}/File${i}.ts`)
    // Every term matches, so nothing short-circuits on a miss.
    const paragraph = 'r '.repeat(5000).trim()

    const started = performance.now()
    rankMatches(files, paragraph, (f) => f, { path: true })
    const elapsed = performance.now() - started

    // Uncapped this took well over two seconds; the cap puts it in the tens of
    // milliseconds. Loose enough not to fail on a busy machine.
    expect(elapsed).toBeLessThan(400)
  })

  it('still honours a realistic multi-word query', () => {
    expect(fuzzyMatch('Git: Checkout Branch', 'git checkout branch')).not.toBeNull()
    expect(fuzzyMatch('Git: Checkout Branch', 'git checkout missing')).toBeNull()
  })
})

describe('alignment invariants', () => {
  /** Deterministic PRNG — a flaky property test is worse than none. */
  function makeRandom(seed: number): () => number {
    let state = seed
    return () => {
      state = (state * 1103515245 + 12345) & 0x7fffffff
      return state / 0x7fffffff
    }
  }

  it('the reported ranges always spell the query, in order and in bounds', () => {
    const random = makeRandom(20260812)
    const alphabet = 'abcABC._-/12'
    const pick = (): string => alphabet[Math.floor(random() * alphabet.length)]

    for (let iteration = 0; iteration < 4000; iteration++) {
      let text = ''
      for (let i = 0; i < 1 + Math.floor(random() * 24); i++) text += pick()
      // Draw the query out of the text so most iterations exercise a hit
      // rather than the cheap subsequence rejection.
      let query = ''
      for (let i = 0; i < text.length && query.length < 5; i++) {
        if (random() < 0.3) query += text[i]
      }
      if (query === '') query = text[0]

      const result = fuzzyMatch(text, query)
      if (!result) continue

      let previousEnd = 0
      for (const range of result.ranges) {
        expect(range.start).toBeGreaterThanOrEqual(previousEnd)
        expect(range.end).toBeGreaterThan(range.start)
        expect(range.end).toBeLessThanOrEqual(text.length)
        previousEnd = range.end
      }
      const matched = result.ranges.map((r) => text.slice(r.start, r.end)).join('')
      expect(matched.toLowerCase()).toBe(query.toLowerCase())
    }
  })
})

describe('throughput', () => {
  it('ranks a large project without stalling a keystroke', () => {
    const files: string[] = []
    for (let i = 0; i < 5000; i++) {
      files.push(`src/feature-${i % 40}/nested/dir/Component${i}Renderer.tsx`)
    }
    const started = performance.now()
    const ranked = rankMatches(files, 'cmprnd', (f) => f, { path: true })
    const elapsed = performance.now() - started

    expect(ranked.length).toBeGreaterThan(0)
    // Deliberately loose — this guards against an accidental O(n^2), not
    // against the machine being busy.
    expect(elapsed).toBeLessThan(2000)
  })
})
