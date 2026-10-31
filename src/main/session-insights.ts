/**
 * Session inspector data — what one session actually did, turn by turn.
 *
 * `cost.ts` owns the token and context maths and `transcript.ts` owns the
 * session totals; neither looks at the *shape* of the work. This module reads
 * the same JSONL transcript a second way and answers the questions a totals
 * line cannot: which request was the heavy one, which tool is being hammered,
 * which one keeps failing, and how the context window filled up over time.
 *
 * Everything below the reader is pure, so the aggregation can be tested against
 * hand-built lines with no filesystem in the way.
 *
 * Field shapes were confirmed against the real transcripts on this machine
 * (133 files, the largest 154 MB / 15,738 lines / 3,071 requests) rather than
 * assumed — the surprises are called out at each site.
 */

import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import { open, stat } from 'node:fs/promises'
import { basename, resolve } from 'node:path'
import { StringDecoder } from 'node:string_decoder'
import {
  cacheHitRate,
  contextUsage,
  contextWarning,
  contextWindowFor,
  effectiveContextWindow,
  emptyUsage,
  isBillableModel,
  normalizeModelId,
  preContextWarning,
  promptTokens,
  sumUsage,
  totalTokens,
  addUsage,
  SYNTHETIC_MODEL,
  type BloatWarning,
  type ContextUsage,
  type TokenUsage,
} from './cost'
import {
  isTranscriptPath,
  listTranscripts,
  parseUsage,
  transcriptDirs,
  UNKNOWN_MODEL,
  type TranscriptFile,
} from './transcript'

/* -------------------------------------------------------------------------- */
/* Line parsing                                                                */
/* -------------------------------------------------------------------------- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function num(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function str(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

/**
 * Ceiling on any one token count, ~1000x the largest session ever seen here.
 *
 * A transcript is a plain file, and a corrupt `output_tokens: 1e308` is finite
 * enough to survive `parseUsage`. Left unclamped it makes every share in the
 * per-model table zero, every total read `Infinity`, and the context meter
 * meaningless — one bad line takes down a whole panel of otherwise good
 * numbers.
 */
const MAX_TOKENS = 1e12

/**
 * Clamp a usage block to counts that can exist.
 *
 * Transcripts are plain files an editor, a crash or a sync conflict can corrupt,
 * and `parseUsage` accepts any finite number — including negatives, which
 * silently *subtract* from the session total and can drive `cacheHitRate`
 * below zero (the meter then renders a negative width).
 */
function sanitizeUsage(usage: TokenUsage): TokenUsage {
  const clamp = (value: number): number =>
    Number.isFinite(value) ? Math.min(MAX_TOKENS, Math.max(0, Math.floor(value))) : 0
  return {
    input: clamp(usage.input),
    output: clamp(usage.output),
    cacheWrite5m: clamp(usage.cacheWrite5m),
    cacheWrite1h: clamp(usage.cacheWrite1h),
    cacheRead: clamp(usage.cacheRead),
  }
}

export interface ToolUseRef {
  /** `toolu_…` id the matching result will quote back. */
  id: string
  name: string
}

export interface ToolResultRef {
  id: string
  failed: boolean
}

export interface CompactionInfo {
  /** Prompt size immediately before compaction — a hard lower bound on the window. */
  preTokens: number
  /** Prompt size the conversation restarted from. */
  postTokens: number
  /** `auto` when the window filled, `manual` when the user ran /compact. */
  trigger: string
  /** How long compaction itself took, as the CLI recorded it. */
  durationMs: number
}

/** The API-response half of a transcript line. */
export interface RequestLine {
  messageId?: string
  requestId?: string
  uuid?: string
  /** Raw model id as written; normalise before using it as a key. */
  model: string
  usage: TokenUsage
  speed: 'standard' | 'fast'
  stopReason: string | null
}

/**
 * One transcript line, reduced to the parts the inspector reads.
 *
 * A single line can be several of these things at once — an assistant line
 * carries usage *and* a tool call — so this is a flat record rather than a
 * union.
 */
export interface InsightLine {
  /** Epoch ms, or 0 when the line carries no usable timestamp. */
  at: number
  sessionId?: string
  cwd?: string
  isSidechain: boolean
  request: RequestLine | null
  toolUses: ToolUseRef[]
  toolResults: ToolResultRef[]
  compaction: CompactionInfo | null
}

