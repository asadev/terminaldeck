/**
 * Reads Claude Code's JSONL transcripts and turns them into cost and context
 * numbers.
 *
 * Claude Code writes one JSONL file per session under
 * `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`, appending a line per
 * event. This module locates that directory for a project, tails the files
 * incrementally, and feeds `cost.ts`. It never re-reads bytes it has already
 * seen, so a live session costs a stat plus the bytes that actually arrived.
 */

import { watch, type FSWatcher } from 'chokidar'
import { open, readdir, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, extname, join, resolve } from 'node:path'
import { StringDecoder } from 'node:string_decoder'
import {
  addUsage,
  aggregateCost,
  contextUsage,
  contextWarning,
  contextWindowFor,
  effectiveContextWindow,
  emptyUsage,
  isBillableModel,
  mergeAggregates,
  normalizeModelId,
  preContextWarning,
  promptTokens,
  sumUsage,
  totalTokens,
  type AggregateCost,
  type BloatWarning,
  type ContextUsage,
  type TokenUsage,
} from './cost'

/* -------------------------------------------------------------------------- */
/* Locating transcripts                                                        */
/* -------------------------------------------------------------------------- */

/**
 * Claude Code's directory-name encoding for a project path.
 *
 * Every character that is not `[a-zA-Z0-9]` becomes `-`. Worked out from the
 * real directories on this machine and verified against the `cwd` field each
 * transcript records — 7/7 local projects round-trip, including the awkward
 * ones: `/Users/apple/ClaudeImza/.claude/worktrees/x` becomes
 * `-Users-apple-ClaudeImza--claude-worktrees-x` (the `/.` collapses to `--`),
 * and iCloud's `com~apple~CloudDocs` becomes `com-apple-CloudDocs`.
 *
 * The encoding is lossy and deliberately one-way: `-` is produced by `/`, `.`,
 * `~`, space and more, so a directory name cannot be decoded back to a path.
 * Always go path -> directory, never the reverse.
 *
 * Remote sessions live in `ssh-<uuid>` directories instead and have no local
 * cwd, so they are not addressable through this function at all.
 */
export function encodeProjectPath(cwd: string): string {
  return resolve(cwd).replace(/[^a-zA-Z0-9]/g, '-')
}

/** Root of the Claude CLI's config. `CLAUDE_CONFIG_DIR` is how profiles are isolated. */
export function claudeConfigDir(): string {
  const override = process.env.CLAUDE_CONFIG_DIR?.trim()
  return override && override.length > 0 ? override : join(homedir(), '.claude')
}

/** Directory holding every transcript for a project. May not exist yet. */
export function transcriptDir(cwd: string, configDir = claudeConfigDir()): string {
  return join(configDir, 'projects', encodeProjectPath(cwd))
}

export interface TranscriptFile {
  path: string
  /** Session id — Claude Code names the file after it. */
  sessionId: string
  modifiedAt: number
  bytes: number
}

/** Transcripts in a directory, most recently written first. Missing dir yields []. */
export async function listTranscripts(dir: string): Promise<TranscriptFile[]> {
  let names: string[]
  try {
    names = await readdir(dir)
  } catch {
    return []
  }

  const files: TranscriptFile[] = []
  for (const name of names) {
    if (extname(name) !== '.jsonl') continue
    const path = join(dir, name)
    try {
      const info = await stat(path)
      if (!info.isFile()) continue
      files.push({
        path,
        sessionId: basename(name, '.jsonl'),
        modifiedAt: info.mtimeMs,
        bytes: info.size,
      })
    } catch {
      // Raced with a delete — skip it.
    }
  }
  return files.sort((a, b) => b.modifiedAt - a.modifiedAt)
}

/** The transcript most recently written to, i.e. the live session. */
export async function newestTranscript(dir: string): Promise<TranscriptFile | null> {
  const files = await listTranscripts(dir)
  return files[0] ?? null
}

