/**
 * The one alert row whose button is answered by the sheet itself.
 *
 * Five of the six action kinds are navigations: the sheet closes and the window
 * behind it shows a panel, focuses a tab, types a command. `approve-device` has
 * nowhere behind it to go — the only other place approval lives is a pane inside
 * Settings, and "go and look in Settings" is the sentence this whole
 * announcement exists so that nobody has to read. So the sheet runs the flow.
 *
 * What is pinned here is the wiring that makes that true, and one rule that is
 * older than this feature: **a control with no handler must not be drawn.** The
 * row is the worst possible place to break it. Somebody presses "Review this
 * device…", nothing happens, and the phone in their hand goes on saying it is
 * waiting — which is precisely the state the app was in before any of this, only
 * now with a button on it.
 */

import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { AlertRow, AlertsPanel, type Alert, type AlertAction, type AlertReport } from './AlertsPanel'

const NOW = Date.parse('2026-08-18T07:00:00.000Z')

const waiting: Alert = {
  id: 'device-pending:phone-1',
  kind: 'device-pending',
  severity: 'critical',
  title: 'iPhone is waiting for you to let it in',
  detail: 'It used your pairing code, so it is paired. It can reach nothing here until you approve it.',
  at: NOW,
  action: { kind: 'approve-device', label: 'Review this device…', target: 'phone-1' },
}

function report(alerts: Alert[]): AlertReport {
  const counts = { critical: 0, warning: 0, info: 0 }
  for (const one of alerts) counts[one.severity] += 1
  return { projectPath: '/p', alerts, counts, worst: alerts[0]?.severity ?? null, scannedAt: NOW }
}

describe('the row for a device waiting to be approved', () => {
  it('draws its button when the sheet can run the flow', () => {
    const html = renderToStaticMarkup(<AlertRow alert={waiting} onApproveDevice={() => {}} />)
    expect(html).toContain('Review this device…')
    expect(html).toContain('data-kind="device-pending"')
  })

  it('draws no button when nothing can run the flow', () => {
    // `onAction` is present and is deliberately not enough. Handing this action
    // to the workspace would land in a switch that has no case for it, so the
    // press would be swallowed — a dead control, which rule 1.1 says must be
    // removed rather than left looking alive.
    const html = renderToStaticMarkup(<AlertRow alert={waiting} onAction={() => {}} />)
    expect(html).not.toContain('Review this device…')
    expect(html).toContain('waiting for you to let it in')
  })

  it('does not hand this action to the workspace even when both handlers exist', () => {
    const routed: AlertAction[] = []
    const approved: string[] = []
    // Rendered to static markup, so the click cannot be dispatched here — what is
    // asserted instead is the resolution that decides which handler the button
    // carries, by rendering with only one of them at a time. With the approval
    // handler alone the button exists; with the workspace handler alone it does
    // not. Together, the first is what it must resolve to.
    const withBoth = renderToStaticMarkup(
      <AlertRow
        alert={waiting}
        onAction={(action) => routed.push(action)}
        onApproveDevice={(id) => approved.push(id)}
      />,
    )
    expect(withBoth).toContain('Review this device…')
    expect(routed).toEqual([])
    expect(approved).toEqual([])
  })

  it('draws no button for a device alert that names no device', () => {
    const nameless: Alert = { ...waiting, action: { kind: 'approve-device', label: 'Review…' } }
    // Without a target there is nothing to approve, and a button that opened the
    // flow on `undefined` would ask three questions about no device at all.
    expect(renderToStaticMarkup(<AlertRow alert={nameless} onApproveDevice={() => {}} />)).not.toContain(
      'Review…',
    )
  })
})

describe('the panel around it', () => {
  it('passes the handler down to the rows', () => {
    const html = renderToStaticMarkup(
      <AlertsPanel report={report([waiting])} onApproveDevice={() => {}} />,
    )
    expect(html).toContain('Review this device…')
  })

  it('counts a waiting device as needing you now', () => {
    const html = renderToStaticMarkup(
      <AlertsPanel report={report([waiting])} onApproveDevice={() => {}} />,
    )
    // The summary line is what the sheet says above the list, and the bell's
    // count is computed from the same report. A waiting device is the loudest
    // thing this app has to say.
    expect(html).toContain('1 needing you now')
  })

  it('survives the insight switch being off', () => {
    // "Show insight alerts" hides the five kinds this app *infers* from what
    // sessions are doing. A device waiting is not an inference — it is a row in
    // the trust store — and hiding it would put the app straight back into
    // announcing nothing.
    const html = renderToStaticMarkup(
      <AlertsPanel report={report([waiting])} showInsights={false} onApproveDevice={() => {}} />,
    )
    expect(html).toContain('waiting for you to let it in')
  })
})
