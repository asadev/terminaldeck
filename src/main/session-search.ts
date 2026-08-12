/**
 * Full-text search across Claude Code's past transcripts.
 *
 * The inspector answers "what did this session cost"; this answers "where did I
 * say that". It streams every `.jsonl` under `<config>/projects/<encoded-cwd>/`
 * — optionally every project — and returns ranked, snippet-highlighted hits.
 *
 * ## Why this does not reuse `TranscriptTail`
 *
 * `transcript.ts` owns transcript *discovery* and this module reuses all of it
 * (`transcriptDir`, `listTranscripts`, `claudeConfigDir`). What it cannot reuse
 * is `TranscriptTail.read()`: that reader gates every line through
 * `mayCarryCost`, which keeps only lines carrying a `usage` block. Measured on
 * a real 15,738-line transcript here, that filter throws away 100% of the user
 * prompts and every tool result — precisely the text a search exists to find.
 * The same reasoning is already recorded in `session-insights.ts`, whose
 * `readInsightLines` keeps tool calls the cost reader also discards.
 *
 * What is shared instead is the *shape* of the read: 4 MB chunks with an
 * `await` between them so a 154 MB file cannot stall the main process, and a
 * `StringDecoder` so a chunk boundary inside a multi-byte character cannot
 * corrupt a match. A follow-up worth doing once the waves land is to lift that
 * loop into one `streamLines` helper shared by all three modules — it is
 * duplicated three times now, and this file may not edit the other two.
 *
 * Wiring:
 *
 *     import { registerSessionSearchIpc } from './session-search'
 *     registerSessionSearchIpc(ipcMain)
 */

import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import { open, readdir, stat } from 'node:fs/promises'
import { basename, join, resolve, sep } from 'node:path'
import { StringDecoder } from 'node:string_decoder'
import {
  claudeConfigDir,
  listTranscripts,
  transcriptDir,
  type TranscriptFile,
} from './transcript'

export const SESSION_SEARCH_CHANNEL = 'session-search:run'
export const SESSION_SEARCH_CANCEL_CHANNEL = 'session-search:cancel'

/* -------------------------------------------------------------------------- */
/* Limits                                                                      */
/* -------------------------------------------------------------------------- */

/** Bytes pulled per `read()`. Bounds peak memory on a large transcript. */
const CHUNK_BYTES = 4 * 1024 * 1024

/**
 * Cap on a single buffered line. The largest real line in this machine's
 * transcripts is 1.1 MB (a tool result carrying a file dump), so this is
 * insurance against a `.jsonl` with no newlines being buffered whole.
 */
const MAX_LINE_BYTES = 8 * 1024 * 1024

/**
 * Longest run of text searched inside one message block.
 *
 * Past this a "message" is a dumped file, and quick-open searches files far
 * better than this does. Truncating keeps one pathological tool result from
 * dominating a query's cost.
 */
export const MAX_BLOCK_CHARS = 120_000

/**
 * Highlight ranges recorded per block, shared out between the query's terms.
 *
 * Shared out rather than first-come-first-served, which is how this was first
 * written and was wrong: for `the needle`, `the` matched 200 times, took the
 * whole budget, and `needle` — the term that made the query selective — was
 * never recorded. The snippet then centred on the first `the` and the user got
 * back "the the the the…" with no sign of the word they searched for.
 */
const MAX_MATCHES_PER_BLOCK = 50

/**
 * Occurrences counted per term before the tally stops.
 *
 * Only the count feeds ranking, and `scoreHit` damps it logarithmically, so
 * there is nothing to learn from occurrence 201 that occurrence 200 did not
 * already say — and a term matching every character of a 120 kB block would
 * otherwise spin `exec` a hundred thousand times.
 */
const MAX_COUNTED_PER_TERM = 200

/**
 * Lines between wall-clock checks inside one transcript.
 *
 * Exported because the deadline test has to write more than this many lines to
 * reach the first check, and hardcoding the number in the test would let the
 * two drift apart.
 */
export const DEADLINE_CHECK_LINES = 512

export const DEFAULT_MAX_HITS = 200
export const MAX_MAX_HITS = 1000
/** Stops one chatty session from filling the whole result list. */
export const DEFAULT_MAX_HITS_PER_SESSION = 6
export const DEFAULT_MAX_SESSIONS = 80
export const MAX_MAX_SESSIONS = 600
/** Search reaches further back than the cost watcher's 90 days. */
export const DEFAULT_MAX_AGE_MS = 365 * 24 * 60 * 60 * 1000
/** Wall-clock ceiling. Past it the search stops and reports `truncated`. */
export const DEFAULT_TIME_BUDGET_MS = 12_000

/** Shortest query accepted. One character matches everything and ranks nothing. */
export const MIN_QUERY_CHARS = 2

/** Raw characters kept either side of a match before whitespace is collapsed. */
const SNIPPET_LEAD = 90
const SNIPPET_TRAIL = 220
/** Length of the collapsed snippet handed to the renderer. */
const SNIPPET_MAX_CHARS = 260

/* -------------------------------------------------------------------------- */
/* Query parsing                                                              */
/* -------------------------------------------------------------------------- */

/**
 * Which part of a conversation a hit came from.
 *
 * Derived from real transcript lines: a `user` line's content is either a
 * string (what was typed) or an array of `tool_result` blocks; an `assistant`
 * line's content array holds `text`, `thinking` and `tool_use` blocks.
 */
export type SearchRole = 'user' | 'assistant' | 'thinking' | 'tool' | 'system'