/* -------------------------------------------------------------------------- */
/* Parsing                                                                     */
/* -------------------------------------------------------------------------- */

export interface TranscriptEvent {
  type: string
  uuid?: string
  /**
   * Identifies one API request. Several JSONL lines share it — see
   * `SessionAggregator.add` for why that matters.
   */
  messageId?: string
  requestId?: string
  model?: string
  usage?: TokenUsage
  speed?: 'standard' | 'fast'
  /** Epoch ms, or 0 when the line carries no usable timestamp. */
  timestamp: number
  sessionId?: string
  cwd?: string
  /** Sub-agent work. Real spend, but attributable to a Task rather than the main thread. */
  isSidechain: boolean
  /** Only on `compact_boundary`: prompt size immediately before compaction. */
  compactedFrom?: number
}

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
 * Pull billable token counts out of an API `usage` object.
 *
 * Shape verified against live transcripts:
 *   { input_tokens, output_tokens, cache_creation_input_tokens,
 *     cache_read_input_tokens,
 *     cache_creation: { ephemeral_5m_input_tokens, ephemeral_1h_input_tokens },
 *     service_tier, speed, iterations, server_tool_use }
 *
 * `cache_creation` is what makes correct pricing possible — Claude Code writes
 * 1-hour caches, which cost 2x input rather than the 1.25x a 5-minute write
 * costs. Older transcripts have only the flat total; the unexplained remainder
 * is attributed to the 5-minute rate, so an unknown split can never inflate
 * the bill.
 */
export function parseUsage(raw: unknown): TokenUsage | null {
  if (!isRecord(raw)) return null

  const declaredWrite = num(raw.cache_creation_input_tokens)
  const detail = isRecord(raw.cache_creation) ? raw.cache_creation : undefined
  const write5m = detail ? num(detail.ephemeral_5m_input_tokens) : 0
  const write1h = detail ? num(detail.ephemeral_1h_input_tokens) : 0
  const unattributed = Math.max(0, declaredWrite - write5m - write1h)

  return {
    input: num(raw.input_tokens),
    output: num(raw.output_tokens),
    cacheWrite5m: write5m + unattributed,
    cacheWrite1h: write1h,
    cacheRead: num(raw.cache_read_input_tokens),
  }
}

/**
 * Parse one JSONL line into the subset of an event we care about.
 *
 * Returns null for malformed lines and for events that carry neither usage nor
 * a compaction marker — a transcript is mostly attachments, queue operations
 * and title updates, and none of that costs anything.
 */
export function parseEventLine(line: string): TranscriptEvent | null {
  const trimmed = line.trim()
  if (trimmed.length === 0) return null

  let raw: unknown
  try {
    raw = JSON.parse(trimmed)
  } catch {
    // A half-written trailing line, or a log the CLI garbled. Skip it silently:
    // transcripts are appended to live and a torn last line is normal.
    return null
  }
  if (!isRecord(raw)) return null

  const type = str(raw.type)
  if (!type) return null

  const event: TranscriptEvent = {
    type,
    uuid: str(raw.uuid),
    requestId: str(raw.requestId),
    timestamp: typeof raw.timestamp === 'string' ? Date.parse(raw.timestamp) || 0 : 0,
    sessionId: str(raw.sessionId),
    cwd: str(raw.cwd),
    isSidechain: raw.isSidechain === true,
  }

  if (type === 'system' && str(raw.subtype) === 'compact_boundary') {
    const meta = isRecord(raw.compactMetadata) ? raw.compactMetadata : undefined
    event.compactedFrom = meta ? num(meta.preTokens) : 0
    return event
  }

  if (type !== 'assistant' || !isRecord(raw.message)) return null

  const message = raw.message
  const usage = parseUsage(message.usage)
  if (!usage) return null

  event.messageId = str(message.id)
  event.model = str(message.model)
  event.usage = usage
  if (isRecord(message.usage) && str(message.usage.speed) === 'fast') event.speed = 'fast'

  return event
}

