/**
 * Cost, token and context-window maths for agent sessions.
 *
 * Everything here is pure — numbers in, numbers out — so the arithmetic can be
 * tested without a transcript, a filesystem or an Electron app. `transcript.ts`
 * feeds it; the IPC layer formats what comes back.
 */

const MILLION = 1_000_000

/**
 * Cache rates are multipliers on a model's input rate rather than separately
 * published numbers, and they are uniform across the Claude family:
 *
 *   cache read      0.10x input  — a hit is ~90% off, which is why a session
 *                                  can bill 900k prompt tokens for pennies
 *   5-minute write  1.25x input  — the default ephemeral TTL
 *   1-hour write    2.00x input  — what Claude Code actually writes
 *
 * The two write rates are the reason this module tracks them separately.
 * Charging every cache write at the 5-minute rate under-reports a Claude Code
 * session's spend by 37.5% on the cached portion, and cache writes dominate
 * the bill on a long session.
 *
 * Source: Anthropic prompt-caching docs (economics section) — "Cache reads cost
 * ~0.1x base input price. Cache writes cost 1.25x for 5-minute TTL, 2x for
 * 1-hour TTL."
 */
const CACHE_READ_MULTIPLIER = 0.1
const CACHE_WRITE_5M_MULTIPLIER = 1.25
const CACHE_WRITE_1H_MULTIPLIER = 2

/** Model id Claude Code writes for locally generated messages (errors, interrupts). */
export const SYNTHETIC_MODEL = '<synthetic>'

/** Token counts for one or more API requests, split by how each part is billed. */
export interface TokenUsage {
  /** Fresh input — the part of the prompt that was neither written to nor read from cache. */
  input: number
  output: number
  /** Prompt tokens written to a 5-minute ephemeral cache. */
  cacheWrite5m: number
  /** Prompt tokens written to a 1-hour ephemeral cache. */
  cacheWrite1h: number
  /** Prompt tokens served from cache. */
  cacheRead: number
}

export function emptyUsage(): TokenUsage {
  return { input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0 }
}

export function addUsage(a: TokenUsage, b: TokenUsage): TokenUsage {
  return {
    input: a.input + b.input,
    output: a.output + b.output,
    cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
    cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
    cacheRead: a.cacheRead + b.cacheRead,
  }
}

export function sumUsage(items: Iterable<TokenUsage>): TokenUsage {
  let total = emptyUsage()
  for (const item of items) total = addUsage(total, item)
  return total
}

/**
 * How large the prompt was.
 *
 * `input_tokens` in an API response is only the *uncached remainder*, so on a
 * warm session it reads as a handful of tokens against a 900k-token prompt.
 * The cache columns have to be added back to get the real size — this is the
 * single most common way a token counter ends up off by three orders of
 * magnitude.
 */
export function promptTokens(usage: TokenUsage): number {
  return usage.input + usage.cacheWrite5m + usage.cacheWrite1h + usage.cacheRead
}

export function totalTokens(usage: TokenUsage): number {
  return promptTokens(usage) + usage.output
}

/** Share of the prompt that was served from cache, 0–1. Zero-safe. */
export function cacheHitRate(usage: TokenUsage): number {
  const prompt = promptTokens(usage)
  return prompt === 0 ? 0 : usage.cacheRead / prompt
}

interface ModelEntry {
  /** USD per million fresh input tokens. */
  input: number
  /** USD per million output tokens. */
  output: number
  contextWindow: number
  /** Promotional rate, applied while `at` is before `until`. */
  intro?: { input: number; output: number; until: number }
  /** Fast-mode rate, applied when the request ran with `speed: "fast"`. */
  fast?: { input: number; output: number }
  /**
   * Historical list price, no longer in the published table. Kept so old
   * transcripts still produce a number, flagged so the UI can caveat it.
   */
  legacy?: boolean
}

