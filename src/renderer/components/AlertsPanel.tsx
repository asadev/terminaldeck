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
      </div>
      {action ? (
        <button type="button" className="alerts-action" onClick={() => onAction?.(action, alert)}>
          {action.label}
        </button>
      ) : null}
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

export function AlertsPanel({ projectPath, onAction, bridge, refreshMs }: AlertsPanelProps) {
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

  const groups = useMemo(() => (report ? groupAlerts(report.alerts) : []), [report])

  /* A quiet project is the state this panel is in most of the time, and it
     used to be shown twice: a summary line pinned to the top-left corner and a
     second sentence saying the same thing ten viewport-percent below it. When
     there is nothing to list there is nothing to head, so the page is one
     composed empty state and the rescan button moves into it. */
  const quiet = host && report !== null && report.alerts.length === 0 && !error

  return (
    <section className="alerts" aria-label="Project alerts">
      {!quiet && (
        <header className="alerts-head">
          <div className="alerts-headline">
            <p className="alerts-summary" data-worst={report?.worst ?? 'none'}>
              {error ?? summarize(report)}
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
          title={summarize(report)}
          action={{ label: busy ? 'Checking…' : 'Check again', onClick: () => void scan(), busy }}
        >
          Context is healthy, nothing is blocked, and the tools this project uses are installed.
        </PageEmpty>
      ) : (
        groups.map((group) => (
          <section className="alerts-group" key={group.severity} data-severity={group.severity}>
            <h3 className="alerts-group-head">
              {SEVERITY_HEADING[group.severity]}
              <span className="alerts-count">{group.alerts.length}</span>
            </h3>
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