/**
 * Parse one JSONL line, or null when it holds nothing the inspector reports.
 *
 * Deliberately not `transcript.ts`'s `parseEventLine`: that one exists to total
 * a session and throws away every line without a `usage` block, which is
 * precisely the set of lines — tool calls and their results — this module is
 * built to read.
 */
export function parseInsightLine(line: string): InsightLine | null {
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

  const type = str(raw.type)
  if (!type) return null

  const parsed: InsightLine = {
    at: typeof raw.timestamp === 'string' ? Date.parse(raw.timestamp) || 0 : 0,
    sessionId: str(raw.sessionId),
    cwd: str(raw.cwd),
    isSidechain: raw.isSidechain === true,
    request: null,
    toolUses: [],
    toolResults: [],
    compaction: null,
  }

  if (type === 'system' && str(raw.subtype) === 'compact_boundary') {
    const meta = isRecord(raw.compactMetadata) ? raw.compactMetadata : undefined
    // Clamped for the same reason usage is: `preTokens` feeds
    // `effectiveContextWindow`, so a corrupt one silently redefines the window
    // every context percentage in the panel is measured against.
    const count = (value: unknown): number =>
      Math.min(MAX_TOKENS, Math.max(0, Math.floor(num(value))))
    parsed.compaction = {
      preTokens: meta ? count(meta.preTokens) : 0,
      postTokens: meta ? count(meta.postTokens) : 0,
      trigger: (meta ? str(meta.trigger) : undefined) ?? 'auto',
      durationMs: meta ? Math.max(0, num(meta.durationMs)) : 0,
    }
    return parsed
  }

  const message = isRecord(raw.message) ? raw.message : undefined
  if (!message) return null

  // Content is an array of blocks. Verified on real files: assistant lines
  // carry exactly one block each — a request that thinks, speaks and calls two
  // tools is written as four lines sharing one `message.id`.
  if (Array.isArray(message.content)) {
    for (const block of message.content) {
      if (!isRecord(block)) continue
      const blockType = str(block.type)
      if (blockType === 'tool_use') {
        const id = str(block.id)
        const name = str(block.name)
        if (id && name) parsed.toolUses.push({ id, name })
      } else if (blockType === 'tool_result') {
        const id = str(block.tool_use_id)
        if (id) parsed.toolResults.push({ id, failed: block.is_error === true })
      }
    }
  }

  if (type === 'assistant') {
    const usage = parseUsage(message.usage)
    if (usage) {
      parsed.request = {
        messageId: str(message.id),
        requestId: str(raw.requestId),
        uuid: str(raw.uuid),
        model: str(message.model) ?? '',
        usage: sanitizeUsage(usage),
        speed:
          isRecord(message.usage) && str(message.usage.speed) === 'fast' ? 'fast' : 'standard',
        stopReason: str(message.stop_reason) ?? null,
      }
    }
  }

  if (!parsed.request && parsed.toolUses.length === 0 && parsed.toolResults.length === 0) {
    return null
  }
  return parsed
}

/**
 * Cheap substring gate before the expensive `JSON.parse`.
 *
 * On the largest transcript here it skips 6,011 of 15,738 lines — attachments,
 * queue operations and title updates, some over a megabyte each. Matching a bit
 * too eagerly is free: a line that gets through and holds nothing simply parses
 * to null.
 */
function mayCarryInsight(line: string): boolean {
  return (
    line.includes('"usage"') ||
    line.includes('"tool_use"') ||
    line.includes('"tool_result"') ||
    line.includes('compact_boundary')
  )
}

/* -------------------------------------------------------------------------- */
/* Server / tool naming                                                        */
/* -------------------------------------------------------------------------- */

/**
 * MCP tools are named `mcp__<server>__<tool>`. The separator is a *double*
 * underscore and both halves may contain single ones (`mcp__ccd_session__mark_chapter`),
 * so the first group has to be lazy or `ccd_session` splits down the middle.
 */
const MCP_TOOL = /^mcp__(.+?)__(.+)$/

/** The MCP server a tool came from, or null for a built-in tool. */
export function mcpServerOf(toolName: string): string | null {
  return MCP_TOOL.exec(toolName)?.[1] ?? null
}

/** Tool name with the `mcp__server__` prefix stripped, for display. */
export function shortToolName(toolName: string): string {
  return MCP_TOOL.exec(toolName)?.[2] ?? toolName
}