/**
 * Cheap gate before the expensive `JSON.parse`.
 *
 * Roughly half a transcript's lines are attachments and UI bookkeeping, and
 * some are hundreds of kilobytes. Substring-testing first keeps a 14 MB file
 * from becoming 14 MB of parsed objects.
 */
function mayCarryCost(line: string): boolean {
  return line.includes('"usage"') || line.includes('compact_boundary')
}

/* -------------------------------------------------------------------------- */
/* Incremental tailing                                                         */
/* -------------------------------------------------------------------------- */

/** Bytes pulled per `read()`. Bounds peak memory on the first pass over a large file. */
const CHUNK_BYTES = 4 * 1024 * 1024

/**
 * Cap on a single buffered line.
 *
 * A partial line is carried across chunk boundaries, so a file with no newlines
 * in it — a corrupt transcript, or something else that landed in the directory
 * with a `.jsonl` name — would be buffered whole, with no ceiling but the
 * runtime's string limit. Nothing that can carry a `usage` record comes close to
 * this: one response caps out around 64k output tokens, a few hundred KB.
 */
const MAX_LINE_BYTES = 8 * 1024 * 1024

export interface TailResult {
  events: TranscriptEvent[]
  /** The file shrank or was replaced — callers must discard state derived from it. */
  reset: boolean
  /** Bytes remain unread; call `read()` again. */
  more: boolean
}

/**
 * Reads only the bytes appended since the last call.
 *
 * Holds a byte offset plus any trailing partial line, and decodes through a
 * `StringDecoder` so a chunk boundary landing inside a multi-byte character
 * cannot corrupt it.
 */
export class TranscriptTail {
  private offset = 0
  private partial = ''
  private decoder = new StringDecoder('utf8')

  constructor(readonly path: string) {}

  /** Bytes consumed so far. */
  get position(): number {
    return this.offset
  }

  private rewind(): void {
    this.offset = 0
    this.partial = ''
    this.decoder = new StringDecoder('utf8')
  }

  async read(): Promise<TailResult> {
    let size: number
    try {
      size = (await stat(this.path)).size
    } catch {
      return { events: [], reset: false, more: false }
    }

    // A shorter file is a different file: the session was rewritten or the id
    // was reused. Re-reading from zero is the only safe response.
    let reset = false
    if (size < this.offset) {
      this.rewind()
      reset = true
    }
    if (size === this.offset) return { events: [], reset, more: false }

    const length = Math.min(CHUNK_BYTES, size - this.offset)
    const buffer = Buffer.allocUnsafe(length)
    const handle = await open(this.path, 'r')
    try {
      const { bytesRead } = await handle.read(buffer, 0, length, this.offset)
      // The file was truncated between the stat and the read. `more` is derived
      // from a size we no longer trust, and callers loop on it — returning
      // `more: true` after consuming nothing would spin. Stop and let the next
      // call re-stat.
      if (bytesRead === 0) return { events: [], reset, more: false }
      this.offset += bytesRead
      const text = this.partial + this.decoder.write(buffer.subarray(0, bytesRead))
      const lines = text.split('\n')
      // The last element is either '' (chunk ended on a newline) or a line that
      // is still being written. Either way it is not ready to parse.
      this.partial = lines.pop() ?? ''
      // Runaway line: drop what we are holding. Whatever remains of it before
      // the next newline then fails to parse as JSON and is skipped, which is
      // the same outcome at a fixed memory cost.
      if (this.partial.length > MAX_LINE_BYTES) this.partial = ''

      const events: TranscriptEvent[] = []
      for (const line of lines) {
        if (!mayCarryCost(line)) continue
        const event = parseEventLine(line)
        if (event) events.push(event)
      }
      return { events, reset, more: this.offset < size }
    } finally {
      await handle.close()
    }
  }
}

