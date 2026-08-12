import { useMemo } from 'react'
import type { PlanLimitSnapshot, SessionSummary } from './types'
import {
  contextReadout,
  contextWarningOf,
  describeAge,
  formatExact,
  formatPercent,
  formatTokens,
  formatUsd,
  isStale,
  levelOfPercent,
  pickSession,
  planLabel,
  planTitle,
  refreshFailureMessage,
  spendToday,
  tokenTotals,
  type TodaySpend,
} from './usage-model'
import { useUsage, type UsageBridge } from './useUsage'
import './UsageStrip.css'

/**
 * What this session has cost, and how close it is to its limits.
 *
 * A reading strip, not a dashboard: the session inspector already owns the
 * per-request detail. Everything here comes from figures the main process has
 * already computed — `cost.ts` for the money and the context window,
 * `transcript.ts` for the incremental tail, `plan-limit.ts` for whatever Claude
 * Code itself said about the subscription plan.
 *
 * Two honesty rules run through it:
 *
 *  1. Context occupancy above 100% is shown as it is. Auto-compaction fires at
 *     the limit, so the last request before it genuinely tips over; only the
 *     bar clamps, because a bar cannot do otherwise.
 *  2. A plan limit is only ever what the CLI printed. There is no local file
 *     holding it and no flag that prints it, so when nothing has been seen the
 *     strip says so instead of estimating.
 */

/* ------------------------------------------------------------------ pieces */

function Meter({ percent, level }: { percent: number; level: 'ok' | 'warning' | 'critical' }) {
  return (
    <span className="us-meter" data-level={level} aria-hidden="true">
      {/* Clamped for the bar only — a 104% prompt still renders as a full bar,
          while the label beside it keeps saying 104%. */}
      <span className="us-meter-fill" style={{ width: `${Math.min(100, Math.max(0, percent))}%` }} />
    </span>
  )
}

function Item({
  label,
  title,
  children,
  wide,
}: {
  label: string
  title?: string
  children: React.ReactNode
  wide?: boolean
}) {
  return (
    <div className={wide ? 'us-item us-item-wide' : 'us-item'} title={title}>
      <span className="us-label">{label}</span>
      {children}
    </div>
  )
}

/* -------------------------------------------------------------------- view */

export interface UsageStripViewProps {
  session: SessionSummary | null
  today: TodaySpend
  plan: PlanLimitSnapshot | null
  /** True while the main process is still reading this project's history. */
  scanning: boolean
  now: number
  unwired?: boolean
  canRefreshPlan?: boolean
  refreshing?: boolean
  refreshReason?: string | null
  onRefreshPlan?: () => void
}

interface Note {
  tone: 'muted' | 'warning' | 'critical'
  text: string
}

/** At most this many notes; the strip is meant to stay quiet. */
const MAX_NOTES = 2

/**
 * Presentational half, exported for its own tests.
 *
 * Every figure arrives already decided, so the rules about what is shown and
 * what is caveated are testable without a bridge, a watcher or a DOM.
 */