/**
 * Bucket key for one model at one speed, mirroring `transcript.ts`.
 *
 * Fast mode is a different service from the same model and the transcript says
 * which one ran, so the two keep separate buckets. `contextWindowFor` strips
 * the suffix back off — the window does not change with the speed.
 */
function rateKey(normalizedModel: string, speed: 'standard' | 'fast'): string {
  if (speed !== 'fast' || normalizedModel.endsWith('-fast')) return normalizedModel
  return `${normalizedModel}-fast`
}

/* -------------------------------------------------------------------------- */
/* Aggregation                                                                 */
/* -------------------------------------------------------------------------- */

export interface TimelineEntry {
  /** 1-based ordinal across the whole session, stable even when the list is trimmed. */
  index: number
  /** Whatever identified the request: message id, else request id, else line uuid. */
  key: string
  /** Epoch ms of the request's first line. */
  at: number
  /** Epoch ms of its last line. */
  endedAt: number
  /**
   * Span across the request's own lines. A lower bound on generation time — the
   * transcript records no request-start, and a single-line request spans 0.
   */
  streamMs: number
  /** Gap since the previous request finished: the user thinking, or tools running. */
  sinceLastMs: number
  /** Bucket key, e.g. `claude-opus-5` or `claude-opus-5-fast`. */
  model: string
  speed: 'standard' | 'fast'
  usage: TokenUsage
  /** Full prompt size, cache included — not the `input_tokens` remainder. */
  promptTokens: number
  outputTokens: number
  /** Prompt and output together — what `heaviest` ranks on. */
  totalTokens: number
  /** Context occupancy at this request, or null for a sub-agent's own context. */
  contextPercent: number | null
  isSidechain: boolean
  stopReason: string | null
  /** Tools this request invoked, in call order. */
  tools: string[]
}

export interface ToolStat {
  name: string
  /** MCP server the tool came from, or null for a built-in. */
  server: string | null
  calls: number
  failures: number
  /** Calls whose result was seen with usable timestamps on both sides. */
  timedCalls: number
  /**
   * Summed elapsed time from call to result. Wall clock, not CPU: a tool that
   * waits on the user (AskUserQuestion runs to hours here) dominates this.
   */
  totalMs: number
  maxMs: number
  avgMs: number
  /** Share of all tool calls, 0–1. */
  share: number
}

export interface ModelStat {
  model: string
  requests: number
  usage: TokenUsage
  promptTokens: number
  outputTokens: number
  /**
   * Share of the session's tokens, 0–1.
   *
   * This used to be a share of the session's *priced cost*, which quietly made
   * the column answer a different question for every reader: a Haiku bucket and
   * an Opus bucket of the same size showed wildly different bars because the
   * rate cards differed. A share of tokens is the same question for every row.
   */
  share: number
}

export interface CompactionMarker {
  at: number
  /** Ordinal of the last request before this compaction, or 0 when it led. */
  afterRequest: number
  preTokens: number
  postTokens: number
  /** Prompt tokens the compaction gave back. */
  reclaimedTokens: number
  /** `auto` when the window filled, `manual` when the user asked. */
  trigger: string
  durationMs: number
}

export interface ContextPoint {
  index: number
  at: number
  tokens: number
  /** True occupancy — may exceed 100. Clamp for a bar, not for the label. */
  percent: number
}

export interface SessionInsights {
  sessionId: string
  transcriptPath: string
  cwd: string
  startedAt: number
  lastActivityAt: number
  /** Wall clock from first line to last. */
  durationMs: number
  /** Summed request spans — the part of the session that was model generation. */
  generatingMs: number
  /** Summed tool call-to-result elapsed time. */
  toolMs: number
  /** Deduplicated API requests. */
  requests: number
  sidechainRequests: number
  /** Newest-first-trimmed slice of the requests, in chronological order. */
  timeline: TimelineEntry[]
  /** Requests dropped off the front of `timeline` to bound the payload. */
  omittedRequests: number
  /**
   * The largest requests in the session by total tokens, heaviest first.
   *
   * Computed over *every* request, not over `timeline`: a long session trims
   * its timeline to the newest few hundred rows, and the request that actually
   * moved the tokens is usually not one of them.
   */
  heaviest: TimelineEntry[]
  tools: ToolStat[]
  toolCalls: number
  toolFailures: number
  models: ModelStat[]
  usage: TokenUsage
  /** Share of prompt tokens served from cache, 0–1. */
  cacheHitRate: number
  context: ContextUsage | null
  contextSeries: ContextPoint[]
  compactions: CompactionMarker[]
  warnings: BloatWarning[]
  /** Prompt size of the first request — the fixed prefix every later turn re-pays. */
  preContextTokens: number
  generatedAt: number
}

