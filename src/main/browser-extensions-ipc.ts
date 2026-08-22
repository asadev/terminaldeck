import { BrowserWindow, dialog, type IpcMain, type Session } from 'electron'
import { BROWSER_EXTENSION_CATALOGUE } from './browser-extension-catalogue'
import { EXTENSION_LIMITS, optionsPageOf, popupPage } from './browser-extension-support'
import {
  createExtensionStore,
  orphanExtensionIds,
  profileExtensionsRoot,
  safeProfileId,
  type ExtensionCatalogue,
  type ExtensionResult,
  type ExtensionStore,
  sideloadId,
  type ExtensionStoreView,
  type FetchArchive,
  type InstalledExtension,
} from './browser-extensions'
import { activeProfile, profileState, sessionForPartition, partitionFor } from './browser-profiles'

/**
 * The half of the extension store that touches Electron: loading, unloading,
 * and the channels a panel and an agent reach it through.
 *
 * ## Why loading is replayed at launch rather than remembered
 *
 * Electron's own documentation for `loadExtension`, quoted because it is the
 * whole design constraint: *"Note that in previous versions of Electron,
 * extensions that were loaded would be remembered for future runs of the
 * application. This is no longer the case: `loadExtension` must be called on
 * every boot of your app if you want the extension to be loaded."*
 *
 * So the record of what is installed is **this app's disk**, and the browser's
 * state is derived from it on every launch. That inverts the usual worry: there
 * is no such thing as an extension that is loaded but not installed, and an
 * extension that is installed and switched on but failed to load is a visible,
 * reportable condition rather than a silent one — {@link loadFailures} keeps the
 * reason so the panel can print it instead of drawing an On switch over nothing.
 *
 * ## Why extensions load per profile, and when
 *
 * `session.extensions` is per `Session`, and a session here is a profile. At
 * launch every profile that has an install on disk gets its extensions loaded —
 * only those profiles, because a profile directory under
 * `<userData>/browser-extensions/` exists **only** because somebody installed
 * something into it. Nothing mints a session for a profile that has none.
 *
 * The load happens before the first page can open, from `registerIpc()`, for the
 * same reason `registerRecorderPreload` is called there: a content script that
 * arrives after a page has loaded has already missed the page.
 *
 * ## What "switched off" means, exactly
 *
 * `removeExtension` unloads it from the live session — the program stops running
 * immediately, its content scripts stop being injected, its background context
 * goes. Its files stay on the disk and its `installed.json` records `enabled:
 * false`, so it does not come back at the next launch. Switching it on loads it
 * again without a download. That is a real switch with a real effect, which is
 * the only kind this app is allowed to draw.
 *
 * ## The popup window
 *
 * Electron draws no extension toolbar, so this app draws its own row and opens
 * the extension's own popup page in a small window on the profile's session.
 * That URL is **never** user input: it is composed here out of the id Electron
 * handed back from `loadExtension` and the `default_popup` in the manifest on
 * disk. `browser-url.ts` allows only `http:` and `https:` into a guest tab and
 * that stays exactly as it is — this window is not a guest tab, and widening the
 * guest allow-list to reach an extension page would have handed every page in
 * the browser a new scheme to aim at.
 */

let store: ExtensionStore | null = null
let userDataDir = ''

/** Catalogue id → the id Electron minted, per profile. Only what is loaded now. */
const loaded = new Map<string, Map<string, string>>()

/** Catalogue id → why it did not load, per profile. Cleared when it does. */
const loadFailures = new Map<string, Map<string, string>>()

function bucket(map: Map<string, Map<string, string>>, profileId: string): Map<string, string> {
  const existing = map.get(profileId)
  if (existing) return existing
  const fresh = new Map<string, string>()
  map.set(profileId, fresh)
  return fresh
}

export interface BrowserExtensionDeps {
  /** `app.getPath('userData')`, read per call for the same reason downloads does. */
  userData(): string
  /**
   * Replaced in tests. Production passes neither and gets the shipped catalogue
   * and a real https fetch.
   *
   * The same seam `ToolStoreOptions.fetchBytes` opens next door, and for the
   * same reason: the interesting behaviour of this module is what it does when a
   * load *fails*, and there is no way to provoke that against a nine-megabyte
   * download from somebody else's release page.
   */
  catalogue?: ExtensionCatalogue
  fetchArchive?: FetchArchive
  /**
   * How somebody picks a folder or a `.crx`. Replaced in tests.
   *
   * The dialog lives here rather than in the renderer, and that is a rule and
   * not a convenience: a path chosen in the main process is a path a person
   * pointed at, and a path arriving over IPC is a string a renderer composed.
   * The second one is how an app ends up loading a directory nobody chose.
   * Answering `null` means the dialog was cancelled, which is not a failure and
   * does not produce an error on the row.
   */
  chooseFolder?(): Promise<string | null>
  chooseCrx?(): Promise<string | null>
}

