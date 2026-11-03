/**
 * Token and context-window maths for agent sessions.
 *
 * Everything here is pure — numbers in, numbers out — so the arithmetic can be
 * tested without a transcript, a filesystem or an Electron app. `transcript.ts`
 * feeds it; the IPC layer formats what comes back.
 *
 * The file is still called `cost.ts`, and the money is gone from it. That is
 * deliberate on both counts. The channels the renderer talks to are named
 * `cost:*` and are wired through the preload bridge, so renaming the module
 * would leave the name half-changed across a boundary this module does not own;
 * and this is the file somebody will open when they decide the app should show
 * a dollar figure again. The argument waiting for them is at the bottom, under
 * "why this app shows no prices". Read it before adding one.
 */

const MILLION = 1_000_000

/** Model id Claude Code writes for locally generated messages (errors, interrupts). */
export const SYNTHETIC_MODEL = '<synthetic>'

/** Token counts for one or more API requests, split by how the API reports each part. */
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

/**
 * Share of the prompt that was served from cache, 0–1. Zero-safe.
 *
 * A measured ratio of two token counts, which is why it survived the deletion
 * of everything priced: nothing about it depends on what anybody was charged.
 */
export function cacheHitRate(usage: TokenUsage): number {
  const prompt = promptTokens(usage)
  return prompt === 0 ? 0 : usage.cacheRead / prompt
}

/**
 * How many tokens each model can hold in one conversation.
 *
 * This used to be a rate card with a `contextWindow` column bolted on: per
 * million input and output prices, a fast-mode premium, cache multipliers, and
 * a `legacy` flag for models that had aged out of the published table. All of
 * the money is gone — see "why this app shows no prices" at the bottom of this
 * file — and the window is what is left, because a window is not a price. It is
 * a capability of the model, it does not move with anybody's billing, and the
 * context percentage this app draws is meaningless without it: 3% of 200k and
 * 3% of a million are the same reading of two very different situations.
 *
 * Retired models stay in the table for the same reason they always did. A
 * transcript from March still has to report its occupancy against the right
 * denominator, and dropping the row would silently re-measure it against the
 * 200k default.
 *
 * Bedrock and Vertex serve the same models with the same windows, so their
 * prefixes are normalised away rather than given rows of their own.
 */