export const ALL_ROLES: readonly SearchRole[] = ['user', 'assistant', 'thinking', 'tool', 'system']

/** Conversation only. Tool output is enormous and usually noise. */
export const DEFAULT_ROLES: readonly SearchRole[] = ['user', 'assistant']

export interface QueryTerm {
  /** The literal the user typed, for display. */
  text: string
  /** Came from `"quotes"` — ranks above a bare word. */
  phrase: boolean
  /** Compiled with `g`, and `i` unless the search is case-sensitive. */
  pattern: RegExp
}

export interface ParsedQuery {
  /** Every one of these must match inside the same message block. */
  include: QueryTerm[]
  /** A block matching any of these is dropped. */
  exclude: QueryTerm[]
  /**
   * A plain ASCII term safe to test against the raw JSON line before parsing
   * it, or null when no term qualifies. See `rawLinePrefilter`.
   */
  prefilter: RegExp | null
}

export type QueryError = 'query-too-short' | 'invalid-regex' | 'unsafe-regex'

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/* -------------------------------------------------------------------------- */
/* Regex safety                                                               */
/* -------------------------------------------------------------------------- */

/**
 * Reject a regular expression that repeats something already repeating.
 *
 * This is the one input in the whole module that can stop the app dead.
 * `RegExp.exec` is not interruptible: no abort signal, no timeout and no
 * deadline check can cut it short, because nothing else runs until V8 returns.
 * Measured here against a transcript line of *n* `a` characters and the pattern
 * `(a+)+$`: n=22 took 0.6 s, n=26 took 0.9 s, n=30 took 14.4 s — doubling per
 * character. At n=40 that is hours, and the Electron main process is where
 * every session's pty and every IPC reply lives, so "hours" means force-quit.
 *
 * Transcripts are full of long single-character runs — indentation, `---`
 * rules, base64 in tool results — so this is not a contrived input. Someone
 * typing `(\s+)+$` into the search box hits it on the first line it reads.
 *
 * The check is deliberately narrow: an *unbounded* quantifier (`*`, `+`, `{n,}`)
 * applied to a group whose body also contains an unbounded quantifier. That is
 * the shape that goes exponential. `(foo|bar)+`, `\d+\.\d+`, `(a{2,3})+` and
 * every other ordinary pattern are left alone.
 *
 * It is a mitigation of the dominant class, not a proof of termination — a
 * genuinely bounded guarantee needs the match run in a worker that can be
 * terminated, or V8's non-backtracking engine. Both are out of this module's
 * reach; the deadline below limits everything except a single `exec`.
 */
function classEnd(source: string, start: number): number {
  // `start` sits on '['. Returns the index just past the closing ']'.
  let i = start + 1
  // A ']' in first position is a literal, not a terminator.
  if (source[i] === '^') i += 1
  if (source[i] === ']') i += 1
  while (i < source.length && source[i] !== ']') {
    if (source[i] === '\\') i += 1
    i += 1
  }
  return i + 1
}

interface Quantifier {
  /** Characters the quantifier occupies, 0 when there is none. */
  length: number
  /** `*`, `+` or `{n,}` — the ones with no upper bound. */
  unbounded: boolean
}

function quantifierAt(source: string, index: number): Quantifier {
  const ch = source[index]
  if (ch === '*' || ch === '+') return { length: 1, unbounded: true }
  if (ch === '?') return { length: 1, unbounded: false }
  if (ch !== '{') return { length: 0, unbounded: false }
  const close = source.indexOf('}', index)
  if (close === -1) return { length: 0, unbounded: false }
  const body = source.slice(index + 1, close)
  if (!/^\d*(,\d*)?$/.test(body) || body === '') return { length: 0, unbounded: false }
  return { length: close - index + 1, unbounded: /,\s*$/.test(body) }
}

/** Does this fragment contain an unbounded quantifier outside a character class? */
function repeatsUnbounded(fragment: string): boolean {
  let i = 0
  while (i < fragment.length) {
    const ch = fragment[i]
    if (ch === '\\') {
      i += 2
      continue
    }
    if (ch === '[') {
      i = classEnd(fragment, i)
      continue
    }
    if (ch === '*' || ch === '+') return true
    if (ch === '{') {
      const quant = quantifierAt(fragment, i)
      if (quant.unbounded) return true
      i += Math.max(1, quant.length)
      continue
    }
    i += 1
  }
  return false
}

/** True when the pattern nests one unbounded repeat inside another. */
export function hasNestedRepeat(source: string): boolean {
  const opens: number[] = []
  let i = 0
  while (i < source.length) {
    const ch = source[i]
    if (ch === '\\') {
      i += 2
      continue
    }
    if (ch === '[') {
      i = classEnd(source, i)
      continue
    }
    if (ch === '(') {
      opens.push(i)
      i += 1
      continue
    }
    if (ch === ')') {
      const start = opens.pop()
      i += 1
      if (start === undefined) continue
      const quant = quantifierAt(source, i)
      if (quant.unbounded && repeatsUnbounded(source.slice(start + 1, i - 1))) return true
      i += quant.length
      continue
    }
    i += 1
  }
  return false
}

interface RawToken {
  text: string
  negated: boolean
  phrase: boolean
}

/**
 * Split a query into terms, honouring `"quoted phrases"` and `-exclusions`.
 *
 * Hand-rolled rather than regex-split because `-"a phrase"` has to survive, and
 * an unterminated quote has to degrade into a phrase running to end-of-input
 * instead of throwing while the user is still typing it.
 */
