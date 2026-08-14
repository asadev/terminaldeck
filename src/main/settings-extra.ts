/**
 * Persistence for the settings `store.ts` does not already hold.
 *
 * `store.ts` keeps four preferences plus the project list, and the main process
 * reads two of them while spawning (`defaultProvider`) and at launch
 * (`restoreSessions`). Those stay where they are. Everything else the settings
 * window offers lands here, in `settings.json` beside it.
 *
 * ## Why this module knows nothing about the settings themselves
 *
 * The schema — id, kind, default, validation — lives in the renderer
 * (`src/renderer/settings/settings-schema.ts`), and the renderer tsconfig is
 * the only one that can see it. Duplicating the table here would be a second
 * copy of the truth and would drift within a release. So this side is a typed
 * key/value bag with hard limits: primitives only, capped in count and length,
 * written atomically, and never interpreted. The renderer coerces on the way
 * in and merges defaults on the way out.
 *
 * The one exception is documented at `BROWSER_PERSIST_KEY`, which is read here
 * because the value has to be acted on at quit time, after every renderer is
 * gone. It fails in the safe direction.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { app, session, shell, type IpcMain, type IpcMainInvokeEvent } from 'electron'
import { BRAND } from '../shared/brand'
import { GUEST_PARTITION } from './browser-session'
import { traceFilePath } from './ipc-trace'
import { updateSupport } from './updates/updater'

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

function isRecord(value: unknown): value is Record<string, unknown> {
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

function settingsFile(): string {
  return join(app.getPath('userData'), 'settings.json')
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
  const tmp = `${file}.tmp`
  writeFileSync(tmp, JSON.stringify(payload, null, 2), 'utf8')
  renameSync(tmp, file)
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

/* ------------------------------------------------------------ config paths -- */

export interface ConfigPath {
  key: string
  label: string
  /** What lives there, in the user's terms. */
  purpose: string
  path: string
  kind: 'file' | 'folder'
  exists: boolean
}

/**
 * Everything this app writes, named. Shown in Advanced so "where does it keep
 * my stuff" has an answer that does not require a support thread.
 */
export function configPaths(): ConfigPath[] {
  const userData = app.getPath('userData')
  const entries: Array<Omit<ConfigPath, 'exists'>> = [
    {
      key: 'userData',
      label: 'App data',
      purpose: 'Everything below lives in here.',
      path: userData,
      kind: 'folder',
    },
    {
      key: 'settings',
      label: 'Settings',
      purpose: 'The options in this window.',
      path: join(userData, 'settings.json'),
      kind: 'file',
    },
    {
      key: 'state',
      label: 'Projects and preferences',
      purpose: 'Your project list, theme, default agent and window size.',
      path: join(userData, 'state.json'),
      kind: 'file',
    },
    {
      key: 'profiles',
      label: 'Profiles',
      purpose: 'The list of agent profiles. Logins themselves live in the OS keychain.',
      path: join(userData, 'profiles.json'),
      kind: 'file',
    },
    {
      key: 'profilesDir',
      label: 'Profile folders',
      purpose: 'One config directory per profile this app created.',
      path: join(userData, 'profiles'),
      kind: 'folder',
    },
    {
      key: 'logs',
      label: 'Logs',
      purpose: 'Crash and diagnostic logs written by the runtime.',
      path: app.getPath('logs'),
      kind: 'folder',
    },
    {
      key: 'ipcTrace',
      label: 'Debug trace',
      // Listed whether or not it exists, and says when it is written: a file
      // that only appears in this list once something has already created it is
      // no use to somebody wondering what the app is putting on their disk. An
      // earlier build wrote 12 MB here with Debug mode off and never mentioned
      // it anywhere.
      purpose: 'Every IPC call, recorded while Debug mode is on. Off by default.',
      path: traceFilePath(),
      kind: 'file',
    },
  ]

  return entries.map((entry) => ({ ...entry, exists: existsSync(entry.path) }))
}

export interface OpenPathResult {
  opened: boolean
  path: string | null
  message: string
}

/**
 * Reveal one of the paths above in the file manager.
 *
 * By key, never by path. The renderer asking for an arbitrary path would make
 * this a "open anything on the disk" channel, and a settings window has no need
 * of one.
 */
