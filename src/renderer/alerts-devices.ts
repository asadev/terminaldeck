/**
 * A device waiting for approval, as an alert.
 *
 * ## The hole this fills
 *
 * v0.4.0 made approval **the** gate: a paired device reaches nothing at all
 * until somebody at this machine has said what it is and what it may open. That
 * is the right shape, and it turned the quietest corner of the app into the
 * most consequential one — because the app then told nobody. A device that had
 * paired appeared in exactly one place, Settings → Remote, and only while that
 * pane was open. No alert, no badge, nothing. So the first thing a new person
 * does with remote access ended in silence, on both ends: a phone saying "waiting
 * to be approved" and a desktop saying nothing at all.
 *
 * ## Why it is raised here and not by the project scan
 *
 * Every other alert in this app is a fact about **a project** — a session
 * blocked in it, its context filling up, its tree uncommitted — and
 * `src/main/alerts.ts` gathers them by reading that project's transcripts and
 * its git state. A device waiting is a fact about **the machine**. It is equally
 * true in every folder, and it is not discoverable from any of the things that
 * scan reads.
 *
 * So it is derived here, in the window, from the roster the remote bridge
 * already answers with — the same `remote:devices` read the settings pane makes,
 * narrowed by the same `toRemoteDevices`. One read of one list, two surfaces, no
 * second definition of what "pending" means. `AlertKind` in `src/main/alerts.ts`
 * still carries the kind, so the vocabulary stays in one file and the panel's
 * mirror of it stays honest; what that file does not carry is a *rule* it has no
 * way to evaluate.
 *
 * ## Pure
 *
 * Takes devices and a clock, returns alerts. The fetching and the merging live
 * in `alerts-feed.ts`; everything here can be pinned without a bridge, a DOM or
 * a timer.
 */

import type { Alert, AlertReport, AlertSeverity } from './components/AlertsPanel'
import type { RemoteDevice } from './remote/RemoteSection'

/**
 * The prefix every one of these alerts is identified by.
 *
 * Exported because two other files need to recognise one without re-deriving
 * it: the feed, to know which alerts it owns and may replace on every read, and
 * the panel, to know which row opens the approval flow instead of calling the
 * action handler. A string built in three places is a string that gets
 * mistyped in one of them.
 */
export const DEVICE_ALERT_PREFIX = 'device-pending:'

/** The device id an alert of this kind is about, or null if it is not one. */
export function deviceIdOfAlert(alert: Alert): string | null {
  if (alert.kind !== 'device-pending') return null
  const target = alert.action?.target
  if (typeof target === 'string' && target !== '') return target
  // The id is in two places on purpose — the action targets it and the alert id
  // embeds it — because the id has to be stable for `alerts-unread.ts` whether
  // or not the alert ends up carrying an action. Falling back to it means a row
  // is still identifiable if the action is ever dropped.
  return alert.id.startsWith(DEVICE_ALERT_PREFIX)
    ? alert.id.slice(DEVICE_ALERT_PREFIX.length)
    : null
}

/**
 * One alert per device waiting to be let in.
 *
 * Per device rather than one summary row saying "3 devices are waiting", and
 * the reason is what pressing it does: each device is a separate decision, made
 * against a fingerprint that is on that device's screen and no other. A row that
 * collapsed three of them would have to either pick one to open — approving one
 * device from a button that named three — or lead somewhere that asks again,
 * which is the "go and look in Settings" failure this exists to remove.
 *
 * `severity` is `critical` for all of them, which reads as *Needs you now* in
 * the panel, and that is the honest reading: somebody is standing in front of a
 * device that has told them it is waiting, and until this is answered they can
 * do nothing at all. It is also, deliberately, the only alert in the app that is
 * critical from the instant it appears rather than after a threshold — there is
 * no such thing as a device that has been waiting for a *short enough* time to
 * be worth mentioning quietly.
 */