export function tokenizeQuery(raw: string): RawToken[] {
  const tokens: RawToken[] = []
  let i = 0
  while (i < raw.length) {
    while (i < raw.length && /\s/.test(raw[i])) i += 1
    if (i >= raw.length) break

    let negated = false
    if (raw[i] === '-' && i + 1 < raw.length && !/\s/.test(raw[i + 1])) {
      negated = true
      i += 1
    }

    let phrase = false
    let text = ''
    if (raw[i] === '"') {
      phrase = true
      i += 1
      while (i < raw.length && raw[i] !== '"') {
        text += raw[i]
        i += 1
      }
      if (i < raw.length) i += 1
    } else {
      while (i < raw.length && !/\s/.test(raw[i])) {
        text += raw[i]
        i += 1
      }
    }

    // A dash standing on its own is a typo or a half-typed exclusion. Keeping it
    // would AND "contains a hyphen" onto every other term and silently empty
    // the result list.
    if (!phrase && text === '-') continue
    if (text.length > 0) tokens.push({ text, negated, phrase })
  }
  return tokens
}

/**
 * A term safe to substring-test against the *unparsed* JSON line.
 *
 * `JSON.parse` on 128 MB of user lines — the real weight of one project's
 * transcripts here — is the dominant cost of a search. Testing the raw line
 * first skips almost all of it. It is only sound when the term cannot be
 * altered by JSON escaping, so it is restricted to plain identifier characters:
 * anything with a quote, backslash, whitespace or non-ASCII could appear
 * escaped in the file and would produce a false *negative*, which is the one
 * kind of error a search must never make.
 */
const PREFILTER_SAFE = /^[A-Za-z0-9_.\-/]+$/

function rawLinePrefilter(include: QueryTerm[], caseSensitive: boolean): RegExp | null {
  // Longest term first: the rarest one rejects the most lines.
  const candidates = include
    .filter((term) => PREFILTER_SAFE.test(term.text))
    .sort((a, b) => b.text.length - a.text.length)
  const best = candidates[0]
  if (!best) return null
  return new RegExp(escapeRegExp(best.text), caseSensitive ? '' : 'i')
}

export interface ParseQueryOptions {
  caseSensitive?: boolean
  /** Treat the whole query as one regular expression. */
  regex?: boolean
}

export type ParseQueryResult =
  | { ok: true; query: ParsedQuery }
  | { ok: false; error: QueryError; message: string }

export function parseQuery(raw: string, options: ParseQueryOptions = {}): ParseQueryResult {
  const caseSensitive = options.caseSensitive === true
  const flags = caseSensitive ? 'g' : 'gi'
  const trimmed = raw.trim()

  if (trimmed.length < MIN_QUERY_CHARS) {
    return {
      ok: false,
      error: 'query-too-short',
      message: `Type at least ${MIN_QUERY_CHARS} characters.`,
    }
  }

  if (options.regex === true) {
    try {
      const pattern = new RegExp(trimmed, flags)
      // Checked after compiling so an outright syntax error still reports as
      // one; a pattern that compiles fine is the dangerous case.
      if (hasNestedRepeat(trimmed)) {
        return {
          ok: false,
          error: 'unsafe-regex',
          message:
            'That pattern repeats inside a repeat (like `(a+)+`), which can take hours on one line. Rewrite it without the inner repeat.',
        }
      }
      return {
        ok: true,
        query: {
          include: [{ text: trimmed, phrase: false, pattern }],
          exclude: [],
          // A regex cannot be substring-tested against the raw line.
          prefilter: null,
        },
      }
    } catch (error) {
      return {
        ok: false,
        error: 'invalid-regex',
        message: error instanceof Error ? error.message : 'Not a valid regular expression.',
      }
    }
  }

  const include: QueryTerm[] = []
  const exclude: QueryTerm[] = []
  for (const token of tokenizeQuery(trimmed)) {
    const term: QueryTerm = {
      text: token.text,
      phrase: token.phrase,
      pattern: new RegExp(escapeRegExp(token.text), flags),
    }
    if (token.negated) exclude.push(term)
    else include.push(term)
  }

  // `-foo` on its own excludes everything and includes nothing. Refusing it is
  // kinder than returning zero hits and letting the user wonder why.
  if (include.length === 0) {
    return {
      ok: false,
      error: 'query-too-short',
      message: 'Add something to search for, not only exclusions.',
    }
  }

  return { ok: true, query: { include, exclude, prefilter: rawLinePrefilter(include, caseSensitive) } }
}

/* -------------------------------------------------------------------------- */
/* Line parsing                                                               */
/* -------------------------------------------------------------------------- */

export interface TextBlock {
  role: SearchRole
  text: string
  /** Tool name, on `tool_use` blocks only — a `tool_result` carries just an id. */
  tool?: string
}

