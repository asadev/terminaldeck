import { useMemo } from 'react'
import { Modal } from './Modal'
import { PageEmpty } from './PageEmpty'
import './AlertsPanel.css'

/**
 * The bell, on a 24×24 grid at 1.5 stroke like every other glyph in the app.
 *
 * It lives here rather than in `shell/panels.ts` because Alerts is not a panel
 * any more — the rail draws this next to the gear, and this file is what the
 * glyph is *of*. Two places need it and they are this panel's own empty states
 * and that button, so the icon travels with the feature rather than with the
 * list of pages.
 */
export const ALERTS_GLYPH =
  'M12 4.2a5.6 5.6 0 0 0-5.6 5.6c0 3.7-1.8 4.7-1.8 4.7h14.8s-1.8-1-1.8-4.7A5.6 5.6 0 0 0 12 4.2zM10.3 18.5a2 2 0 0 0 3.4 0'

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
  | 'heavy-session'
  | 'loop'
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

/**
 * Everything this panel draws, and none of it fetched here.
 *
 * The scan used to live in this component, and moving it out is what made the
 * bell's count possible: this panel only exists while the sheet is open, so
 * while it owned the scan there was nothing producing a report the rest of the
 * time and nothing the sidebar could count. `alerts-feed.ts` owns it now, one
 * feed per window, and both surfaces read that one report — which is also why
 * the dot and the list can no longer disagree about how many there are.
 */
export interface AlertsPanelProps {
  /** The latest report for the project, or null before the first scan lands. */
  report: AlertReport | null
  /** A scan is running: the button says so and is disabled. */
  busy?: boolean
  /** The last scan's failure, shown in place of the summary line. */
  error?: string | null
  /** Is there a main process to ask at all? False draws the explanation. */
  available?: boolean
  /** "Check again". Absent leaves the panel read-only rather than dead. */
  onRescan?: () => void
  /** Invoked when the user takes an alert's action. */
  onAction?: (action: AlertAction, alert: Alert) => void
  /**
   * General → "Show insight alerts". Off keeps the alerts that describe the
   * project itself and drops the ones this panel infers from what sessions are
   * doing. The switch has existed since the settings window was written and
   * nothing read it, so turning it off changed nothing on this page.
   */
  showInsights?: boolean
}

/* ---------------------------------------------------------------- helpers -- */

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

/**
 * The alert kinds this panel *infers* rather than observes.
 *
 * The distinction the setting draws: "provider missing" and "dirty tree" are
 * facts about the project that are true whether or not anyone is working, and
 * hiding them would hide a broken setup. The five below are read out of what
 * sessions have been doing — a context window filling up, a session blocked on
 * a question, a run that moved more tokens than the rest put together, an agent
 * retrying the same failing tool — and those are the ones somebody may not want
 * raised without being asked.
 *
 * `loop` belongs here and not in the other group, even though it is the most
 * actionable alert in the list. It is an *inference*: `alerts.ts` derives it
 * from tool names and outcomes, with no view of the arguments, so it is a strong
 * hint rather than a fact about the project — and the switch exists precisely so
 * that somebody who does not want inferences raised at them gets none.
 */