export interface BuildOptions {
  transcriptPath?: string
  sessionId?: string
  /**
   * Cap on timeline entries returned. A 3,000-request session would otherwise
   * push megabytes across the IPC bridge for a panel showing thirty rows.
   */
  maxTimelineEntries?: number
  /** Cap on `contextSeries` points. See `DEFAULT_MAX_CONTEXT_POINTS`. */
  maxContextPoints?: number
  /** Clock, for tests. */
  now?: number
}

export const DEFAULT_MAX_TIMELINE_ENTRIES = 750

/** How many requests `heaviest` reports. */
export const HEAVIEST_COUNT = 5

/**
 * Cap on `contextSeries`, which rides the same IPC bridge as the timeline.
 *
 * The chart is 600px of sparkline reduced to 160 points before it is drawn, so
 * a 3,000-request session was shipping ~2,800 points nothing ever read. Kept
 * well above the renderer's own target so the peak survives both reductions.
 */
export const DEFAULT_MAX_CONTEXT_POINTS = 400

/**
 * Reduce a series to at most `target` points, keeping the tallest of each
 * bucket.
 *
 * Reduced by *max* rather than by mean on purpose: the spike immediately before
 * a compaction is the only interesting feature of this chart, and averaging is
 * exactly what erases it. Order is preserved, and the global peak always
 * survives because it is the max of whichever bucket holds it.
 */
export function downsampleContext(points: ContextPoint[], target: number): ContextPoint[] {
  if (target <= 0) return []
  if (points.length <= target) return points

  const size = points.length / target
  const out: ContextPoint[] = []
  for (let i = 0; i < target; i += 1) {
    const from = Math.floor(i * size)
    const to = Math.min(points.length, Math.floor((i + 1) * size))
    let peak = points[from]
    for (let j = from + 1; j < to; j += 1) {
      const candidate = points[j]
      if (candidate && (!peak || candidate.percent > peak.percent)) peak = candidate
    }
    if (peak) out.push(peak)
  }
  return out
}

interface MutableRequest {
  index: number
  key: string
  at: number
  endedAt: number
  model: string
  speed: 'standard' | 'fast'
  usage: TokenUsage
  stopReason: string | null
  isSidechain: boolean
  tools: string[]
}

/**
 * Bucket key for a request whose model id is not a model.
 *
 * Two cases that must not be confused, and only one of them is anonymous.
 * Claude Code writes a literal `<synthetic>` for locally generated messages —
 * interrupts and API errors — which normalises to itself and keeps its own
 * bucket: those requests happened, and a row saying so with no tokens on it is
 * the honest record of an interrupted turn. A request with *no* id at all and
 * real tokens is the anonymous case, and it lands under `unknown` because its
 * tokens have to appear somewhere or the per-model table stops adding up to the
 * session.
 */
function unbillableBucket(request: RequestLine): string {
  const normalized = normalizeModelId(request.model)
  if (normalized !== '') return normalized
  return totalTokens(request.usage) > 0 ? UNKNOWN_MODEL : SYNTHETIC_MODEL
}

interface MutableToolStat {
  name: string
  calls: number
  failures: number
  timedCalls: number
  totalMs: number
  maxMs: number
}

/**
 * Fold transcript lines into everything the inspector shows.
 *
 * Two pieces of this are load-bearing and easy to get wrong:
 *
 *  1. **Requests are deduplicated by `message.id`, tool calls are not.** Every
 *     line of a multi-line request repeats the same `usage` object verbatim
 *     (1,803 multi-line requests checked, zero disagreed, up to 28 lines for
 *     one request) — but each line carries a *different* content block, so the
 *     tool calls have to be gathered from all of them while the tokens are
 *     counted once.
 *  2. **Tool ids repeat.** 75 of 3,074 `toolu_` ids in the largest transcript
 *     appear twice, and 101 results are re-emitted, because compaction replays
 *     part of the conversation. Counting them raw inflates call and failure
 *     counts by a couple of percent, so both sides are deduplicated by id.
 */
