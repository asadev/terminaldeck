import { getSetting, splitPatch, type SettingValue } from '../settings/settings-schema'
import { FEATURES, feature, type Feature, type FeatureId } from './registry'

/**
 * Which features this machine has, and the three states one can be in.
 *
 * ## Off and uninstalled are different, and the difference is the data
 *
 * `off` keeps your settings and your data and stops drawing the feature.
 * `uninstalled` removes what the feature owns as well. That distinction is the
 * whole reason this is not a boolean: somebody who turns the browser off for a
 * week and back on expects their start page to still be there, and somebody who
 * uninstalls it expects it gone. Collapsing the two would make one of those two
 * people wrong, silently, and only once it was too late.
 *
 * ## Why `localStorage` and not the settings file
 *
 * Because the answer has to be known at the *first paint*, and the settings file
 * arrives one IPC round trip later. Everything gated by this is chrome — the
 * sidebar's rows, the mode switch's segments, the ＋ menu — so reading it late
 * means the window visibly rearranges itself a frame after launch, every
 * launch. That is the flicker this app spent a release removing from the
 * theme, and it would be worse here, because a row appearing under a pointer
 * that is already moving is a misclick rather than a blink.
 *
 * The trade is that "reset all settings" in Advanced does not reset this, which
 * is why the store carries its own "Back to the starter set" instead.
 */

export type FeatureStatus = 'on' | 'off' | 'uninstalled'

/**
 * The stored map, ids to status.
 *
 * Keyed by plain string rather than `FeatureId` for the same reason
 * `SettingValues` is keyed loosely: a file written by a newer build carries ids
 * this one has never heard of, and dropping them is how a downgrade — or one
 * agent's build meeting another's — silently uninstalls something the user
 * chose to keep. Unknown keys ride along untouched; reads go through
 * `statusOf`, which falls back to the registry's default.
 */
export type FeatureState = Readonly<Record<string, FeatureStatus>>

/**
 * Where the map lives. No product-name prefix: `localStorage` is already scoped
 * to this app's renderer origin, and the product name is allowed in exactly one
 * file, which is not this one.
 */
export const FEATURES_KEY = 'features.v1'

function isStatus(value: unknown): value is FeatureStatus {
  return value === 'on' || value === 'off' || value === 'uninstalled'
}

/** What a fresh install has: the starter set on, the specialist tools off. */
export function defaultFeatureState(): FeatureState {
  return Object.fromEntries(
    FEATURES.map((entry) => [entry.id, entry.default === 'on' ? 'on' : 'uninstalled']),
  )
}

/**
 * Fill in what is missing, fix what is wrong, keep what we do not recognise.
 *
 * Total by construction: this parses a string somebody can edit by hand in
 * devtools, and a malformed blob must cost the *choices*, never the app.
 *
 * A feature the stored map says nothing about arrives at its declared default,
 * which is what makes shipping a new feature work: it appears for everyone who
 * would have got it on a fresh install, rather than being invisible to every
 * existing install until they go looking in a store they have no reason to open.
 */
export function mergeFeatureState(raw: unknown): FeatureState {
  const merged: Record<string, FeatureStatus> = { ...defaultFeatureState() }
  const source = typeof raw === 'string' ? safeParse(raw) : raw
  if (typeof source !== 'object' || source === null || Array.isArray(source)) return merged

  for (const [key, value] of Object.entries(source as Record<string, unknown>)) {
    // `__proto__` arrives as a plain own key from JSON.parse, but assigning it
    // through a computed property would walk the prototype instead of the map.
    if (key === '__proto__') continue
    if (!isStatus(value)) continue
    merged[key] = value
  }

  return merged
}

