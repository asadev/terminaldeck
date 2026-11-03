/**
 * Which alerts the bell has not shown you yet.
 *
 * The dot on the bell in `shell/Sidebar.tsx` is not "how many alerts does this
 * project have" — that number is on screen inside the sheet, and a mark that
 * repeats what is one click away is a mark that is always lit. It is "how many
 * of them have you not been shown", which needs a definition of *shown*, and
 * this file is that definition.
 *
 * ## The rules
 *
 * 1. An alert is **unread until the Alerts sheet has been open while it was in
 *    the report.** Opening the sheet is the only thing that clears it, because
 *    opening the sheet is the only moment the app can honestly say the alert
 *    was put in front of somebody. There is no per-row dismiss to hook into and
 *    there should not be one: five of the six alert kinds describe a condition
 *    that is still true after you have read about it, so a dismiss would either
 *    lie about the state of the project or resurrect itself on the next scan.
 *
 * 2. **Seen-ness is keyed on the alert's id *and* its severity.** `alerts.ts`
 *    promises an id that is stable "across refreshes for the same underlying
 *    condition" — which is exactly what makes a plain id the wrong key here.
 *    `session-blocked:abc` is a warning at ten minutes and a *critical* at
 *    forty-five, under the same id both times. That escalation is a new fact
 *    about the project, arguably the most important one this panel produces,
 *    and keying on the id alone would swallow it silently: you glance at the
 *    sheet at minute eleven and the bell never lights again, however long the
 *    agent sits there. Keying on both re-raises it once, when it gets worse,
 *    and not on every scan in between.
 *
 * 3. **Seen-ness is per project.** The sheet is about the project you have
 *    open, so the bell is too. Reading one project's alerts says nothing about
 *    another's.
 *
 * ## Where it is kept, and why not in the settings file
 *
 * `localStorage`, for the reason `features/state.ts` gives about its own map:
 * the sidebar draws on the first paint, and the settings file arrives one IPC
 * round trip later. A badge that appears a frame after launch is a dot that
 * flickers on every start. This is also window state rather than a preference —
 * nobody would look for it in Settings, and nothing else should read it.
 *
 * It survives a restart deliberately. The alternative — forget on quit — means
 * every launch re-raises the same missing CLI and the same uncommitted tree you
 * looked at yesterday, which is the "always lit" failure by a slower route.
 *
 * ## It cannot grow without bound
 *
 * Two caps, because there are two dimensions to grow in. Each project's entry
 * is replaced wholesale on every write with the keys that are *currently* in
 * the report, so a resolved alert's key is dropped rather than accumulated —
 * an entry is as big as the project's live alert list, which the panel itself
 * keeps to single digits. And the map remembers {@link MAX_REMEMBERED_PROJECTS}
 * projects, newest write last, so a machine that opens hundreds of folders over
 * a year does not carry all of them in a string it parses on every launch.
 *
 * Pure. No storage is touched except through the two functions that name it.
 */

import type { Alert } from './components/AlertsPanel'

/**
 * No product-name prefix, and a version in the name: `localStorage` is already
 * scoped to this renderer's origin, and the product name is allowed in exactly
 * one file, which is not this one. The `v1` is there so a later change to what
 * a key means is a new namespace rather than a set of keys that mean two things.
 */
export const ALERTS_SEEN_KEY = 'alerts.seen.v1'

/**
 * How many projects' seen-sets are remembered.
 *
 * Chosen against how the app is used rather than against a byte budget: the
 * sidebar's project list is the set of folders somebody is working in this
 * week, and thirty-two is comfortably more than that. Past it the oldest write
 * goes, and the cost of being wrong is one bell that lights again for a folder
 * nobody has opened in months.
 */
export const MAX_REMEMBERED_PROJECTS = 32

/** Project path to the alert keys that were on screen the last time it was read. */
export type SeenAlerts = Readonly<Record<string, readonly string[]>>

/**
 * The identity an alert is remembered by. See rule 2 above for the severity.
 *
 * Severity first so the string sorts by urgency if anything ever lists these,
 * and because an id can contain a colon (`context-bloat:abc123`) while a
 * severity cannot — putting the fixed-vocabulary half first keeps the join
 * unambiguous without escaping either side.
 */
export function alertKey(alert: Alert): string {
  return `${alert.severity}:${alert.id}`
}

/**
 * The kinds that stay unread until they stop being true.
 *
 * Rule 1 above — an alert is unread until the sheet has been open while it was
 * in the report — is right for every alert that *describes* something. A context
 * window at 78%, a tree with four uncommitted files, a CLI that is not installed:
 * you read it, you know it, and the app has no business lighting a dot about it
 * again.
 *
 * A device waiting to be approved is not a description, it is a **question
 * addressed to you**, and it has two properties none of the others have. It ends
 * the moment you answer it — approve or deny and the device leaves the pending
 * list, so the alert is gone and the dot goes out on its own. And until then,
 * somebody is standing in front of a device that says it is waiting. Marking it
 * read because the sheet was open once would put the dot out while the question
 * was still open, which is the exact failure this whole surface was built to fix,
 * reintroduced one layer down.
 *
 * So it cannot spam, because it cannot outlive the thing it is about, and there
 * is no state in which it is lit and there is nothing to do.
 */
