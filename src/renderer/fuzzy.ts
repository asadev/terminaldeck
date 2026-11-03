/**
 * Fuzzy matching for quick open and the command palette.
 *
 * The matcher is a Smith-Waterman-style dynamic program rather than a greedy
 * left-to-right scan. Greedy scanning is cheaper but reports the *first*
 * alignment instead of the *best* one, which shows up twice: the score is
 * wrong (`cmp` against `src/components/CommandPalette.tsx` greedily consumes
 * the `c` of `components`) and the highlight ranges land on the wrong
 * characters. The DP finds the optimal alignment, and the traceback hands
 * back exactly the indices that produced the score.
 *
 * Ranking rules, in the order they matter:
 *   1. Consecutive characters — `abc` beats `a_b_c`.
 *   2. Word boundaries — the start of a path segment, a word after `_`/`-`/`.`,
 *      a camelCase hump, the first digit of a number.
 *   3. A run inherits the bonus of the character it started on, so a run that
 *      begins at a boundary scores as if every character were a boundary.
 *      Without this, `a_b_c` ties `abc` because three boundary bonuses cancel
 *      out three consecutive bonuses.
 *   4. Gaps cost, and each extra skipped character costs a little more.
 */

export interface MatchRange {
  /** Inclusive. */
  start: number
  /** Exclusive. */
  end: number
}

export interface FuzzyResult {
  score: number
  ranges: MatchRange[]
}

export interface FuzzyOptions {
  /** An uppercase letter in the query makes that term case-sensitive. Default true. */
  smartCase?: boolean
  /** Whitespace-separated words are independent required terms. Default true. */
  splitTerms?: boolean
}

/**
 * Exported so tests can assert against the model rather than magic numbers,
 * and so the weights can be tuned in one place.
 */
export const SCORES = {
  /** Awarded for every matched character. */
  match: 16,
  /** First character of a word — after a separator, or the very start. */
  boundary: 8,
  /** First character of a path segment. Ranks above a plain word start
   *  because in a file list that is where the name a human thinks of begins. */
  pathBoundary: 10,
  /** A capital following a lowercase — the `P` of `CommandPalette`. */
  camel: 7,
  /** First digit of a number — the `2` of `v2`. */
  digit: 6,
  /** Adjacent to the previously matched character. */
  consecutive: 5,
  /** The query character matched the same case as the text. */
  caseMatch: 1,
  /** The first query character weighs double, so where a match *starts* counts. */
  firstCharMultiplier: 2,
  /** Every character of a path's final segment. */
  basename: 4,
  /** Cost of opening a gap. */
  gapStart: -3,
  /** Cost of each further skipped character. */
  gapExtension: -1,
} as const

/** Cells this far below zero can only be unreachable states, never alignments. */
const NO_MATCH = -1_000_000

/**
 * Only the tail of an absurdly long path is scored. Nobody types a query that
 * spans 320 characters, and the DP is O(query x text) per candidate.
 */
const MAX_TEXT_LENGTH = 320

/** Guards against a pasted essay turning one keystroke into a megabyte of DP. */
const MAX_QUERY_LENGTH = 64

/**
 * ...and against it turning into *thousands* of small ones. Every term is a
 * separate DP pass over every candidate, so cost is terms x candidates x
 * query x text. Capping the length alone leaves a pasted paragraph — which
 * clips to nothing per term but splits into thousands of them — free to block
 * the renderer for seconds on a single keystroke. Nobody narrows a list with
 * more than a handful of words; the extras are dropped, not truncated into a
 * term that would match the wrong thing.
 */
const MAX_TERMS = 16

const CLASS_OTHER = 0
const CLASS_LOWER = 1
const CLASS_UPPER = 2
const CLASS_DIGIT = 3

function charClass(ch: string): number {
  if (ch >= 'a' && ch <= 'z') return CLASS_LOWER
  if (ch >= 'A' && ch <= 'Z') return CLASS_UPPER
  if (ch >= '0' && ch <= '9') return CLASS_DIGIT
  // Non-ASCII letters (é, ü, 名) behave like word characters. Without this
  // every accented character would read as a separator and hand its neighbour
  // an undeserved boundary bonus.
  if (ch.charCodeAt(0) > 127) return CLASS_LOWER
  return CLASS_OTHER
}

/*
 * Scoring runs over thousands of candidates per keystroke. Allocating four
 * typed arrays per candidate is most of the cost and all of the GC pressure,
 * so the buffers are module-level and reused. Nothing here yields, so there is
 * no way for two matches to be in flight at once.
 */