/**
 * List prices in USD per million tokens, first-party Anthropic API.
 *
 * Sources:
 *  - Current models (Fable 5, Mythos 5, Opus 5/4.8/4.7/4.6, Sonnet 5/4.6,
 *    Haiku 4.5): Anthropic models-overview pricing table, cached 2026-06-24.
 *  - Sonnet 5's $2/$10 introductory rate runs through 2026-08-31, so it is
 *    time-boxed here rather than hardcoded — a session priced today and the
 *    same session re-priced in September must not silently disagree.
 *  - Opus 5 fast mode is $10/$50. Fast mode also exists on Opus 4.8 but no
 *    rate is published for it, so 4.8 falls back to its standard rate rather
 *    than guessing high.
 *  - Entries marked `legacy` are historical list prices for models that have
 *    aged out of the published table. They exist so an old transcript still
 *    costs out; re-verify before quoting them.
 *
 * Bedrock and Vertex are partner-operated and priced separately — those rates
 * are deliberately not modelled here.
 */
const MODELS: Record<string, ModelEntry> = {
  'claude-fable-5': { input: 10, output: 50, contextWindow: 1_000_000 },
  'claude-mythos-5': { input: 10, output: 50, contextWindow: 1_000_000 },
  'claude-opus-5': {
    input: 5,
    output: 25,
    contextWindow: 1_000_000,
    fast: { input: 10, output: 50 },
  },
  'claude-opus-4-8': { input: 5, output: 25, contextWindow: 1_000_000 },
  'claude-opus-4-7': { input: 5, output: 25, contextWindow: 1_000_000 },
  'claude-opus-4-6': { input: 5, output: 25, contextWindow: 1_000_000 },
  'claude-opus-4-5': { input: 5, output: 25, contextWindow: 200_000, legacy: true },
  'claude-sonnet-5': {
    input: 3,
    output: 15,
    contextWindow: 1_000_000,
    // Introductory pricing, ends 2026-08-31 inclusive.
    intro: { input: 2, output: 10, until: Date.UTC(2026, 8, 1) },
  },
  'claude-sonnet-4-6': { input: 3, output: 15, contextWindow: 1_000_000 },
  'claude-sonnet-4-5': { input: 3, output: 15, contextWindow: 200_000, legacy: true },
  'claude-haiku-4-5': { input: 1, output: 5, contextWindow: 200_000 },
  // Retired or deprecated, historical list prices only.
  'claude-opus-4-1': { input: 15, output: 75, contextWindow: 200_000, legacy: true },
  'claude-opus-4-0': { input: 15, output: 75, contextWindow: 200_000, legacy: true },
  'claude-sonnet-4-0': { input: 3, output: 15, contextWindow: 200_000, legacy: true },
  'claude-3-5-haiku': { input: 0.8, output: 4, contextWindow: 200_000, legacy: true },
  'claude-3-haiku': { input: 0.25, output: 1.25, contextWindow: 200_000, legacy: true },
  'claude-3-opus': { input: 15, output: 75, contextWindow: 200_000, legacy: true },
}

/** Window assumed for a model we have no entry for. */
export const DEFAULT_CONTEXT_WINDOW = 200_000

/**
 * Reduce the many shapes a model id arrives in down to one table key.
 *
 * Transcripts on this machine carry plain ids (`claude-opus-5`) and dated
 * snapshots (`claude-haiku-4-5-20251001`); the same code has to survive
 * Bedrock's `anthropic.` prefix, Vertex's `@20251001` pin and the `[1m]` tag
 * Claude Code appends when the long-context beta is on.
 */
export function normalizeModelId(model: string): string {
  return model
    .trim()
    .toLowerCase()
    .replace(/^(?:us|eu|apac|global)\./, '')
    .replace(/^anthropic\./, '')
    .replace(/\[1m\]$/, '')
    .replace(/@\d{8}$/, '')
    .replace(/-v\d+:\d+$/, '')
    .replace(/-\d{8}$/, '')
}

