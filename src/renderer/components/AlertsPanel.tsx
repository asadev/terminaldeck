import { useCallback, useEffect, useMemo, useState } from 'react'
import { useEvery } from '../schedule'
import { panelSpec } from '../shell/panels'
import { PageEmpty } from './PageEmpty'
import './AlertsPanel.css'

/* ------------------------------------------------------------------ types -- */

/**
 * Mirrors of the types in `src/main/alerts.ts`, duplicated rather than imported
 * because the renderer tsconfig does not include `src/main`. The same
 * arrangement is used by `ReadinessPanel`; when the orchestrator lifts these
 * into `src/shared/types.ts` this block goes away and the imports point there.
 */
export type AlertSeverity = 'info' | 'warning' | 'critical'

export type AlertKind =
  | 'context-bloat'
  | 'pre-context-bloat'
  | 'session-blocked'
  | 'provider-missing'
  | 'expensive-session'
  | 'dirty-tree'

export interface AlertAction {
  kind: 'open-inspector' | 'focus-session' | 'compact-session' | 'open-git' | 'install-provider'
  label: string
  target?: string
}

export interface Alert {
  id: string
  kind: AlertKind
  severity: AlertSeverity
  title: string
  detail: string
  sessionId?: string
  at: number
  action: AlertAction | null
}

export interface AlertReport {
  projectPath: string
  alerts: Alert[]
  counts: Record<AlertSeverity, number>
  worst: AlertSeverity | null
  scannedAt: number
}

/** The slice of the preload bridge this panel needs. */
export interface AlertsBridge {
  projectAlerts(projectPath: string): Promise<AlertReport>
}

export interface AlertsPanelProps {
  /** Absolute path of the project to check. */
  projectPath: string
  /** Invoked when the user takes an alert's action. */
  onAction?: (action: AlertAction, alert: Alert) => void
  /**
   * General → "Show insight alerts". Off keeps the alerts that describe the
   * project itself and drops the ones this panel infers from what sessions are
   * doing. The switch has existed since the settings window was written and
   * nothing read it, so turning it off changed nothing on this page.
   */
  showInsights?: boolean
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: AlertsBridge
  /** Re-scan interval. 0 disables it. Defaults to 60s. */
  refreshMs?: number
}

/* ---------------------------------------------------------------- helpers -- */

/**
 * Read defensively: alerts are wired into the preload separately, so the panel
 * has to explain itself rather than crash if it mounts first.
 */
function resolveBridge(): AlertsBridge | null {
  // Tests render this to static markup, where there is no window at all.
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<AlertsBridge> }).deck
  if (!host || typeof host.projectAlerts !== 'function') return null
  return host as AlertsBridge
}

export const SEVERITY_ORDER: readonly AlertSeverity[] = ['critical', 'warning', 'info']

/**
 * Headings, not severity names.
 *
 * "Critical / Warning / Info" describes the data; these describe what the user
 * is meant to do with it, which is the only reason a severity is on screen.
 */
export const SEVERITY_HEADING: Record<AlertSeverity, string> = {
  critical: 'Needs you now',
  warning: 'Worth fixing',
  info: 'Worth knowing',
}

export interface AlertGroup {
  severity: AlertSeverity
  alerts: Alert[]
}

/* ------------------------------------------------------------------ gate -- */

/**
 * Latest-wins gate around the panel's async scan.
 *
 * Two things went wrong without it, and both are invisible until they bite:
 *
 *  - **A superseded scan could still write.** Switching project cleared the
 *    report and started a new scan, but the *previous* project's scan was still
 *    in flight; whichever finished last won. A slow project handed its alerts
 *    to a different project's panel — naming sessions that are not in front of
 *    the user — which is exactly what the effect's comment claims it prevents.
 *  - **Refreshes stacked.** The 60-second interval fired regardless of whether
 *    the last scan had finished, and a scan reads every transcript in the
 *    project. On a folder where one scan takes longer than the interval, that
 *    is unbounded pile-up on the main process.
 *
 * Kept as a plain object rather than refs inside the component so it can be
 * tested without a DOM — this project's renderer tests render to static markup
 * and never run an effect.
 */
export interface ScanGate {
  /** Claim the next token. Anything already running is superseded. */
  begin(): number
  /** May the scan holding `token` write what it found? */
  isCurrent(token: number): boolean
  /** Mark the scan finished, whatever its outcome. */
  end(): void
  /** Is any scan still running? The interval skips its tick when one is. */
  isBusy(): boolean
  /** Supersede everything in flight — a project switch, or unmount. */
  invalidate(): void
}

export function createScanGate(): ScanGate {
  let latest = 0
  let running = 0
  return {
    begin() {
      latest += 1
      running += 1
      return latest
    },
    isCurrent(token) {
      return token === latest
    },
    end() {
      running = Math.max(0, running - 1)
    },
    isBusy() {
      return running > 0
    },
    invalidate() {
      latest += 1
    },
  }
}