/** Build the store. Called once from `registerIpc()`, before any page opens. */
export function installBrowserExtensions(deps: BrowserExtensionDeps): ExtensionStore {
  userDataDir = deps.userData()
  chooseFolder = deps.chooseFolder ?? pickFolder
  chooseCrx = deps.chooseCrx ?? pickCrx
  store = createExtensionStore({
    userData: userDataDir,
    catalogue: deps.catalogue ?? BROWSER_EXTENSION_CATALOGUE,
    fetchArchive: deps.fetchArchive,
  })
  return store
}

/** The real dialogs. Cancelled comes back as `null`, never as an error. */
async function pickFolder(): Promise<string | null> {
  const chosen = await dialog.showOpenDialog({
    title: 'Choose an unpacked extension',
    message: 'Pick the folder that has the manifest.json in it.',
    properties: ['openDirectory'],
    buttonLabel: 'Add to this profile',
  })
  return chosen.canceled ? null : (chosen.filePaths[0] ?? null)
}

async function pickCrx(): Promise<string | null> {
  const chosen = await dialog.showOpenDialog({
    title: 'Choose a .crx',
    properties: ['openFile'],
    filters: [{ name: 'Chrome extension', extensions: ['crx'] }],
    buttonLabel: 'Add to this profile',
  })
  return chosen.canceled ? null : (chosen.filePaths[0] ?? null)
}

let chooseFolder: () => Promise<string | null> = pickFolder
let chooseCrx: () => Promise<string | null> = pickCrx

/** Test seam and shutdown: forget everything this run loaded. */
export function resetBrowserExtensions(): void {
  store = null
  userDataDir = ''
  chooseFolder = pickFolder
  chooseCrx = pickCrx
  loaded.clear()
  loadFailures.clear()
}

/**
 * The session for a profile id, or null when the id is not one this app minted.
 *
 * Deliberately not `profileSession` from `browser-session.ts`, which falls back
 * to the active profile for an unknown id. That fallback is right for a panel
 * asking a question and catastrophic here: it would load somebody's extension
 * into the wrong profile's cookie jar, which is the one thing the per-profile
 * design exists to prevent.
 */
function sessionFor(profileId: string): Session | null {
  const safe = safeProfileId(profileId)
  if (safe === null) return null
  if (!profileState(userDataDir).profiles.some((profile) => profile.id === safe)) return null
  const partition = partitionFor(safe)
  return partition === null ? null : sessionForPartition(partition)
}

/**
 * Load one installed extension into its profile's session.
 *
 * Returns the id Electron minted, or the reason it did not. Failures are kept
 * rather than logged and forgotten: a store row that says On over an extension
 * that threw at load is the defect this feature is written against, and the only
 * way the panel can say otherwise is if somebody wrote the reason down.
 */
async function loadOne(profileId: string, extension: InstalledExtension): Promise<string> {
  const ses = sessionFor(profileId)
  if (ses === null) return ''
  const live = bucket(loaded, profileId)
  const failed = bucket(loadFailures, profileId)
  const already = live.get(extension.entry.id)
  if (already !== undefined) return already
  try {
    const result = await ses.extensions.loadExtension(extension.dir)
    live.set(extension.entry.id, result.id)
    failed.delete(extension.entry.id)
    return result.id
  } catch (error) {
    failed.set(
      extension.entry.id,
      error instanceof Error ? error.message : 'it could not be loaded into the browser',
    )
    return ''
  }
}

/** Unload one from its profile's session. Silent when it was not loaded. */
function unloadOne(profileId: string, id: string): void {
  const live = loaded.get(profileId)
  const electronId = live?.get(id)
  if (live === undefined || electronId === undefined) return
  const ses = sessionFor(profileId)
  try {
    ses?.extensions.removeExtension(electronId)
  } catch {
    // Already gone, or the session was never minted. Either way it is not
    // running, which is what the caller asked for.
  }
  live.delete(id)
}