export interface SearchLine {
  /** Epoch ms, or 0 when the line carries no usable timestamp. */
  at: number
  sessionId?: string
  cwd?: string
  isSidechain: boolean
  blocks: TextBlock[]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function str(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

function clip(text: string): string {
  return text.length > MAX_BLOCK_CHARS ? text.slice(0, MAX_BLOCK_CHARS) : text
}

/** Flatten a `tool_result`'s content, which is a string on some lines and an array of blocks on others. */
function toolResultText(content: unknown): string {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  const parts: string[] = []
  for (const block of content) {
    if (!isRecord(block)) continue
    // Image blocks are base64 payloads — searching them would only ever match noise.
    if (str(block.type) === 'text') {
      const text = str(block.text)
      if (text) parts.push(text)
    }
  }
  return parts.join('\n')
}

/**
 * Reduce one JSONL line to its searchable text, or null when it holds none.
 *
 * Shapes confirmed against real transcripts on this machine (15,738 lines):
 *  - `user` + string content .......... what the human typed
 *  - `user` + array content ........... `tool_result` blocks, and occasionally `text`
 *  - `assistant` + array content ...... `text`, `thinking`, `tool_use`
 *  - `system` + top-level `content` ... compaction summaries (7 of 254 system lines)
 *  - `attachment`, `queue-operation`, `mode`, `last-prompt`, `pr-link`, `ai-title`
 *    carry no conversation and are dropped.
 *
 * `isMeta` lines are skipped: they are the CLI's own local-command caveats
 * injected into the conversation, not anything a person wrote.
 */
export function parseSearchLine(line: string): SearchLine | null {
  const trimmed = line.trim()
  if (trimmed.length === 0) return null

  let raw: unknown
  try {
    raw = JSON.parse(trimmed)
  } catch {
    // Transcripts are appended to live, so a torn final line is normal.
    return null
  }
  if (!isRecord(raw)) return null
  if (raw.isMeta === true) return null

  const type = str(raw.type)
  if (!type) return null

  const parsed: SearchLine = {
    at: typeof raw.timestamp === 'string' ? Date.parse(raw.timestamp) || 0 : 0,
    sessionId: str(raw.sessionId),
    cwd: str(raw.cwd),
    isSidechain: raw.isSidechain === true,
    blocks: [],
  }

  if (type === 'system') {
    const content = str(raw.content)
    if (!content) return null
    parsed.blocks.push({ role: 'system', text: clip(content) })
    return parsed
  }

  if (type !== 'user' && type !== 'assistant') return null

  const message = isRecord(raw.message) ? raw.message : undefined
  if (!message) return null

  const content = message.content
  if (typeof content === 'string') {
    if (content.length === 0) return null
    parsed.blocks.push({ role: type === 'user' ? 'user' : 'assistant', text: clip(content) })
    return parsed
  }
  if (!Array.isArray(content)) return null

  for (const block of content) {
    if (!isRecord(block)) continue
    switch (str(block.type)) {
      case 'text': {
        const text = str(block.text)
        if (text) parsed.blocks.push({ role: type === 'user' ? 'user' : 'assistant', text: clip(text) })
        break
      }
      case 'thinking': {
        const text = str(block.thinking)
        if (text) parsed.blocks.push({ role: 'thinking', text: clip(text) })
        break
      }
      case 'tool_use': {
        const name = str(block.name) ?? 'tool'
        // The arguments are the searchable part — a file path, a shell command,
        // the string that was grepped for.
        let args = ''
        try {
          args = block.input === undefined ? '' : JSON.stringify(block.input)
        } catch {
          // Circular or otherwise unserialisable input; the name alone still indexes.
          args = ''
        }
        parsed.blocks.push({ role: 'tool', text: clip(`${name} ${args}`.trim()), tool: name })
        break
      }
      case 'tool_result': {
        const text = toolResultText(block.content)
        if (text) parsed.blocks.push({ role: 'tool', text: clip(text) })
        break
      }
      default:
        break
    }
  }

  return parsed.blocks.length > 0 ? parsed : null
}

/**
 * Cheap gate before `JSON.parse`.
 *
 * Every line that can hold conversation carries either a `"message"` object or,
 * for compaction summaries, a top-level `"content"`. Matching a little too
 * eagerly is free — a line that gets through and holds nothing parses to null.
 */
function mayCarryText(line: string): boolean {
  return line.includes('"message"') || line.includes('"content"')
}

/* -------------------------------------------------------------------------- */
/* Matching and snippets                                                      */
/* -------------------------------------------------------------------------- */

export interface MatchRange {
  start: number
  length: number
}

export interface Snippet {
  /** Whitespace collapsed to single spaces so it renders as one line. */
  text: string
  /** Offsets into `text`. The renderer highlights these — it never re-matches. */
  ranges: MatchRange[]
  truncatedStart: boolean
  truncatedEnd: boolean
}

/**
 * Append this term's matches to `out`, recording at most `limit` of them.
 *
 * `limit` is this term's own share of the block budget — see
 * `MAX_MATCHES_PER_BLOCK` for why the budget is not simply first-come.
 * The return value is the true occurrence count, which is what ranking uses.
 */
function findMatches(text: string, pattern: RegExp, out: MatchRange[], limit: number): number {
  // Shared `RegExp` objects carry `lastIndex` between calls; reset before use.
  pattern.lastIndex = 0
  let found = 0
  const ceiling = out.length + Math.max(1, limit)
  for (;;) {
    const match = pattern.exec(text)
    if (!match) break
    found += 1
    if (out.length < ceiling) {
      out.push({ start: match.index, length: match[0].length })
    }
    // A pattern that can match empty (`a*` in regex mode) would spin forever.
    if (match[0].length === 0) pattern.lastIndex += 1
    if (found >= MAX_COUNTED_PER_TERM) break
  }
  return found
}

const WORD_CHAR = /[A-Za-z0-9_]/

function atWordBoundary(text: string, range: MatchRange): boolean {
  const before = range.start > 0 ? text[range.start - 1] : ''
  const after = text[range.start + range.length] ?? ''
  return (before === '' || !WORD_CHAR.test(before)) && (after === '' || !WORD_CHAR.test(after))
}

/**
 * Collapse runs of whitespace while keeping the highlight offsets aligned.
 *
 * The offsets are the reason this is not a one-line `.replace()`: the renderer
 * slices `text` by them, so every character dropped here has to shift the
 * ranges that follow it.
 */
export function condense(window: string, ranges: MatchRange[]): { text: string; ranges: MatchRange[] } {
  const map = new Array<number>(window.length + 1)
  let out = ''
  let pendingSpace = false

  for (let i = 0; i < window.length; i += 1) {
    map[i] = out.length
    const ch = window[i]
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\f' || ch === '\v') {
      // Leading whitespace is dropped outright; interior runs become one space.
      if (out.length > 0) pendingSpace = true
      continue
    }
    if (pendingSpace) {
      out += ' '
      pendingSpace = false
      map[i] = out.length
    }
    out += ch
  }
  map[window.length] = out.length

  const moved: MatchRange[] = []
  for (const range of ranges) {
    const start = map[Math.max(0, Math.min(window.length, range.start))]
    const end = map[Math.max(0, Math.min(window.length, range.start + range.length))]
    if (end > start) moved.push({ start, length: end - start })
  }
  return { text: out, ranges: moved }
}

/**
 * Build the snippet shown for a hit: a window around one chosen match, with as
 * many others as fit.
 *
 * `anchor` is the match the window centres on, and defaults to the earliest.
 * Callers with a multi-term query should pass the rarest term's first match:
 * centring on the earliest is what produced snippets reading "the the the the…"
 * for `the needle`, with the word the user was actually looking for hundreds of
 * characters off the right-hand edge.
 */
export function buildSnippet(text: string, ranges: MatchRange[], anchor?: MatchRange): Snippet {
  const first = anchor ?? ranges[0]
  if (!first) {
    const whole = condense(text.slice(0, SNIPPET_LEAD + SNIPPET_TRAIL), [])
    return {
      text: whole.text.slice(0, SNIPPET_MAX_CHARS),
      ranges: [],
      truncatedStart: false,
      truncatedEnd: whole.text.length > SNIPPET_MAX_CHARS || text.length > SNIPPET_LEAD + SNIPPET_TRAIL,
    }
  }

  const start = Math.max(0, first.start - SNIPPET_LEAD)
  const end = Math.min(text.length, first.start + first.length + SNIPPET_TRAIL)
  const window = text.slice(start, end)
  const local = ranges
    .filter((range) => range.start >= start && range.start + range.length <= end)
    .map((range) => ({ start: range.start - start, length: range.length }))

  const collapsed = condense(window, local)
  let body = collapsed.text
  let kept = collapsed.ranges
  let truncatedEnd = end < text.length

  if (body.length > SNIPPET_MAX_CHARS) {
    body = body.slice(0, SNIPPET_MAX_CHARS)
    truncatedEnd = true
    kept = kept
      .filter((range) => range.start < body.length)
      .map((range) => ({ start: range.start, length: Math.min(range.length, body.length - range.start) }))
  }

  return { text: body, ranges: kept, truncatedStart: start > 0, truncatedEnd }
}

/* -------------------------------------------------------------------------- */
/* Ranking                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * What a role is worth before any other signal.
 *
 * Prompts rank highest because "what did I ask it to do" is the search people
 * actually run; tool output ranks lowest because it is machine-generated bulk
 * that would otherwise bury the conversation it belongs to.
 */
export const ROLE_WEIGHT: Record<SearchRole, number> = {
  user: 4,
  assistant: 3,
  thinking: 1.5,
  tool: 1,
  system: 0.75,
}

/** Recency is a tie-breaker, not a ranking. Two weeks halves its contribution. */
export const RECENCY_HALF_LIFE_MS = 14 * 24 * 60 * 60 * 1000
const RECENCY_WEIGHT = 2

export interface ScoreInput {
  role: SearchRole
  /** Distinct include terms that matched this block. */
  termsMatched: number
  termsTotal: number
  matches: number
  phraseHit: boolean
  wordBoundaryHit: boolean
  at: number
  now: number
  isSidechain: boolean
}

export function scoreHit(input: ScoreInput): number {
  const coverage = input.termsTotal > 0 ? input.termsMatched / input.termsTotal : 0
  let score = ROLE_WEIGHT[input.role] * coverage
  if (input.phraseHit) score += 1.5
  if (input.wordBoundaryHit) score += 0.75
  // Damped: the tenth occurrence of a word says far less than the second.
  score += Math.min(2, Math.log2(1 + input.matches))
  if (input.at > 0 && input.now > input.at) {
    score += RECENCY_WEIGHT * Math.pow(0.5, (input.now - input.at) / RECENCY_HALF_LIFE_MS)
  } else if (input.at > 0) {
    score += RECENCY_WEIGHT
  }
  // Sub-agent chatter is real, but it is not what the user was talking about.
  if (input.isSidechain) score *= 0.8
  return score
}

/* -------------------------------------------------------------------------- */
/* Searching                                                                  */
/* -------------------------------------------------------------------------- */

export type SearchScope = 'project' | 'all'

export interface SearchHit {
  sessionId: string
  transcriptPath: string
  /** Project folder the session ran in, as the transcript recorded it. */
  cwd: string
  /** Folder name of `cwd`, for grouping in the UI. */
  projectName: string
  at: number
  role: SearchRole
  tool?: string
  isSidechain: boolean
  score: number
  /** Occurrences in this block, uncapped even when only the first few are highlighted. */
  matches: number
  snippet: Snippet
}

export interface SearchResult {
  query: string
  scope: SearchScope
  hits: SearchHit[]
  /** Transcript files actually opened. */
  sessionsScanned: number
  /** Transcripts the caps left unread. */
  sessionsSkipped: number
  bytesScanned: number
  /** Hits found before `maxHits` trimmed the list. */
  totalHits: number
  /** A cap or the time budget cut the search short. */
  truncated: boolean
  cancelled: boolean
  tookMs: number
}

export interface SearchOptions {
  scope?: SearchScope
  roles?: readonly SearchRole[]
  caseSensitive?: boolean
  regex?: boolean
  maxHits?: number
  maxHitsPerSession?: number
  maxSessions?: number
  maxAgeMs?: number
  timeBudgetMs?: number
  signal?: AbortSignal
  configDir?: string
  /** Injected in tests so ranking is deterministic. */
  now?: number
  /**
   * Wall clock the time budget is measured against. Injected in tests so the
   * budget can be proven to bite without the test depending on how fast the
   * machine running it happens to be.
   */
  clock?: () => number
}

class SearchAborted extends Error {
  constructor() {
    super('session search aborted')
    this.name = 'AbortError'
  }
}

export function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError'
}

