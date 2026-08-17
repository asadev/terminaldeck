/**
 * Everything the usage strip needs to decide what to say, with no React in it.
 *
 * The arithmetic all happens in `src/main/cost.ts` — context occupancy, the
 * thresholds, the token splits. This module only *reads* what came across the
 * bridge and picks the numbers for one strip: which session the chat view is
 * looking at, what the project has moved today, and how to word an absence.
 *
 * Nothing here recomputes a total, and nothing here is money. See "why this app
 * shows no prices" at the bottom of `src/main/cost.ts`.
 */

import type {
  ContextLevel,
  ContextUsage,
  PlanLimit,
  PlanLimitSnapshot,
  ProjectSummary,
  RefreshReason,
  SessionSummary,
  TokenUsage,
} from './types'

/* --------------------------------------------------------------- reading -- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function num(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function str(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []
}

function readUsage(raw: unknown): TokenUsage {
  const source = isRecord(raw) ? raw : {}
  return {
    input: num(source.input),
    output: num(source.output),
    cacheWrite5m: num(source.cacheWrite5m),
    cacheWrite1h: num(source.cacheWrite1h),
    cacheRead: num(source.cacheRead),
  }
}

/**
 * The project's tokens keyed by model.
 *
 * Read defensively one model at a time rather than cast, for the same reason
 * every other field here is: the payload crosses the bridge as `unknown`, and a
 * `Record<string, TokenUsage>` whose values are actually `undefined` fails at
 * the point of *use*, several components away from the line that trusted it.
 */
function readUsageByModel(raw: unknown): Record<string, TokenUsage> {
  if (!isRecord(raw)) return {}
  const out: Record<string, TokenUsage> = {}
  for (const [model, usage] of Object.entries(raw)) out[model] = readUsage(usage)
  return out
}

const LEVELS: ContextLevel[] = ['ok', 'warning', 'critical']

function readContext(raw: unknown): ContextUsage | null {
  // Null until a session has made its first request. A percent read off that
  // yields 0, and "0% of the context window" is a claim, not an absence.
  if (!isRecord(raw)) return null
  const level = str(raw.level) as ContextLevel
  return {
    tokens: num(raw.tokens),
    window: num(raw.window),
    percent: num(raw.percent),
    remaining: num(raw.remaining),
    level: LEVELS.includes(level) ? level : 'ok',
  }
}

function readSession(raw: unknown): SessionSummary | null {
  if (!isRecord(raw)) return null
  const warnings = Array.isArray(raw.warnings) ? raw.warnings : []
  return {
    sessionId: str(raw.sessionId),
    transcriptPath: str(raw.transcriptPath),
    cwd: str(raw.cwd),
    models: strings(raw.models),
    requests: num(raw.requests),
    usage: readUsage(raw.usage),
    context: readContext(raw.context),
    warnings: warnings.filter(isRecord).map((warning) => ({
      kind: str(warning.kind) === 'pre-context' ? ('pre-context' as const) : ('context-window' as const),
      level: str(warning.level) === 'critical' ? ('critical' as const) : ('warning' as const),
      percent: num(warning.percent),
      message: str(warning.message),
    })),
    preContextTokens: num(raw.preContextTokens),
    compactions: num(raw.compactions),
    sidechainRequests: num(raw.sidechainRequests),
    startedAt: num(raw.startedAt),
    lastActivityAt: num(raw.lastActivityAt),
  }
}

/** A `ProjectSummary` off the bridge, or null when the payload is not one. */
export function readProjectSummary(raw: unknown): ProjectSummary | null {
  if (!isRecord(raw) || !Array.isArray(raw.sessions)) return null
  const sessions = raw.sessions.map(readSession).filter((s): s is SessionSummary => s !== null)
  return {
    cwd: str(raw.cwd),
    sessions,
    usage: readUsage(raw.usage),
    usageByModel: readUsageByModel(raw.usageByModel),
    requests: num(raw.requests),
    activeSessionId: typeof raw.activeSessionId === 'string' ? raw.activeSessionId : null,
    scanning: raw.scanning === true,
    updatedAt: num(raw.updatedAt),
  }
}

/** A `PlanLimitSnapshot` off the bridge, or null when the payload is not one. */
export function readPlanSnapshot(raw: unknown): PlanLimitSnapshot | null {
  if (!isRecord(raw) || !Array.isArray(raw.limits)) return null
  const source = str(raw.source)
  return {
    sessionId: str(raw.sessionId),
    available: raw.available === true,
    limits: raw.limits.filter(isRecord).map((limit) => ({
      id: str(limit.id),
      label: str(limit.label),
      scope:
        str(limit.scope) === 'session'
          ? ('session' as const)
          : str(limit.scope) === 'week'
            ? ('week' as const)
            : ('other' as const),
      // Null is meaningful: the CLI named a limit without a number.
      percent: typeof limit.percent === 'number' && Number.isFinite(limit.percent) ? limit.percent : null,
      resetsAt: typeof limit.resetsAt === 'string' && limit.resetsAt.length > 0 ? limit.resetsAt : null,
    })),
    source: source === 'usage-panel' || source === 'warning' ? source : null,
    message: typeof raw.message === 'string' && raw.message.length > 0 ? raw.message : null,
    capturedAt: num(raw.capturedAt),
    reason: typeof raw.reason === 'string' && raw.reason.length > 0 ? raw.reason : null,
  }
}