export async function openConfigPath(key: unknown): Promise<OpenPathResult> {
  const entry = configPaths().find((candidate) => candidate.key === key)
  if (!entry) return { opened: false, path: null, message: 'No such location.' }

  // A folder we own and promise to open should exist by the time it is clicked;
  // the logs folder in particular is created lazily by the runtime and is
  // usually missing on a machine that has never crashed.
  if (entry.kind === 'folder' && !entry.exists) {
    try {
      mkdirSync(entry.path, { recursive: true })
    } catch {
      return { opened: false, path: entry.path, message: 'That folder does not exist yet.' }
    }
  }

  if (entry.kind === 'file') {
    if (!existsSync(entry.path)) {
      return {
        opened: false,
        path: entry.path,
        message: 'That file has not been written yet.',
      }
    }
    // Reveal rather than open: these are JSON files, and handing one to whatever
    // the OS thinks opens .json is a good way to have it edited by accident.
    shell.showItemInFolder(entry.path)
    return { opened: true, path: entry.path, message: 'Revealed in your file manager.' }
  }

  const error = await shell.openPath(entry.path)
  return error
    ? { opened: false, path: entry.path, message: error }
    : { opened: true, path: entry.path, message: 'Opened.' }
}

/* ------------------------------------------------------------------ about -- */

export interface UpdateChannel {
  /** Whether this build could install an update at all. */
  packaged: boolean
  /** Whether an update feed file is present beside the app. */
  feedPresent: boolean
  /**
   * Whether this build *could* install an update it found.
   *
   * Not a claim that anything checks. Nothing calls `registerUpdateIpc` yet —
   * see {@link updateChannel}.
   */
  checkable: boolean
  detail: string
}

export interface AboutInfo {
  name: string
  tagline: string
  version: string
  electron: string
  chromium: string
  node: string
  platform: string
  arch: string
  license: string | null
  repository: string | null
  homepage: string | null
  updates: UpdateChannel
}

function readPackageJson(): Record<string, unknown> {
  try {
    const raw: unknown = JSON.parse(readFileSync(join(app.getAppPath(), 'package.json'), 'utf8'))
    return isRecord(raw) ? raw : {}
  } catch {
    return {}
  }
}

/**
 * npm's `repository` field is a string, a shorthand, or an object, and the URL
 * inside it is routinely `git+https://…​.git`. Normalised to something a link
 * can point at, or null — inventing a URL for a repo whose address is not
 * recorded would be worse than showing nothing.
 */