/* -------------------------------------------------------------------------- */
/* Aggregation                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * Bucket for requests that carry tokens but no model id.
 *
 * Deliberately not a real model id, so it can never collide with one and always
 * lands in `AggregateCost.unpricedModels`.
 */
export const UNKNOWN_MODEL = 'unknown'

/**
 * Bucket key for one rate card.
 *
 * Standard and fast requests to the same model are billed differently, so they
 * are kept apart here and rejoined by `priceFor`, which understands the suffix.
 */
function rateKey(normalizedModel: string, speed: TranscriptEvent['speed']): string {
  if (speed !== 'fast' || normalizedModel.endsWith('-fast')) return normalizedModel
  return `${normalizedModel}-fast`
}

export interface SessionSummary {
  sessionId: string
  transcriptPath: string
  cwd: string
  /** Billable models seen, heaviest first. */
  models: string[]
  /** Deduplicated API requests. */
  requests: number
  usage: TokenUsage
  usageByModel: Record<string, TokenUsage>
  cost: AggregateCost
  /** Occupancy of the context window right now, or null before the first request. */
  context: ContextUsage | null
  warnings: BloatWarning[]
  /** Prompt size of the first request — the fixed prefix every later turn re-pays. */
  preContextTokens: number
  /** How many times this session has been compacted. */
  compactions: number
  /** Requests attributable to sub-agents rather than the main thread. */
  sidechainRequests: number
  startedAt: number
  lastActivityAt: number
}

/**
 * Folds a stream of transcript events into one session's totals.
 *
 * Feed it events in file order; it is incremental and safe to keep alive for
 * the lifetime of a session.
 */
export class SessionAggregator {
  private seen = new Set<string>()
  private byModel = new Map<string, TokenUsage>()
  private requests = 0
  private sidechainRequests = 0
  private compactions = 0
  private firstPromptTokens = 0
  private lastPromptTokens = 0
  /** Model of the most recent *main-thread* request — the one holding the window. */
  private lastMainModel = ''
  /** Model of the most recent request of any kind, used only as a fallback. */
  private lastAnyModel = ''
  private maxPromptTokens = 0
  private startedAt = 0
  private lastActivityAt = 0

  sessionId: string
  cwd = ''

  constructor(
    readonly transcriptPath: string,
    sessionId = basename(transcriptPath, '.jsonl'),
  ) {
    this.sessionId = sessionId
  }