function clamp(value: number | undefined, fallback: number, max: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return fallback
  return Math.min(Math.floor(value), max)
}

/**
 * Stream a file's lines without holding it in memory.
 *
 * Chunked with an `await` per chunk on purpose: the main process has the UI
 * hanging off it, and these files reach 154 MB here.
 */
async function* streamLines(path: string, signal?: AbortSignal): AsyncGenerator<string, void, void> {
  let size: number
  try {
    const info = await stat(path)
    // `open(dir, 'r')` succeeds on macOS and only fails at the first `read()`,
    // with a raw EISDIR. A directory named `<x>.jsonl` inside the transcript
    // store is reachable, and should behave like a missing file.
    if (!info.isFile()) return
    size = info.size
  } catch {
    return
  }

  const handle = await open(path, 'r')
  const decoder = new StringDecoder('utf8')
  let offset = 0
  let partial = ''

  try {
    while (offset < size) {
      if (signal?.aborted) throw new SearchAborted()
      const length = Math.min(CHUNK_BYTES, size - offset)
      const buffer = Buffer.allocUnsafe(length)
      const { bytesRead } = await handle.read(buffer, 0, length, offset)
      // Truncated between the stat and the read; stop rather than spin.
      if (bytesRead === 0) break
      offset += bytesRead

      const text = partial + decoder.write(buffer.subarray(0, bytesRead))
      const lines = text.split('\n')
      // The tail is either '' or a line still being written — not ready to parse.
      partial = lines.pop() ?? ''
      if (partial.length > MAX_LINE_BYTES) partial = ''
      for (const line of lines) yield line
    }
  } finally {
    await handle.close()
  }

  // A live session's last line is usually complete; parse it if it stands alone.
  if (partial.length > 0) yield partial
}