let bufferWidth = 0
let bufferCells = 0
let rowCurrent = new Int32Array(0)
let rowPrevious = new Int32Array(0)
let runCurrent = new Int32Array(0)
let runPrevious = new Int32Array(0)
let bonusBuffer = new Int32Array(0)
let fromBuffer = new Int32Array(0)

function ensureBuffers(width: number, rows: number): void {
  if (width > bufferWidth) {
    bufferWidth = width
    rowCurrent = new Int32Array(width)
    rowPrevious = new Int32Array(width)
    runCurrent = new Int32Array(width)
    runPrevious = new Int32Array(width)
    bonusBuffer = new Int32Array(width)
  }
  const cells = width * rows
  if (cells > bufferCells) {
    bufferCells = cells
    fromBuffer = new Int32Array(cells)
  }
}

/**
 * Per-position bonus for the character at each index, written into the shared
 * buffer. `basenameFrom` is the index the final path segment starts at; pass
 * the text length to disable the basename weighting.
 */
function computeBonuses(text: string, basenameFrom: number): Int32Array {
  const n = text.length
  const bonuses = bonusBuffer
  let previousClass = CLASS_OTHER
  let previousChar = ''

  for (let i = 0; i < n; i++) {
    const ch = text[i]
    const cls = charClass(ch)
    let bonus = 0

    if (cls !== CLASS_OTHER && previousClass === CLASS_OTHER) {
      // Index 0 counts as a word start: there is no preceding character.
      bonus = previousChar === '/' || previousChar === '\\' ? SCORES.pathBoundary : SCORES.boundary
    } else if (previousClass === CLASS_LOWER && cls === CLASS_UPPER) {
      bonus = SCORES.camel
    } else if (previousClass !== CLASS_DIGIT && cls === CLASS_DIGIT) {
      bonus = SCORES.digit
    }

    bonuses[i] = i >= basenameFrom ? bonus + SCORES.basename : bonus
    previousClass = cls
    previousChar = ch
  }

  return bonuses
}

/** Cheap rejection: if the query is not a subsequence at all, skip the DP. */
function isSubsequence(haystack: string, needle: string, from: number): boolean {
  let j = from
  for (let i = 0; i < needle.length; i++) {
    j = haystack.indexOf(needle[i], j)
    if (j < 0) return false
    j++
  }
  return true
}

function toRanges(indices: readonly number[]): MatchRange[] {
  const ranges: MatchRange[] = []
  for (const index of indices) {
    const last = ranges[ranges.length - 1]
    if (last && last.end === index) last.end = index + 1
    else ranges.push({ start: index, end: index + 1 })
  }
  return ranges
}

/**
 * One query term against one text. `bonuses` is expected to already hold the
 * per-position weights for `text`.
 */
