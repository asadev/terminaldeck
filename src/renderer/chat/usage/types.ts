/**
 * Mirrors of the shapes the main process sends across the bridge.
 *
 * Duplicated rather than imported because the renderer tsconfig does not include
 * `src/main` — the arrangement `SessionInspector`, `GitPanel` and `ChatView`
 * already use. Everything arrives as `unknown`, so `usage-model.ts` reads each
 * field defensively instead of casting one of these over a raw payload.
 */

/** `src/main/cost.ts` — token counts split by how each part is recorded. */
export interface TokenUsage {
  input: number
  output: number
  cacheWrite5m: number
  cacheWrite1h: number
  cacheRead: number
}

export type ContextLevel = 'ok' | 'warning' | 'critical'

export interface ContextUsage {
  tokens: number
  window: number
  /** Can exceed 100 — compaction fires at the limit, so the last request tips over. */
  percent: number
  remaining: number
  level: ContextLevel
}

export interface BloatWarning {
  kind: 'context-window' | 'pre-context'
  level: 'warning' | 'critical'
  percent: number
  message: string
}

/** `src/main/transcript.ts` — one session's totals. */
export interface SessionSummary {
  sessionId: string
  transcriptPath: string
  cwd: string
  models: string[]
  requests: number
  usage: TokenUsage
  context: ContextUsage | null
  warnings: BloatWarning[]
  preContextTokens: number
  compactions: number
  sidechainRequests: number
  startedAt: number
  lastActivityAt: number
}

export interface ProjectSummary {
  cwd: string
  sessions: SessionSummary[]
  usage: TokenUsage
  usageByModel: Record<string, TokenUsage>
  requests: number
  activeSessionId: string | null
  /** True while the first pass over historical transcripts is still running. */
  scanning: boolean
  updatedAt: number
}

/** `src/main/plan-limit.ts` — what the CLI said about the subscription plan. */
export interface PlanLimit {
  id: string
  label: string
  scope: 'session' | 'week' | 'other'
  /** Null when Claude Code named a limit without a number. Never rendered as 0. */
  percent: number | null
  resetsAt: string | null
}

export interface PlanLimitSnapshot {
  sessionId: string
  available: boolean
  limits: PlanLimit[]
  source: 'usage-panel' | 'warning' | null
  message: string | null
  capturedAt: number
  reason: string | null
}

export type RefreshReason = 'unwired' | 'not-watching' | 'busy' | 'prompt-busy' | 'no-panel' | null

export interface RefreshResult {
  ok: boolean
  reason: RefreshReason
  snapshot: PlanLimitSnapshot
}
