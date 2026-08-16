import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
} from 'react'
import { Modal } from './Modal'
import {
  useSessionTranscript,
  type Attribution,
  type SessionScope,
  type TranscriptLookup,
} from '../session-transcript'
import './SessionInspector.css'

/**
 * Everything about one session: what it spent, what it called, and how full its
 * context is.
 *
 * The numbers all come from `src/main/session-insights.ts`, which reads the
 * same JSONL transcript the cost panel reads. Nothing is computed here beyond
 * formatting and a couple of view-local sorts — if a figure looks wrong, the
 * bug is in the main process, not in this file.
 */

/* -------------------------------------------------------------------- types */

/**
 * Mirrors of the types in `src/main/session-insights.ts`. Duplicated rather
 * than imported because the renderer tsconfig does not include `src/main` —
 * the same arrangement GitPanel uses for `git.ts`. When the orchestrator lifts
 * these into `src/shared/types.ts` this block goes away.
 */
export interface TokenUsage {
  input: number
  output: number
  cacheWrite5m: number
  cacheWrite1h: number
  cacheRead: number
}

export interface CostBreakdown {
  input: number
  output: number
  cacheWrite: number
  cacheRead: number
  total: number
}

export interface AggregateCost {
  cost: CostBreakdown
  byModel: Record<string, CostBreakdown>
  unpricedModels: string[]
  usedLegacyRate: boolean
}

export interface TimelineEntry {
  index: number
  key: string
  at: number
  endedAt: number
  streamMs: number
  sinceLastMs: number
  model: string
  speed: 'standard' | 'fast'
  usage: TokenUsage
  promptTokens: number
  outputTokens: number
  cost: CostBreakdown | null
  costUsd: number | null
  contextPercent: number | null
  isSidechain: boolean
  stopReason: string | null
  tools: string[]
}

export interface ToolStat {
  name: string
  server: string | null
  calls: number
  failures: number
  timedCalls: number
  totalMs: number
  maxMs: number
  avgMs: number
  share: number
}

export interface ModelStat {
  model: string
  requests: number
  usage: TokenUsage
  promptTokens: number
  outputTokens: number
  cost: CostBreakdown | null
  costUsd: number | null
  share: number
  legacyRate: boolean
}

export interface CompactionMarker {
  at: number
  afterRequest: number
  preTokens: number
  postTokens: number
  reclaimedTokens: number
  trigger: string
  durationMs: number
}

export interface ContextPoint {
  index: number
  at: number
  tokens: number
  percent: number
}

export interface ContextUsage {
  tokens: number
  window: number
  percent: number
  remaining: number
  level: 'ok' | 'warning' | 'critical'
}

export interface BloatWarning {
  kind: 'context-window' | 'pre-context'
  level: 'warning' | 'critical'
  percent: number
  message: string
}

export interface SessionInsights {
  sessionId: string
  transcriptPath: string
  cwd: string
  startedAt: number
  lastActivityAt: number
  durationMs: number
  generatingMs: number
  toolMs: number
  requests: number
  sidechainRequests: number
  timeline: TimelineEntry[]
  omittedRequests: number
  /**
   * Priciest requests across the whole session, most expensive first.
   *
   * Ranked in the main process rather than here: `timeline` is trimmed to the
   * newest few hundred rows, so ranking it locally reported the priciest of
   * what happened to be *visible* — on a long session, never the real answer.
   */
  costliest: TimelineEntry[]
  tools: ToolStat[]
  toolCalls: number
  toolFailures: number
  models: ModelStat[]
  usage: TokenUsage
  cost: AggregateCost
  cacheHitRate: number
  context: ContextUsage | null
  contextSeries: ContextPoint[]
  compactions: CompactionMarker[]
  warnings: BloatWarning[]
  preContextTokens: number
  generatedAt: number
}

/**
 * The preload methods this panel needs. Optional because the bridge is wired by
 * the orchestrator: until it lands, the panel says so instead of throwing.
 */
interface InsightsBridge {
  getSessionInsights?(transcriptPath: string): Promise<unknown>
  getLatestSessionInsights?(cwd: string): Promise<unknown>
}

/* --------------------------------------------------------------- formatting */

/**
 * Mirrors `formatUsd`/`formatTokens` in `src/main/cost.ts` — same reason the
 * types are mirrored, and the reasoning is written out there: two places,
 * because a three-place figure reads as thousands wherever the full stop is the
 * group separator, and a spend under half a cent says `<$0.01` rather than
 * rounding to nothing.
 */
function formatUsd(usd: number): string {
  const abs = Math.abs(usd)
  if (abs === 0) return '$0.00'
  if (abs < 0.005) return usd < 0 ? '-<$0.01' : '<$0.01'
  return `$${usd.toFixed(2)}`
}

/**
 * One tier beyond `cost.ts`: a long session reads 1.5 *billion* prompt tokens
 * once cache hits are counted, and its `M` branch renders that as "1568.73M".
 * Worth fixing upstream — until then this is display-only and cannot drift the
 * arithmetic.
 */