  /**
   * Add one event. Returns true when it changed the totals.
   *
   * The deduplication is the load-bearing part. A single API request produces
   * one JSONL line per content block — a thinking block, a text block and two
   * tool calls come out as four `assistant` lines — and **every one of them
   * repeats the same `usage` object verbatim**. Verified across 133 real
   * transcripts: 2,801 multi-line requests, all with byte-identical usage, up
   * to 19 lines for one request. Summing per line rather than per request
   * inflates the bill by ~2.7x on average.
   */
  add(event: TranscriptEvent): boolean {
    if (event.sessionId && !this.sessionId) this.sessionId = event.sessionId
    if (event.cwd && !this.cwd) this.cwd = event.cwd
    if (event.timestamp > 0) {
      if (this.startedAt === 0) this.startedAt = event.timestamp
      if (event.timestamp > this.lastActivityAt) this.lastActivityAt = event.timestamp
    }

    if (event.compactedFrom !== undefined) {
      this.compactions += 1
      // preTokens is a hard lower bound on the real window: compaction fires
      // when the prompt reaches it.
      if (event.compactedFrom > this.maxPromptTokens) this.maxPromptTokens = event.compactedFrom
      return true
    }

    if (!event.usage) return false

    const key = event.messageId ?? event.requestId ?? event.uuid
    if (key) {
      if (this.seen.has(key)) return false
      this.seen.add(key)
    }

    const model = event.model ?? ''
    const prompt = promptTokens(event.usage)

    this.requests += 1
    if (event.isSidechain) this.sidechainRequests += 1
    // A request with tokens but no model id would otherwise vanish from the
    // totals entirely — the id is what every bucket is keyed on. Park it under
    // a sentinel so `aggregateCost` reports it as unpriced (making the total a
    // stated floor) instead of quietly under-counting. Synthetic messages are
    // excluded: they are locally generated and carry no tokens.
    if (!isBillableModel(model) && normalizeModelId(model) === '' && totalTokens(event.usage) > 0) {
      this.byModel.set(
        UNKNOWN_MODEL,
        addUsage(this.byModel.get(UNKNOWN_MODEL) ?? emptyUsage(), event.usage),
      )
    }
    if (isBillableModel(model)) {
      // Fast mode is a separate rate card (2x on Opus 5), so it cannot share a
      // bucket with the standard rate — the `-fast` suffix is exactly what
      // `priceFor` splits back off. Without this the premium is parsed off the
      // wire and then thrown away, billing a fast session at half price.
      const id = rateKey(normalizeModelId(model), event.speed)
      this.byModel.set(id, addUsage(this.byModel.get(id) ?? emptyUsage(), event.usage))
      this.lastAnyModel = id
      if (!event.isSidechain) this.lastMainModel = id
    }

    if (prompt > 0) {
      // The main thread's prompt is the one that occupies the window; a
      // sub-agent runs in its own context and would otherwise masquerade as it.
      // That applies to the high-water mark too: a 900k sub-agent prompt must
      // not widen the window the main thread is measured against.
      if (!event.isSidechain) {
        if (this.firstPromptTokens === 0) this.firstPromptTokens = prompt
        this.lastPromptTokens = prompt
        if (prompt > this.maxPromptTokens) this.maxPromptTokens = prompt
      }
    }

    return true
  }

  /** Epoch ms of the last event seen. Cheap enough to sort a watcher's files by. */
  get activityAt(): number {
    return this.lastActivityAt
  }

  /** Discard everything — used when a tail reports the file was replaced. */
  reset(): void {
    this.seen.clear()
    this.byModel.clear()
    this.requests = 0
    this.sidechainRequests = 0
    this.compactions = 0
    this.firstPromptTokens = 0
    this.lastPromptTokens = 0
    this.lastMainModel = ''
    this.lastAnyModel = ''
    this.maxPromptTokens = 0
    this.startedAt = 0
    this.lastActivityAt = 0
  }

  get isEmpty(): boolean {
    return this.requests === 0
  }

  summary(at = Date.now()): SessionSummary {
    const usageByModel: Record<string, TokenUsage> = {}
    for (const [model, usage] of this.byModel) usageByModel[model] = usage

    const models = [...this.byModel.entries()]
      .sort((a, b) => promptTokens(b[1]) + b[1].output - (promptTokens(a[1]) + a[1].output))
      .map(([model]) => model)

    // Price against when the work happened, not when the panel was opened —
    // rates are time-boxed and a session run under an introductory rate must
    // keep costing what it cost.
    const pricedAt = this.lastActivityAt > 0 ? this.lastActivityAt : at
    const cost = aggregateCost(this.byModel, { at: pricedAt })

    // Window and occupancy have to come from the same thread. A Task sub-agent
    // running Haiku after an Opus turn would otherwise pin a 200k window onto
    // the main thread's 1M-token conversation and report it as nearly full.
    const contextModel = this.lastMainModel || this.lastAnyModel || models[0] || ''
    const window = effectiveContextWindow(contextWindowFor(contextModel), this.maxPromptTokens)
    const context =
      this.lastPromptTokens > 0
        ? contextUsage(this.lastPromptTokens, contextModel, window)
        : null

    const warnings: BloatWarning[] = []
    if (context) {
      const live = contextWarning(context)
      if (live) warnings.push(live)
    }
    const prefix = preContextWarning(this.firstPromptTokens, window)
    if (prefix) warnings.push(prefix)

    return {
      sessionId: this.sessionId,
      transcriptPath: this.transcriptPath,
      cwd: this.cwd,
      models,
      requests: this.requests,
      usage: sumUsage(this.byModel.values()),
      usageByModel,
      cost,
      context,
      warnings,
      preContextTokens: this.firstPromptTokens,
      compactions: this.compactions,
      sidechainRequests: this.sidechainRequests,
      startedAt: this.startedAt,
      lastActivityAt: this.lastActivityAt,
    }
  }
}