export function buildSessionInsights(
  lines: Iterable<InsightLine>,
  options: BuildOptions = {},
): SessionInsights {
  const requests: MutableRequest[] = []
  const byKey = new Map<string, MutableRequest>()
  const toolStats = new Map<string, MutableToolStat>()
  const pendingTools = new Map<string, { name: string; at: number }>()
  const seenToolUses = new Set<string>()
  const seenToolResults = new Set<string>()
  const rawCompactions: Array<CompactionInfo & { at: number; afterRequest: number }> = []

  let sessionId = options.sessionId ?? ''
  let cwd = ''
  let startedAt = 0
  let lastActivityAt = 0
  let toolMs = 0
  /** High-water prompt mark on the *main* thread — what the window is measured against. */
  let maxMainPrompt = 0
  let lastMainModel = ''
  let lastAnyModel = ''

  for (const line of lines) {
    if (line.sessionId && !sessionId) sessionId = line.sessionId
    if (line.cwd && !cwd) cwd = line.cwd
    if (line.at > 0) {
      // Earliest, not first-seen. Transcript lines are appended in completion
      // order, so a sub-agent's lines land after the main-thread lines they ran
      // under and carry earlier timestamps. Anchoring on the first line seen
      // then puts `startedAt` after `lastActivityAt` and collapses `durationMs`
      // to 0 — the session reports as instantaneous.
      if (startedAt === 0 || line.at < startedAt) startedAt = line.at
      if (line.at > lastActivityAt) lastActivityAt = line.at
    }

    if (line.compaction) {
      rawCompactions.push({
        ...line.compaction,
        at: line.at,
        afterRequest: requests.length,
      })
      // Compaction fires when the prompt reaches the limit, so `preTokens` is a
      // hard lower bound on the real window even if no request reported it.
      if (line.compaction.preTokens > maxMainPrompt) maxMainPrompt = line.compaction.preTokens
      continue
    }

    let owner: MutableRequest | undefined
    if (line.request) {
      const key = line.request.messageId ?? line.request.requestId ?? line.request.uuid ?? ''
      const existing = key ? byKey.get(key) : undefined
      if (existing) {
        // A continuation line of a request already counted: it extends the span
        // and can carry another tool call, but its tokens are a repeat. The
        // span widens in both directions — an out-of-order line that is
        // *earlier* than the one that opened the request is still part of it,
        // and clamping it away understates `streamMs`.
        if (line.at > existing.endedAt) existing.endedAt = line.at
        if (line.at > 0 && (existing.at === 0 || line.at < existing.at)) existing.at = line.at
        owner = existing
      } else {
        const normalized = normalizeModelId(line.request.model)
        const billable = isBillableModel(line.request.model)
        const created: MutableRequest = {
          index: requests.length + 1,
          key: key || `line-${requests.length + 1}`,
          at: line.at,
          endedAt: line.at,
          model: billable ? rateKey(normalized, line.request.speed) : unbillableBucket(line.request),
          speed: line.request.speed,
          usage: line.request.usage,
          stopReason: line.request.stopReason,
          isSidechain: line.isSidechain,
          tools: [],
        }
        requests.push(created)
        if (key) byKey.set(key, created)
        owner = created

        if (billable) {
          lastAnyModel = created.model
          if (!line.isSidechain) lastMainModel = created.model
        }
        const prompt = promptTokens(line.request.usage)
        // A sub-agent runs in its own context; letting its prompt widen the
        // window would misreport how full the main thread is.
        if (!line.isSidechain && prompt > maxMainPrompt) maxMainPrompt = prompt
      }
    }

    for (const use of line.toolUses) {
      if (seenToolUses.has(use.id)) continue
      seenToolUses.add(use.id)
      const stat = toolStats.get(use.name) ?? {
        name: use.name,
        calls: 0,
        failures: 0,
        timedCalls: 0,
        totalMs: 0,
        maxMs: 0,
      }
      stat.calls += 1
      toolStats.set(use.name, stat)
      pendingTools.set(use.id, { name: use.name, at: line.at })
      // Attach to the request that issued it; a tool call always rides an
      // assistant line, but fall back to the newest request if that changes.
      const target = owner ?? requests[requests.length - 1]
      if (target) target.tools.push(use.name)
    }

    for (const result of line.toolResults) {
      if (seenToolResults.has(result.id)) continue
      seenToolResults.add(result.id)
      const pending = pendingTools.get(result.id)
      // A result whose call was never seen (2 of 3,175 in the largest file,
      // replayed across a compaction boundary) has nothing to attribute to.
      if (!pending) continue
      pendingTools.delete(result.id)
      const stat = toolStats.get(pending.name)
      if (!stat) continue
      if (result.failed) stat.failures += 1
      if (pending.at > 0 && line.at > 0 && line.at >= pending.at) {
        const elapsed = line.at - pending.at
        stat.timedCalls += 1
        stat.totalMs += elapsed
        toolMs += elapsed
        if (elapsed > stat.maxMs) stat.maxMs = elapsed
      }
    }
  }

  /* ------------------------------------------------------------ finalise -- */

  const contextModel = lastMainModel || lastAnyModel || requests[requests.length - 1]?.model || ''
  const window = effectiveContextWindow(contextWindowFor(contextModel), maxMainPrompt)

  const entries: TimelineEntry[] = []
  const contextSeries: ContextPoint[] = []
  const byModel = new Map<string, { usage: TokenUsage; requests: number }>()
  let generatingMs = 0
  let sidechainRequests = 0
  let previousEnd = 0
  let firstMainPrompt = 0
  let lastMainPrompt = 0

  for (const request of requests) {
    const bucket = byModel.get(request.model) ?? { usage: emptyUsage(), requests: 0 }
    bucket.usage = addUsage(bucket.usage, request.usage)
    bucket.requests += 1
    byModel.set(request.model, bucket)

    const prompt = promptTokens(request.usage)
    const streamMs = request.endedAt > request.at ? request.endedAt - request.at : 0
    generatingMs += streamMs
    if (request.isSidechain) sidechainRequests += 1
    else {
      if (firstMainPrompt === 0) firstMainPrompt = prompt
      lastMainPrompt = prompt
    }

    // Sub-agents hold their own context, so measuring them against the main
    // thread's window would report a number that means nothing.
    const percent =
      request.isSidechain || window <= 0 ? null : (prompt / window) * 100

    entries.push({
      index: request.index,
      key: request.key,
      at: request.at,
      endedAt: request.endedAt,
      streamMs,
      sinceLastMs: previousEnd > 0 && request.at > previousEnd ? request.at - previousEnd : 0,
      model: request.model,
      speed: request.speed,
      usage: request.usage,
      promptTokens: prompt,
      outputTokens: request.usage.output,
      totalTokens: totalTokens(request.usage),
      contextPercent: percent,
      isSidechain: request.isSidechain,
      stopReason: request.stopReason,
      tools: request.tools,
    })

    if (percent !== null && prompt > 0) {
      contextSeries.push({ index: request.index, at: request.at, tokens: prompt, percent })
    }
    if (request.endedAt > previousEnd) previousEnd = request.endedAt
  }

  const sessionTokens = [...byModel.values()].reduce(
    (sum, bucket) => sum + totalTokens(bucket.usage),
    0,
  )

  const models: ModelStat[] = [...byModel.entries()]
    .map(([model, bucket]) => {
      const bucketTokens = totalTokens(bucket.usage)
      return {
        model,
        requests: bucket.requests,
        usage: bucket.usage,
        promptTokens: promptTokens(bucket.usage),
        outputTokens: bucket.usage.output,
        share: sessionTokens > 0 ? bucketTokens / sessionTokens : 0,
      }
    })
    // Heaviest first, which is what the tab is for. The tiebreak keeps the order
    // stable for two buckets that moved the same number of tokens.
    .sort(
      (a, b) =>
        totalTokens(b.usage) - totalTokens(a.usage) || a.model.localeCompare(b.model),
    )

  const totalCalls = [...toolStats.values()].reduce((sum, stat) => sum + stat.calls, 0)
  const tools: ToolStat[] = [...toolStats.values()]
    .map((stat) => ({
      name: stat.name,
      server: mcpServerOf(stat.name),
      calls: stat.calls,
      failures: stat.failures,
      timedCalls: stat.timedCalls,
      totalMs: stat.totalMs,
      maxMs: stat.maxMs,
      avgMs: stat.timedCalls > 0 ? stat.totalMs / stat.timedCalls : 0,
      share: totalCalls > 0 ? stat.calls / totalCalls : 0,
    }))
    .sort((a, b) => b.calls - a.calls || a.name.localeCompare(b.name))

  const usage = sumUsage([...byModel.values()].map((bucket) => bucket.usage))
  const context = lastMainPrompt > 0 ? contextUsage(lastMainPrompt, contextModel, window) : null

  const warnings: BloatWarning[] = []
  if (context) {
    const live = contextWarning(context)
    if (live) warnings.push(live)
  }
  const prefix = preContextWarning(firstMainPrompt, window)
  if (prefix) warnings.push(prefix)

  const compactions: CompactionMarker[] = rawCompactions.map((entry) => ({
    at: entry.at,
    afterRequest: entry.afterRequest,
    preTokens: entry.preTokens,
    postTokens: entry.postTokens,
    reclaimedTokens: Math.max(0, entry.preTokens - entry.postTokens),
    trigger: entry.trigger,
    durationMs: entry.durationMs,
  }))

  // A cap of zero is a cap, not an escape hatch: reading `max > 0` as
  // "unlimited" reopened the megabyte payload the option exists to prevent, and
  // did it for exactly the caller who asked for the smallest one.
  const max = Math.max(0, Math.floor(options.maxTimelineEntries ?? DEFAULT_MAX_TIMELINE_ENTRIES))
  // Trim from the front: the newest requests are the ones worth looking at, and
  // `index` keeps saying where each row sits in the whole session.
  const timeline = entries.length > max ? entries.slice(entries.length - max) : entries

  // Sorted over every request, then trimmed — see `heaviest`. Sorting a copy:
  // `entries` is already sliced into `timeline`, which must stay chronological.
  const heaviest = entries
    .filter((entry) => entry.totalTokens > 0)
    .sort((a, b) => b.totalTokens - a.totalTokens || a.index - b.index)
    .slice(0, HEAVIEST_COUNT)

  const contextPoints = downsampleContext(
    contextSeries,
    Math.max(0, Math.floor(options.maxContextPoints ?? DEFAULT_MAX_CONTEXT_POINTS)),
  )

  return {
    sessionId,
    transcriptPath: options.transcriptPath ?? '',
    cwd,
    startedAt,
    lastActivityAt,
    durationMs: lastActivityAt > startedAt ? lastActivityAt - startedAt : 0,
    generatingMs,
    toolMs,
    requests: requests.length,
    sidechainRequests,
    timeline,
    omittedRequests: entries.length - timeline.length,
    heaviest,
    tools,
    toolCalls: totalCalls,
    toolFailures: tools.reduce((sum, tool) => sum + tool.failures, 0),
    models,
    usage,
    cacheHitRate: cacheHitRate(usage),
    context,
    contextSeries: contextPoints,
    compactions,
    warnings,
    preContextTokens: firstMainPrompt,
    generatedAt: options.now ?? Date.now(),
  }
}

