/**
 * The Electron-free half of the settings the `store.ts` preferences do not hold.
 *
 * Everything here needs only `fs` and a user-data directory, so it reads on a
 * headless host the same way it reads under Electron — the directory comes from
 * `platform/paths.ts`, which both shells install at boot, rather than from
 * `app.getPath`. The shell half — the config-path list, the About panel, the
 * browsing-data clear, the IPC registration — stays in `settings-extra.ts`,
 * which re-exports every name moved here so the modules that import from it
 * compile unchanged.
 *
 * ## Why this side knows nothing about the settings themselves
 *
 * The schema — id, kind, default, validation — lives in the renderer
 * (`src/renderer/settings/settings-schema.ts`), and the renderer tsconfig is
 * the only one that can see it. Duplicating the table here would be a second
 * copy of the truth and would drift within a release. So this side is a typed
 * key/value bag with hard limits: primitives only, capped in count and length,
 * written atomically, and never interpreted. The renderer coerces on the way
 * in and merges defaults on the way out.
 *
 * The one exception is documented at `BROWSER_PERSIST_KEY`, which is read at
 * quit time — after every renderer is gone — by the shell half. It fails in the
 * safe direction.
 */

import { mkdirSync, readFileSync, renameSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { writeFileAtomic } from './atomic-write'
import { userDataDir } from './platform/paths'

/* ---------------------------------------------------------------- limits -- */

export const SETTINGS_FILE_VERSION = 1

/** A settings file is a list of small choices, not a document store. */
export const MAX_KEYS = 500
export const MAX_KEY_LENGTH = 128
export const MAX_STRING_LENGTH = 4096

export type StoredValue = string | number | boolean

export interface StoredSettings {
  version: number
  values: Record<string, StoredValue>
}

/* ------------------------------------------------------------ validation -- */

/** Shared by both halves; exported so `settings-extra.ts` reads JSON the same way. */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Reduce anything to values worth persisting.
 *
 * Primitives only, deliberately. The renderer is the only writer today, but an
 * IPC handler is reachable from any code running in that window, and "the
 * settings file" is a fine place to hide a megabyte of nested JSON that then
 * has to be parsed on every launch. Rejecting structure keeps the failure mode
 * boring: an unsupported value is dropped, not stored and mis-read later.
 */
export function sanitizeValues(raw: unknown): Record<string, StoredValue> {
  const out: Record<string, StoredValue> = {}
  if (!isRecord(raw)) return out

  let kept = 0
  for (const [key, value] of Object.entries(raw)) {
    if (kept >= MAX_KEYS) break
    // Own key from JSON.parse, but assigning it walks the prototype.
    if (key === '__proto__' || key === '' || key.length > MAX_KEY_LENGTH) continue

    if (typeof value === 'boolean') out[key] = value
    else if (typeof value === 'number' && Number.isFinite(value)) out[key] = value
    else if (typeof value === 'string') out[key] = value.slice(0, MAX_STRING_LENGTH)
    else continue

    kept += 1
  }
  return out
}

/**
 * Apply a patch. A key set to null is removed, which is how a single setting
 * goes back to its default without the caller having to know what that is.
 */
export function applyPatch(
  current: Readonly<Record<string, StoredValue>>,
  patch: unknown,
): Record<string, StoredValue> {
  const next: Record<string, StoredValue> = { ...current }
  if (!isRecord(patch)) return next

  for (const [key, value] of Object.entries(patch)) {
    if (key === '__proto__' || key === '' || key.length > MAX_KEY_LENGTH) continue
    if (value === null || value === undefined) {
      delete next[key]
      continue
    }
    const cleaned = sanitizeValues({ [key]: value })
    if (key in cleaned) next[key] = cleaned[key]
  }

  return sanitizeValues(next)
}

/* ----------------------------------------------------------- persistence -- */

/**
 * The settings file, under the user-data directory `platform/paths.ts` answers.
 *
 * `userDataDir()` rather than `app.getPath('userData')` — that was the one
 * Electron call this half made, and swapping it for the seam both shells install
 * at boot is what lets a headless host read and write these settings without an
 * Electron process anywhere near it.
 */
function settingsFile(): string {
  return join(userDataDir(), 'settings.json')
}

let cache: Record<string, StoredValue> | null = null

/**
 * Top-level keys we did not write, kept verbatim so a newer build's data
 * survives an older build reading and rewriting the file.
 */
let carriedForward: Record<string, unknown> = {}

/**
 * Set when the file exists but could not be understood.
 *
 * Same reasoning as `profiles.ts`: the user's only copy of their settings is on
 * disk, and an empty object in memory is indistinguishable from a real one by
 * the time the next write happens. Without this, the first toggle of the
 * session replaces an unreadable-but-intact file with `{}`.
 */
let backupBeforeWrite = false

/** Drop the in-memory copy. Exported for tests, which swap userData per case. */
export function resetSettingsCache(): void {
  cache = null
  carriedForward = {}
  backupBeforeWrite = false
}

function load(): Record<string, StoredValue> {
  if (cache) return cache
  cache = {}
  carriedForward = {}
  backupBeforeWrite = false

  let text: string
  try {
    text = readFileSync(settingsFile(), 'utf8')
  } catch (cause) {
    // Absent is first run — the only case where "no settings" is the truth.
    backupBeforeWrite = (cause as NodeJS.ErrnoException | null)?.code !== 'ENOENT'
    return cache
  }

  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    backupBeforeWrite = true
    return cache
  }

  if (!isRecord(raw)) {
    backupBeforeWrite = true
    return cache
  }

  // Both shapes are read: the envelope, and a bare map from before there was
  // one. The renderer's migration does the same, from the other side.
  const values = isRecord(raw.values) ? raw.values : raw
  cache = sanitizeValues(values)

  for (const [key, value] of Object.entries(raw)) {
    if (key !== 'version' && key !== 'values') carriedForward[key] = value
  }

  const version = raw.version
  // A file from a newer build: its unknown keys are kept, but we cannot know
  // what it did to the ones we parse, so keep a copy before rewriting.
  if (typeof version === 'number' && version > SETTINGS_FILE_VERSION) backupBeforeWrite = true

  return cache
}

