import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  AlertRow,
  AlertsPanel,
  groupAlerts,
  SEVERITY_HEADING,
  summarize,
  withInsights,
  type Alert,
  type AlertReport,
} from './AlertsPanel'

/**
 * No DOM environment in this project's test setup, so these render to static
 * markup. The invariant worth protecting here is the quiet one: an empty report
 * must render as reassurance, not as a panel that looks like it failed.
 */

const NOW = Date.parse('2026-08-12T12:00:00.000Z')

function alert(overrides: Partial<Alert> & { id: string }): Alert {
  return {
    kind: 'context-bloat',
    severity: 'warning',
    title: 'Context 78% full',
    detail: 'Session abc12345 is holding a lot of window.',
    at: NOW,
    action: null,
    ...overrides,
  }
}

function report(alerts: Alert[]): AlertReport {
  const counts = { critical: 0, warning: 0, info: 0 }
  for (const item of alerts) counts[item.severity] += 1
  return {
    projectPath: '/Users/apple/Projects/terminaldeck',
    alerts,
    counts,
    worst: alerts[0]?.severity ?? null,
    scannedAt: NOW,
  }
}

describe('withInsights', () => {
  const report = (...alerts: Alert[]): AlertReport => ({
    projectPath: '/p',
    alerts,
    counts: {
      info: alerts.filter((a) => a.severity === 'info').length,
      warning: alerts.filter((a) => a.severity === 'warning').length,
      critical: alerts.filter((a) => a.severity === 'critical').length,
    },
    worst: alerts.some((a) => a.severity === 'critical')
      ? 'critical'
      : alerts.some((a) => a.severity === 'warning')
        ? 'warning'
        : alerts.length > 0
          ? 'info'
          : null,
    scannedAt: 0,
  })

  const inferred = alert({ id: 'a', kind: 'context-bloat', severity: 'warning' })
  const structural = alert({ id: 'b', kind: 'provider-missing', severity: 'critical' })

  it('is the identity when insights are on', () => {
    const full = report(inferred, structural)
    expect(withInsights(full, true)).toBe(full)
  })

  it('drops what it inferred and keeps what it observed', () => {
    // A missing provider is a fact about the machine that is true whether or
    // not anyone is working; hiding it would hide a broken setup.
    const filtered = withInsights(report(inferred, structural), false)
    expect(filtered.alerts.map((a) => a.id)).toEqual(['b'])
  })

  it('recomputes the counts and the worst severity', () => {
    // The summary line is built from these. Two alerts under "3 needing you
    // now" is worse than either number alone.
    const filtered = withInsights(report(inferred, structural), false)
    expect(filtered.counts).toEqual({ info: 0, warning: 0, critical: 1 })
    expect(filtered.worst).toBe('critical')

    const nothingLeft = withInsights(report(inferred), false)
    expect(nothingLeft.alerts).toEqual([])
    expect(nothingLeft.worst).toBeNull()
    expect(summarize(nothingLeft)).toBe('Nothing needs your attention.')
  })

  it('returns the same object when it changed nothing', () => {
    const only = report(structural)
    expect(withInsights(only, false)).toBe(only)
  })
})

describe('groupAlerts', () => {
  it('orders the sections critical, warning, info', () => {
    const groups = groupAlerts([
      alert({ id: 'a', severity: 'info' }),
      alert({ id: 'b', severity: 'critical' }),
      alert({ id: 'c', severity: 'warning' }),
    ])
    expect(groups.map((group) => group.severity)).toEqual(['critical', 'warning', 'info'])
  })

  it('drops severities with nothing in them', () => {
    const groups = groupAlerts([alert({ id: 'a', severity: 'info' })])
    expect(groups).toHaveLength(1)
    expect(groups[0].severity).toBe('info')
  })

  it('returns nothing for a quiet project', () => {
    expect(groupAlerts([])).toEqual([])
  })
})

describe('summarize', () => {
  it('reads as an all-clear when there is nothing to say', () => {
    const line = summarize(report([]))
    expect(line).toBe('Nothing needs your attention.')
    // Explicitly not "0 alerts" — an empty list is the normal state.
    expect(line).not.toMatch(/\b0\b/)
  })

  it('counts each severity in the user\'s language', () => {
    const line = summarize(
      report([
        alert({ id: 'a', severity: 'critical' }),
        alert({ id: 'b', severity: 'warning' }),
        alert({ id: 'c', severity: 'info' }),
      ]),
    )
    expect(line).toBe('1 needing you now, 1 worth fixing, 1 worth knowing')
  })

  it('says it is still checking before the first scan lands', () => {
    expect(summarize(null)).toBe('Checking…')
  })
})