/* -------------------------------------------------------------------------- */
/* Reader                                                                      */
/* -------------------------------------------------------------------------- */

/** Bytes per `read()`. Bounds peak memory and lets the event loop breathe between chunks. */
const CHUNK_BYTES = 4 * 1024 * 1024

/**
 * Cap on a single buffered line.
 *
 * The largest real line here is 1.1 MB (a tool result carrying an image), so
 * this is pure insurance against a file with no newlines being buffered whole.
 */
const MAX_LINE_BYTES = 8 * 1024 * 1024

/**
 * Read a whole transcript into parsed lines.
 *
 * Chunked with an `await` per chunk rather than slurped: these files reach
 * 154 MB, and the main process has a UI hanging off it. Measured on that file
 * the full pass costs ~680 ms and ~160 MB of peak RSS.
 *
 * `transcript.ts`'s `TranscriptTail` is not reused here because it is a
 * usage-only filter — see `parseInsightLine`.
 */
export async function readInsightLines(path: string): Promise<InsightLine[]> {
  let size: number
  try {
    const info = await stat(path)
    // `open(dir, 'r')` succeeds on macOS and Linux and only fails at the first
    // `read()`, with a raw EISDIR that escapes to the renderer as the dialog's
    // error text. A directory named `<something>.jsonl` inside the transcript
    // store passes `assertTranscriptPath`, so this is reachable, and a path
    // that cannot be read should behave like the missing one below.
    if (!info.isFile()) return []
    size = info.size
  } catch {
    return []
  }

  const handle = await open(path, 'r')
  const decoder = new StringDecoder('utf8')
  const lines: InsightLine[] = []
  let offset = 0
  let partial = ''

  try {
    while (offset < size) {
      const length = Math.min(CHUNK_BYTES, size - offset)
      const buffer = Buffer.allocUnsafe(length)
      const { bytesRead } = await handle.read(buffer, 0, length, offset)
      // Truncated between the stat and the read; stop rather than spin.
      if (bytesRead === 0) break
      offset += bytesRead

      const text = partial + decoder.write(buffer.subarray(0, bytesRead))
      const chunk = text.split('\n')
      // The tail is either '' or a line still being written — not ready to parse.
      partial = chunk.pop() ?? ''
      if (partial.length > MAX_LINE_BYTES) partial = ''

      for (const line of chunk) {
        if (!mayCarryInsight(line)) continue
        const parsed = parseInsightLine(line)
        if (parsed) lines.push(parsed)
      }
    }
  } finally {
    await handle.close()
  }

  // A live session's last line is usually complete; parse it if it stands alone.
  if (partial.length > 0 && mayCarryInsight(partial)) {
    const parsed = parseInsightLine(partial)
    if (parsed) lines.push(parsed)
  }

  return lines
}

