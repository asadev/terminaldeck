/**
 * Readiness rows somebody has put away, and the door back.
 *
 * ## Why this exists
 *
 * From the recorded review of 2026-08-17, about AI readiness:
 *
 *   > *"Every not-ready item needs an action button that actually does it, or a
 *   > way to dismiss it. They should not see something they cannot do something
 *   > about it."*
 *
 * Several findings genuinely have no button, and no amount of engineering gives
 * them one: nobody can write your README for you, and a working tree is dirty
 * because you are working. A row like that with no way to put it away is a
 * screen that scolds a person for something they have already decided about,
 * every time they open it. So it can be put away.
 *
 * ## Two rules that keep dismissal honest
 *
 * **It hides a row; it does not change the score.** The weighting still counts
 * a dismissed check exactly as it did before, and the panel says so under the
 * number. A dismissal that lifted the score would let anybody click their way to
 * a hundred, which is the fake control this whole pass is about removing.
 *
 * **It is never a one-way door.** His words, about the close-session
 * confirmation in the same review: *"'Don't ask again' is a one-way door — once
 * ticked there is no way to turn it back on. That has to exist."* Everything put
 * away here is counted on screen and can be brought back, one row or all of
 * them.
 *
 * ## Why `localStorage`
 *
 * The same trade `features/state.ts` sets out at length: this is window chrome
 * rather than a setting, the panel needs the answer on its first paint, and the
 * settings file arrives an IPC round trip later. A row that appears and then
 * vanishes a frame after the panel opens is worse than one that was never drawn.
 *
 * The cost is that this is per-machine and does not travel with the project,
 * which is the right shape anyway — "I know, leave me alone" is a fact about a
 * person, not about a repository.
 */

/**
 * Where the map lives. No product-name prefix: `localStorage` is already scoped
 * to this renderer's origin, and the product name is allowed in exactly one file
 * in this repo, which is not this one.
 */
export const DISMISSED_KEY = 'readiness.dismissed.v1'

/**
 * Project path to the check ids put away for it.
 *
 * Keyed by the absolute path rather than by a project id because that is what
 * the panel is handed and the only thing it knows; two different folders with
 * the same name must not share a dismissal.
 */
export type DismissedMap = Readonly<Record<string, readonly string[]>>

/**
 * The key machine-wide rows are filed under.
 *
 * A stale agent CLI is not a property of any project — it is the same fact in
 * every folder on the computer — so it cannot be keyed by a project path
 * without appearing again the moment you look at a different one. The `*` is
 * not a valid absolute path on any platform this ships to, so it cannot collide
 * with a real project.
 */
export const MACHINE_SCOPE = '*machine*'

const EMPTY: readonly string[] = []

function storageOf(): Storage | null {
  // Reading through `globalThis` rather than the bare identifier: this module is
  // imported by tests that run with no DOM at all, where `localStorage` is not
  // merely empty but undeclared.
  return (globalThis as unknown as { localStorage?: Storage }).localStorage ?? null
}

/**
 * Everything read here is total by construction.
 *
 * The blob is editable by hand in devtools and can be corrupted by a half-
 * written quota failure, and a malformed one must cost the *dismissals*, never
 * the panel. Anything that is not a string array is dropped; anything that is
 * rides along untouched, including keys written by a newer build.
 */
export function parseDismissed(raw: string | null): DismissedMap {
  if (raw === null || raw === '') return {}
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return {}
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return {}

  const out: Record<string, readonly string[]> = {}
  for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
    // `__proto__` arrives as a plain own key from JSON.parse, but assigning it
    // through a computed property walks the prototype instead of the map.
    if (key === '__proto__') continue
    if (!Array.isArray(value)) continue
    const ids = value.filter((entry): entry is string => typeof entry === 'string' && entry !== '')
    if (ids.length > 0) out[key] = ids
  }
  return out
}

export function readDismissed(storage: Storage | null = storageOf()): DismissedMap {
  try {
    return parseDismissed(storage?.getItem(DISMISSED_KEY) ?? null)
  } catch {
    // Reading storage throws in a sandboxed frame with cookies blocked. An empty
    // map is the honest answer: nothing has been dismissed that we can prove.
    return {}
  }
}

export function writeDismissed(map: DismissedMap, storage: Storage | null = storageOf()): void {
  try {
    storage?.setItem(DISMISSED_KEY, JSON.stringify(map))
  } catch {
    // Quota, or storage disabled. The in-memory state is already correct, so the
    // dismissal works for this session and is simply not remembered — which is a
    // far better failure than a panel that throws while somebody is reading it.
  }
}

export function idsFor(map: DismissedMap, scope: string): readonly string[] {
  return map[scope] ?? EMPTY
}

export function isDismissed(map: DismissedMap, scope: string, id: string): boolean {
  return idsFor(map, scope).includes(id)
}

/** Put one row away. Returns the same map when it was already away. */
export function dismiss(map: DismissedMap, scope: string, id: string): DismissedMap {
  if (isDismissed(map, scope, id)) return map
  return { ...map, [scope]: [...idsFor(map, scope), id] }
}

/** Bring one row back. The scope key goes with the last id in it. */
export function restore(map: DismissedMap, scope: string, id: string): DismissedMap {
  const kept = idsFor(map, scope).filter((entry) => entry !== id)
  const next = { ...map }
  if (kept.length === 0) delete next[scope]
  else next[scope] = kept
  return next
}

/** Bring every row in one scope back — the "turn it all back on" door. */
export function restoreAll(map: DismissedMap, scope: string): DismissedMap {
  if (idsFor(map, scope).length === 0) return map
  const next = { ...map }
  delete next[scope]
  return next
}