/** Read a whole transcript in one go. Convenience wrapper over `TranscriptTail`. */
export async function readTranscript(path: string): Promise<SessionSummary> {
  const tail = new TranscriptTail(path)
  const aggregator = new SessionAggregator(path)
  for (;;) {
    const { events, reset, more } = await tail.read()
    if (reset) aggregator.reset()
    for (const event of events) aggregator.add(event)
    if (!more) break
  }
  return aggregator.summary()
}

/* -------------------------------------------------------------------------- */
/* Watching a project                                                          */
/* -------------------------------------------------------------------------- */

export interface ProjectSummary {
  cwd: string
  transcriptDir: string
  /** Sessions, most recently active first. */
  sessions: SessionSummary[]
  usage: TokenUsage
  cost: AggregateCost
  requests: number
  /** Session the user is most likely looking at. */
  activeSessionId: string | null
  /** True while the initial pass over historical transcripts is still running. */
  scanning: boolean
  updatedAt: number
}

export interface TranscriptWatcherOptions {
  /** Absolute path to the project folder. */
  cwd: string
  configDir?: string
  /** Called on every change, and repeatedly during the initial scan. */
  onUpdate: (summary: ProjectSummary) => void
  /** Coalesce bursts of appends. Default 300ms. */
  debounceMs?: number
  /** Ignore transcripts older than this. Default 90 days; 0 keeps everything. */
  maxAgeMs?: number
  /** Cap on transcripts indexed, newest first. Default 40. */
  maxSessions?: number
}

const DEFAULT_DEBOUNCE_MS = 300
export const DEFAULT_MAX_AGE_MS = 90 * 24 * 60 * 60 * 1000
export const DEFAULT_MAX_SESSIONS = 40

/**
 * Watches one project's transcript directory and reports cost as it changes.
 *
 * The initial pass runs newest-first and emits after each file, so the live
 * session's numbers appear immediately and history fills in behind it rather
 * than blocking on a directory that can hold hundreds of megabytes.
 */
export class TranscriptWatcher {
  private readonly dir: string
  private readonly tails = new Map<string, TranscriptTail>()
  private readonly aggregators = new Map<string, SessionAggregator>()
  private readonly queue = new Set<string>()
  private watcher: FSWatcher | null = null
  private timer: NodeJS.Timeout | undefined
  private draining = false
  private scanning = true
  private stopped = false

  constructor(private readonly options: TranscriptWatcherOptions) {
    this.dir = transcriptDir(options.cwd, options.configDir)
  }

  get directory(): string {
    return this.dir
  }

  async start(): Promise<void> {
    const maxAge = this.options.maxAgeMs ?? DEFAULT_MAX_AGE_MS
    const maxSessions = this.options.maxSessions ?? DEFAULT_MAX_SESSIONS
    const cutoff = maxAge > 0 ? Date.now() - maxAge : 0

    const files = (await listTranscripts(this.dir))
      .filter((file) => file.modifiedAt >= cutoff)
      .slice(0, maxSessions)

    for (const file of files) this.queue.add(file.path)

    // Watch before draining, so appends that land mid-scan are not missed.
    // `ignoreInitial` because the scan above already has the current contents.
    this.watcher = watch(this.dir, {
      ignoreInitial: true,
      depth: 0,
      persistent: true,
    })
    this.watcher.on('add', (path: string) => this.enqueue(path))
    this.watcher.on('change', (path: string) => this.enqueue(path))
    this.watcher.on('unlink', (path: string) => this.forget(path))
    this.watcher.on('error', (err: unknown) =>
      console.error('[transcript] watch failed:', this.dir, err),
    )

    await this.drain()
    this.scanning = false
    this.emit()
  }