/**
 * The alert kinds this panel *infers* rather than observes.
 *
 * The distinction the setting draws: "provider missing" and "dirty tree" are
 * facts about the project that are true whether or not anyone is working, and
 * hiding them would hide a broken setup. The four below are read out of what
 * sessions have been doing — a context window filling up, a session blocked on
 * a question, a run that cost more than the rest put together — and those are
 * the ones somebody may not want raised without being asked.
 */
export const INSIGHT_ALERT_KINDS: ReadonlySet<AlertKind> = new Set<AlertKind>([
  'context-bloat',
  'pre-context-bloat',
  'session-blocked',
  'expensive-session',
])

export function isInsightAlert(alert: Alert): boolean {
  return INSIGHT_ALERT_KINDS.has(alert.kind)
}

/**
 * Apply the switch to a report, counts and all.
 *
 * The counts have to be recomputed rather than passed through: the summary line
 * is built from them, and a page listing two alerts under "3 needing you now"
 * is worse than either number on its own.
 */
export function withInsights(report: AlertReport, showInsights: boolean): AlertReport {
  if (showInsights) return report
  const alerts = report.alerts.filter((alert) => !isInsightAlert(alert))
  if (alerts.length === report.alerts.length) return report
  const counts: Record<AlertSeverity, number> = { info: 0, warning: 0, critical: 0 }
  for (const alert of alerts) counts[alert.severity] += 1
  const worst = SEVERITY_ORDER.find((severity) => counts[severity] > 0) ?? null
  return { ...report, alerts, counts, worst }
}

/** Group alerts for a panel with one section per severity. Empty groups are dropped. */
export function groupAlerts(alerts: Alert[]): AlertGroup[] {
  return SEVERITY_ORDER.map((severity) => ({
    severity,
    alerts: alerts.filter((alert) => alert.severity === severity),
  })).filter((group) => group.alerts.length > 0)
}

/**
 * The line under the heading.
 *
 * A quiet project gets a sentence that sounds like an all-clear, not "0 alerts":
 * an empty list is the normal state, and the panel should read as reassurance
 * rather than as something that failed to load.
 */
export function summarize(report: AlertReport | null): string {
  if (!report) return 'Checking…'
  if (report.alerts.length === 0) return 'Nothing needs your attention.'
  const parts: string[] = []
  if (report.counts.critical > 0) parts.push(`${report.counts.critical} needing you now`)
  if (report.counts.warning > 0) parts.push(`${report.counts.warning} worth fixing`)
  if (report.counts.info > 0) parts.push(`${report.counts.info} worth knowing`)
  return parts.join(', ')
}

/* ------------------------------------------------------------ sub-elements -- */

export function AlertRow({
  alert,
  onAction,
}: {
  alert: Alert
  onAction?: (action: AlertAction, alert: Alert) => void
}) {
  const action = alert.action
  return (
    <li className="alerts-item" data-severity={alert.severity} data-kind={alert.kind}>
      <span className="alerts-dot" aria-hidden="true" />
      <div className="alerts-body">
        <p className="alerts-title">{alert.title}</p>
        <p className="alerts-detail">{alert.detail}</p>
        {/* Under the sentence it belongs to, not out at the row's right edge.

            The body fills the row and the detail wraps at its own measure, so a
            right-aligned button ended up 143px clear of the last word it was
            about — pointing at nothing, and further from its own text than from
            the alert above it. Proximity is what says which text a button acts
            on.

            Only when there is a host to act on it. Rule 1.1: an alert's button
            is the whole point of the alert, and one that renders without a
            handler is a control that swallows the click and reports nothing —
            which is exactly how "Open the git panel" spent its life re-running
            the scan and never navigating. */}
        {action && onAction ? (
          <button type="button" className="alerts-action" onClick={() => onAction(action, alert)}>
            {action.label}
          </button>
        ) : null}
      </div>
    </li>
  )
}

/* ------------------------------------------------------------------ panel -- */

/**
 * How often to rescan, and why this one cannot be an event.
 *
 * Most of what this panel reports has a push behind it — a transcript that
 * grew, a working tree that changed — but two of the rules do not, and they are
 * the two worth interrupting for. `BLOCKED_WARNING_MS` and
 * `BLOCKED_CRITICAL_MS` in `src/main/alerts.ts` turn a session that asked a
 * question into an alert after ten minutes and a louder one after forty-five,
 * and a session sitting on an unanswered question is by definition a session
 * that is not doing anything. Nothing happens. No file changes, no process
 * writes, no channel fires — the alert comes into existence purely because time
 * passed, and the only thing that can notice that is a clock.
 *
 * A minute is a tenth of the finest threshold, so the alert is never more than
 * that late. It runs on the shared tick rather than an interval of its own, and
 * the shared tick does not run at all behind a hidden window — an alert nobody
 * is looking at can wait for the moment they look.
 */
