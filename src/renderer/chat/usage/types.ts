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
  /**
   * True when some of the folder's transcripts were never read, so these totals
   * describe part of its work rather than all of it. The same field in
   * `src/main/transcript.ts` says what the caps are and why a tile's sentence
   * has to change with it.
   */
  truncated: boolean
  /**
   * True when a live watch is established over a transcript directory that
   * exists, so a reader may rely on the push and switch its own re-read off.
   * The field in `src/main/transcript.ts` says what makes it false and what that
   * costs a pane that believes otherwise.
   */
  watching: boolean
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

/**
 * How a usage refresh went, mirroring `UsageRefreshResult['outcome']` in
 * `src/main/usage-ipc.ts`.
 *
 * The list that replaced `RefreshReason` on 2026-08-18, and the shape of it is
 * the change. The old one was a catalogue of ways typing `/usage` into
 * somebody's session could go wrong — `prompt-busy`, `no-panel`, `panel-open`,
 * a panel left sitting on their conversation — and three of its members had to
 * stop the app asking again for the life of the session, because every one of
 * them had been paid for out of a terminal.
 *
 * Nothing here is paid for out of a terminal. A refresh reads a file and, at
 * worst, starts a short-lived `claude` in the user's home directory, so a
 * failure costs the reader nothing and none of these is terminal. What is left
 * is a list of *answers*, each of which has to be sayable on the bar.
 */
export type UsageRefreshOutcome =
  /** Numbers arrived, from a `claude` this app started and then stopped. */
  | 'ok'
  /** Numbers arrived from what the CLI had already written down. Free. */
  | 'cached'
  /** The login answered, and has no subscription windows to report. */
  | 'no-limits'
  /** Remembered from an earlier `no-limits`, so nothing was started. */
  | 'settled'
  /** That configuration directory is not signed in to Claude Code. */
  | 'signed-out'
  /** There is no runnable `claude` on this machine. */
  | 'no-binary'
  /** It timed out, or answered something this build could not read. */
  | 'unreadable'
  /** This session runs another agent, or is not one this process knows. */
  | 'unwatched'

export interface UsageRefreshResult {
  ok: boolean
  outcome: UsageRefreshOutcome
  /** One sentence for the bar, present in every outcome including `ok`. */
  detail: string
  /** Wall clock, so what this feature costs is visible rather than asserted. */
  elapsedMs: number
  /** True when a `claude` process was started. False on both free paths. */
  spawned: boolean
}
