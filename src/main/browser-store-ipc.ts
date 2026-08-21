import type { IpcMain } from 'electron'
import { BROWSER_TOOL_CATALOGUE } from './browser-store-catalogue'
import {
  createToolStore,
  orphanIds,
  storeRoot,
  type InstalledTool,
  type StoreResult,
  type StoreView,
  type ToolStore,
} from './browser-store'

/**
 * The store's three channels, and the one function the tool layer reads.
 *
 * ## Why three invokes and no push
 *
 * Downloads pushes because a row moves on every chunk of a file with nobody
 * touching anything. A store row changes only when somebody presses Install or
 * Remove *in this panel*, so the panel already knows, and it re-reads. A push
 * channel with nothing on the far end that ever fires it is the shape of dead
 * wiring this app's contract test exists to catch, and there is no honest event
 * to hang one on.
 *
 * ## Why the store is built here rather than in `index.ts`
 *
 * The same seam every other browser feature uses: `index.ts` knows where
 * `userData` is and nothing else about this, and everything testable lives on
 * the other side of the call. `browser-store.ts` takes a root and a catalogue
 * and touches no Electron at all, which is why its tests need no app.
 */

let store: ToolStore | null = null
let root = ''

export interface BrowserStoreDeps {
  /** `app.getPath('userData')`, read per call for the same reason downloads does. */
  userData(): string
}

/** Build the store. Called once from `registerIpc()`, before the panel can ask. */
export function installBrowserStore(deps: BrowserStoreDeps): ToolStore {
  root = storeRoot(deps.userData())
  store = createToolStore({ root, catalogue: BROWSER_TOOL_CATALOGUE })
  return store
}

/**
 * Every installed, verified tool — or none, when the store was never built.
 *
 * The empty answer is deliberate and it is not a silent failure: `browser.extract`
 * with nothing installed says so in a sentence naming where to install one, so a
 * build whose wiring order changed underneath this costs the store its tools
 * visibly rather than taking a launch down. The same judgement `browserDriveTools`
 * makes about the drive.
 */
export function installedBrowserTools(): InstalledTool[] {
  return store?.installed() ?? []
}

/** Test seam and shutdown: forget the store this run built. */
export function resetBrowserStore(): void {
  store = null
  root = ''
}

const NO_STORE: StoreResult = {
  ok: false,
  message: 'The tools store is not available in this build.',
}

const EMPTY: StoreView = { tools: [], folder: '' }

/**
 * Wire the store.
 *
 * Channels:
 * - `browser-store:list`    (invoke)     → `{ view, orphans }`
 * - `browser-store:install` (invoke, id) → `{ ok, message }`
 * - `browser-store:remove`  (invoke, id) → `{ ok, message }`
 */
export function registerBrowserStoreIpc(ipcMain: IpcMain): void {
  ipcMain.handle('browser-store:list', () => ({
    view: store?.view() ?? EMPTY,
    /*
     * Directories with no catalogue row — a tool withdrawn from the app between
     * releases. Reported so the panel can offer a Remove for them, because a
     * file this app wrote and can no longer name is a file nobody has any way to
     * delete except by hand.
     */
    orphans: store === null ? [] : orphanIds(root, BROWSER_TOOL_CATALOGUE),
  }))
  ipcMain.handle('browser-store:install', async (_event, id: unknown) =>
    store === null || typeof id !== 'string' ? NO_STORE : store.install(id),
  )
  ipcMain.handle('browser-store:remove', (_event, id: unknown) =>
    store === null || typeof id !== 'string' ? NO_STORE : store.remove(id),
  )
}