describe('AlertRow', () => {
  it('carries the severity and kind as data attributes for the stylesheet', () => {
    const markup = renderToStaticMarkup(
      <AlertRow alert={alert({ id: 'a', severity: 'critical', kind: 'session-blocked' })} />,
    )
    expect(markup).toContain('data-severity="critical"')
    expect(markup).toContain('data-kind="session-blocked"')
  })

  it('renders an action button only when the alert has one and a host to run it', () => {
    const withAction = alert({
      id: 'a',
      action: { kind: 'compact-session' as const, label: 'Compact this session', target: 's1' },
    })

    expect(renderToStaticMarkup(<AlertRow alert={alert({ id: 'a' })} />)).not.toContain('<button')

    // No host, no button. An alert's action is the entire point of the alert,
    // and one rendered without a handler is a control that eats the click —
    // which is what "Open the git panel" did for its whole life, right down to
    // re-running the scan behind it so it looked like something had happened.
    expect(renderToStaticMarkup(<AlertRow alert={withAction} />)).not.toContain('<button')

    expect(
      renderToStaticMarkup(<AlertRow alert={withAction} onAction={() => {}} />),
    ).toContain('Compact this session')
  })

  it('escapes a detail string rather than trusting it as markup', () => {
    const markup = renderToStaticMarkup(
      <AlertRow alert={alert({ id: 'a', detail: 'run <b>npm test</b>' })} />,
    )
    expect(markup).toContain('&lt;b&gt;')
  })
})

describe('AlertsPanel', () => {
  it('says it is still checking before the first report arrives', () => {
    // `report: null` is the state between the sheet opening and the feed's
    // first scan landing. It must not read as an all-clear — the difference
    // between "nothing is wrong" and "nobody has looked yet" is the whole
    // value of the panel.
    const markup = renderToStaticMarkup(<AlertsPanel report={null} onRescan={() => {}} />)
    expect(markup).toContain('Checking\u2026')
    expect(markup).not.toContain('Nothing needs')
    expect(markup).not.toMatch(/error|failed/i)
  })

  it('renders a calm empty state, not an error, for a quiet project', () => {
    const markup = renderToStaticMarkup(<AlertsPanel report={report([])} onRescan={() => {}} />)
    expect(markup).toContain('Nothing needs your attention')
    expect(markup).not.toMatch(/error|failed/i)
  })

  it('explains itself when there is no main process to ask', () => {
    const markup = renderToStaticMarkup(<AlertsPanel report={null} available={false} />)
    expect(markup).toContain('not connected to the main process')
  })

  it('labels itself for assistive tech', () => {
    const markup = renderToStaticMarkup(<AlertsPanel report={report([])} onRescan={() => {}} />)
    expect(markup).toContain('aria-label="Project alerts"')
  })

  /**
   * The regression this whole change exists to prevent, stated as a render.
   *
   * The panel fetched for itself until 2026-08-17, which meant nothing produced
   * a report while the sheet was shut and the bell's `alertCount` could never
   * be fed. A `bridge` or `projectPath` prop coming back is that design coming
   * back, so the props are asserted absent rather than merely unused.
   */
  it('fetches nothing itself \u2014 the report is handed to it', () => {
    const source = readFileSync(join(__dirname, 'AlertsPanel.tsx'), 'utf8')
    expect(source, 'the panel must not call the bridge').not.toContain('projectAlerts')
    expect(source, 'no scan means no gate of its own').not.toContain('createScanGate')
    expect(source, 'and no clock').not.toContain('useEvery')
  })

  it('draws the button as dead rather than pretending, with no way to rescan', () => {
    // Rule 1.1 in this repo: a control that swallows a click and reports
    // nothing is worse than no control. Without `onRescan` there is nothing to
    // run, so the button says so by being disabled.
    const markup = renderToStaticMarkup(<AlertsPanel report={report([alert({ id: 'a' })])} />)
    expect(markup).toContain('disabled')
  })
})

describe('SEVERITY_HEADING', () => {
  it('describes what to do, not what the data is called', () => {
    expect(Object.values(SEVERITY_HEADING)).not.toContain('Critical')
    expect(SEVERITY_HEADING.critical).toBe('Needs you now')
  })
})