const DEFAULT_REFRESH_MS = 60_000

export function AlertsPanel({
  projectPath,
  onAction,
  bridge,
  refreshMs,
  showInsights = true,
}: AlertsPanelProps) {
  const host = useMemo(() => bridge ?? resolveBridge(), [bridge])
  const [report, setReport] = useState<AlertReport | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const gate = useMemo(() => createScanGate(), [])

  const scan = useCallback(async () => {
    if (!host) return
    const token = gate.begin()
    setBusy(true)
    try {
      const next = await host.projectAlerts(projectPath)
      if (!gate.isCurrent(token)) return
      setReport(next)
      setError(null)
    } catch (err) {
      if (!gate.isCurrent(token)) return
      setError(err instanceof Error ? err.message : 'Could not check this project.')
    } finally {
      gate.end()
      // A superseded scan leaves `busy` alone: the one that superseded it is
      // still running, and clearing the flag would re-enable the button.
      if (gate.isCurrent(token)) setBusy(false)
    }
  }, [gate, host, projectPath])

  useEffect(() => {
    // A project switch must not leave the previous project's alerts on screen —
    // they name sessions that are not in front of the user any more. Clearing
    // the state is not enough on its own: the old project's scan is still in
    // flight and will happily write its result over the new project's.
    gate.invalidate()
    setReport(null)
    setError(null)
    void scan()
    return () => gate.invalidate()
  }, [gate, scan])

  const interval = refreshMs ?? DEFAULT_REFRESH_MS
  useEvery(interval > 0 ? interval : null, () => {
    // A scan that outlasts its own period must not have another stacked on top
    // of it — each one reads every transcript in the project.
    if (!gate.isBusy()) void scan()
  })

  /**
   * Filtered here rather than at fetch time: the switch can be flipped while
   * this page is open, and re-reading every transcript in the project to hide
   * four rows would be absurd.
   */
  const shown = useMemo(
    () => (report ? withInsights(report, showInsights) : null),
    [report, showInsights],
  )

  const groups = useMemo(() => (shown ? groupAlerts(shown.alerts) : []), [shown])

  /* A quiet project is the state this panel is in most of the time, and it
     used to be shown twice: a summary line pinned to the top-left corner and a
     second sentence saying the same thing ten viewport-percent below it. When
     there is nothing to list there is nothing to head, so the page is one
     composed empty state and the rescan button moves into it. */
  const quiet = host && shown !== null && shown.alerts.length === 0 && !error

  return (
    <section className="alerts" aria-label="Project alerts">
      {!quiet && (
        <header className="alerts-head">
          <div className="alerts-headline">
            <p className="alerts-summary" data-worst={shown?.worst ?? 'none'}>
              {error ?? summarize(shown)}
            </p>
          </div>
          <button
            type="button"
            className="alerts-rescan"
            onClick={() => void scan()}
            disabled={busy || !host}
          >
            {busy ? 'Checking…' : 'Check again'}
          </button>
        </header>
      )}

      {!host ? (
        <PageEmpty icon={panelSpec('alerts').icon} title="Alerts are not available here">
          Alerts are not connected to the main process yet.
        </PageEmpty>
      ) : quiet ? (
        <PageEmpty
          icon={panelSpec('alerts').icon}
          /* Not `summarize`, which writes a sentence for the header line and
             ends it with a full stop. This slot is a title, and every other
             one in the app is a phrase without one — one treatment includes
             the punctuation. */
          title="Nothing needs your attention"
          action={{ label: busy ? 'Checking…' : 'Check again', onClick: () => void scan(), busy }}
        >
          Context is healthy, nothing is blocked, and the tools this project uses are installed.
        </PageEmpty>
      ) : (
        groups.map((group) => (
          <section className="alerts-group" key={group.severity} data-severity={group.severity}>
            {/* The heading and nothing else.

                It used to carry a count badge, and between it, the summary line
                above ("1 worth knowing") and this heading, the phrase "worth
                knowing" was printed three times inside the top 150px of the
                panel — twice as words and once as a bare digit. The summary
                counts them; the rows underneath *are* them. */}
            {/* The heading is dropped when it is the only one.

                With a single group the summary line above has already said
                "1 worth knowing", and this printed "Worth knowing" fifty pixels
                under it — the same words, stacked, as though the page had two
                titles. A group heading earns its place by telling one group
                from another; with nothing to tell it from, it is a repeat. */}
            {groups.length > 1 && (
              <h3 className="alerts-group-head">{SEVERITY_HEADING[group.severity]}</h3>
            )}
            <ul className="alerts-list">
              {group.alerts.map((alert) => (
                <AlertRow key={alert.id} alert={alert} onAction={onAction} />
              ))}
            </ul>
          </section>
        ))
      )}
    </section>
  )
}

export default AlertsPanel