interface SessionHits {
  hits: SearchHit[]
  bytes: number
  /** The wall-clock deadline was reached partway through this file. */
  timedOut: boolean
}

/** Search one transcript. Exported so tests can drive a single file. */
export async function searchTranscript(
  file: TranscriptFile,
  query: ParsedQuery,
  roles: ReadonlySet<SearchRole>,
  options: {
    maxHits: number
    now: number
    signal?: AbortSignal
    /** Absolute time past which this file stops being read. */
    deadline?: number
    clock?: () => number
  },
): Promise<SessionHits> {
  const hits: SearchHit[] = []
  const clock = options.clock ?? Date.now
  const perTerm = Math.max(1, Math.floor(MAX_MATCHES_PER_BLOCK / Math.max(1, query.include.length)))
  let bytes = 0
  let cwd = ''
  let lines = 0
  let timedOut = false

  for await (const line of streamLines(file.path, options.signal)) {
    bytes += line.length + 1
    // The budget used to be checked only between files, so a single transcript
    // — and this machine has one of 154 MB — ran to completion however long it
    // took and still reported `truncated: false`.
    lines += 1
    if (
      options.deadline !== undefined &&
      lines % DEADLINE_CHECK_LINES === 0 &&
      clock() > options.deadline
    ) {
      timedOut = true
      break
    }
    if (!mayCarryText(line)) continue
    if (query.prefilter && !query.prefilter.test(line)) continue

    const parsed = parseSearchLine(line)
    if (!parsed) continue
    if (parsed.cwd && !cwd) cwd = parsed.cwd

    for (const block of parsed.blocks) {
      if (!roles.has(block.role)) continue

      let excluded = false
      for (const term of query.exclude) {
        term.pattern.lastIndex = 0
        if (term.pattern.test(block.text)) {
          excluded = true
          break
        }
      }
      if (excluded) continue

      const ranges: MatchRange[] = []
      let termsMatched = 0
      let matches = 0
      let phraseHit = false
      // The snippet centres on the most selective term's first match, so a
      // query's rare word is what the user sees rather than its common one.
      let anchor: MatchRange | undefined
      let rarest = Number.POSITIVE_INFINITY
      for (const term of query.include) {
        const before = ranges.length
        const found = findMatches(block.text, term.pattern, ranges, perTerm)
        if (found === 0) {
          // Every include term must land in the same block — a hit is a place
          // you can read, not a session that mentions both words somewhere.
          termsMatched = 0
          break
        }
        termsMatched += 1
        matches += found
        if (term.phrase) phraseHit = true
        if (found < rarest && ranges.length > before) {
          rarest = found
          anchor = ranges[before]
        }
      }
      if (termsMatched !== query.include.length) continue

      // Sorting reorders the same objects, so `anchor` still points at its own.
      ranges.sort((a, b) => a.start - b.start)
      const wordBoundaryHit = ranges.some((range) => atWordBoundary(block.text, range))

      hits.push({
        sessionId: file.sessionId,
        transcriptPath: file.path,
        cwd,
        projectName: cwd ? basename(cwd) : '',
        at: parsed.at > 0 ? parsed.at : file.modifiedAt,
        role: block.role,
        tool: block.tool,
        isSidechain: parsed.isSidechain,
        matches,
        score: scoreHit({
          role: block.role,
          termsMatched,
          termsTotal: query.include.length,
          matches,
          phraseHit,
          wordBoundaryHit,
          at: parsed.at > 0 ? parsed.at : file.modifiedAt,
          now: options.now,
          isSidechain: parsed.isSidechain,
        }),
        snippet: buildSnippet(block.text, ranges, anchor),
      })
    }

    // Keep the best few from this session rather than every mention of a common
    // word — the list is re-trimmed as it grows so memory stays flat.
    if (hits.length > options.maxHits * 4) {
      hits.sort((a, b) => b.score - a.score)
      hits.length = options.maxHits
    }
  }

  hits.sort((a, b) => b.score - a.score)
  if (hits.length > options.maxHits) hits.length = options.maxHits

  // Backfill the project path for hits parsed before any line carried a `cwd`.
  if (cwd) {
    for (const hit of hits) {
      if (!hit.cwd) {
        hit.cwd = cwd
        hit.projectName = basename(cwd)
      }
    }
  }

  return { hits, bytes, timedOut }
}