function persist(values: Record<string, StoredValue>): void {
  const file = settingsFile()
  mkdirSync(dirname(file), { recursive: true })

  if (backupBeforeWrite) {
    try {
      renameSync(file, `${file}.bak-${Date.now()}`)
    } catch {
      // Already gone, or the directory is unwritable — the write below reports it.
    }
    backupBeforeWrite = false
  }

  const payload = { ...carriedForward, version: SETTINGS_FILE_VERSION, values }
  // Temp file plus rename: a crash mid-write cannot leave a truncated file that
  // would read as "no settings" and silently reset everything on next launch.
  //
  // Through `writeFileAtomic` rather than written out here, because the two
  // Windows hazards in that dance were both present. The temp name was the
  // fixed `${file}.tmp`, which two windows of this app share — and this is the
  // file two windows are most likely to write at once, since both of them save
  // settings. And a `rename` over a destination another process holds open
  // fails on Windows with EPERM where POSIX `rename` always succeeds; that
  // throw reaches `patchStoredSettings`'s caller as "could not save" with no
  // cause named and no way for the user to act on it. A short bounded retry
  // covers the millisecond-scale handle a virus scanner or the search indexer
  // takes on a file the instant it is closed.
  writeFileAtomic(file, JSON.stringify(payload, null, 2))
}

export function getStoredSettings(): StoredSettings {
  return { version: SETTINGS_FILE_VERSION, values: { ...load() } }
}

export function patchStoredSettings(patch: unknown): StoredSettings {
  const next = applyPatch(load(), patch)
  // Disk first. `persist` throws on a full or read-only disk, and the caller
  // turns that into "could not save" — which would have been a lie if the
  // in-memory copy had already been replaced, because everything that reads a
  // setting afterwards (`clearBrowserDataIfNotPersisting` at quit, most of all)
  // reads the cache.
  persist(next)
  cache = next
  return { version: SETTINGS_FILE_VERSION, values: { ...next } }
}

/**
 * Forget everything this module stores.
 *
 * Only this file. The four preferences in `store.ts` are reset by the caller
 * writing schema defaults through `prefs:set` — the schema owns those defaults,
 * and copying them here would be the drift this module exists to avoid.
 */
export function resetStoredSettings(): StoredSettings {
  const empty: Record<string, StoredValue> = {}
  // Keys from a newer build go too — the user asked for a reset, not a merge.
  carriedForward = {}
  // No unlink first. `persist` replaces the file atomically anyway, and
  // deleting it beforehand threw away the one case this module exists to
  // protect: a file that could not be parsed was destroyed without the backup
  // that every other write path takes. It also left a window where the app had
  // no settings file at all.
  persist(empty)
  cache = empty
  return { version: SETTINGS_FILE_VERSION, values: {} }
}

/** One stored value, for main-process code that needs to act on a setting. */
export function storedValue(key: string): StoredValue | undefined {
  return load()[key]
}

/* --------------------------------------------------------------- last good -- */

/** Sits beside `settings.json`, so somebody looking for one finds the other. */
export const SETTINGS_SNAPSHOT_FILE = 'settings.last-good.json'