function formatTokens(tokens: number): string {
  const abs = Math.abs(tokens)
  if (abs >= 999_950_000) return `${(tokens / 1_000_000_000).toFixed(2).replace(/\.?0+$/, '')}B`
  if (abs >= 999_950) return `${(tokens / 1_000_000).toFixed(2).replace(/\.?0+$/, '')}M`
  if (abs >= 1000) return `${(tokens / 1000).toFixed(1).replace(/\.0$/, '')}k`
  return String(Math.round(tokens))
}

function formatDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return '—'
  if (ms < 1000) return `${Math.round(ms)}ms`
  const seconds = ms / 1000
  if (seconds < 60) return `${seconds < 10 ? seconds.toFixed(1) : Math.round(seconds)}s`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ${Math.round(seconds % 60)}s`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m`
}

const DAY_MS = 24 * 60 * 60 * 1000

/**
 * Times get a date once the session spans more than a day.
 *
 * A resumed session runs for weeks — the one this was built against covers 17
 * days — and a bare clock makes its compactions look shuffled out of order.
 */
function formatClock(at: number, withDate = false): string {
  if (!at) return '—'
  const date = new Date(at)
  const time = date.toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
  if (!withDate) return time
  return `${date.toLocaleDateString([], { month: 'short', day: 'numeric' })} ${time}`
}

export function formatPercent(percent: number, digits = 1): string {
  if (!Number.isFinite(percent)) return '—'
  return `${percent.toFixed(digits)}%`
}

/**
 * Machine-readable timestamp for a `<time>`, or nothing when there isn't one.
 *
 * Two reasons it is not just `new Date(at).toISOString()`. A line with no
 * usable timestamp arrives as `at: 0` — a case the main module supports and
 * tests — and would publish `1970-01-01T00:00:00.000Z` as fact while the
 * visible text correctly reads "—". And `toISOString()` *throws* on a
 * non-finite value: the insights object crosses the IPC bridge as an unchecked
 * `as SessionInsights` cast, so one bad number would take down the whole
 * dialog rather than one cell.
 */
export function isoOrUndefined(at: number): string | undefined {
  if (!at || !Number.isFinite(at)) return undefined
  try {
    return new Date(at).toISOString()
  } catch {
    return undefined
  }
}

/** Strip the `mcp__server__` prefix so a tool table stays readable. */
function shortToolName(name: string): string {
  return /^mcp__.+?__(.+)$/.exec(name)?.[1] ?? name
}

/**
 * Drop the `claude-` prefix, and translate the two sentinels the main process
 * uses — `<synthetic>` and `unknown` mean nothing to someone reading a table.
 */
function shortModelName(model: string): string {
  if (model === '<synthetic>') return 'local only'
  if (model === 'unknown') return 'unidentified'
  return model.startsWith('claude-') ? model.slice('claude-'.length) : model
}

/** Why a bucket has no price, for the tooltip on its row. */
function modelHint(model: string): string | undefined {
  if (model === '<synthetic>') return 'Interrupts and API errors the CLI wrote locally. Never billed.'
  if (model === 'unknown') return 'Tokens with no model id on the request — the total is a floor.'
  return undefined
}

function levelOf(percent: number): 'ok' | 'warning' | 'critical' {
  if (percent >= 90) return 'critical'
  if (percent >= 70) return 'warning'
  return 'ok'
}

/* ------------------------------------------------------------------- pieces */

function Meter({ percent, level }: { percent: number; level: 'ok' | 'warning' | 'critical' }) {
  return (
    <div className="si-meter" data-level={level}>
      {/* Clamped for the bar only — a 104% prompt still renders as a full bar,
          while the label next to it keeps saying 104%. */}
      <div className="si-meter-fill" style={{ width: `${Math.min(100, Math.max(0, percent))}%` }} />
    </div>
  )
}

function Stat({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="si-stat">
      <span className="si-stat-label">{label}</span>
      <span className="si-stat-value" title={hint}>
        {value}
      </span>
    </div>
  )
}

/**
 * Reduce a long series to something a 600px sparkline can draw.
 *
 * Buckets are reduced by *max*, not by mean: the spikes right before a
 * compaction are the whole point of the chart, and averaging flattens them.
 */
