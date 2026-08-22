/**
 * The Electron shell half of the settings the `store.ts` preferences do not hold.
 *
 * The store half — sanitize, patch, load, persist, the last-good snapshot, the
 * two setting-key constants — moved to `settings-store.ts`, which needs only
 * `fs` and a user-data directory and so reads on a headless host too. This file
 * keeps everything that genuinely needs Electron: the config-path list a person
 * opens in Advanced, the About panel, the guest browsing-data clear, and the IPC
 * registration. It **re-exports every name that moved**, so the fifteen modules
 * that import them from here compile unchanged.
 *
 * @see settings-store
 */

import { existsSync, mkdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { app, session, shell, type IpcMain, type IpcMainInvokeEvent } from 'electron'
import { BRAND } from '../shared/brand'
import { GUEST_PARTITION } from './browser-session'
import { traceFilePath } from './ipc-trace'
import { updateSupport } from './updates/updater'
import {
  BROWSER_PERSIST_KEY,
  getStoredSettings,
  isRecord,
  patchStoredSettings,
  resetStoredSettings,
  SETTINGS_SNAPSHOT_FILE,
  storedValue,
} from './settings-store'

// Everything the store half owns, re-exported so `lid-awake.ts`, `index.ts`,
// `deck-control/live-surface.ts` and every test that reads them from here still
// resolve them here. The names live in one place; they are reachable from two.
export * from './settings-store'

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
      // Listed even before anything has written one, for the same reason
      // `ipcTrace` below is: the value of a way back is knowing it is there
      // *before* you need it, and a row that only appears once the copilot has
      // already changed something is a row nobody finds in time.
      key: 'settingsLastGood',
      label: 'Settings — last good',
      purpose: 'A copy of your settings taken before the copilot changed any. Written only then.',
      path: join(userData, SETTINGS_SNAPSHOT_FILE),
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
      /*
       * The field this panel used to leave out, and the only one whose absence
       * changes the answer rather than narrowing it.
       *
       * `updateSupport` refuses a portable Windows build outright — an update
       * on Windows runs an installer, and installing is the one thing a
       * portable app does not do (`PORTABLE_REASON`). Omitting the value here
       * made that branch unreachable *from this panel only*, so somebody
       * running `-portable.exe` read "this build is code-signed and carries a
       * release feed, so it could install an update" in About while the update
       * controller in `index.ts` — which does pass it — refused with the
       * opposite sentence. Two screens of one app disagreeing, on Windows only,
       * about the one artifact that genuinely cannot update.
       *
       * Read from the environment rather than inferred: electron-builder's own
       * portable launcher sets `PORTABLE_EXECUTABLE_FILE` to the exe's path
       * before starting the app (`templates/nsis/portable.nsi`), and there is
       * no other way to tell the two Windows artifacts apart from inside the
       * process. `?? null` keeps the pure function's contract — absent means
       * "not the portable build", which is right on every other platform, where
       * the variable never exists.
       */
      portableExecutable: process.env.PORTABLE_EXECUTABLE_FILE ?? null,
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
 * @see {@link BROWSER_PERSIST_KEY} in `settings-store.ts` for the setting read here.
 */

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