/**
 * Load every switched-on extension, in every profile that has one.
 *
 * Awaited by nobody at launch — `registerIpc` is synchronous and a slow
 * extension must not hold up the window — but every failure lands in
 * {@link loadFailures} and every success in {@link loaded}, both of which the
 * panel reads on the next `list`. A page opened in the first second of a launch
 * can therefore beat an extension into the session, which is honest and
 * unavoidable: Electron offers no way to load one before the app is ready.
 */
export async function loadInstalledExtensions(): Promise<void> {
  if (store === null) return
  for (const profileId of store.profilesWithExtensions()) {
    for (const extension of store.installed(profileId)) {
      if (!extension.enabled) continue
      await loadOne(profileId, extension)
    }
  }
}

/**
 * Every extension a session's agent may ask about, for one profile.
 *
 * A function rather than a snapshot, for the argument `browserStoreTools` makes
 * about grants: a list read once at wiring time *"would freeze whatever was
 * installed at launch, so pressing Install would change nothing until the app
 * was restarted — a control that does nothing"*.
 */
export function installedExtensionsFor(profileId: string): InstalledExtension[] {
  return store?.installed(profileId) ?? []
}

/** Which profile a tool means when it is not told. The one switched on. */
export function currentProfileId(): string {
  return userDataDir === '' ? 'default' : activeProfile(userDataDir).id
}

/** The name of a profile, for a sentence. Its id when it has gone. */
export function profileNameFor(profileId: string): string {
  if (userDataDir === '') return profileId
  const found = profileState(userDataDir).profiles.find((profile) => profile.id === profileId)
  return found?.name ?? profileId
}

/** Is this extension running in this profile right now? */
export function isLoaded(profileId: string, id: string): boolean {
  return loaded.get(profileId)?.has(id) === true
}

/** Turn one on or off, on disk and in the live session, and say what happened. */
export async function setExtensionEnabled(
  profileId: string,
  id: string,
  on: boolean,
): Promise<ExtensionResult> {
  if (store === null) return NO_STORE
  const written = store.setEnabled(profileId, id, on)
  if (!written.ok) return written
  if (!on) {
    unloadOne(profileId, id)
    return written
  }
  const extension = store.installed(profileId).find((one) => one.entry.id === id)
  if (extension === undefined) {
    return { ok: false, message: 'It is not installed in this profile.' }
  }
  const electronId = await loadOne(profileId, extension)
  if (electronId === '') {
    /*
     * On disk it is now on and in the browser it is not. Said plainly rather
     * than reported as success — a switch that flipped and changed nothing is
     * the exact shape of control this app refuses to ship.
     */
    const why = loadFailures.get(profileId)?.get(id) ?? 'the browser refused it'
    return { ok: false, message: `${extension.entry.name} could not be switched on: ${why}.` }
  }
  return written
}

const NO_STORE: ExtensionResult = {
  ok: false,
  message: 'The extension store is not available in this build.',
}

const EMPTY: ExtensionStoreView = {
  profileId: '',
  profileName: '',
  extensions: [],
  folder: '',
}

/**
 * The view, with the live session's answer folded into each row.
 *
 * The store reads `enabled` off the disk, which is what should be true. This
 * corrects it to what **is** true, so a row can never show On for an extension
 * that is not running. Where they disagree the row carries the reason.
 */
function viewFor(profileId: string): ExtensionStoreView {
  if (store === null) return EMPTY
  const view = store.view(profileId, profileNameFor(profileId))
  const failed = loadFailures.get(profileId)
  return {
    ...view,
    extensions: view.extensions.map((row) => {
      if (row.state !== 'installed') return row
      const running = isLoaded(profileId, row.id)
      const why = failed?.get(row.id) ?? ''
      if (row.enabled && !running) {
        return {
          ...row,
          enabled: false,
          message:
            why === ''
              ? 'It is switched on but has not loaded into the browser yet.'
              : `It is switched on but the browser did not load it: ${why}.`,
        }
      }
      return { ...row, enabled: running }
    }),
  }
}

/**
 * Open an extension's own popup page in a small window on its profile's session.
 *
 * Refused rather than approximated when the extension draws no popup: an
 * extension with no `default_popup` has no page to show, and opening a blank
 * window would be a button that appears to work and shows nothing. The panel
 * asks {@link StoreExtension.popup} before it draws the control, so this refusal
 * is a second line rather than the only one.
 */