/** Format tag, so a future reader can tell this file's shape from a settings file. */
export const SETTINGS_SNAPSHOT_VERSION = 1

export interface SettingsSnapshotFile {
  version: number
  /** ISO 8601, matching the convention the action log already uses. */
  at: string
  /** What was about to happen. Free text; this is a file a person reads. */
  reason: string
  /**
   * The whole of `settings.json` as it was parsed off disk — envelope, unknown
   * keys and all — or the live values when the file could not be read.
   */
  settings: unknown
  /** `state.json`'s preferences block. The other half of "the settings". */
  preferences: unknown
  /** True when `settings.json` was missing or unparseable and this is the cache. */
  fromCache: boolean
}

export function settingsSnapshotPath(): string {
  return join(userDataDir(), SETTINGS_SNAPSHOT_FILE)
}

/**
 * Write the last-good copy of both settings stores.
 *
 * One invalid value cost OpenClaw its entire gateway — `tools.profile: "none"`,
 * outside the enum, and recovery needed a different application on a different
 * machine to hand-edit JSON. They keep `.bak`, `.bak.1`…`.bak.4`, `.last-good`
 * and `.prebridge` now. This app needs far less than that because
 * `patchStoredSettings` already keeps a `.bak-<timestamp>` for the case it was
 * written for — a file that could not be *parsed* — but that case is not this
 * one. A perfectly parseable file full of values that break the window is
 * exactly what a confirmed-but-wrong copilot write produces, and nothing here
 * kept a copy of the state before it.
 *
 * Both stores in one file rather than a copy per store, because "put my settings
 * back" is one intention and answering it from two files with two timestamps
 * invites putting half of them back. The settings half is the raw parsed file
 * rather than the sanitised cache, so keys written by a newer build — which
 * `load()` deliberately carries but does not interpret — survive a restore.
 *
 * A single generation, overwritten each time, and that is a real limit worth
 * stating: two bad writes in a row and the snapshot is of the state after the
 * first one. It is the same trade `DEFAULT_KEEP = 1` makes in the action log,
 * and the alternative — a rolling set — is a thing that has to be pruned,
 * measured and explained in the settings pane. The copilot's writes are
 * confirmed one at a time by a person at the keyboard, so the second-bad-write
 * case has a human in it who has already been shown the first one.
 *
 * Throws rather than reporting failure, because every caller must treat a
 * missing snapshot as a reason not to proceed.
 */
export function writeSettingsSnapshot(preferences: unknown, reason: string): { path: string; at: number } {
  const file = settingsSnapshotPath()
  mkdirSync(dirname(file), { recursive: true })

  let settings: unknown
  let fromCache = false
  try {
    settings = JSON.parse(readFileSync(settingsFile(), 'utf8'))
  } catch {
    // Missing (first run, nothing written yet) or unparseable. The in-memory
    // envelope is then the best true statement about what the app is using, and
    // `fromCache` says so rather than letting a reader assume it is the file.
    settings = { version: SETTINGS_FILE_VERSION, values: { ...load() } }
    fromCache = true
  }

  const at = Date.now()
  const payload: SettingsSnapshotFile = {
    version: SETTINGS_SNAPSHOT_VERSION,
    at: new Date(at).toISOString(),
    reason,
    settings,
    preferences,
    fromCache,
  }
  // Temp file plus rename, like every other write here: a snapshot truncated by
  // a crash is worse than no snapshot, because it looks like one. Same shared
  // helper as `persist` above, for the same two Windows reasons — see there.
  writeFileAtomic(file, `${JSON.stringify(payload, null, 2)}\n`)
  return { path: file, at }
}

/* --------------------------------------------------------- setting keys -- */

/**
 * The setting that decides whether guest cookies survive a quit.
 *
 * The id is the renderer schema's, and it is read at quit time — by
 * `clearBrowserDataIfNotPersisting` in `settings-extra.ts` — because the value
 * has to be acted on after every renderer is gone. A missing key means "keep",
 * so a renamed id degrades to leaving the user's logins alone rather than wiping
 * them.
 */
export const BROWSER_PERSIST_KEY = 'browser.persistSession'

/**
 * Whether this Mac dials out for remote access when the app launches.
 *
 * A *missing* key means yes. That direction matters: remote access is meant to
 * need no switch at all, so the only state worth storing is the one where
 * someone deliberately turned it off. Written by `index.ts` when a start or a
 * stop takes, never by the panel directly — the panel asks the main process to
 * do something, and what actually happened is what gets remembered.
 */
export const REMOTE_ENABLED_KEY = 'remote.enabled'