/** True for real API models. Synthetic and empty ids are not billed at all. */
export function isBillableModel(model: string): boolean {
  const id = normalizeModelId(model)
  return id !== '' && id !== SYNTHETIC_MODEL
}

export interface PriceOptions {
  /** When the request happened, for time-boxed rates. Defaults to now. */
  at?: number
  speed?: 'standard' | 'fast'
}

export interface ResolvedPrice {
  /** Normalized id the rate was found under. */
  model: string
  input: number
  output: number
  cacheWrite5m: number
  cacheWrite1h: number
  cacheRead: number
  contextWindow: number
  legacy: boolean
}

/** Split a trailing `-fast` off an id — some deployments encode speed in the name. */
function splitSpeed(id: string): { id: string; fast: boolean } {
  return id.endsWith('-fast') ? { id: id.slice(0, -'-fast'.length), fast: true } : { id, fast: false }
}

/** Resolved rates for a model, or null when we have no published rate for it. */
export function priceFor(model: string, opts: PriceOptions = {}): ResolvedPrice | null {
  const { id, fast: fastSuffix } = splitSpeed(normalizeModelId(model))
  const entry = MODELS[id]
  if (!entry) return null

  const at = opts.at ?? Date.now()
  let { input, output } = entry
  if (entry.intro && at < entry.intro.until) {
    input = entry.intro.input
    output = entry.intro.output
  }
  // Fast mode is a premium rate, so it wins over any promotional rate.
  if ((opts.speed === 'fast' || fastSuffix) && entry.fast) {
    input = entry.fast.input
    output = entry.fast.output
  }

  return {
    model: id,
    input,
    output,
    cacheWrite5m: input * CACHE_WRITE_5M_MULTIPLIER,
    cacheWrite1h: input * CACHE_WRITE_1H_MULTIPLIER,
    cacheRead: input * CACHE_READ_MULTIPLIER,
    contextWindow: entry.contextWindow,
    legacy: entry.legacy ?? false,
  }
}

export interface CostBreakdown {
  input: number
  output: number
  /** 5-minute and 1-hour writes combined — they are one line item to a user. */
  cacheWrite: number
  cacheRead: number
  total: number
}

export function emptyCost(): CostBreakdown {
  return { input: 0, output: 0, cacheWrite: 0, cacheRead: 0, total: 0 }
}

/**
 * Cost of some usage in USD, or null when the model has no known rate.
 *
 * Null rather than 0 on purpose: a zero renders as "this was free", which is a
 * worse lie than "we don't know".
 */
export function costOf(
  usage: TokenUsage,
  model: string,
  opts: PriceOptions = {},
): CostBreakdown | null {
  const price = priceFor(model, opts)
  if (!price) return null

  const input = (usage.input * price.input) / MILLION
  const output = (usage.output * price.output) / MILLION
  const cacheWrite =
    (usage.cacheWrite5m * price.cacheWrite5m + usage.cacheWrite1h * price.cacheWrite1h) / MILLION
  const cacheRead = (usage.cacheRead * price.cacheRead) / MILLION

  return { input, output, cacheWrite, cacheRead, total: input + output + cacheWrite + cacheRead }
}

export function addCost(a: CostBreakdown, b: CostBreakdown): CostBreakdown {
  return {
    input: a.input + b.input,
    output: a.output + b.output,
    cacheWrite: a.cacheWrite + b.cacheWrite,
    cacheRead: a.cacheRead + b.cacheRead,
    total: a.total + b.total,
  }
}

export interface AggregateCost {
  cost: CostBreakdown
  /** Per-model costs, keyed by normalized id. Only priced models appear. */
  byModel: Record<string, CostBreakdown>
  /**
   * Models whose tokens were counted but not priced. Non-empty means the
   * total is a floor, not the answer — say so in the UI.
   */
  unpricedModels: string[]
  /** True when a legacy (historical) rate contributed to the total. */
  usedLegacyRate: boolean
}