/**
 * Every transcript directory under the config root.
 *
 * The directory encoding is deliberately one-way (`encodeProjectPath` is lossy),
 * so an all-projects search enumerates directories and reads each transcript's
 * own `cwd` field rather than trying to decode a name back into a path.
 */
async function allTranscriptDirs(configDir: string): Promise<string[]> {
  const root = join(configDir, 'projects')
  let names: string[]
  try {
    names = await readdir(root)
  } catch {
    return []
  }
  return names.map((name) => join(root, name)).sort()
}

async function collectFiles(
  cwd: string,
  scope: SearchScope,
  configDir: string,
  cutoff: number,
  stop?: () => boolean,
): Promise<TranscriptFile[]> {
  if (scope === 'project') {
    return (await listTranscripts(transcriptDir(cwd, configDir))).filter(
      (file) => file.modifiedAt >= cutoff,
    )
  }

  const dirs = await allTranscriptDirs(configDir)
  const files: TranscriptFile[] = []
  for (const dir of dirs) {
    // Enumeration is a `stat` per transcript across every project that has ever
    // run, which on a busy machine is thousands of them. Without this check an
    // already-cancelled all-projects search still paid for all of it before
    // noticing, once per keystroke.
    if (stop?.()) break
    for (const file of await listTranscripts(dir)) {
      if (file.modifiedAt >= cutoff) files.push(file)
    }
  }
  // Newest first, so the session cap keeps the transcripts most likely to hold
  // what is being looked for.
  return files.sort((a, b) => b.modifiedAt - a.modifiedAt)
}

/**
 * Search a project's transcripts — or every project's.
 *
 * Streams each file, never loads one whole, stops at the first of: `maxHits`,
 * `maxSessions`, the time budget, or the abort signal.
 */
export async function searchSessions(
  cwd: string,
  rawQuery: string,
  options: SearchOptions = {},
): Promise<SearchResult | { error: QueryError; message: string }> {
  const parsed = parseQuery(rawQuery, options)
  if (!parsed.ok) return { error: parsed.error, message: parsed.message }

  const clock = options.clock ?? Date.now
  const startedAt = clock()
  const now = options.now ?? Date.now()
  const scope: SearchScope = options.scope === 'all' ? 'all' : 'project'
  const configDir = options.configDir ?? claudeConfigDir()
  const maxHits = clamp(options.maxHits, DEFAULT_MAX_HITS, MAX_MAX_HITS)
  const perSession = clamp(options.maxHitsPerSession, DEFAULT_MAX_HITS_PER_SESSION, maxHits)
  const maxSessions = clamp(options.maxSessions, DEFAULT_MAX_SESSIONS, MAX_MAX_SESSIONS)
  const maxAge = options.maxAgeMs === 0 ? 0 : clamp(options.maxAgeMs, DEFAULT_MAX_AGE_MS, Number.MAX_SAFE_INTEGER)
  const budget = clamp(options.timeBudgetMs, DEFAULT_TIME_BUDGET_MS, 120_000)
  const roles = new Set<SearchRole>(options.roles && options.roles.length > 0 ? options.roles : DEFAULT_ROLES)
  const cutoff = maxAge > 0 ? now - maxAge : 0

  const deadline = startedAt + budget
  const stop = (): boolean => options.signal?.aborted === true || clock() > deadline

  const hits: SearchHit[] = []
  let all: TranscriptFile[] = []
  let sessionsScanned = 0
  let bytesScanned = 0
  let totalHits = 0
  let truncated = false
  let cancelled = false

  try {
    all = await collectFiles(resolve(cwd), scope, configDir, cutoff, stop)
    if (options.signal?.aborted) throw new SearchAborted()
    const files = all.slice(0, maxSessions)
    truncated = all.length > files.length

    for (const file of files) {
      if (options.signal?.aborted) throw new SearchAborted()
      if (clock() > deadline) {
        truncated = true
        break
      }
      const found = await searchTranscript(file, parsed.query, roles, {
        maxHits: perSession,
        now,
        signal: options.signal,
        deadline,
        clock,
      })
      sessionsScanned += 1
      bytesScanned += found.bytes
      totalHits += found.hits.length
      hits.push(...found.hits)
      // Reached partway through this file, so the file itself is incomplete.
      if (found.timedOut) {
        truncated = true
        break
      }
    }
  } catch (error) {
    if (!isAbortError(error)) throw error
    cancelled = true
  }

  hits.sort((a, b) => b.score - a.score || b.at - a.at)
  if (hits.length > maxHits) {
    hits.length = maxHits
    truncated = true
  }

  return {
    query: rawQuery,
    scope,
    hits,
    sessionsScanned,
    sessionsSkipped: Math.max(0, all.length - sessionsScanned),
    bytesScanned,
    totalHits,
    truncated,
    cancelled,
    tookMs: clock() - startedAt,
  }
}

