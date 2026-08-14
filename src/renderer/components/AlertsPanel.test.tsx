import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  AlertRow,
  AlertsPanel,
  createScanGate,
  groupAlerts,
  SEVERITY_HEADING,
  summarize,
  withInsights,
  type Alert,
  type AlertReport,
  type AlertsBridge,
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
  const quiet: AlertsBridge = { projectAlerts: async () => report([]) }

  it('renders a calm empty state, not an error, for a quiet project', () => {
    // Static markup renders before the async scan resolves, so the empty branch
    // is asserted through `summarize` above; here the panel must at least not
    // claim something is wrong.
    const markup = renderToStaticMarkup(
      <AlertsPanel projectPath="/Users/apple/Projects/terminaldeck" bridge={quiet} />,
    )
    expect(markup).toContain('Checking…')
    expect(markup).not.toContain('Nothing needs')
    expect(markup).not.toMatch(/error|failed/i)
  })

  it('explains itself when the bridge is missing', () => {
    const markup = renderToStaticMarkup(<AlertsPanel projectPath="/Users/apple/Projects/terminaldeck" />)
    expect(markup).toContain('not connected to the main process')
  })

  it('labels itself for assistive tech', () => {
    const markup = renderToStaticMarkup(
      <AlertsPanel projectPath="/Users/apple/Projects/terminaldeck" bridge={quiet} />,
    )
    expect(markup).toContain('aria-label="Project alerts"')
  })
})

describe('createScanGate', () => {
  it('lets the newest scan write and silences the one it superseded', () => {
    // Regression: switching project started a second scan while the first was
    // still in flight, and whichever finished last won. A slow project handed
    // its alerts to a different project's panel — naming sessions that were no
    // longer in front of the user.
    const gate = createScanGate()
    const first = gate.begin()
    const second = gate.begin()

    expect(gate.isCurrent(first)).toBe(false)
    expect(gate.isCurrent(second)).toBe(true)

    // The stale one finishing last must still lose.
    gate.end()
    expect(gate.isCurrent(first)).toBe(false)
  })

  it('reports busy until every scan has finished, so refreshes cannot stack', () => {
    // Regression: the 60s interval fired whether or not the previous scan had
    // returned, and each scan reads every transcript in the project.
    const gate = createScanGate()
    expect(gate.isBusy()).toBe(false)

    gate.begin()
    expect(gate.isBusy()).toBe(true)

    gate.begin()
    gate.end()
    // One of the two is still running.
    expect(gate.isBusy()).toBe(true)

    gate.end()
    expect(gate.isBusy()).toBe(false)
  })

  it('never lets a completed scan write after an unmount', () => {
    const gate = createScanGate()
    const token = gate.begin()
    gate.invalidate()
    expect(gate.isCurrent(token)).toBe(false)
  })

  it('does not go negative when end is called more than begin', () => {
    const gate = createScanGate()
    gate.end()
    gate.end()
    expect(gate.isBusy()).toBe(false)
    gate.begin()
    expect(gate.isBusy()).toBe(true)
  })
})

describe('SEVERITY_HEADING', () => {
  it('describes what to do, not what the data is called', () => {
    expect(Object.values(SEVERITY_HEADING)).not.toContain('Critical')
    expect(SEVERITY_HEADING.critical).toBe('Needs you now')
  })
})