/**
 * Price a whole session or project. Sessions routinely mix models — a Haiku
 * background task inside an Opus session — so each model is priced against its
 * own rate card and only then summed.
 */
export function aggregateCost(
  byModel: Iterable<readonly [string, TokenUsage]>,
  opts: PriceOptions = {},
): AggregateCost {
  const result: AggregateCost = {
    cost: emptyCost(),
    byModel: {},
    unpricedModels: [],
    usedLegacyRate: false,
  }

  for (const [model, usage] of byModel) {
    // Synthetic messages carry zero usage and have no rate; counting them as
    // "unpriced" would flag almost every session that ever hit an API error.
    if (!isBillableModel(model)) continue

    const cost = costOf(usage, model, opts)
    if (!cost) {
      const id = normalizeModelId(model)
      if (!result.unpricedModels.includes(id)) result.unpricedModels.push(id)
      continue
    }

    const id = normalizeModelId(model)
    result.byModel[id] = result.byModel[id] ? addCost(result.byModel[id], cost) : cost
    result.cost = addCost(result.cost, cost)
    if (priceFor(model, opts)?.legacy) result.usedLegacyRate = true
  }

  result.unpricedModels.sort()
  return result
}

/**
 * Combine aggregates that have already been priced.
 *
 * A project total must be the sum of its sessions, and each session is priced
 * against the moment its work ran. Pooling every session's raw token counts and
 * re-running `aggregateCost` prices the whole project at *today's* rates, so the
 * project total silently stops matching the sessions it is made of as soon as a
 * time-boxed rate expires. Adding the money instead keeps them in agreement.
 */
export function mergeAggregates(parts: Iterable<AggregateCost>): AggregateCost {
  const merged: AggregateCost = {
    cost: emptyCost(),
    byModel: {},
    unpricedModels: [],
    usedLegacyRate: false,
  }
  const unpriced = new Set<string>()

  for (const part of parts) {
    merged.cost = addCost(merged.cost, part.cost)
    for (const [model, cost] of Object.entries(part.byModel)) {
      merged.byModel[model] = merged.byModel[model] ? addCost(merged.byModel[model], cost) : cost
    }
    for (const model of part.unpricedModels) unpriced.add(model)
    if (part.usedLegacyRate) merged.usedLegacyRate = true
  }

  merged.unpricedModels = [...unpriced].sort()
  return merged
}

export type ContextLevel = 'ok' | 'warning' | 'critical'

/** Context is filling up — worth surfacing, not yet urgent. */
export const CONTEXT_WARNING_PERCENT = 70
/** Compaction is imminent; quality and cost both degrade past here. */
export const CONTEXT_CRITICAL_PERCENT = 90
/**
 * Fixed prefix (system prompt, CLAUDE.md, MCP tool schemas) that is paid for on
 * every single request before the conversation has said anything. Past this
 * share of the window it is worth trimming.
 */
export const PRE_CONTEXT_BLOAT_PERCENT = 15

export function contextWindowFor(model: string): number {
  return priceFor(model)?.contextWindow ?? DEFAULT_CONTEXT_WINDOW
}

/** The context sizes Anthropic actually ships, smallest first. */
const WINDOW_TIERS = [200_000, 1_000_000]

/**
 * Widen a model's table window when the transcript proves it is bigger.
 *
 * A 900k-token prompt against a model we have pinned at 200k means the
 * long-context beta is on, or our table has gone stale. Reporting "450% full"
 * helps nobody, so the observed size promotes the window to the next real tier.
 */
export function effectiveContextWindow(modelWindow: number, observedPromptTokens: number): number {
  if (observedPromptTokens <= modelWindow) return modelWindow
  return WINDOW_TIERS.find((tier) => tier >= observedPromptTokens) ?? observedPromptTokens
}