/** Read and aggregate one transcript. */
export async function readSessionInsights(
  path: string,
  options: BuildOptions = {},
): Promise<SessionInsights> {
  const lines = await readInsightLines(path)
  return buildSessionInsights(lines, {
    ...options,
    transcriptPath: path,
    sessionId: options.sessionId ?? basename(path, '.jsonl'),
  })
}

/* -------------------------------------------------------------------------- */
/* IPC                                                                         */
/* -------------------------------------------------------------------------- */

/**
 * Everything the renderer sends is untrusted, a path most of all: these handlers
 * read whatever file they are handed and echo fields out of it, so an unchecked
 * path is an arbitrary-file-read primitive reachable from the renderer.
 *
 * This used to be a hand copy of the one in `cost-ipc.ts`, which was a hand copy
 * of the one in `chat-transcript.ts`, and all three said "under
 * `~/.claude/projects`". That stopped being the whole truth when confined
 * sessions started writing to a home of their own, and three copies of a rule
 * that has to widen is three chances for one of them to widen wrong — where
 * wrong, here, means an open file read from page code. One implementation now,
 * in `transcript.ts`, which is also the module that knows where the stores are.
 * Nested paths are still allowed on purpose — sub-agent transcripts live in
 * `<session-id>/subagents/*.jsonl`.
 */
