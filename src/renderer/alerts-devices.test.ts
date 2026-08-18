/**
 * A device waiting for approval, as an alert.
 *
 * The behaviour these pin is the announcement itself: that a paired device
 * produces exactly one alert, that it is the loudest severity the panel has,
 * that it names something the sheet can act on, and that folding it into a
 * project's report leaves that report shaped exactly as the main process would
 * have shaped it. Everything downstream — the count on the bell, the summary
 * line, the "have you been shown this" record — is computed from that one list,
 * so a merge that got the counts or the order wrong would be wrong in three
 * places at once.
 */

import { describe, expect, it } from 'vitest'
import {
  DEVICE_ALERT_PREFIX,
  deviceIdOfAlert,
  machineReport,
  mergeAlerts,
  pendingDeviceAlerts,
} from './alerts-devices'
import type { Alert, AlertReport } from './components/AlertsPanel'
import type { RemoteDevice } from './remote/RemoteSection'

const NOW = Date.parse('2026-08-18T07:00:00.000Z')

function device(overrides: Partial<RemoteDevice> & { id: string }): RemoteDevice {
  return {
    name: 'iPhone',
    state: 'pending',
    addedAt: NOW - 30_000,
    lastSeenAt: null,
    fingerprint: 'ab12 cd34 ef56 7890 abcd ef12',
    ...overrides,
  }
}

function report(alerts: Alert[]): AlertReport {
  const counts = { critical: 0, warning: 0, info: 0 }
  for (const one of alerts) counts[one.severity] += 1
  return {
    projectPath: '/Users/apple/Projects/terminaldeck',
    alerts,
    counts,
    worst: alerts[0]?.severity ?? null,
    scannedAt: NOW,
  }
}

describe('a device waiting for approval becomes an alert', () => {
  it('raises one per waiting device and none for the rest', () => {
    const alerts = pendingDeviceAlerts(
      [
        device({ id: 'a', name: 'iPhone' }),
        device({ id: 'b', name: 'Old iPad', state: 'approved' }),
        device({ id: 'c', name: 'Someone else', state: 'revoked' }),
        device({ id: 'd', name: 'Work laptop' }),
      ],
      NOW,
    )
    expect(alerts.map((one) => one.id)).toEqual([
      `${DEVICE_ALERT_PREFIX}a`,
      `${DEVICE_ALERT_PREFIX}d`,
    ])
  })

  it('is critical from the moment it appears', () => {
    // Not after a threshold, unlike every other alert in the app: somebody is
    // standing in front of a device that says it is waiting, and there is no
    // amount of time for which that is worth mentioning quietly.
    const [alert] = pendingDeviceAlerts([device({ id: 'a' })], NOW)
    expect(alert?.severity).toBe('critical')
  })

  it('carries an action that names the device', () => {
    const [alert] = pendingDeviceAlerts([device({ id: 'phone-1' })], NOW)
    // The action is the whole point. An alert about a waiting device with
    // nothing to press is the "go and look in Settings" failure written as a
    // notification.
    expect(alert?.action).toMatchObject({ kind: 'approve-device', target: 'phone-1' })
    expect(deviceIdOfAlert(alert as Alert)).toBe('phone-1')
  })

  it('says that nothing is reachable, because that is the part people miss', () => {
    const [alert] = pendingDeviceAlerts([device({ id: 'a', name: 'iPhone' })], NOW)
    expect(alert?.title).toContain('iPhone')
    // Somebody who does not know approval is a hard gate reads "waiting" as a
    // formality, leaves it, and reports that remote access does not work.
    expect(alert?.detail).toMatch(/can reach nothing/i)
  })

  it('is stamped with the moment it paired, not the moment it was noticed', () => {
    const [alert] = pendingDeviceAlerts([device({ id: 'a', addedAt: NOW - 600_000 })], NOW)
    expect(alert?.at).toBe(NOW - 600_000)
    // And falls back to now for a row with no readable timestamp, rather than
    // sorting to the beginning of time.
    const [undated] = pendingDeviceAlerts([device({ id: 'b', addedAt: null })], NOW)
    expect(undated?.at).toBe(NOW)
  })

  it('answers nothing for an alert of another kind', () => {
    const other: Alert = {
      id: 'dirty-tree:x',
      kind: 'dirty-tree',
      severity: 'info',
      title: 'Uncommitted work',
      detail: 'Four files.',
      at: NOW,
      action: null,
    }
    expect(deviceIdOfAlert(other)).toBeNull()
  })
})