/* -------------------------------------------------------------- selecting -- */

/** `/a/b/` and `/a/b` are the same project — main resolves, the renderer may not. */
export function sameProject(a: string, b: string): boolean {
  const trim = (value: string): string => value.replace(/\/+$/, '')
  return trim(a) === trim(b) && a.length > 0
}

export interface SessionKey {
  transcriptPath?: string
  sessionId?: string
}

/**
 * The session the strip is about.
 *
 * The chat view is addressed by transcript path when it has one and by project
 * folder otherwise, and the watcher sorts sessions by last activity — so the
 * newest is the live one. Matching on the path first matters when the user is
 * reading back an older session: the strip must describe *that* session's
 * numbers, not the one currently running.
 */
export function pickSession(summary: ProjectSummary | null, key: SessionKey = {}): SessionSummary | null {
  if (!summary) return null
  const { sessions } = summary
  if (sessions.length === 0) return null

  if (key.transcriptPath) {
    const byPath = sessions.find((session) => session.transcriptPath === key.transcriptPath)
    if (byPath) return byPath
  }
  if (key.sessionId) {
    const byId = sessions.find((session) => session.sessionId === key.sessionId)
    if (byId) return byId
  }
  if (summary.activeSessionId) {
    const active = sessions.find((session) => session.sessionId === summary.activeSessionId)
    if (active) return active
  }
  return sessions[0]
}

export interface TodayUsage {
  /** Every token class summed across the sessions active today. */
  tokens: number
  /** Sessions that were active today. */
  sessions: number
  /**
   * How many of those began before today. Their whole token count is included,
   * because a `ProjectSummary` carries one total per session and no per-day
   * split — so the figure is an upper bound whenever this is non-zero, and the
   * strip says so.
   */
  carriedOver: number
}

export function startOfDay(now: number): number {
  const date = new Date(now)
  date.setHours(0, 0, 0, 0)
  return date.getTime()
}

/**
 * What this project has moved today.
 *
 * This used to be `spendToday`, summing each session's already-priced money.
 * The money is gone — see the bottom of `src/main/cost.ts` — and the question
 * the item answers is unchanged: how much work happened today, in the unit the
 * transcript actually recorded.
 */
export function usageToday(summary: ProjectSummary | null, now: number): TodayUsage {
  const empty: TodayUsage = { tokens: 0, sessions: 0, carriedOver: 0 }
  if (!summary) return empty
  const dayStart = startOfDay(now)

  return summary.sessions.reduce((acc, session) => {
    if (session.lastActivityAt < dayStart) return acc
    return {
      tokens: acc.tokens + tokenTotals(session.usage).total,
      sessions: acc.sessions + 1,
      carriedOver: acc.carriedOver + (session.startedAt > 0 && session.startedAt < dayStart ? 1 : 0),
    }
  }, empty)
}

export interface TokenTotals {
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
  /** Full prompt size across the session, cache included. */
  prompt: number
  total: number
}

/**
 * Split a session's tokens the way the API reports them.
 *
 * `input` is only the uncached remainder — on a warm session it reads as a
 * handful of tokens against a 900k prompt — so the cache columns are shown
 * beside it rather than folded in. They are most of the traffic.
 */
export function tokenTotals(usage: TokenUsage): TokenTotals {
  const cacheWrite = usage.cacheWrite5m + usage.cacheWrite1h
  const prompt = usage.input + cacheWrite + usage.cacheRead
  return {
    input: usage.input,
    output: usage.output,
    cacheRead: usage.cacheRead,
    cacheWrite,
    prompt,
    total: prompt + usage.output,
  }
}

/* ------------------------------------------------------------- formatting -- */

/**
 * One tier beyond `cost.ts`: a long session reads over a billion prompt tokens
 * once cache hits are counted, and its `M` branch renders that as "1568.73M".
 * Display only — it cannot drift the arithmetic.
 */
export function formatTokens(tokens: number): string {
  const abs = Math.abs(tokens)
  if (abs >= 999_950_000) return `${(tokens / 1_000_000_000).toFixed(2).replace(/\.?0+$/, '')}B`
  if (abs >= 999_950) return `${(tokens / 1_000_000).toFixed(2).replace(/\.?0+$/, '')}M`
  if (abs >= 1000) return `${(tokens / 1000).toFixed(1).replace(/\.0$/, '')}k`
  return String(Math.round(tokens))
}

const EXACT = new Intl.NumberFormat()

export function formatExact(tokens: number): string {
  return EXACT.format(Math.round(tokens))
}

/**
 * A percentage for a strip.
 *
 * Rounded to a whole number, except below 1% where rounding to "0%" would claim
 * the context is empty when it is not.
 */
export function formatPercent(percent: number): string {
  if (!Number.isFinite(percent)) return '—'
  if (percent > 0 && percent < 1) return '<1%'
  return `${Math.round(percent)}%`
}