function assertTranscriptPath(path: unknown): string {
  if (typeof path !== 'string' || path.length === 0) {
    throw new Error('insights: a transcript path is required')
  }
  if (!isTranscriptPath(path)) {
    throw new Error(`insights: refusing to read outside the transcript store: ${path}`)
  }
  return resolve(path)
}

function projectPath(cwd: unknown): string {
  if (typeof cwd !== 'string' || cwd.trim().length === 0) {
    throw new Error('insights: a project path is required')
  }
  return resolve(cwd)
}

/**
 * Register the session-inspector IPC handlers.
 *
 * Channels:
 *  - `insights:session` (transcriptPath) -> SessionInsights
 *  - `insights:latest`  (cwd)            -> SessionInsights | null
 *  - `insights:list`    (cwd)            -> TranscriptFile[]
 */
export function registerInsightsIpc(ipcMain: IpcMain): void {
  ipcMain.handle(
    'insights:session',
    (_e: IpcMainInvokeEvent, transcriptPath: string): Promise<SessionInsights> =>
      readSessionInsights(assertTranscriptPath(transcriptPath)),
  )

  ipcMain.handle(
    'insights:latest',
    async (_e: IpcMainInvokeEvent, cwd: string): Promise<SessionInsights | null> => {
      // Every store, so a session a paired device started can be inspected at
      // all. It runs with a home of its own and writes its transcript there.
      const newest = (await listAcrossStores(projectPath(cwd)))[0]
      return newest ? readSessionInsights(newest.path) : null
    },
  )

  ipcMain.handle(
    'insights:list',
    (_e: IpcMainInvokeEvent, cwd: string): Promise<TranscriptFile[]> =>
      listAcrossStores(projectPath(cwd)),
  )
}

/**
 * Every transcript for one project, newest first, from every store it can be in.
 *
 * The re-sort is the part that is easy to leave out: `listTranscripts` orders
 * each directory on its own, so concatenating two of them puts a device's live
 * session after the owner's oldest one. The inspector opens the first row.
 */
async function listAcrossStores(cwd: string): Promise<TranscriptFile[]> {
  const found = await Promise.all(transcriptDirs(cwd).map((dir) => listTranscripts(dir)))
  return found.flat().sort((a, b) => b.modifiedAt - a.modifiedAt)
}