function matchTerm(
  text: string,
  lowerText: string,
  query: string,
  lowerQuery: string,
  bonuses: Int32Array,
  caseSensitive: boolean,
): FuzzyResult | null {
  const n = text.length
  const m = query.length
  if (m === 0) return { score: 0, ranges: [] }
  if (m > n) return null

  const haystack = caseSensitive ? text : lowerText
  const needle = caseSensitive ? query : lowerQuery

  // Characters before the first possible first-character match, and after the
  // last possible last-character match, cannot take part in any alignment.
  const start = haystack.indexOf(needle[0])
  if (start < 0) return null
  const end = haystack.lastIndexOf(needle[m - 1]) + 1
  if (end - start < m) return null
  if (!isSubsequence(haystack, needle, start)) return null

  let previous = rowPrevious
  let current = rowCurrent
  let previousRun = runPrevious
  let currentRun = runCurrent
  const from = fromBuffer

  for (let i = 0; i < m; i++) {
    const qc = needle[i]
    const qcRaw = query[i]
    current.fill(NO_MATCH, start, end)
    currentRun.fill(0, start, end)

    // Best score reachable at column j from row i-1 across a gap of at least
    // one character, maintained incrementally as j advances.
    let gap = NO_MATCH
    let gapFrom = -1

    for (let j = start; j < end; j++) {
      if (i > 0 && j >= start + 2) {
        const opening = previous[j - 2] + SCORES.gapStart
        const extending = gap + SCORES.gapExtension
        if (opening >= extending) {
          gap = opening
          gapFrom = j - 2
        } else {
          gap = extending
        }
      }

      if (haystack[j] !== qc) continue

      const matchScore = SCORES.match + (text[j] === qcRaw ? SCORES.caseMatch : 0)

      if (i === 0) {
        current[j] = matchScore + bonuses[j] * SCORES.firstCharMultiplier
        currentRun[j] = bonuses[j]
        continue
      }

      const adjacent = j > start ? previous[j - 1] : NO_MATCH
      const runStartBonus = j > start ? previousRun[j - 1] : 0
      // A run is worth the best of: this position's own bonus, the flat
      // consecutive reward, or the bonus of the character the run began on.
      const runBonus = Math.max(bonuses[j], SCORES.consecutive, runStartBonus)
      const viaRun = adjacent + matchScore + runBonus
      const viaGap = gap + matchScore + bonuses[j]

      if (viaRun >= viaGap) {
        current[j] = viaRun
        currentRun[j] = j > start ? previousRun[j - 1] : bonuses[j]
        from[i * n + j] = j - 1
      } else {
        current[j] = viaGap
        currentRun[j] = bonuses[j]
        from[i * n + j] = gapFrom
      }
    }

    const swapRow = previous
    previous = current
    current = swapRow
    const swapRun = previousRun
    previousRun = currentRun
    currentRun = swapRun
  }

  // `previous` holds the final row after the last swap.
  let best = NO_MATCH
  let bestColumn = -1
  for (let j = start; j < end; j++) {
    if (previous[j] > best) {
      best = previous[j]
      bestColumn = j
    }
  }
  // Unreachable states stay pinned near NO_MATCH; a real alignment can go
  // negative through gap penalties but never that far.
  if (bestColumn < 0 || best < NO_MATCH / 2) return null

  const indices = new Array<number>(m)
  let column = bestColumn
  for (let i = m - 1; i >= 0; i--) {
    indices[i] = column
    if (i > 0) column = from[i * n + column]
  }

  return { score: best, ranges: toRanges(indices) }
}

function mergeRanges(ranges: MatchRange[]): MatchRange[] {
  if (ranges.length < 2) return ranges
  ranges.sort((a, b) => a.start - b.start)
  const merged: MatchRange[] = [ranges[0]]
  for (let i = 1; i < ranges.length; i++) {
    const last = merged[merged.length - 1]
    const next = ranges[i]
    if (next.start <= last.end) last.end = Math.max(last.end, next.end)
    else merged.push(next)
  }
  return merged
}

function splitQuery(query: string, options: FuzzyOptions): string[] {
  const trimmed = query.trim()
  if (trimmed === '') return []
  if (options.splitTerms === false) return [trimmed.slice(0, MAX_QUERY_LENGTH)]
  // The limit argument to `split` stops it building the full array first —
  // this runs once per candidate, so a 10,000-word paste must not allocate
  // 10,000 strings 10,000 times.
  return trimmed.split(/\s+/, MAX_TERMS).map((term) => term.slice(0, MAX_QUERY_LENGTH))
}

function run(
  text: string,
  query: string,
  options: FuzzyOptions,
  basenameFrom: number,
): FuzzyResult | null {
  const terms = splitQuery(query, options)
  // An empty query matches everything equally — the caller keeps its own order.
  if (terms.length === 0) return { score: 0, ranges: [] }

  // Sized once, before any writes: `computeBonuses` and the DP share buffers,
  // and growing them mid-match would throw the bonuses away.
  let widestTerm = 0
  for (const term of terms) widestTerm = Math.max(widestTerm, term.length)
  ensureBuffers(text.length, widestTerm)

  const bonuses = computeBonuses(text, basenameFrom)
  const lowerText = text.toLowerCase()
  let score = 0
  const ranges: MatchRange[] = []

  for (const term of terms) {
    const caseSensitive = options.smartCase !== false && /[A-Z]/.test(term)
    const result = matchTerm(text, lowerText, term, term.toLowerCase(), bonuses, caseSensitive)
    if (!result) return null
    score += result.score
    for (const range of result.ranges) ranges.push(range)
  }

  return { score, ranges: mergeRanges(ranges) }
}

/** Keep the tail, which for a path is the part that identifies the file. */
function clip(text: string): { text: string; offset: number } {
  if (text.length <= MAX_TEXT_LENGTH) return { text, offset: 0 }
  const offset = text.length - MAX_TEXT_LENGTH
  return { text: text.slice(offset), offset }
}