function safeParse(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

export function statusOf(state: FeatureState, id: FeatureId): FeatureStatus {
  const stored = state[id]
  return isStatus(stored) ? stored : feature(id).default === 'on' ? 'on' : 'uninstalled'
}

/** Installed and switched on — the only state in which a feature is drawn. */
export function isOn(state: FeatureState, id: FeatureId): boolean {
  return statusOf(state, id) === 'on'
}

/** Installed, whether or not it is currently switched on. */
export function isInstalled(state: FeatureState, id: FeatureId): boolean {
  return statusOf(state, id) !== 'uninstalled'
}

export function withStatus(state: FeatureState, id: FeatureId, status: FeatureStatus): FeatureState {
  return { ...state, [id]: status }
}

/** In registry order, so the two lists in the store never reshuffle. */
export function installedFeatures(state: FeatureState): Feature[] {
  return FEATURES.filter((entry) => isInstalled(state, entry.id))
}

/** Everything not installed — what the store has to offer. */
export function availableFeatures(state: FeatureState): Feature[] {
  return FEATURES.filter((entry) => !isInstalled(state, entry.id))
}

/* --------------------------------------------------------------- storage -- */

/** What this machine has, or the shipped defaults when nothing is stored. */
export function readFeatureState(storage: Storage | null): FeatureState {
  if (!storage) return defaultFeatureState()
  try {
    return mergeFeatureState(storage.getItem(FEATURES_KEY))
  } catch {
    // A store disabled between reads. The defaults are a working app; refusing
    // to start over a preferences read is not.
    return defaultFeatureState()
  }
}

export function writeFeatureState(state: FeatureState, storage: Storage | null): void {
  if (!storage) return
  try {
    storage.setItem(FEATURES_KEY, JSON.stringify(state))
  } catch {
    // Quota, or a disabled store. The window already reflects the choice; it
    // just will not survive a restart, and there is nothing better to do about
    // it from here than keep working.
  }
}

/* ------------------------------------------------------------- uninstall -- */

/**
 * One thing uninstalling will delete, in the words the confirmation prints.
 *
 * There is no `size` field, and that is deliberate. "This will delete 4 saved
 * sessions and 2 MB of history" is a decision only when the 2 MB is real —
 * nothing a feature here owns has a size this side of the app can measure, and
 * a number that was estimated to satisfy a sentence is exactly the fake data
 * the design brief forbids. What *is* knowable is counted: a settings line says
 * how many and names them.
 */
export interface DeletionItem {
  label: string
  /** A second line, when the first would otherwise be a category. */
  detail?: string
}

/**
 * Exactly what uninstalling this feature removes.
 *
 * Empty is a real and common answer, and the store says so in words rather than
 * showing an empty list: most features here store nothing of yours at all, and
 * "nothing will be deleted" is the thing somebody hesitating actually wants to
 * know.
 */
export function uninstallPlan(id: FeatureId): DeletionItem[] {
  const entry = feature(id)
  const items: DeletionItem[] = []

  if (entry.settings.length > 0) {
    const names = entry.settings.map((setting) => getSetting(setting)?.label ?? setting)
    items.push({
      label: `${entry.settings.length} ${entry.settings.length === 1 ? 'setting' : 'settings'} go back to their defaults`,
      detail: names.join(', '),
    })
  }

  for (const data of entry.data) items.push({ label: data.label })

  return items
}

/**
 * What uninstalling has to be able to reach.
 *
 * `save` is the settings window's own writer, so a reset lands in the same
 * place a person changing that setting by hand would have written it — and the
 * window, and the app behind it, both see the new value immediately. Passing it
 * in rather than resolving `window.deck` here is what lets the whole thing be
 * tested without a bridge.
 */
export interface UninstallIo {
  save(patch: Record<string, SettingValue>): void
  clearBrowserData?(): Promise<unknown>
}

/**
 * Delete what the plan promised.
 *
 * Deliberately mirrors `uninstallPlan` item for item: the dialog and the
 * deletion read the same declaration, so the app cannot promise one thing and
 * do another. A missing bridge method is not an error here — the settings still
 * reset, and a build with no clearance channel is a build where that data does
 * not exist to begin with.
 */
export function clearFeatureData(id: FeatureId, io: UninstallIo): void {
  const entry = feature(id)

  if (entry.settings.length > 0) {
    const patch: Record<string, SettingValue> = {}
    for (const setting of entry.settings) {
      const declared = getSetting(setting)
      if (declared) patch[setting] = declared.default
    }
    // Routed through the schema's own splitter on the way out, so a prefs-backed
    // setting lands in prefs. `save` does that itself; this is the check that
    // every id we are about to write is one the schema will actually accept,
    // which is the difference between resetting a setting and quietly writing a
    // key nothing reads.
    const { unknown } = splitPatch(patch)
    for (const rejected of unknown) delete patch[rejected]
    if (Object.keys(patch).length > 0) io.save(patch)
  }

  for (const data of entry.data) {
    if (data.kind === 'browser-data') void io.clearBrowserData?.()
  }
}

/* ---------------------------------------------------------------- guards -- */

/** Every feature installed and on. One half of the extremes worth testing. */
export function everythingOn(): FeatureState {
  return Object.fromEntries(FEATURES.map((entry) => [entry.id, 'on' as const]))
}

/** Every feature uninstalled. The other half. */
export function everythingOff(): FeatureState {
  return Object.fromEntries(FEATURES.map((entry) => [entry.id, 'uninstalled' as const]))
}