export function downsample(points: ContextPoint[], target: number): ContextPoint[] {
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

/**
 * A readable ceiling for the y-axis, at or above the series peak.
 *
 * The axis used to be pinned to 0–100 because the number being plotted is a
 * percentage *of the context window*, and rescaling it felt like overstating
 * how full the window was. In practice that drew nothing at all: a healthy
 * session peaks around four percent, so all 160 points landed within a pixel
 * of the baseline and the chart was an empty box with a line ruled along the
 * bottom of it — which is what shipped.
 *
 * So the axis scales, and both the tick labels and the caption print the
 * ceiling, because the honesty problem was never the scale — it was a chart
 * that said nothing. The ladder is chosen so that half of every rung is also a
 * clean number, since the middle gridline is labelled too.
 */
const AXIS_LADDER = [1, 2, 3, 4, 5, 6, 8, 10, 20, 30, 40, 50, 60, 80, 100]

export function axisMax(peak: number): number {
  if (!Number.isFinite(peak) || peak <= 0) return 0
  // Headroom, so the peak is a point on the chart rather than a corner of it.
  const wanted = peak * 1.15
  return AXIS_LADDER.find((step) => step >= wanted) ?? 100
}

/**
 * A tick label.
 *
 * Every rung on the ladder halves to something with at most one decimal, which
 * is the whole reason the ladder is the shape it is — the middle gridline is
 * labelled too, and "37.5%" rounded to "38%" on an axis that is not at 38 is a
 * chart lying about its own scale.
 */
export function axisLabel(value: number): string {
  if (!Number.isFinite(value)) return '—'
  const rounded = Math.round(value * 10) / 10
  return `${Number.isInteger(rounded) ? rounded.toFixed(0) : rounded.toFixed(1)}%`
}

/**
 * How the context window filled, request by request.
 *
 * Drawn as an SVG stretched by `preserveAspectRatio="none"` — so the geometry
 * follows the container at any width — with every stroke marked
 * `non-scaling-stroke` so nothing is smeared by that stretch, and every piece
 * of text and every dot rendered as positioned HTML rather than as SVG, which
 * is the other half of not being smeared.
 *
 * The readout lives in the caption rather than in a floating tooltip: a chip
 * following the pointer has to be clamped at both ends of a container this
 * wide, and a line of text that was already there has nowhere to overflow to.
 */
function ContextChart({ series }: { series: ContextPoint[] }) {
  const points = useMemo(() => downsample(series, 160), [series])
  const [hover, setHover] = useState<number | null>(null)
  if (points.length < 2) return null

  const peak = points.reduce((max, point) => (point.percent > max.percent ? point : max), points[0])
  const max = axisMax(peak.percent)

  // Every request reported an empty prompt. There is no chart to draw and no
  // scale to draw it against, so the section says that instead of ruling a
  // line along the floor and calling it a chart.
  if (max <= 0) {
    return (
      <p className="si-empty">No request has reported a prompt size yet.</p>
    )
  }

  const level = levelOf(peak.percent)
  const xOf = (i: number): number => (i / (points.length - 1)) * 100
  // Clamped at the ceiling: a prompt past 100% of the window rides the top edge
  // and the caption keeps saying what it really was.
  const yOf = (percent: number): number => 100 - (Math.min(max, percent) / max) * 100

  const path = points
    .map((point, i) => `${i === 0 ? 'M' : 'L'}${xOf(i).toFixed(3)},${yOf(point.percent).toFixed(3)}`)
    .join(' ')

  const hovered = hover === null ? null : points[hover]
  const ticks = [max, max / 2, 0]

  return (
    <figure
      className="si-chart"
      data-level={level}
      onPointerLeave={() => setHover(null)}
      onPointerMove={(event) => {
        const box = event.currentTarget.querySelector('.si-chart-plot')?.getBoundingClientRect()
        if (!box || box.width === 0) return
        const ratio = (event.clientX - box.left) / box.width
        if (ratio < 0 || ratio > 1) return setHover(null)
        setHover(Math.round(ratio * (points.length - 1)))
      }}
    >
      <div className="si-chart-frame">
        <div className="si-chart-yaxis" aria-hidden="true">
          {ticks.map((tick) => (
            <span key={tick}>{axisLabel(tick)}</span>
          ))}
        </div>

        <div className="si-chart-plot">
          <svg viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
            {ticks.map((tick) => (
              <line
                key={tick}
                className={tick === 0 ? 'si-chart-base' : 'si-chart-rule'}
                x1="0"
                x2="100"
                y1={yOf(tick)}
                y2={yOf(tick)}
                vectorEffect="non-scaling-stroke"
              />
            ))}
            <path className="si-chart-area" d={`${path} L100,100 L0,100 Z`} />
            <path className="si-chart-line" d={path} vectorEffect="non-scaling-stroke" />
            {hover !== null && (
              <line
                className="si-chart-cursor"
                x1={xOf(hover)}
                x2={xOf(hover)}
                y1="0"
                y2="100"
                vectorEffect="non-scaling-stroke"
              />
            )}
          </svg>
          {/* The peak stays marked while the pointer moves, so the reading
              being hovered always has the session's worst case to sit against. */}
          <span
            className="si-chart-dot"
            style={{ left: `${xOf(points.indexOf(peak))}%`, top: `${yOf(peak.percent)}%` }}
            aria-hidden="true"
          />
          {hover !== null && hovered && (
            <span
              className="si-chart-dot si-chart-dot-hover"
              style={{ left: `${xOf(hover)}%`, top: `${yOf(hovered.percent)}%` }}
              aria-hidden="true"
            />
          )}
        </div>

        <span />
        <div className="si-chart-xaxis" aria-hidden="true">
          <span>request {points[0].index}</span>
          <span>request {points[points.length - 1].index}</span>
        </div>
      </div>

      <figcaption>
        {hovered ? (
          <>
            Request {hovered.index} — {formatPercent(hovered.percent)} of the window,{' '}
            {formatTokens(hovered.tokens)} in the prompt.
          </>
        ) : (
          <>
            Context per request across the session — peak {formatPercent(peak.percent)} at request{' '}
            {peak.index}. The axis tops out at {axisLabel(max)} of the window.
          </>
        )}
      </figcaption>
    </figure>
  )
}

/* --------------------------------------------------------------------- tabs */

type TabId = 'timeline' | 'cost' | 'tools' | 'context'

const TABS: ReadonlyArray<{ id: TabId; label: string }> = [
  { id: 'timeline', label: 'Timeline' },
  { id: 'cost', label: 'Cost' },
  { id: 'tools', label: 'Tools' },
  { id: 'context', label: 'Context' },
]

/** Rows added each time the timeline is expanded. */
const TIMELINE_PAGE = 80

export function TimelineTab({ insights }: { insights: SessionInsights }) {
  const [visible, setVisible] = useState(TIMELINE_PAGE)
  const dated = insights.durationMs > DAY_MS

  // A different session starts from the top again.
  useEffect(() => setVisible(TIMELINE_PAGE), [insights.transcriptPath, insights.generatedAt])

  const rows = useMemo(() => insights.timeline.slice(-visible), [insights.timeline, visible])
  const hidden = insights.timeline.length - rows.length

  // Compactions are keyed to the request they follow, so they can be dropped
  // into the run of rows rather than listed somewhere else entirely.
  const compactionAfter = useMemo(() => {
    const map = new Map<number, CompactionMarker[]>()
    for (const marker of insights.compactions) {
      const list = map.get(marker.afterRequest) ?? []
      list.push(marker)
      map.set(marker.afterRequest, list)
    }
    return map
  }, [insights.compactions])

  if (insights.timeline.length === 0) {
    return <p className="si-empty">No API requests in this transcript yet.</p>
  }

  return (
    <div className="si-timeline">
      {(hidden > 0 || insights.omittedRequests > 0) && (
        <div className="si-more">
          {hidden > 0 && (
            <button
              type="button"
              className="si-more-btn"
              onClick={() => setVisible((n) => n + TIMELINE_PAGE)}
            >
              Show {Math.min(TIMELINE_PAGE, hidden)} earlier
            </button>
          )}
          <span>
            Showing requests {rows[0]?.index}–{rows[rows.length - 1]?.index} of {insights.requests}
            {insights.omittedRequests > 0 &&
              `. The first ${insights.omittedRequests} are summarised in the totals but not listed.`}
          </span>
        </div>
      )}

      <ol className="si-rows">
        {rows.map((entry) => (
          <li key={`${entry.key}-${entry.index}`}>
            <article className="si-row" data-sidechain={entry.isSidechain || undefined}>
              <span className="si-row-index">{entry.index}</span>
              <div className="si-row-main">
                <div className="si-row-head">
                  <time dateTime={isoOrUndefined(entry.at)}>{formatClock(entry.at, dated)}</time>
                  <span className="si-chip" title={modelHint(entry.model)}>
                    {shortModelName(entry.model)}
                  </span>
                  {entry.speed === 'fast' && <span className="si-chip si-chip-accent">fast</span>}
                  {entry.isSidechain && <span className="si-chip">sub-agent</span>}
                  {entry.stopReason === 'end_turn' && <span className="si-chip si-chip-quiet">end of turn</span>}
                </div>
                {entry.tools.length > 0 && (
                  <div className="si-row-tools">
                    {entry.tools.map((tool, i) => (
                      <span key={`${tool}-${i}`} className="si-tool-chip" title={tool}>
                        {shortToolName(tool)}
                      </span>
                    ))}
                  </div>
                )}
                <dl className="si-row-facts">
                  <div>
                    <dt>Prompt</dt>
                    <dd>{formatTokens(entry.promptTokens)}</dd>
                  </div>
                  <div>
                    <dt>Output</dt>
                    <dd>{formatTokens(entry.outputTokens)}</dd>
                  </div>
                  <div>
                    <dt>Generated in</dt>
                    <dd title="Span across the request's own transcript lines — a lower bound.">
                      {formatDuration(entry.streamMs)}
                    </dd>
                  </div>
                  <div>
                    <dt>Waited</dt>
                    <dd title="Gap since the previous request finished: tools running, or you thinking.">
                      {formatDuration(entry.sinceLastMs)}
                    </dd>
                  </div>
                </dl>
              </div>
              <div className="si-row-cost">
                <span className="si-row-money">
                  {entry.costUsd === null ? 'unpriced' : formatUsd(entry.costUsd)}
                </span>
                {entry.contextPercent !== null && (
                  <span className="si-row-context" data-level={levelOf(entry.contextPercent)}>
                    {formatPercent(entry.contextPercent)} ctx
                  </span>
                )}
              </div>
            </article>

            {(compactionAfter.get(entry.index) ?? []).map((marker, i) => (
              <p key={`compact-${entry.index}-${i}`} className="si-compaction">
                Compacted ({marker.trigger}) — {formatTokens(marker.preTokens)} down to{' '}
                {formatTokens(marker.postTokens)}, {formatTokens(marker.reclaimedTokens)} reclaimed
                in {formatDuration(marker.durationMs)}.
              </p>
            ))}
          </li>
        ))}
      </ol>
    </div>
  )
}

export function CostTab({ insights }: { insights: SessionInsights }) {
  const { cost, usage } = insights
  const total = cost.cost.total

  const parts = [
    { label: 'Output', value: cost.cost.output, tokens: usage.output },
    { label: 'Cache writes', value: cost.cost.cacheWrite, tokens: usage.cacheWrite5m + usage.cacheWrite1h },
    { label: 'Cache reads', value: cost.cost.cacheRead, tokens: usage.cacheRead },
    { label: 'Fresh input', value: cost.cost.input, tokens: usage.input },
  ].sort((a, b) => b.value - a.value)

  // Ranked over every request by the main process. An older build sorted
  // `insights.timeline` here, which is the newest few hundred rows and not the
  // session — on a 3,000-request session the expensive requests are almost
  // always among the ones trimmed away.
  const priciest = insights.costliest ?? []

  return (
    <div className="si-sections">
      <section>
        <h3>Where the money went</h3>
        <table className="si-table">
          <thead>
            <tr>
              <th scope="col">Line item</th>
              <th scope="col">Tokens</th>
              <th scope="col">Cost</th>
              <th scope="col">Share</th>
            </tr>
          </thead>
          <tbody>
            {parts.map((part) => (
              <tr key={part.label}>
                <th scope="row">{part.label}</th>
                <td className="si-num">{formatTokens(part.tokens)}</td>
                <td className="si-num">{formatUsd(part.value)}</td>
                <td className="si-bar-cell">
                  <Meter percent={total > 0 ? (part.value / total) * 100 : 0} level="ok" />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {/* The rate card moves to the hover. Somebody reading a cost table
            wants the number; the person who wants to know why cache writes
            cost more than cache reads can ask for it. */}
        <p
          className="si-note"
          title="Cache reads are billed at a tenth of input. Cache writes cost 1.25x input at five minutes, 2x at an hour."
        >
          {formatPercent(insights.cacheHitRate * 100)} of the prompt came from cache.
        </p>
      </section>

      <section>
        <h3>By model</h3>
        <table className="si-table">
          <thead>
            <tr>
              <th scope="col">Model</th>
              <th scope="col">Requests</th>
              <th scope="col">Prompt</th>
              <th scope="col">Output</th>
              <th scope="col">Cost</th>
              <th scope="col">Share</th>
            </tr>
          </thead>
          <tbody>
            {insights.models.map((model) => (
              <tr key={model.model}>
                <th scope="row">
                  <span title={modelHint(model.model)}>{shortModelName(model.model)}</span>
                  {model.legacyRate && (
                    <span className="si-chip si-chip-quiet" title="Historical list price — re-verify before quoting it.">
                      legacy rate
                    </span>
                  )}
                </th>
                <td className="si-num">{model.requests}</td>
                <td className="si-num">{formatTokens(model.promptTokens)}</td>
                <td className="si-num">{formatTokens(model.outputTokens)}</td>
                <td className="si-num">
                  {model.costUsd === null ? <span className="si-muted">unpriced</span> : formatUsd(model.costUsd)}
                </td>
                <td className="si-bar-cell">
                  <Meter percent={model.share * 100} level="ok" />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {cost.unpricedModels.length > 0 && (
          <p className="si-note si-warn">
            No published rate for {cost.unpricedModels.join(', ')} — the total above is a floor, not
            the answer.
          </p>
        )}
      </section>

      {priciest.length > 0 && (
        <section>
          <h3>Most expensive requests</h3>
          <ul className="si-list">
            {priciest.map((entry) => (
              <li key={`${entry.key}-${entry.index}`}>
                <span className="si-list-lead">#{entry.index}</span>
                <span className="si-muted">
                  {formatClock(entry.at, insights.durationMs > DAY_MS)}
                </span>
                <span>
                  {formatTokens(entry.promptTokens)} prompt · {formatTokens(entry.outputTokens)} out
                </span>
                <span className="si-list-trail">{formatUsd(entry.costUsd ?? 0)}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  )
}

export function ToolsTab({ insights }: { insights: SessionInsights }) {
  if (insights.tools.length === 0) {
    return <p className="si-empty">This session has not called a tool.</p>
  }

  return (
    <div className="si-sections">
      <section>
        <div className="si-stats">
          <Stat label="Tool calls" value={String(insights.toolCalls)} />
          <Stat
            label="Failures"
            value={`${insights.toolFailures} (${formatPercent(
              insights.toolCalls > 0 ? (insights.toolFailures / insights.toolCalls) * 100 : 0,
            )})`}
          />
          <Stat
            label="Distinct tools"
            value={String(insights.tools.length)}
            hint="Counted by tool name, MCP tools included."
          />
          <Stat
            label="In tools"
            value={formatDuration(insights.toolMs)}
            hint="Summed call-to-result elapsed time."
          />
        </div>

        <table className="si-table">
          <thead>
            <tr>
              <th scope="col">Tool</th>
              <th scope="col">Calls</th>
              <th scope="col">Failed</th>
              <th scope="col">Avg</th>
              <th scope="col">Slowest</th>
              <th scope="col">Share</th>
            </tr>
          </thead>
          <tbody>
            {insights.tools.map((tool) => (
              <tr key={tool.name}>
                <th scope="row">
                  <span title={tool.name}>{shortToolName(tool.name)}</span>
                  {tool.server && <span className="si-chip si-chip-quiet">{tool.server}</span>}
                </th>
                <td className="si-num">{tool.calls}</td>
                <td
                  className="si-num"
                  data-bad={tool.failures > 0 || undefined}
                  title={
                    tool.failures > 0
                      ? `${formatPercent((tool.failures / tool.calls) * 100)} of its calls`
                      : undefined
                  }
                >
                  {tool.failures || '—'}
                </td>
                <td className="si-num">{tool.timedCalls > 0 ? formatDuration(tool.avgMs) : '—'}</td>
                <td className="si-num">{tool.timedCalls > 0 ? formatDuration(tool.maxMs) : '—'}</td>
                <td className="si-bar-cell">
                  <Meter percent={tool.share * 100} level="ok" />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {/* Kept as a caveat, cut to a caveat. A tool that "took" four minutes
            because it sat on a permission prompt is a number somebody will
            otherwise act on. */}
        <p className="si-note">Wall clock, so time spent waiting on you counts.</p>
      </section>
    </div>
  )
}

export function ContextTab({ insights }: { insights: SessionInsights }) {
  const { context } = insights

  return (
    <div className="si-sections">
      <section>
        <h3>Context window</h3>
        {context ? (
          <>
            <div className="si-context-head">
              <span className="si-context-percent" data-level={context.level}>
                {formatPercent(context.percent)}
              </span>
              <span className="si-muted">
                {formatTokens(context.tokens)} of {formatTokens(context.window)} ·{' '}
                {formatTokens(context.remaining)} left
              </span>
            </div>
            <Meter percent={context.percent} level={context.level} />
            {context.percent > 100 && (
              <p className="si-note">
                Over the window — the bar stops at 100%, the number does not.
              </p>
            )}
          </>
        ) : (
          <p className="si-empty">No request has reported a prompt size yet.</p>
        )}
      </section>

      {insights.contextSeries.length > 1 && (
        <section>
          <h3>How it filled</h3>
          <ContextChart series={insights.contextSeries} />
        </section>
      )}

      <section>
        <h3>Fixed prefix</h3>
        <div className="si-context-head">
          <span className="si-context-percent">
            {formatTokens(insights.preContextTokens)}
          </span>
          <span className="si-muted">
            {context && context.window > 0
              ? `${formatPercent((insights.preContextTokens / context.window) * 100)} of the window`
              : 'system prompt, CLAUDE.md and tool schemas'}
          </span>
        </div>
        <p className="si-note" title="Usually CLAUDE.md and MCP tool schemas.">
          Every turn re-pays it, so it is the one number worth trimming.
        </p>
      </section>

      {insights.warnings.length > 0 && (
        <section>
          <h3>Warnings</h3>
          <ul className="si-warnings">
            {insights.warnings.map((warning) => (
              <li key={warning.kind} data-level={warning.level}>
                {warning.message}
              </li>
            ))}
          </ul>
        </section>
      )}

      <section>
        <h3>Compactions</h3>
        {insights.compactions.length === 0 ? (
          <p className="si-empty">Not compacted yet.</p>
        ) : (
          <ul className="si-list">
            {insights.compactions.map((marker, i) => (
              <li key={`${marker.at}-${i}`}>
                <span className="si-list-lead">
                  {formatClock(marker.at, insights.durationMs > DAY_MS)}
                </span>
                <span className="si-muted">{marker.trigger}</span>
                <span>
                  {formatTokens(marker.preTokens)} → {formatTokens(marker.postTokens)}
                </span>
                <span className="si-list-trail">
                  −{formatTokens(marker.reclaimedTokens)} in {formatDuration(marker.durationMs)}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  )
}

/* ---------------------------------------------------------------- container */

interface Props {
  open: boolean
  onClose(): void
  /** Project folder holding the transcripts. */
  cwd: string | null
  /** Inspect one specific transcript, whatever else is in the folder. */
  transcriptPath?: string | null
  /**
   * The session this dialog is about.
   *
   * Without it the dialog is about a *folder*, and it said so by showing that
   * folder's most recently written transcript under the active session's name —
   * which, with a `claude` running in the same folder outside the app, was a
   * stranger's 143 requests and $18.49. See `session-transcript.ts`.
   */
  session?: SessionScope | null
  /** Tab label of the session being inspected, for the dialog heading. */
  sessionTitle?: string
}

/**
 * Name the transcript on screen, not just the tab it was opened from.
 *
 * The app cannot prove which conversation a terminal is driving — see
 * `session-transcript.ts` — so the dialog says which one it read. A number that
 * looks wrong is then traceable to a file instead of being silently attributed
 * to whichever tab happened to be in front.
 */
export function describeSource(
  sessionTitle: string | undefined,
  insights: { sessionId: string; startedAt: number } | null,
  attribution: Attribution | null,
): string | undefined {
  if (!insights) return sessionTitle ? `${sessionTitle} — from its Claude Code transcript` : undefined
  const short = insights.sessionId.slice(0, 8)
  const began = formatClock(insights.startedAt, true)
  const lead =
    attribution === 'resumed'
      ? `continued transcript ${short}`
      : attribution === 'project'
        ? `newest transcript in this folder, ${short}`
        : `transcript ${short}`
  return `${sessionTitle ? `${sessionTitle} — ` : ''}${lead}, started ${began}`
}

type LoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'ready'; insights: SessionInsights }
  | { status: 'empty' }
  | { status: 'error'; message: string }

/** What this dialog should read, given what it has been told to be about. */
export type InsightsTarget =
  | { kind: 'transcript'; path: string }
  | { kind: 'folder'; cwd: string }
  /** The lookup has not settled; read nothing yet. */
  | { kind: 'waiting' }
  | { kind: 'none' }

/**
 * The whole of bug three in one function.
 *
 * A dialog opened *about a session* must never fall back to the folder. "The
 * newest transcript in this folder" is a different question with a different
 * answer — on the run that found this, the answer was a `claude` the app had
 * not started, whose 143 requests and $18.49 were shown under a tab that was
 * eight minutes old and had never been prompted.
 */
export function insightsTarget(
  transcriptPath: string | null | undefined,
  cwd: string | null,
  session: SessionScope | null | undefined,
  lookup: TranscriptLookup,
): InsightsTarget {
  if (transcriptPath) return { kind: 'transcript', path: transcriptPath }
  if (session) {
    if (lookup.status === 'loading') return { kind: 'waiting' }
    if (lookup.status === 'ready') return { kind: 'transcript', path: lookup.choice.path }
    return { kind: 'none' }
  }
  return cwd ? { kind: 'folder', cwd } : { kind: 'none' }
}

export function SessionInspector({
  open,
  onClose,
  cwd,
  transcriptPath,
  session,
  sessionTitle,
}: Props) {
  const [tab, setTab] = useState<TabId>('timeline')
  const [state, setState] = useState<LoadState>({ status: 'idle' })
  /** Bumped to force a re-read of a transcript that is still being appended to. */
  const [nonce, setNonce] = useState(0)

  // Resolved against the session rather than the folder. An explicit path still
  // wins — the alerts panel opens this dialog on one it already knows. Only
  // while open: the lookup retries until a session has a transcript, and a
  // closed dialog polling forever costs a directory listing every few seconds.
  const lookup = useSessionTranscript(open && !transcriptPath ? cwd : null, session ?? null)
  const attribution = lookup.status === 'ready' ? lookup.choice.attribution : null
  const target = insightsTarget(transcriptPath, cwd, session, lookup)
  const targetKind = target.kind
  const targetPath = target.kind === 'transcript' ? target.path : null
  const targetCwd = target.kind === 'folder' ? target.cwd : null

  const load = useCallback(async (): Promise<LoadState> => {
    const bridge = window.deck as unknown as InsightsBridge | undefined
    if (!bridge?.getSessionInsights && !bridge?.getLatestSessionInsights) {
      return { status: 'error', message: 'The insights bridge is not wired up in this build.' }
    }
    try {
      const raw = targetPath
        ? await bridge.getSessionInsights?.(targetPath)
        : // No session to scope by: the caller is asking about a folder, and
          // the folder's newest transcript is the honest answer to that.
          targetCwd
          ? await bridge.getLatestSessionInsights?.(targetCwd)
          : null
      if (!raw) return { status: 'empty' }
      return { status: 'ready', insights: raw as SessionInsights }
    } catch (err) {
      return { status: 'error', message: err instanceof Error ? err.message : String(err) }
    }
  }, [targetPath, targetCwd])

  useEffect(() => {
    if (!open) return
    // Nothing to read until the lookup has settled. Reading the folder's newest
    // in the meantime is exactly the flash of somebody else's numbers this
    // dialog exists to stop showing.
    if (targetKind === 'waiting') {
      setState({ status: 'loading' })
      return
    }
    let cancelled = false
    setState({ status: 'loading' })
    void load().then((next) => {
      // The dialog can close, or the target can change, while a 150 MB
      // transcript is still being read.
      if (!cancelled) setState(next)
    })
    return () => {
      cancelled = true
    }
  }, [open, load, nonce, targetKind])

  /**
   * Arrow keys move the selection *and* the focus, which is the half of the
   * tablist contract that was missing: the roving `tabIndex` below takes the
   * unselected tabs out of the Tab order, so without this the focus would be
   * left sitting on a button that is now `tabindex="-1"` and the next Tab would
   * jump somewhere unrelated. A screen reader also announces nothing at all
   * unless focus actually lands on the newly selected tab.
   */
  const tabRefs = useRef(new Map<TabId, HTMLButtonElement>())

  const onTabKeys = (event: ReactKeyboardEvent<HTMLDivElement>): void => {
    const order = TABS.map((entry) => entry.id)
    const current = order.indexOf(tab)
    let next = -1
    if (event.key === 'ArrowRight') next = (current + 1) % order.length
    else if (event.key === 'ArrowLeft') next = (current - 1 + order.length) % order.length
    else if (event.key === 'Home') next = 0
    else if (event.key === 'End') next = order.length - 1
    if (next < 0) return
    event.preventDefault()
    const target = order[next]
    setTab(target)
    tabRefs.current.get(target)?.focus()
  }

  const insights = state.status === 'ready' ? state.insights : null

  return (
    <Modal
      open={open}
      title="Session inspector"
      description={describeSource(sessionTitle, insights, transcriptPath ? 'session' : attribution)}
      onClose={onClose}
      size="lg"
      footer={
        <>
          <span className="si-footer-note">
            {insights ? `Read ${formatClock(insights.generatedAt)}` : ''}
          </span>
          <button
            type="button"
            className="modal-btn"
            onClick={() => setNonce((n) => n + 1)}
            disabled={state.status === 'loading'}
          >
            Refresh
          </button>
          <button type="button" className="modal-btn primary" onClick={onClose}>
            Done
          </button>
        </>
      }
    >
      <div className="session-inspector">
        {state.status === 'loading' && <p className="si-empty">Reading the transcript…</p>}

        {state.status === 'error' && (
          <p className="si-empty si-warn">Could not read this session: {state.message}</p>
        )}

        {state.status === 'empty' && (
          <p className="si-empty">
            {session
              ? 'No transcript yet — one appears with the session’s first request.'
              : 'No transcript for this folder yet — one appears with a session’s first request.'}
          </p>
        )}

        {insights && (
          <>
            <div className="si-stats si-stats-hero">
              <Stat label="Requests" value={String(insights.requests)} />
              <Stat
                label="Cost"
                value={formatUsd(insights.cost.cost.total)}
                hint={
                  insights.cost.unpricedModels.length > 0
                    ? 'A floor — some models have no published rate.'
                    : undefined
                }
              />
              <Stat
                label="Output"
                value={formatTokens(insights.usage.output)}
                hint={`Output tokens. The prompt side read ${formatTokens(
                  insights.usage.input +
                    insights.usage.cacheRead +
                    insights.usage.cacheWrite5m +
                    insights.usage.cacheWrite1h,
                )} across the session.`}
              />
              <Stat label="Tools" value={String(insights.toolCalls)} />
              <Stat
                label="Context"
                value={insights.context ? formatPercent(insights.context.percent, 0) : '—'}
              />
              <Stat
                label="Elapsed"
                value={formatDuration(insights.durationMs)}
                hint={`${formatDuration(insights.generatingMs)} of it generating.`}
              />
            </div>

            <div className="si-tabs" role="tablist" aria-label="Session detail" onKeyDown={onTabKeys}>
              {TABS.map((entry) => (
                <button
                  key={entry.id}
                  type="button"
                  role="tab"
                  id={`si-tab-${entry.id}`}
                  aria-selected={tab === entry.id}
                  aria-controls={`si-panel-${entry.id}`}
                  className="si-tab"
                  // Roving tabindex: one stop for the whole strip, then arrows
                  // move within it. Four separate Tab stops inside a focus-
                  // trapped dialog is four presses to reach the buttons below.
                  tabIndex={tab === entry.id ? 0 : -1}
                  ref={(node) => {
                    if (node) tabRefs.current.set(entry.id, node)
                    else tabRefs.current.delete(entry.id)
                  }}
                  onClick={() => setTab(entry.id)}
                >
                  {entry.label}
                </button>
              ))}
            </div>

            <div
              className="si-panel"
              role="tabpanel"
              id={`si-panel-${tab}`}
              aria-labelledby={`si-tab-${tab}`}
              tabIndex={0}
            >
              {tab === 'timeline' && <TimelineTab insights={insights} />}
              {tab === 'cost' && <CostTab insights={insights} />}
              {tab === 'tools' && <ToolsTab insights={insights} />}
              {tab === 'context' && <ContextTab insights={insights} />}
            </div>
          </>
        )}
      </div>
    </Modal>
  )
}