/** Width for a meter, clamped. The *label* is never clamped — see `contextReadout`. */
export function barWidth(percent: number): number {
  if (!Number.isFinite(percent)) return 0
  return Math.min(100, Math.max(0, percent))
}

export interface ContextReadout {
  percent: number
  level: ContextLevel
  width: number
  /** `142k / 1M · 14%` */
  label: string
  title: string
  /** True when the prompt exceeded the window — real, and not clamped away. */
  over: boolean
}

/**
 * How full the context window is.
 *
 * The percentage can exceed 100: auto-compaction fires right at the limit, so
 * the last request before it tips over. The bar clamps because a bar cannot do
 * anything else; the number does not, because the number is the finding.
 */
export function contextReadout(context: ContextUsage | null): ContextReadout | null {
  if (!context || context.window <= 0) return null
  const over = context.percent > 100
  return {
    percent: context.percent,
    level: context.level,
    width: barWidth(context.percent),
    label: `${formatTokens(context.tokens)} / ${formatTokens(context.window)} · ${formatPercent(context.percent)}`,
    title: over
      ? `${formatExact(context.tokens)} prompt tokens against a ${formatExact(context.window)}-token window — over the limit, which is where auto-compaction fires.`
      : `${formatExact(context.tokens)} of ${formatExact(context.window)} tokens; ${formatExact(context.remaining)} left before compaction.`,
    over,
  }
}

const MINUTE = 60_000
const HOUR = 60 * MINUTE

/** How old a plan reading is, in words. Empty string when it was just taken. */
export function describeAge(capturedAt: number, now: number): string {
  if (capturedAt <= 0) return ''
  const age = now - capturedAt
  if (age < 2 * MINUTE) return 'just now'
  if (age < HOUR) return `${Math.round(age / MINUTE)}m ago`
  if (age < 24 * HOUR) return `${Math.round(age / HOUR)}h ago`
  return `${Math.round(age / (24 * HOUR))}d ago`
}

/** A plan reading older than this is worth flagging — limits move underneath it. */
export const PLAN_STALE_MS = 15 * MINUTE

export function isStale(capturedAt: number, now: number): boolean {
  return capturedAt > 0 && now - capturedAt > PLAN_STALE_MS
}

/* ------------------------------------------------------------ plan limits -- */

/** Short name for a limit: `Session`, `Week`, `Week (Opus)`. */
export function planLabel(limit: PlanLimit): string {
  if (limit.id === 'session') return 'Session'
  if (limit.id === 'week') return 'Week'
  if (limit.id.startsWith('week:')) {
    const model = limit.id.slice('week:'.length)
    return `Week (${model.charAt(0).toUpperCase()}${model.slice(1)})`
  }
  return limit.label
}

/**
 * The context meter's thresholds, reused for plan limits.
 *
 * Mirrors `CONTEXT_WARNING_PERCENT` / `CONTEXT_CRITICAL_PERCENT` in
 * `src/main/cost.ts`. Reused rather than invented so one strip does not carry
 * two different ideas of "nearly full"; a plan limit has no published threshold
 * of its own, and making one up would be a claim.
 */
export const LIMIT_WARNING_PERCENT = 70
export const LIMIT_CRITICAL_PERCENT = 90

export function levelOfPercent(percent: number | null): ContextLevel {
  if (percent === null || !Number.isFinite(percent)) return 'ok'
  if (percent >= LIMIT_CRITICAL_PERCENT) return 'critical'
  if (percent >= LIMIT_WARNING_PERCENT) return 'warning'
  return 'ok'
}

/** What a limit says, in full, for a tooltip. */
export function planTitle(limit: PlanLimit): string {
  const parts = [limit.label]
  if (limit.percent !== null) parts.push(`${formatPercent(limit.percent)} used`)
  else parts.push('no figure reported')
  if (limit.resetsAt) parts.push(`resets ${limit.resetsAt}`)
  return parts.join(' · ')
}

/**
 * Why a `/usage` run did not happen, in a sentence the user can act on.
 *
 * A control that appears to do nothing is worse than no control, so every
 * refusal has words.
 */
export function refreshFailureMessage(reason: RefreshReason): string {
  switch (reason) {
    case 'busy':
      return 'The session is working — try again once it is idle.'
    case 'prompt-busy':
      // The gate is "an empty `❯` prompt is on screen", which a session running
      // something other than Claude Code will also fail — so this says what was
      // seen rather than asserting there is text in a prompt that may not exist.
      return 'No empty Claude Code prompt on screen — clear the prompt, or check this session is running Claude Code.'
    case 'no-panel':
      return 'Claude Code did not show its usage panel.'
    case 'not-watching':
      return 'This session is not being watched.'
    case 'unwired':
      return 'Running /usage is not wired into this build.'
    default:
      return 'Could not read the plan limit.'
  }
}

/** The context-window warning for this session, or null while it is healthy. */
export function contextWarningOf(session: SessionSummary | null): SessionSummary['warnings'][number] | null {
  if (!session) return null
  return session.warnings.find((warning) => warning.kind === 'context-window') ?? null
}