export function repositoryUrl(field: unknown): string | null {
  const raw =
    typeof field === 'string'
      ? field
      : isRecord(field) && typeof field.url === 'string'
        ? field.url
        : null
  if (!raw) return null

  const shorthand = /^(?:github:)?([\w.-]+)\/([\w.-]+)$/.exec(raw.trim())
  if (shorthand) return `https://github.com/${shorthand[1]}/${shorthand[2]}`

  const cleaned = raw
    .trim()
    .replace(/^git\+/, '')
    .replace(/\.git$/, '')
    .replace(/^git:\/\//, 'https://')
    .replace(/^ssh:\/\/git@/, 'https://')
    .replace(/^git@([^:]+):/, 'https://$1/')

  return /^https?:\/\//.test(cleaned) ? cleaned : null
}

/**
 * Whether this build can update itself.
 *
 * This used to say, correctly at the time, that `electron-updater` was a
 * dependency nothing imported and that no code path checked a feed. That is no
 * longer the shape of the truth: `./updates/updater.ts` is the code path, and
 * the question has become the harder one it always should have been — not
 * "does anything check" but "could an update actually be installed if it did".
 *
 * So the verdict is not computed here twice. It is asked of the module that
 * owns it, which weighs three things against the disk: whether this is a
 * packaged build at all, whether the bundle carries a real code signature
 * (macOS will not apply an update to one that does not), and whether
 * electron-builder wrote a feed beside the app. `feedPresent` is still reported
 * separately because the About panel shows it as its own fact.
 *
 * One thing this deliberately does **not** claim: that a check happens.
 * `./updates/updater.ts` exports `registerUpdateIpc`, and `src/main/index.ts`
 * does not call it — only `updateSupport` is reached from here, for the
 * sentence below. So the supported branch describes what the build could do
 * and says plainly that nothing checks yet. Rewrite that sentence in the same
 * commit that wires the IPC, and not before: understating a feature is
 * recoverable, and this project has already shipped the other kind.
 *
 * @see updateSupport
 */
export function updateChannel(): UpdateChannel {
  const packaged = app.isPackaged
  const feed = packaged
    ? join(process.resourcesPath, 'app-update.yml')
    : join(app.getAppPath(), 'dev-app-update.yml')

  let feedPresent = false
  try {
    feedPresent = statSync(feed).isFile()
  } catch {
    feedPresent = false
  }

  const verdict = updateSupport(
    {
      platform: process.platform,
      isPackaged: packaged,
      execPath: process.execPath,
      feedConfigPath: feed,
    },
    existsSync,
  )

  return {
    packaged,
    feedPresent,
    checkable: verdict.supported,
    // The unsupported sentence is the updater's own, printed verbatim. A
    // paraphrase here would be a second copy of a message that changes.
    detail: verdict.supported
      ? 'This build is code-signed and carries a release feed, so it could install an ' +
        'update — but nothing in this build checks for one yet. Download new versions ' +
        'from Releases.'
      : verdict.reason,
  }
}

export function aboutInfo(): AboutInfo {
  const pkg = readPackageJson()
  return {
    name: BRAND.name,
    tagline: BRAND.tagline,
    version: app.getVersion(),
    electron: process.versions.electron ?? '',
    chromium: process.versions.chrome ?? '',
    node: process.versions.node ?? '',
    platform: process.platform,
    arch: process.arch,
    license: typeof pkg.license === 'string' ? pkg.license : null,
    repository: repositoryUrl(pkg.repository),
    homepage: typeof pkg.homepage === 'string' ? pkg.homepage : null,
    updates: updateChannel(),
  }
}

/* --------------------------------------------------------- browsing data -- */

/**
 * The partition the guest views use is imported, never retyped.
 *
 * It used to be a copy of the string in `browser-tab.ts`, on the grounds that
 * a mismatch would only clear an empty partition. That is a no-op with a
 * dialog on top of it: this module's own message says the browser tab's
 * cookies are gone. `browser-session.ts` exports the constant, so the two
 * cannot drift and the message cannot become a lie.
 *
 * @see {@link GUEST_PARTITION}
 */

/**
 * The setting that decides whether guest cookies survive a quit.
 *
 * The id is the renderer schema's, and it is read here because the value has to
 * be acted on after every renderer is gone. A missing key means "keep", so a
 * renamed id degrades to leaving the user's logins alone rather than wiping them.
 */
export const BROWSER_PERSIST_KEY = 'browser.persistSession'

export interface ClearResult {
  cleared: boolean
  message: string
}

export async function clearBrowsingData(): Promise<ClearResult> {
  try {
    const guest = session.fromPartition(GUEST_PARTITION)
    await guest.clearStorageData()
    await guest.clearCache()
    // Present since Electron 12, but guarded — this runs at quit, where a
    // throw would be reported as a crash on exit.
    await guest.clearAuthCache?.()
    return { cleared: true, message: 'Cookies, storage and cache for the browser tab are gone.' }
  } catch (error) {
    return {
      cleared: false,
      message: error instanceof Error ? error.message : 'Could not clear the browsing data.',
    }
  }
}

/**
 * Call from `before-quit`. Honours the "keep cookies and logins" setting, which
 * is the only moment it can be honoured — a session partition named `persist:`
 * writes to disk continuously while the app runs.
 */
export async function clearBrowserDataIfNotPersisting(): Promise<ClearResult> {
  if (storedValue(BROWSER_PERSIST_KEY) !== false) {
    return { cleared: false, message: 'Browsing data is kept between runs.' }
  }
  return clearBrowsingData()
}

/* -------------------------------------------------------------------- ipc -- */

/**
 * Wire the settings channels. Call once from `registerIpc()`:
 * `registerSettingsIpc(ipcMain)`.
 *
 * - `settings:get`                → {@link StoredSettings}
 * - `settings:set` (patch)        → {@link StoredSettings}
 * - `settings:reset`              → {@link StoredSettings} (empty)
 * - `settings:paths`              → {@link ConfigPath}[]
 * - `settings:open-path` (key)    → {@link OpenPathResult}
 * - `settings:about`              → {@link AboutInfo}
 * - `settings:clear-browser-data` → {@link ClearResult}
 */
export function registerSettingsIpc(ipcMain: IpcMain): void {
  ipcMain.handle('settings:get', () => getStoredSettings())
  ipcMain.handle('settings:set', (_e: IpcMainInvokeEvent, patch: unknown) =>
    patchStoredSettings(patch),
  )
  ipcMain.handle('settings:reset', () => resetStoredSettings())
  ipcMain.handle('settings:paths', () => configPaths())
  ipcMain.handle('settings:open-path', (_e: IpcMainInvokeEvent, key: unknown) => openConfigPath(key))
  ipcMain.handle('settings:about', () => aboutInfo())
  ipcMain.handle('settings:clear-browser-data', () => clearBrowsingData())
}