function shift(result: FuzzyResult | null, offset: number): FuzzyResult | null {
  if (!result || offset === 0) return result
  return {
    score: result.score,
    ranges: result.ranges.map((r) => ({ start: r.start + offset, end: r.end + offset })),
  }
}

/** Index the final path segment starts at. */
export function basenameStart(path: string): number {
  return Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\')) + 1
}

/**
 * Score `query` against `text`. Returns null when the query is not present as
 * a subsequence; a match returns its score and the indices that matched.
 */
export function fuzzyMatch(
  text: string,
  query: string,
  options: FuzzyOptions = {},
): FuzzyResult | null {
  const clipped = clip(text)
  return shift(run(clipped.text, query, options, clipped.text.length), clipped.offset)
}

/**
 * As `fuzzyMatch`, but weighted for file paths: characters in the final
 * segment count for more, so `router` prefers `src/router.ts` over
 * `src/router/legacy/adapter.ts`.
 */
export function fuzzyMatchPath(
  path: string,
  query: string,
  options: FuzzyOptions = {},
): FuzzyResult | null {
  const clipped = clip(path)
  return shift(
    run(clipped.text, query, options, basenameStart(clipped.text)),
    clipped.offset,
  )
}

export interface RankOptions extends FuzzyOptions {
  /** How many results to keep. Default 50. */
  limit?: number
  /** Score the text as a file path. */
  path?: boolean
}

export interface Ranked<T> {
  item: T
  score: number
  ranges: MatchRange[]
}

interface Scored<T> extends Ranked<T> {
  length: number
  order: number
}

/**
 * Tie-breaks, after score: fewer highlight groups (a tighter match), then an
 * earlier first hit, then the shorter text, then the caller's original order.
 * Every step is deterministic — a palette whose list reshuffles between
 * identical keystrokes is worse than one that ranks slightly differently.
 */
function byRank<T>(a: Scored<T>, b: Scored<T>): number {
  if (a.score !== b.score) return b.score - a.score
  if (a.ranges.length !== b.ranges.length) return a.ranges.length - b.ranges.length
  const aStart = a.ranges.length > 0 ? a.ranges[0].start : 0
  const bStart = b.ranges.length > 0 ? b.ranges[0].start : 0
  if (aStart !== bStart) return aStart - bStart
  if (a.length !== b.length) return a.length - b.length
  return a.order - b.order
}

/** Score every item, drop the misses, and return the best `limit`, sorted. */
export function rankMatches<T>(
  items: readonly T[],
  query: string,
  toText: (item: T) => string,
  options: RankOptions = {},
): Ranked<T>[] {
  const limit = options.limit ?? 50
  const trimmed = query.trim()

  if (trimmed === '') {
    return items.slice(0, limit).map((item) => ({ item, score: 0, ranges: [] }))
  }

  const matcher = options.path === true ? fuzzyMatchPath : fuzzyMatch
  const scored: Scored<T>[] = []

  for (let i = 0; i < items.length; i++) {
    const item = items[i]
    const text = toText(item)
    const result = matcher(text, trimmed, options)
    if (result) {
      scored.push({ item, score: result.score, ranges: result.ranges, length: text.length, order: i })
    }
  }

  scored.sort(byRank)
  return scored
    .slice(0, limit)
    .map(({ item, score, ranges }) => ({ item, score, ranges }))
}

export interface TextSegment {
  text: string
  matched: boolean
}

/** Split text into alternating plain and matched runs, ready to render. */
export function segmentByRanges(text: string, ranges: readonly MatchRange[]): TextSegment[] {
  const segments: TextSegment[] = []
  let cursor = 0
  for (const range of ranges) {
    const start = Math.max(range.start, cursor)
    const end = Math.min(range.end, text.length)
    if (end <= start) continue
    if (start > cursor) segments.push({ text: text.slice(cursor, start), matched: false })
    segments.push({ text: text.slice(start, end), matched: true })
    cursor = end
  }
  if (cursor < text.length) segments.push({ text: text.slice(cursor), matched: false })
  return segments
}

/**
 * Re-base ranges onto `text.slice(from, to)`. Used when one match is rendered
 * across two elements — a path's directory and its filename.
 */
export function clampRanges(
  ranges: readonly MatchRange[],
  from: number,
  to: number,
): MatchRange[] {
  const out: MatchRange[] = []
  for (const range of ranges) {
    const start = Math.max(range.start, from)
    const end = Math.min(range.end, to)
    if (end > start) out.push({ start: start - from, end: end - from })
  }
  return out
}