const CONTEXT_WINDOWS: Record<string, number> = {
  'claude-fable-5': 1_000_000,
  'claude-mythos-5': 1_000_000,
  'claude-opus-5': 1_000_000,
  'claude-opus-4-8': 1_000_000,
  'claude-opus-4-7': 1_000_000,
  'claude-opus-4-6': 1_000_000,
  'claude-opus-4-5': 200_000,
  'claude-sonnet-5': 1_000_000,
  'claude-sonnet-4-6': 1_000_000,
  'claude-sonnet-4-5': 200_000,
  'claude-haiku-4-5': 200_000,
  // Retired or deprecated. Kept so an old transcript is still measured against
  // the window it actually ran in.
  'claude-opus-4-1': 200_000,
  'claude-opus-4-0': 200_000,
  'claude-sonnet-4-0': 200_000,
  'claude-3-5-haiku': 200_000,
  'claude-3-haiku': 200_000,
  'claude-3-opus': 200_000,
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

/**
 * True for real API models. Synthetic and empty ids are not real requests.
 *
 * The name is a leftover from when this decided what to bill, and it still asks
 * the right question: `<synthetic>` lines are interrupts and API errors the CLI
 * wrote locally, carrying no tokens and belonging to no model, so they must not
 * appear in a per-model token table either.
 */
export function isBillableModel(model: string): boolean {
  const id = normalizeModelId(model)
  return id !== '' && id !== SYNTHETIC_MODEL
}

/**
 * Split a trailing `-fast` off an id.
 *
 * `transcript.ts` buckets a fast-mode request under `<model>-fast` so the two
 * speeds stay distinguishable in a per-model token table — speed is a fact
 * about the request, and it survived the deletion of the rate card that
 * originally forced the split. The window does not change with the speed, so
 * the suffix comes off before the lookup.
 */
function baseModelId(id: string): string {
  return id.endsWith('-fast') ? id.slice(0, -'-fast'.length) : id
}

export type ContextLevel = 'ok' | 'warning' | 'critical'

/** Context is filling up — worth surfacing, not yet urgent. */
export const CONTEXT_WARNING_PERCENT = 70
/** Compaction is imminent; quality degrades before it lands. */
export const CONTEXT_CRITICAL_PERCENT = 90
/**
 * Fixed prefix (system prompt, CLAUDE.md, MCP tool schemas) that is re-sent on
 * every single request before the conversation has said anything. Past this
 * share of the window it is worth trimming.
 */
export const PRE_CONTEXT_BLOAT_PERCENT = 15

export function contextWindowFor(model: string): number {
  return CONTEXT_WINDOWS[baseModelId(normalizeModelId(model))] ?? DEFAULT_CONTEXT_WINDOW
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
 * re-sent on every later turn, so it is the one number worth optimising.
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
    /*
     * "Your instructions file" rather than the filename it named before.
     *
     * This warning is drawn for whatever session is in front of somebody, and
     * the four agents this build can run each read a differently-named file for
     * the same purpose. Telling a person looking at a Codex session to go and
     * trim a CLAUDE.md sends them after a file that is not in their prompt and
     * may not be on their disk — a warning that cannot be acted on is worse than
     * no warning, because it is acted on once and then ignored forever.
     */
    message: `Pre-context is ${Math.round(percent)}% of the window (${formatTokens(
      preContextTokens,
    )} tokens) before the conversation starts — check your instructions file and MCP tool schemas.`,
  }
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

/* ------------------------------------------ why this app shows no prices -- */

/*
 * Terminal Deck shows no cost, no spend and no dollar figure anywhere, and this
 * is where all of the arithmetic that used to produce one was deleted. Read
 * this before putting any of it back — the case against it is not that it was
 * hard, it is that neither of the two numbers that could be shown is honest.
 *
 * What was here: `MODELS` as a rate card (per-million `input` / `output`,
 * `fast`, `intro` and `legacy` rates), `CACHE_READ_MULTIPLIER`,
 * `CACHE_WRITE_5M_MULTIPLIER`, `CACHE_WRITE_1H_MULTIPLIER`, `PriceOptions`,
 * `ResolvedPrice`, `priceFor`, `CostBreakdown`, `emptyCost`, `costOf`,
 * `addCost`, `AggregateCost`, `aggregateCost`, `mergeAggregates`, `formatUsd`
 * and `RATES_VERIFIED_ON`; before that, a subscription block of `PlanPrice`,
 * `SUBSCRIPTION_PLANS`, `subscriptionCost`, `MS_PER_BILLING_MONTH` and
 * `billingMonths`, and after it a `PLAN_LABELS` / `normalizePlanId` /
 * `planLabel` trio that existed only to caption a price. Three hand copies of
 * `formatUsd` lived in the renderer — `chat/usage/usage-model.ts`,
 * `components/SessionInspector.tsx` and `dashboard/widgets.tsx` — because the
 * renderer tsconfig cannot see `src/main`. All four are gone, and `cost.test.ts`
 * asserts by name that none of them come back.
 *
 * **The API figure is real arithmetic and still misleads.** It was correct: the
 * rate table matched Anthropic's published one, and a warm agent session at
 * ~90% cache hits genuinely moves a million tokens for a couple of dollars. But
 * almost nobody running this app is billed that way. Asad, seeing `$4558` on
 * the Overview tile: *"people are using subscription and we are showing API
 * price."* A subscription is a flat monthly fee. Telling someone on a flat fee
 * that they spent four and a half thousand dollars states a number that never
 * left their account, and no label rescues it — "API equivalent" is still four
 * figures in the largest type on the page, and a figure is read before its
 * caption is.
 *
 * **The subscription figure cannot be computed at all.** Not "is hard to get
 * right" — there is no published input. Anthropic quantifies no token allowance
 * and no per-token value for any plan. Both pages were read on 2026-08-17
 * (`platform.claude.com/docs/en/about-claude/pricing` and `claude.com/pricing`)
 * and neither states how many tokens a Pro or Max plan buys; plan limits are
 * published as *usage windows* — messages and hours, varying by model and by
 * demand — which is a deliberately different unit. The obvious shortcut, taking
 * the multiplier in "Max 5×" and "Max 20×" as a discount on API rates, is a
 * misreading: those are multiples of the Pro plan's usage allowance, not of a
 * price. Any per-token subscription figure would be invented.
 *
 * So one figure is misleading and the other is unknowable. There is no honest
 * pair to show side by side, and there is no honest single either. Asad, on
 * exactly that: *"if we cannot show the both, let's not show any of them
 * completely."* And earlier, on the same tile: *"we don't keep anything which is
 * not credible, which is not accurate. If we can't have it accurate we don't
 * keep it."*
 *
 * **What would have to change.** Anthropic would have to publish, for a named
 * plan, either a token allowance per billing period or an effective per-token
 * price — something a session's own token counts could be measured against. A
 * blog post, a forum estimate, or a rate somebody reverse-engineered from their
 * own usage is not that: it is one account's experience of a limit that moves
 * with demand, and pricing every user's dashboard off it would invent the same
 * number by a longer route. Until such a figure exists, this app counts tokens
 * and says nothing about money.
 *
 * **A note on what the deletion also fixed.** The rate card carried a live bug:
 * Sonnet 5's $2/$10 was time-boxed to revert to $3/$15 on 2026-09-01, an
 * increase Anthropic has since cancelled. Nothing was wrong on screen and no
 * test failed — the table was simply going to start over-reporting Sonnet 5 by
 * fifty per cent a fortnight later, silently, on a date nobody was watching.
 * That is what a hardcoded price does when the world moves and the code does
 * not. It is gone with the rest of the table.
 */