describe('merging it into a project report', () => {
  const quiet = report([])

  it('leaves the report untouched when nothing is waiting', () => {
    // Identity, not equality: the merged report is what the workspace holds in
    // state, and a new object on every scan would re-run the seen-marking effect
    // and rewrite localStorage for nothing.
    expect(mergeAlerts(quiet, [])).toBe(quiet)
  })

  it('recomputes the counts and the worst severity', () => {
    const merged = mergeAlerts(
      report([
        {
          id: 'dirty-tree:x',
          kind: 'dirty-tree',
          severity: 'info',
          title: 'Uncommitted work',
          detail: 'Four files.',
          at: NOW,
          action: null,
        },
      ]),
      pendingDeviceAlerts([device({ id: 'a' })], NOW),
    )
    expect(merged.counts).toEqual({ critical: 1, warning: 0, info: 1 })
    // The summary line and the sheet's heading are both built from `worst`. A
    // report listing a critical alert under "1 worth knowing" would be worse
    // than either number on its own.
    expect(merged.worst).toBe('critical')
  })

  it('sorts the way the main process sorts', () => {
    const older = pendingDeviceAlerts([device({ id: 'old', addedAt: NOW - 900_000 })], NOW)
    const newer = pendingDeviceAlerts([device({ id: 'new', addedAt: NOW - 10_000 })], NOW)
    const merged = mergeAlerts(
      report([
        {
          id: 'session-blocked:x',
          kind: 'session-blocked',
          severity: 'warning',
          title: 'Blocked',
          detail: 'Waiting on an answer.',
          at: NOW,
          action: null,
        },
      ]),
      [...older, ...newer],
    )
    // Severity first, newest first inside a severity — so the two devices lead,
    // most recent pairing at the top, and the warning follows.
    expect(merged.alerts.map((one) => one.id)).toEqual([
      `${DEVICE_ALERT_PREFIX}new`,
      `${DEVICE_ALERT_PREFIX}old`,
      'session-blocked:x',
    ])
  })

  it('keeps the project path it was given', () => {
    // The alert is about the machine; the report is still about the folder. A
    // merge that rewrote the path would make the workspace file these alerts
    // under a project that is not open.
    const merged = mergeAlerts(quiet, pendingDeviceAlerts([device({ id: 'a' })], NOW))
    expect(merged.projectPath).toBe('/Users/apple/Projects/terminaldeck')
  })
})

describe('with no project open at all', () => {
  it('still builds a report, because that is where a first pairing happens', () => {
    const alerts = pendingDeviceAlerts([device({ id: 'a' })], NOW)
    const built = machineReport(alerts, null, NOW)
    expect(built.alerts).toHaveLength(1)
    expect(built.counts).toEqual({ critical: 1, warning: 0, info: 0 })
    expect(built.worst).toBe('critical')
    // Honest about what it is about: no folder, rather than a folder it invented.
    expect(built.projectPath).toBe('')
  })

  it('carries the folder through when there is one', () => {
    // The other state that reaches this: a project is open and its first scan
    // has not landed yet. The device must not wait for a transcript read.
    const built = machineReport(pendingDeviceAlerts([device({ id: 'a' })], NOW), '/p', NOW)
    expect(built.projectPath).toBe('/p')
  })
})