export const ALWAYS_UNREAD_KINDS: ReadonlySet<string> = new Set(['device-pending'])

/** Does this alert ignore the seen-set entirely? See {@link ALWAYS_UNREAD_KINDS}. */
export function staysUnread(alert: Alert): boolean {
  return ALWAYS_UNREAD_KINDS.has(alert.kind)
}

/**
 * The alerts in `alerts` that have not been shown.
 *
 * A null project is not the same as "nothing to count" any more. It means there
 * is no folder open, and therefore no per-project record to check — but the
 * alerts that are about the *machine* are just as true with no folder open as
 * with one, and they are exactly the ones that do not consult the record. So a
 * null path answers with those and nothing else, which is what lets a device
 * waiting for approval reach the bell on a fresh install, where nobody has
 * opened anything yet and remote access is the first thing they try.
 */
export function unreadAlerts(
  alerts: readonly Alert[],
  seen: SeenAlerts,
  projectPath: string | null,
): Alert[] {
  const known = projectPath === null ? null : new Set(seen[projectPath] ?? [])
  return alerts.filter((alert) => {
    if (staysUnread(alert)) return true
    if (known === null) return false
    return !known.has(alertKey(alert))
  })
}

/** The number on the bell. */
export function unreadCount(
  alerts: readonly Alert[],
  seen: SeenAlerts,
  projectPath: string | null,
): number {
  return unreadAlerts(alerts, seen, projectPath).length
}

/**
 * Record that this project's alerts have been shown.
 *
 * Returns the same object when nothing changed, so a caller can hold this in
 * React state and let object identity decide whether to re-render — the sheet
 * re-scans while it is open, and most of those scans find the same alerts.
 */
export function markSeen(
  seen: SeenAlerts,
  projectPath: string,
  alerts: readonly Alert[],
): SeenAlerts {
  // The always-unread kinds are left out of the record rather than written and
  // then ignored on the way back. A key stored for something no reader will ever
  // consult is a line in a file that means nothing, and the first person to read
  // it will reasonably assume it does.
  const keys = alerts.filter((alert) => !staysUnread(alert)).map(alertKey)
  const previous = seen[projectPath]

  if (keys.length === 0) {
    // Nothing to remember. Dropping the entry rather than storing `[]` keeps
    // the map to projects that actually have something to forget.
    if (previous === undefined) return seen
    const next: Record<string, readonly string[]> = {}
    for (const [path, value] of Object.entries(seen)) if (path !== projectPath) next[path] = value
    return next
  }

  const unchanged =
    previous !== undefined &&
    previous.length === keys.length &&
    keys.every((key, index) => previous[index] === key)
  // The entry is already last when it is unchanged *and* nothing else has been
  // written since, which is the only case that matters for the cap: a project
  // whose alerts keep being re-confirmed is a project being looked at.
  if (unchanged && Object.keys(seen).at(-1) === projectPath) return seen

  // Rebuilt rather than spread, so this project's key lands at the end and
  // insertion order is a usable recency order for the cap below. Object key
  // order is specified for string keys that are not array indices, and a
  // project path is never one.
  const next: Record<string, readonly string[]> = {}
  for (const [path, value] of Object.entries(seen)) if (path !== projectPath) next[path] = value
  next[projectPath] = keys

  const entries = Object.entries(next)
  if (entries.length <= MAX_REMEMBERED_PROJECTS) return next
  return Object.fromEntries(entries.slice(entries.length - MAX_REMEMBERED_PROJECTS))
}

/**
 * Read the map, defensively.
 *
 * Anything that is not the shape this file writes is dropped rather than
 * repaired: the whole value is one badge, and the cost of starting from empty
 * is that a bell lights once. A parse that threw would take the sidebar with
 * it, which is a window that does not draw over a dot that does not matter.
 */
export function readSeen(storage: Storage | null): SeenAlerts {
  if (!storage) return {}
  let raw: string | null = null
  try {
    raw = storage.getItem(ALERTS_SEEN_KEY)
  } catch {
    // Storage can be denied outright — a renderer with a null origin, a policy
    // that blocks it. Denied is the same answer as empty here.
    return {}
  }
  if (!raw) return {}

  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return {}
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return {}

  const out: Record<string, readonly string[]> = {}
  for (const [path, value] of Object.entries(parsed as Record<string, unknown>)) {
    if (!Array.isArray(value)) continue
    const keys = value.filter((key): key is string => typeof key === 'string')
    if (keys.length > 0) out[path] = keys
  }
  return out
}

/** Persist the map. Failure is silent: a badge is not worth an exception. */
export function writeSeen(storage: Storage | null, seen: SeenAlerts): void {
  if (!storage) return
  try {
    storage.setItem(ALERTS_SEEN_KEY, JSON.stringify(seen))
  } catch {
    // Quota, or storage denied. The in-memory map is still correct for this
    // run; all that is lost is the memory across a restart.
  }
}