  stop(): void {
    this.stopped = true
    clearTimeout(this.timer)
    void this.watcher?.close()
    this.watcher = null
  }

  /** Current numbers without waiting for the next change. */
  summary(): ProjectSummary {
    const sessions = [...this.aggregators.values()]
      .filter((agg) => !agg.isEmpty)
      .map((agg) => agg.summary())
      .sort((a, b) => b.lastActivityAt - a.lastActivityAt)

    const byModel = new Map<string, TokenUsage>()
    let requests = 0
    for (const session of sessions) {
      requests += session.requests
      for (const [model, usage] of Object.entries(session.usageByModel)) {
        byModel.set(model, addUsage(byModel.get(model) ?? emptyUsage(), usage))
      }
    }

    return {
      cwd: this.options.cwd,
      transcriptDir: this.dir,
      sessions,
      usage: sumUsage(byModel.values()),
      // Add the sessions' money rather than re-pricing their pooled tokens:
      // each session is already priced against when it ran.
      cost: mergeAggregates(sessions.map((session) => session.cost)),
      requests,
      activeSessionId: sessions[0]?.sessionId ?? null,
      scanning: this.scanning,
      updatedAt: Date.now(),
    }
  }

  private enqueue(path: string): void {
    if (this.stopped || extname(path) !== '.jsonl') return
    this.queue.add(path)
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      void this.drain().then(() => this.emit())
    }, this.options.debounceMs ?? DEFAULT_DEBOUNCE_MS)
  }

  private forget(path: string): void {
    this.tails.delete(path)
    this.aggregators.delete(path)
    this.emit()
  }

  /** Process every queued file to EOF, one at a time so memory stays bounded. */
  private async drain(): Promise<void> {
    if (this.draining) return
    this.draining = true
    try {
      while (this.queue.size > 0 && !this.stopped) {
        const path = this.queue.values().next().value as string
        this.queue.delete(path)
        try {
          await this.consume(path)
        } catch (err) {
          console.error('[transcript] failed to read', path, err)
          continue
        }
        // Emit per file during the first pass so the live session's cost shows
        // up straight away rather than after the whole backlog.
        if (this.scanning) this.emit()
      }
      this.prune()
    } finally {
      this.draining = false
    }
  }

  /**
   * Keep at most `maxSessions` transcripts resident.
   *
   * The cap was only ever applied to the initial scan, so a watcher left
   * running on a busy project grew a tail and an aggregator — each holding a
   * dedup set of every request id it ever saw — for every new session forever.
   * Oldest activity is dropped first; if that file is appended to again it is
   * simply re-read from the start.
   */
  private prune(): void {
    const max = this.options.maxSessions ?? DEFAULT_MAX_SESSIONS
    if (max <= 0 || this.aggregators.size <= max) return

    const stale = [...this.aggregators.entries()]
      .sort((a, b) => b[1].activityAt - a[1].activityAt)
      .slice(max)
    for (const [path] of stale) {
      this.aggregators.delete(path)
      this.tails.delete(path)
    }
  }

  private async consume(path: string): Promise<void> {
    let tail = this.tails.get(path)
    if (!tail) {
      tail = new TranscriptTail(path)
      this.tails.set(path, tail)
    }
    let aggregator = this.aggregators.get(path)
    if (!aggregator) {
      aggregator = new SessionAggregator(path)
      this.aggregators.set(path, aggregator)
    }

    for (;;) {
      const { events, reset, more } = await tail.read()
      if (reset) aggregator.reset()
      for (const event of events) aggregator.add(event)
      if (!more || this.stopped) break
    }
  }

  private emit(): void {
    if (this.stopped) return
    this.options.onUpdate(this.summary())
  }
}