/* -------------------------------------------------------------------------- */
/* IPC                                                                        */
/* -------------------------------------------------------------------------- */

export interface SessionSearchRequest {
  cwd: string
  query: string
  scope?: SearchScope
  roles?: SearchRole[]
  caseSensitive?: boolean
  regex?: boolean
  maxHits?: number
  maxSessions?: number
}

export type SessionSearchResponse =
  | ({ ok: true } & SearchResult)
  | { ok: false; error: 'cancelled' | 'invalid-project' | QueryError | 'failed'; message: string }

/**
 * A project path from the renderer is untrusted, but it is never opened: it is
 * hashed into a directory name by `encodeProjectPath`, and every file read
 * comes from `listTranscripts` inside `<config>/projects`. This check exists so
 * a malformed value fails loudly instead of searching the wrong folder.
 */
function projectPath(cwd: unknown): string {
  if (typeof cwd !== 'string' || cwd.trim().length === 0) {
    throw new Error('session-search: a project path is required')
  }
  const resolved = resolve(cwd)
  // Belt and braces: nothing downstream joins this onto a filesystem read, but
  // a path with a separator-only body is a sign the caller is confused.
  if (resolved === sep) throw new Error('session-search: refusing to search the filesystem root')
  return resolved
}

function roleList(value: unknown): SearchRole[] | undefined {
  if (!Array.isArray(value)) return undefined
  const roles = value.filter((role): role is SearchRole =>
    typeof role === 'string' && (ALL_ROLES as readonly string[]).includes(role),
  )
  return roles.length > 0 ? roles : undefined
}

/**
 * Register the deep-search channels.
 *
 *  - `session-search:run`    (SessionSearchRequest) -> SessionSearchResponse
 *  - `session-search:cancel` ()                     -> void
 *
 * A second request from the same window cancels the first: the user has typed
 * another character, and two concurrent passes over the same 100 MB only slow
 * each other down.
 */
export function registerSessionSearchIpc(ipcMain: IpcMain): void {
  const inFlight = new Map<number, AbortController>()
  const watched = new Set<number>()

  const cancelFor = (senderId: number): void => {
    inFlight.get(senderId)?.abort()
    inFlight.delete(senderId)
  }

  ipcMain.handle(
    SESSION_SEARCH_CHANNEL,
    async (event: IpcMainInvokeEvent, request: unknown): Promise<SessionSearchResponse> => {
      const payload = (request ?? {}) as Partial<SessionSearchRequest>
      let cwd: string
      try {
        cwd = projectPath(payload.cwd)
      } catch (error) {
        return {
          ok: false,
          error: 'invalid-project',
          message: error instanceof Error ? error.message : 'Invalid project path.',
        }
      }

      const senderId = event.sender.id
      cancelFor(senderId)
      const controller = new AbortController()
      inFlight.set(senderId, controller)
      if (!watched.has(senderId)) {
        watched.add(senderId)
        // A closed window must not leave a 100 MB scan running for nobody.
        event.sender.once('destroyed', () => {
          cancelFor(senderId)
          watched.delete(senderId)
        })
      }

      try {
        const result = await searchSessions(cwd, typeof payload.query === 'string' ? payload.query : '', {
          scope: payload.scope === 'all' ? 'all' : 'project',
          roles: roleList(payload.roles),
          caseSensitive: payload.caseSensitive === true,
          regex: payload.regex === true,
          maxHits: payload.maxHits,
          maxSessions: payload.maxSessions,
          signal: controller.signal,
        })
        if ('error' in result) return { ok: false, error: result.error, message: result.message }
        if (result.cancelled) return { ok: false, error: 'cancelled', message: 'Search cancelled.' }
        return { ok: true, ...result }
      } catch (error) {
        if (isAbortError(error)) return { ok: false, error: 'cancelled', message: 'Search cancelled.' }
        console.error('[session-search] failed:', error)
        return { ok: false, error: 'failed', message: 'Search failed. See the main-process log.' }
      } finally {
        if (inFlight.get(senderId) === controller) inFlight.delete(senderId)
      }
    },
  )

  ipcMain.handle(SESSION_SEARCH_CANCEL_CHANNEL, (event: IpcMainInvokeEvent): void => {
    cancelFor(event.sender.id)
  })
}