export function pendingDeviceAlerts(devices: readonly RemoteDevice[], now: number): Alert[] {
  return devices
    .filter((device) => device.state === 'pending')
    .map((device) => ({
      id: `${DEVICE_ALERT_PREFIX}${device.id}`,
      kind: 'device-pending' as const,
      severity: 'critical' as AlertSeverity,
      title: `${device.name} is waiting for you to let it in`,
      /*
       * One sentence, and it is the one that must not be dropped.
       *
       * Somebody who does not know that approval is a hard gate reads "waiting"
       * as a formality, leaves it, and then reports that remote access does not
       * work — which is what happened. Saying that it can reach *nothing* until
       * this is answered turns a notice into a reason, and the three nouns after
       * the colon are what stop "nothing" reading as hedging.
       *
       * What was here first also explained what the flow would ask — the
       * fingerprint, the kind, the folders — and it ran to three lines, twice
       * over with two devices waiting. The button says the flow asks something,
       * and the flow then asks it. A notice that rehearses the screen behind it
       * is the explanatory scaffolding he took out of the copilot setup, and it
       * comes back a sentence at a time.
       */
      detail:
        `It used your pairing code, so it is paired — but it can reach nothing here until you approve it: not a folder, not a session, not a port.`,
      // The moment it paired, not the moment this was noticed. `alerts.ts` states
      // the rule for every alert — "epoch ms of the evidence, not of the scan" —
      // and here it is also what sorts two devices waiting into the order they
      // arrived in.
      at: device.addedAt ?? now,
      action: {
        kind: 'approve-device' as const,
        /*
         * Not "Approve". The button opens the flow; it does not approve
         * anything, and a button labelled with the outcome would be an invitation
         * to press it without reading — which is precisely the reflex-yes this
         * gate exists to prevent. The ellipsis is the app's own convention for a
         * control that asks something before it acts.
         */
        label: 'Review this device…',
        target: device.id,
      },
    }))
}

/**
 * Fold machine-wide alerts into a project report.
 *
 * Counts and `worst` are recomputed rather than incremented, for the reason
 * `withInsights` gives about the same numbers: the summary line is built from
 * them, and a panel listing four rows under "3 needing you now" is worse than
 * either number alone. Sorting matches `deriveAlerts` — severity first, newest
 * first inside a severity — so a merged report is indistinguishable from one the
 * main process could have produced, which is what lets every surface downstream
 * carry on treating it as one thing.
 *
 * Returns the same object when there is nothing to add, so the feed's state does
 * not change identity on every scan of a machine with no device waiting — which
 * is nearly every scan on nearly every machine.
 */
export function mergeAlerts(report: AlertReport, extra: readonly Alert[]): AlertReport {
  if (extra.length === 0) return report
  const alerts = [...report.alerts, ...extra].sort(
    (a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity] || b.at - a.at,
  )
  const counts: Record<AlertSeverity, number> = { critical: 0, warning: 0, info: 0 }
  for (const alert of alerts) counts[alert.severity] += 1
  return {
    ...report,
    alerts,
    counts,
    worst: alerts[0]?.severity ?? null,
  }
}

/**
 * A report made of machine-wide alerts alone.
 *
 * For the state a fresh install spends its first minutes in: nothing open, and
 * therefore no project scan to fold these into. Without this the surface goes
 * quiet exactly when it matters most — somebody who has just installed the app
 * and is pairing their phone before they have opened a folder is the *first*
 * person this announcement was written for, and they would have been the one
 * person it did not reach.
 *
 * `projectPath` is carried through rather than invented, empty string included,
 * so the report says which folder it is about — or says, honestly, that it is
 * about none.
 */
export function machineReport(
  alerts: readonly Alert[],
  projectPath: string | null,
  now: number,
): AlertReport {
  const counts: Record<AlertSeverity, number> = { critical: 0, warning: 0, info: 0 }
  for (const alert of alerts) counts[alert.severity] += 1
  return {
    projectPath: projectPath ?? '',
    alerts: [...alerts],
    counts,
    worst: alerts[0]?.severity ?? null,
    scannedAt: now,
  }
}

/** Mirrors the order `deriveAlerts` sorts by in `src/main/alerts.ts`. */
const SEVERITY_RANK: Record<AlertSeverity, number> = { critical: 0, warning: 1, info: 2 }