export function UsageStripView({
  session,
  today,
  plan,
  scanning,
  now,
  unwired = false,
  canRefreshPlan = false,
  refreshing = false,
  refreshReason = null,
  onRefreshPlan,
}: UsageStripViewProps) {
  if (unwired) {
    return (
      <div className="usage-strip usage-strip-empty">
        <span className="us-muted">Usage is not wired into this build.</span>
      </div>
    )
  }

  if (!session) {
    return (
      <div className="usage-strip usage-strip-empty">
        <span className="us-muted">
          {scanning ? 'Reading transcripts…' : 'No usage recorded for this project yet.'}
        </span>
      </div>
    )
  }

  const context = contextReadout(session.context)
  const tokens = tokenTotals(session.usage)
  const spend = session.cost.cost
  const unpriced = session.cost.unpricedModels

  const notes: Note[] = []
  if (refreshReason) notes.push({ tone: 'muted', text: refreshReason })
  const warning = contextWarningOf(session)
  if (warning) notes.push({ tone: warning.level, text: warning.message })
  if (unpriced.length > 0) {
    notes.push({
      tone: 'muted',
      // The total is a floor, and saying "$X" flat would be a claim it is not.
      text: `Spend is a floor — no published rate for ${unpriced.join(', ')}.`,
    })
  }
  if (session.cost.usedLegacyRate) {
    notes.push({ tone: 'muted', text: 'Priced partly from a retired rate card.' })
  }
  if (today.carriedOver > 0) {
    notes.push({
      tone: 'muted',
      text: `Today includes ${today.carriedOver} session${today.carriedOver === 1 ? '' : 's'} that started earlier, counted in full.`,
    })
  }

  return (
    <div className="usage-strip" role="group" aria-label="Session usage and limits">
      <div className="us-items">
        {context ? (
          <Item label="Context" title={context.title} wide>
            <Meter percent={context.width} level={context.level} />
            <span className="us-value" data-level={context.level}>
              {context.label}
            </span>
            {context.over ? (
              <span
                className="us-flag"
                title="The prompt exceeded the window — this is the request auto-compaction fires on."
              >
                over
              </span>
            ) : null}
          </Item>
        ) : (
          <Item label="Context" title="No request has been made in this session yet.">
            <span className="us-value us-muted">—</span>
          </Item>
        )}

        <Item
          label="Session"
          title={`in ${formatUsd(spend.input)} · out ${formatUsd(spend.output)} · cache write ${formatUsd(
            spend.cacheWrite,
          )} · cache read ${formatUsd(spend.cacheRead)} · ${session.requests} requests${
            unpriced.length > 0 ? `. A floor, not the answer — no published rate for ${unpriced.join(', ')}.` : ''
          }`}
        >
          {/* The `≥` rides on the figure itself, as it does for Today. The note
              below explains it, but notes are capped and this must not depend on
              one surviving that cap. */}
          <span className="us-value">
            {unpriced.length > 0 ? `≥ ${formatUsd(spend.total)}` : formatUsd(spend.total)}
          </span>
        </Item>

        <Item
          label="Today"
          title={`${formatUsd(today.total)} across ${today.sessions} session${
            today.sessions === 1 ? '' : 's'
          } active today in this project. Sessions are counted in full, so one that started yesterday makes this an upper bound.`}
        >
          <span className="us-value">{today.hasUnpriced ? `≥ ${formatUsd(today.total)}` : formatUsd(today.total)}</span>
        </Item>

        <Item
          label="Tokens"
          title={`${formatExact(tokens.input)} fresh input · ${formatExact(tokens.output)} output · ${formatExact(
            tokens.cacheRead,
          )} cache read · ${formatExact(tokens.cacheWrite)} cache write. Cache reads and writes are most of the bill; fresh input is only the part of each prompt that was neither cached nor read from cache.`}
          wide
        >
          <span className="us-value">
            in {formatTokens(tokens.input)} · out {formatTokens(tokens.output)}
          </span>
          <span className="us-sub">
            cache {formatTokens(tokens.cacheRead)} read / {formatTokens(tokens.cacheWrite)} write
          </span>
        </Item>

        {session.compactions > 0 ? (
          <Item
            label="Compacted"
            title={`This session was compacted ${session.compactions} time${
              session.compactions === 1 ? '' : 's'
            }. Auto-compaction fires when the window fills; /compact does it on request — the totals do not distinguish them. Context above is measured after the most recent one.`}
          >
            <span className="us-value">×{session.compactions}</span>
          </Item>
        ) : null}

        <PlanSection
          plan={plan}
          now={now}
          canRefresh={canRefreshPlan}
          refreshing={refreshing}
          onRefresh={onRefreshPlan}
        />
      </div>

      {notes.length > 0 ? (
        <p className="us-notes">
          {notes.slice(0, MAX_NOTES).map((note) => (
            <span key={note.text} className="us-note" data-tone={note.tone}>
              {note.text}
            </span>
          ))}
        </p>
      ) : null}
    </div>
  )
}

/* --------------------------------------------------------------- the plan */

const PLAN_UNAVAILABLE =
  'Claude Code reports plan usage only in its own output — there is no file or flag that holds it. Run /usage in the session and it appears here.'