export const INSIGHT_ALERT_KINDS: ReadonlySet<AlertKind> = new Set<AlertKind>([
  'context-bloat',
  'pre-context-bloat',
  'session-blocked',
  'heavy-session',
  'loop',
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
    <li
      className="alerts-item"
      data-severity={alert.severity}
      data-kind={alert.kind}
      /*
       * How the copilot's focus overlay says "this alert".
       *
       * On the `<li>` rather than on `.alerts-body`, so the box encloses the
       * severity dot as well as the words. The dot is the only part of the row
       * that carries the severity, and a highlight that framed the sentence and
       * left the dot outside would be pointing at half of what the row says.
       *
       * `alert.id` is the same key the list already renders on, so there is no
       * second identity here to fall out of step with the first.
       */
      data-drive-anchor={`alert:${alert.id}`}
    >
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

export function AlertsPanel({
  report,
  busy = false,
  error = null,
  available = true,
  onRescan,
  onAction,
  showInsights = true,
}: AlertsPanelProps) {
  /**
   * Filtered here rather than at fetch time: the switch can be flipped while
   * this page is open, and re-reading every transcript in the project to hide
   * four rows would be absurd.
   *
   * The sidebar's count applies the same filter to the same report, so the dot
   * and this list are always describing the same set of alerts — which is the
   * property that only holds because there is one feed behind both.
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
  const quiet = available && shown !== null && shown.alerts.length === 0 && !error

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
            onClick={onRescan}
            disabled={busy || !available || !onRescan}
          >
            {busy ? 'Checking…' : 'Check again'}
          </button>
        </header>
      )}

      {!available ? (
        <PageEmpty icon={ALERTS_GLYPH} title="Alerts are not available here">
          Alerts are not connected to the main process yet.
        </PageEmpty>
      ) : quiet ? (
        <PageEmpty
          icon={ALERTS_GLYPH}
          /* Not `summarize`, which writes a sentence for the header line and
             ends it with a full stop. This slot is a title, and every other
             one in the app is a phrase without one — one treatment includes
             the punctuation. */
          title="Nothing needs your attention"
          action={
            onRescan
              ? { label: busy ? 'Checking…' : 'Check again', onClick: onRescan, busy }
              : undefined
          }
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

/* ----------------------------------------------------------------- window -- */

export interface AlertsWindowProps extends AlertsPanelProps {
  open: boolean
  onClose(): void
  /**
   * The project the report is about, or null when nothing is open.
   *
   * The dialog needs this even though it no longer fetches anything: `PanelView`
   * gated every page behind "open a project first" and drew `NeedsProject` in
   * front of the ones that needed one. There is no page any more, so this dialog
   * has to answer the same question itself — the bell is on the rail from the
   * first launch, and pressing it with no folder open must say why it has
   * nothing rather than draw a panel whose empty state reads as an all-clear
   * about a project that is not there.
   */
  projectPath: string | null
}

/**
 * Alerts, as a pop-up.
 *
 * *"And notifications should be a pop-up just like settings, not a full page."*
 * So it is literally the same shell: `Modal`, the same glass, the same scrim,
 * the same Escape and the same focus trap that Settings gets, with the panel
 * that used to fill the window dropped into the body. Writing a second dialog
 * of our own is how the two would have drifted — one of them would grow a
 * different close button, or lose the focus trap, and nobody would notice until
 * somebody tabbed out of it.
 *
 * `lg` rather than Settings' `xl`. The size is not what "just like settings"
 * means — Settings is `xl` because it carries a rail of twelve sections and one
 * of them is the whole remote-access panel, and a list of three or four alerts
 * in a sheet that big would be a wall of empty glass. What has to match is that
 * the workspace stays visible around it and closing it puts you back exactly
 * where you were.
 *
 * Split from `AlertsPanel` for the reason `SettingsWindow` is split from
 * `SettingsPanel`: `Modal` portals into `document.body`, and this project's
 * render tests run with no document at all.
 */
export function AlertsWindow({ open, onClose, projectPath, ...panel }: AlertsWindowProps) {
  return (
    <Modal
      open={open}
      title="Alerts"
      /*
       * No description, for the reason Settings gives at length: the panel's own
       * summary line is the description — "2 needing you now", or "Nothing needs
       * your attention" — and it is the one that is true of what is underneath
       * it. A fixed sentence here would sit between the title and that line and
       * say a third, vaguer version of the same thing.
       */
      onClose={onClose}
      size="lg"
      footer={
        <button type="button" className="modal-btn primary" onClick={onClose}>
          Done
        </button>
      }
    >
      {projectPath === null ? (
        /*
         * No button on this one, deliberately.
         *
         * The page it replaces offered "Open a project", which opens an
         * `NSOpenPanel` — a native window that draws above every pixel the
         * renderer paints, so a dialog underneath one has to step aside for it
         * (`Modal`'s `hidden` prop, and the note there about the New-session
         * panel showing through a folder picker). That is real machinery for a
         * button nobody presses here: you arrive at this dialog by pressing a
         * bell about a project, not by looking for a folder. The sentence says
         * what is missing, and the rail behind the scrim still has the ＋ that
         * opens one.
         */
        <PageEmpty icon={ALERTS_GLYPH} title="No project open">
          Alerts are about the project you have open — what is blocked in it, what is filling up,
          what it is waiting on you for. Open one and this will have something to say.
        </PageEmpty>
      ) : (
        <AlertsPanel {...panel} />
      )}
    </Modal>
  )
}

export default AlertsPanel