export function contextLevel(percent: number): ContextLevel {
  if (percent >= CONTEXT_CRITICAL_PERCENT) return 'critical'
  if (percent >= CONTEXT_WARNING_PERCENT) return 'warning'
  return 'ok'
}

export interface ContextUsage {
  /** Prompt size of the most recent request. */
  tokens: number
  window: number
  /**
   * Percent of the window in use. Can exceed 100 — auto-compaction fires right
   * at the limit, so the last request before it tips slightly over. Clamp for
   * a progress bar; don't clamp the number you report.
   */
  percent: number
  remaining: number
  level: ContextLevel
}

/**
 * Where a session stands against its context window.
 *
 * `tokens` must be the prompt size of the *latest* request, never a running
 * total: summing prompts across a session counts the same cached prefix once
 * per turn and reports 40x the real occupancy.
 */
export function contextUsage(
  latestPromptTokens: number,
  model: string,
  windowOverride?: number,
): ContextUsage {
  const window = windowOverride && windowOverride > 0 ? windowOverride : contextWindowFor(model)
  const tokens = Math.max(0, latestPromptTokens)
  const percent = window > 0 ? (tokens / window) * 100 : 0
  return {
    tokens,
    window,
    percent,
    remaining: Math.max(0, window - tokens),
    level: contextLevel(percent),
  }
}

export interface BloatWarning {
  kind: 'context-window' | 'pre-context'
  level: 'warning' | 'critical'
  percent: number
  message: string
}

/** Warning for a conversation that is filling its window, or null while healthy. */
export function contextWarning(usage: ContextUsage): BloatWarning | null {
  if (usage.level === 'ok') return null
  const pct = Math.round(usage.percent)
  return {
    kind: 'context-window',
    level: usage.level,
    percent: usage.percent,
    message:
      usage.level === 'critical'
        ? `Context ${pct}% full — compaction is imminent, and quality drops before it lands.`
        : `Context ${pct}% full.`,
  }
}

/**
 * Warning for an oversized fixed prefix.
 *
 * Measured from the first request of a session: everything in that prompt is
 * paid for again on every later turn, so it is the one number worth optimising.
 */
export function preContextWarning(
  preContextTokens: number,
  window: number,
): BloatWarning | null {
  if (window <= 0 || preContextTokens <= 0) return null
  const percent = (preContextTokens / window) * 100
  if (percent < PRE_CONTEXT_BLOAT_PERCENT) return null
  return {
    kind: 'pre-context',
    level: percent >= PRE_CONTEXT_BLOAT_PERCENT * 2 ? 'critical' : 'warning',
    percent,
    message: `Pre-context is ${Math.round(percent)}% of the window (${formatTokens(
      preContextTokens,
    )} tokens) before the conversation starts — check CLAUDE.md and MCP tool schemas.`,
  }
}

/** Money, at a precision that suits the magnitude. Sub-cent spends still read as non-zero. */
export function formatUsd(usd: number): string {
  const abs = Math.abs(usd)
  if (abs === 0) return '$0.00'
  if (abs < 0.01) return `$${usd.toFixed(4)}`
  if (abs < 10) return `$${usd.toFixed(3)}`
  return `$${usd.toFixed(2)}`
}

/**
 * Below this the `k` form rounds to `1000.0` and renders as "1000k" instead of
 * "1M" — the one seam where the two branches disagree about the same number.
 */
const K_ROUNDS_TO_MILLION = 999_950

/** Compact token counts — `1.2k`, `31.4k`, `1.05M`. */
export function formatTokens(tokens: number): string {
  const abs = Math.abs(tokens)
  if (abs >= K_ROUNDS_TO_MILLION) return `${(tokens / MILLION).toFixed(2).replace(/\.?0+$/, '')}M`
  if (abs >= 1000) return `${(tokens / 1000).toFixed(1).replace(/\.0$/, '')}k`
  return String(Math.round(tokens))
}