function PlanSection({
  plan,
  now,
  canRefresh,
  refreshing,
  onRefresh,
}: {
  plan: PlanLimitSnapshot | null
  now: number
  canRefresh: boolean
  refreshing: boolean
  onRefresh?: () => void
}) {
  const age = plan?.available ? describeAge(plan.capturedAt, now) : ''
  const stale = plan?.available ? isStale(plan.capturedAt, now) : false

  return (
    <Item
      label="Plan"
      title={
        plan?.available
          ? // `age` is empty when the reading carries no timestamp, and
            // "…output ." would be a dangling sentence.
            (plan.message ?? `Read from Claude Code's own output${age ? ` ${age}` : ''}.`)
          : (plan?.reason ?? PLAN_UNAVAILABLE)
      }
      wide
    >
      {plan?.available && plan.limits.length > 0 ? (
        <>
          {plan.limits.map((limit) => (
            <span key={limit.id} className="us-plan-limit" title={planTitle(limit)}>
              <span className="us-plan-name">{planLabel(limit)}</span>
              <span className="us-value" data-level={levelOfPercent(limit.percent)}>
                {limit.percent === null ? 'near limit' : formatPercent(limit.percent)}
              </span>
            </span>
          ))}
          <span className="us-sub" data-tone={stale ? 'warning' : undefined}>
            {/* Separated from the last chip, or "80% resets Aug 14" reads as
                one phrase. */}
            {`· ${planFootnote(plan, age)}`}
          </span>
        </>
      ) : (
        <span className="us-value us-muted">not available</span>
      )}
      {/* Only rendered when it can actually run: it types `/usage` into the
          session and closes the panel again, exactly as a person would. */}
      {canRefresh && onRefresh ? (
        <button
          type="button"
          className="us-refresh"
          onClick={onRefresh}
          disabled={refreshing}
          title="Types /usage into this session, reads the panel Claude Code draws, then closes it with Esc. Only runs while the session is idle and its prompt is empty."
        >
          {refreshing ? 'Checking…' : 'Check'}
        </button>
      ) : null}
    </Item>
  )
}

/**
 * The line under the limits: when they reset, and how old the reading is.
 *
 * A limit the CLI named without a reset time simply contributes nothing here —
 * "no reset time reported" is noise, and the per-limit tooltip already says it.
 */
function planFootnote(plan: PlanLimitSnapshot, age: string): string {
  const withReset = plan.limits.find((limit) => limit.resetsAt !== null)
  // Limits reset at different times — a session window in hours, a weekly one
  // in days — so an unlabelled reset beside three chips would read as though it
  // covered all of them.
  const resets = withReset?.resetsAt
    ? plan.limits.length > 1
      ? `${planLabel(withReset)} resets ${withReset.resetsAt}`
      : `resets ${withReset.resetsAt}`
    : ''
  return [resets, age ? `read ${age}` : ''].filter(Boolean).join(' · ')
}

/* ------------------------------------------------------------- the strip */

export interface UsageStripProps {
  /** Project folder — the cost watcher is keyed on it. */
  cwd: string | null
  /** A specific transcript. Wins over the project's newest session. */
  transcriptPath?: string
  /**
   * The live PTY session. Plan limits are read from its screen, so without one
   * they are simply not available and the strip says so.
   */
  sessionId?: string
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: UsageBridge
  /** Clock, for tests. */
  now?: number
}

export function UsageStrip({ cwd, transcriptPath, sessionId, bridge, now }: UsageStripProps) {
  const usage = useUsage(cwd, sessionId, bridge)
  const at = now ?? Date.now()

  const session = useMemo(
    () => pickSession(usage.summary, { transcriptPath }),
    [usage.summary, transcriptPath],
  )
  const today = useMemo(() => spendToday(usage.summary, at), [usage.summary, at])

  return (
    <UsageStripView
      session={session}
      today={today}
      plan={usage.plan}
      scanning={usage.summary?.scanning ?? false}
      now={at}
      unwired={usage.unwired}
      canRefreshPlan={usage.canRefreshPlan}
      refreshing={usage.refreshing}
      refreshReason={usage.refreshReason ? refreshFailureMessage(usage.refreshReason) : null}
      onRefreshPlan={usage.refreshPlan}
    />
  )
}