async function openExtensionPage(
  profileId: string,
  id: string,
  which: 'popup' | 'options',
): Promise<ExtensionResult> {
  if (store === null) return NO_STORE
  const extension = store.installed(profileId).find((one) => one.entry.id === id)
  if (extension === undefined) return { ok: false, message: 'It is not installed in this profile.' }
  const electronId = loaded.get(profileId)?.get(id)
  if (electronId === undefined) {
    return { ok: false, message: `${extension.entry.name} is not switched on, so it has nothing open.` }
  }
  const page =
    which === 'popup' ? popupPage(extension.manifest) : optionsPageOf(extension.manifest)
  if (page === '') {
    return {
      ok: false,
      message:
        which === 'popup'
          ? `${extension.entry.name} has no panel of its own.`
          : `${extension.entry.name} has no settings page of its own.`,
    }
  }
  const ses = sessionFor(profileId)
  if (ses === null) return { ok: false, message: 'That profile is not one this app knows.' }

  const window = new BrowserWindow({
    width: 420,
    height: 600,
    title: extension.entry.name,
    webPreferences: {
      // Exactly the shape the popup pages were measured rendering in — uBlock
      // Origin's and Dark Reader's both came up with `chrome.*` present under a
      // sandboxed, context-isolated renderer. Electron injects the extension
      // APIs into an extension page regardless of the sandbox, so there is
      // nothing to buy by weakening it.
      session: ses,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  })
  try {
    await window.loadURL(`chrome-extension://${electronId}/${page}`)
  } catch (error) {
    window.destroy()
    return {
      ok: false,
      message: `${extension.entry.name}’s panel did not open: ${error instanceof Error ? error.message : 'it would not load'}.`,
    }
  }
  return { ok: true, message: '' }
}

/**
 * Wire the extension store.
 *
 * Channels:
 * - `browser-extension:list`    (invoke, profileId?)         → `{ view, orphans, profiles, limits }`
 * - `browser-extension:install` (invoke, profileId, id)      → `{ ok, message }`
 * - `browser-extension:remove`  (invoke, profileId, id)      → `{ ok, message }`
 * - `browser-extension:enable`  (invoke, profileId, id, on)  → `{ ok, message }`
 * - `browser-extension:popup`   (invoke, profileId, id)      → `{ ok, message }`
 * - `browser-extension:options` (invoke, profileId, id)      → `{ ok, message }`
 * - `browser-extension:add-folder` (invoke, profileId)       → `{ ok, message }`
 * - `browser-extension:add-crx`    (invoke, profileId)       → `{ ok, message }`
 *
 * Invokes and no push, for the reason `browser-store-ipc.ts` gives: a row moves
 * only when somebody presses something in this panel, so the panel re-reads, and
 * *"a push channel with nothing on the far end that ever fires it is the shape of
 * dead wiring this app's contract test exists to catch."*
 */
export function registerBrowserExtensionIpc(ipcMain: IpcMain): void {
  const profileOf = (raw: unknown): string => {
    const safe = safeProfileId(raw)
    return safe !== null ? safe : currentProfileId()
  }

  ipcMain.handle('browser-extension:list', (_event, profileId: unknown) => {
    const id = profileOf(profileId)
    return {
      view: viewFor(id),
      orphans:
        store === null || userDataDir === ''
          ? []
          : orphanExtensionIds(userDataDir, id, BROWSER_EXTENSION_CATALOGUE),
      /*
       * Every profile, so the panel can say which one it is talking about and
       * switch between them. An extension store that could only ever show the
       * profile that happens to be switched on would be the same dead end
       * `profileSession` was written to fix: *"the question 'what is in this
       * profile?' had no wire to travel down."*
       */
      profiles:
        userDataDir === ''
          ? []
          : profileState(userDataDir).profiles.map((profile) => ({
              id: profile.id,
              name: profile.name,
            })),
      /*
       * The limits travel with the list rather than being written into the
       * panel. One copy, in the module that measured them, so the sentence a
       * person reads and the sentence `browser.extensions` gives an agent cannot
       * drift apart — and so a limit that stops being true is deleted in one
       * place rather than in two.
       */
      limits: EXTENSION_LIMITS,
    }
  })

  ipcMain.handle('browser-extension:install', async (_event, profileId: unknown, id: unknown) => {
    if (store === null || typeof id !== 'string') return NO_STORE
    const profile = profileOf(profileId)
    const result = await store.install(profile, id)
    if (!result.ok) return result
    /*
     * Unloaded *after* the install succeeded, and before the new one is loaded.
     *
     * Reinstalling replaces the files under a directory that may still be loaded
     * from — so anything running at this point is the old extension, and
     * `loadOne` would hand back its live id and never look at the new bytes. The
     * order matters the other way too: a failed install leaves the old files
     * alone, so unloading first would have stopped a working extension on
     * account of a download that never arrived.
     */
    unloadOne(profile, id)
    /*
     * Loaded straight away rather than at the next launch. An install that
     * needed a restart to do anything would be a button whose effect is
     * invisible, and the person pressing it has no way to tell that from one
     * that failed.
     */
    const extension = store.installed(profile).find((one) => one.entry.id === id)
    if (extension === undefined) return result
    const electronId = await loadOne(profile, extension)
    if (electronId === '') {
      const why = loadFailures.get(profile)?.get(id) ?? 'the browser refused it'
      return {
        ok: false,
        message: `${extension.entry.name} was saved but the browser would not load it: ${why}. It is switched off.`,
      }
    }
    return result
  })

  ipcMain.handle('browser-extension:remove', (_event, profileId: unknown, id: unknown) => {
    if (store === null || typeof id !== 'string') return NO_STORE
    const profile = profileOf(profileId)
    // Unloaded first, then deleted. The other order would delete the files out
    // from under a running program, which is how a browser ends up holding a
    // half-mapped extension until the next launch.
    unloadOne(profile, id)
    loadFailures.get(profile)?.delete(id)
    return store.remove(profile, id)
  })

  ipcMain.handle(
    'browser-extension:enable',
    async (_event, profileId: unknown, id: unknown, on: unknown) => {
      if (store === null || typeof id !== 'string') return NO_STORE
      return setExtensionEnabled(profileOf(profileId), id, on === true)
    },
  )

  ipcMain.handle('browser-extension:popup', async (_event, profileId: unknown, id: unknown) => {
    if (store === null || typeof id !== 'string') return NO_STORE
    return openExtensionPage(profileOf(profileId), id, 'popup')
  })

  /*
   * The settings page, which used to have no door at all.
   *
   * An extension can declare an options page and no `default_popup`, and two in
   * the catalogue do. Before this channel they installed, loaded, ran — and had
   * no interface anybody could open, because this browser draws no toolbar and
   * the store offered only the popup. That is the dead control this app is
   * written against, arrived at by omission rather than by a broken button.
   */
  ipcMain.handle('browser-extension:options', async (_event, profileId: unknown, id: unknown) => {
    if (store === null || typeof id !== 'string') return NO_STORE
    return openExtensionPage(profileOf(profileId), id, 'options')
  })

  const addOwn = async (
    profileId: unknown,
    kind: 'folder' | 'crx',
  ): Promise<ExtensionResult> => {
    if (store === null) return NO_STORE
    const choose = kind === 'folder' ? chooseFolder : chooseCrx
    let chosen: string | null
    try {
      chosen = await choose()
    } catch (error) {
      return {
        ok: false,
        message: `That could not be chosen: ${error instanceof Error ? error.message : 'the dialog did not open'}.`,
      }
    }
    /*
     * Cancelling is not an error and must not read as one. `ok: true` with an
     * empty message: the panel prints nothing, the row does not turn red, and
     * nobody is told something failed because they changed their mind.
     */
    if (chosen === null) return { ok: true, message: '' }
    const profile = profileOf(profileId)
    const result = kind === 'folder' ? store.addFolder(profile, chosen) : store.addCrx(profile, chosen)
    if (!result.ok) return result
    /*
     * Loaded straight away, and the same order the catalogue install uses: the
     * old copy is unloaded only after the new files are down, because adding the
     * same folder again is a replace and anything running at this point is the
     * previous build of it.
     */
    const id = sideloadId(kind, chosen)
    unloadOne(profile, id)
    const extension = store.installed(profile).find((one) => one.entry.id === id)
    if (extension === undefined) return result
    const electronId = await loadOne(profile, extension)
    if (electronId === '') {
      const why = loadFailures.get(profile)?.get(id) ?? 'the browser refused it'
      return {
        ok: false,
        message: `${extension.entry.name} was copied in but the browser would not load it: ${why}. It is switched off.`,
      }
    }
    return result
  }

  ipcMain.handle('browser-extension:add-folder', async (_event, profileId: unknown) =>
    addOwn(profileId, 'folder'),
  )
  ipcMain.handle('browser-extension:add-crx', async (_event, profileId: unknown) =>
    addOwn(profileId, 'crx'),
  )
}

/** Where a profile's extensions live, for a sentence on a panel. */
export function extensionFolderFor(profileId: string): string {
  return userDataDir === '' ? '' : (profileExtensionsRoot(userDataDir, profileId) ?? '')
}
