import { homedir } from 'node:os'
import { app, type IpcMain } from 'electron'
import { storeKeysFor } from '../shared/store-key'
import {
  machineProbe,
  projectView,
  type CommunityViewOut,
  type MachineProbe,
} from './community-view'
import {
  agentHomes,
  createStoreInstaller,
  itemsDir,
  type InstallChoice,
  type StoreInstaller,
  type StoreResult,
  type StoreView,
} from './store-install'

/**
 * The community store's three channels, and the one function the app calls to
 * build it.
 *
 * ## Why three invokes and no push
 *
 * The same argument `browser-store-ipc.ts` makes for the tool store, and it
 * holds here for the same reason: a row in this shelf changes only when somebody
 * presses Install or Remove *in the panel that is already on screen*, so that
 * panel re-reads. A push channel with nothing on the far end that ever fires it
 * is the dead wiring this app's contract test exists to catch.
 *
 * There is no separate `refresh` either. `community:list` fetches the catalogue
 * every time it is called and falls back to the kept copy when the store cannot
 * be reached — so a Refresh button is `community:list` again, and a second
 * channel doing exactly what the first one does is two names for one behaviour
 * that will eventually disagree.
 *
 * ## Why the store is built here rather than in `index.ts`
 *
 * `index.ts` knows where `userData` is and which base to point at, and nothing
 * else about this. Everything testable lives on the other side of this call:
 * `store-install.ts` takes a directory and a fetcher and imports no Electron,
 * which is why its tests need no app and why the headless host can take the same
 * engine when the phone half is built.
 */

let store: StoreInstaller | null = null
let where = ''

export interface CommunityStoreDeps {
  /** `app.getPath('userData')`, read per call the way every other store reads it. */
  userData(): string
  /**
   * Where the catalogue lives, resolved per call rather than cached.
   *
   * Per call because the base is an environment question and a settings
   * question, and a value read once at launch means changing it takes effect on
   * the next launch rather than on the next press.
   */
  base(): string
}

/**
 * Build the store. Called once from `registerIpc()`, before the panel can ask.
 *
 * The keys are decided here because this is the one place in the chain that
 * can ask Electron whether this is a packaged build — `store-install.ts` and
 * `store-index.ts` import no Electron, on purpose, and left to themselves they
 * believe the two slots and nothing else. `storeKeysFor` adds the development
 * key only for an unpackaged run that was started with
 * `TERMINALDECK_STORE_DEV_KEY=1`, which is what the site repository's local
 * preview catalogue is signed with. Read once, at launch, like the variable
 * beside it is typed: a key this run believes does not change under it.
 */
export function installCommunityStore(deps: CommunityStoreDeps): StoreInstaller {
  where = itemsDir(deps.userData())
  store = createStoreInstaller({
    userData: deps.userData,
    base: deps.base,
    keys: storeKeysFor({ env: process.env, packaged: app.isPackaged }),
  })
  return store
}

/** Test seam and shutdown: forget the store this run built. */
export function resetCommunityStore(): void {
  store = null
  where = ''
}

const NO_STORE: StoreResult = {
  ok: false,
  message: 'The community store is not available in this build.',
}

/** The honest empty answer: no list, and a sentence saying why rather than a blank shelf. */
function emptyView(): StoreView {
  return {
    ok: false,
    why: 'The community store is not available in this build.',
    items: [],
    from: null,
    at: null,
    stale: null,
    because: null,
    homes: agentHomes(process.env, homedir()),
    folder: where,
  }
}

/**
 * The machine probe, made once per run.
 *
 * Once because `loginPath()` spawns the user's login shell and reads their whole
 * rc file, and a probe minted per call would do that on every press of the
 * department. `agent-binaries.ts` already memoises its own answers on the same
 * argument.
 */
let probe: MachineProbe | null = null

/** Test seam: forget what this run measured about the machine. */
export function resetCommunityProbe(): void {
  probe = null
}

/**
 * Wire the store.
 *
 * Channels:
 * - `community:list`    (invoke)            → the whole view, list and state
 * - `community:install` (invoke, id, choice) → `{ ok, message }`
 * - `community:remove`  (invoke, id)         → `{ ok, message }`
 */
export function registerCommunityIpc(ipcMain: IpcMain, deps?: CommunityStoreDeps): void {
  ipcMain.handle('community:list', async (): Promise<CommunityViewOut> => {
    const view = store === null ? emptyView() : await store.view()
    probe ??= machineProbe()
    /*
     * The screen is handed flat facts, not the installer's own shape.
     *
     * `community-view.ts` says why the translation is here and not in the
     * renderer: which agent tools are on this machine, which of an item's needs
     * are not, and the exact folders an install writes into are all questions
     * only this process can answer, and a screen that answered them itself would
     * be a second opinion built from less evidence.
     */
    return await projectView(view, deps?.userData() ?? '', probe)
  })

  ipcMain.handle('community:install', async (_event, id: unknown, choice: unknown) => {
    if (store === null || typeof id !== 'string') return NO_STORE
    return await store.install(id, readChoice(choice))
  })

  ipcMain.handle('community:remove', async (_event, id: unknown) =>
    store === null || typeof id !== 'string' ? NO_STORE : await store.remove(id),
  )
}

/**
 * Whatever crossed the bridge, read as a choice — or as no choice at all.
 *
 * Everything from the renderer is `unknown` on this side and is treated that
 * way, which is the rule `mcp-add.ts` states for its own request. Nothing here
 * can widen what an install does: the agents are filtered against what the item
 * itself claims, the values only ever fill placeholders the manifest declared,
 * and the folder is a path this app writes a routine's own `in:` line with.
 */
export function readChoice(raw: unknown): InstallChoice {
  if (typeof raw !== 'object' || raw === null) return {}
  const input = raw as Record<string, unknown>
  const choice: InstallChoice = {}

  if (Array.isArray(input.agents)) {
    choice.agents = input.agents.filter((entry): entry is string => typeof entry === 'string')
  }
  if (typeof input.folder === 'string') choice.folder = input.folder
  if (typeof input.values === 'object' && input.values !== null && !Array.isArray(input.values)) {
    const values: Record<string, string> = {}
    for (const [key, value] of Object.entries(input.values as Record<string, unknown>)) {
      if (typeof value === 'string') values[key] = value
    }
    choice.values = values
  }
  return choice
}
