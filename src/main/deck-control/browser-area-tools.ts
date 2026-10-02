import { existsSync, statSync } from 'node:fs'
import { app, safeStorage } from 'electron'
import { openBarePane, knownWindows, bindWindow, unbindWindow } from '../browser-binding-ipc'
import { ownerOf, slotName, windowNamed } from '../browser-binding'
import type { BrowserDrive } from '../browser-driver'
import { readBlockCapture, setBlockCapture } from '../browser-block-capture'
import { chooseDownloadFolder, openDownload, revealDownload } from '../browser-downloads-electron'
import {
  cancelDownload,
  clearDownloads,
  downloadsView,
  setDownloadDestination,
} from '../browser-downloads-store'
import {
  addOwnExtension,
  extensionListFor,
  installExtension,
  openExtensionWindow,
  profileNameFor,
  reloadOwnExtension,
  removeExtension,
  renameOwnExtension,
} from '../browser-extensions-ipc'
import { allVisits, clearHistory, forgetVisit, historyFor, suggestFor } from '../browser-history'
import { isolatedSessionCount } from '../browser-isolation'
import { listLiftRequests } from '../browser-lift-requests'
import {
  answerPendingOffer,
  forgetAllLogins,
  forgetLogin,
  loginSummariesFor,
  pendingOffer,
  revealLoginsFile,
  storeState,
  summarizeLogin,
} from '../browser-passwords'
import {
  activateProfile,
  createProfile,
  deleteProfile,
  profileState,
  renameProfile,
  setProfileAvatar,
} from '../browser-profiles'
import type { ReachLedger } from '../browser-reach'
import {
  clearScrapeCapture,
  clearScrapeLedgers,
  revealScrapeCapture,
  scrapingConfig,
  scrapingStatus,
  setScrapingConfig,
} from '../browser-scraping-ipc'
import {
  browserCookieDomains,
  browserSessionInfo,
  clearBrowserCache,
  clearBrowserCookies,
  clearBrowserStorage,
} from '../browser-session'
import { forgetLift, liftSummaries } from '../browser-session-lift'
import { diagnoseSignIn, handOverSignIn, staleAgentCli } from '../browser-signin'
import { browserStoreInstall, browserStoreList, browserStoreRemove } from '../browser-store-ipc'
import {
  browserTabProfile,
  browserTabState,
  fillSavedLogin,
  navigateBrowserTab,
  setBrowserTabInspecting,
  signInOffer,
  steerBrowserTab,
  stopBrowserTab,
} from '../browser-tab'
import {
  browserViewRecording,
  clearBrowserViewRecording,
  findInBrowserView,
  printBrowserView,
  revealBrowserScreenshot,
  setBrowserViewRecording,
  setBrowserViewUserAgent,
  stopFindInBrowserView,
  toggleBrowserViewDevtools,
  zoomBrowserView,
} from '../browser-view'
import { cleanPace, paceNote, type PaceSettings } from '../browser-worker-pool'
import {
  ensureWorkers,
  MAX_WORKER_COUNT,
  registerWorker,
  setWorkerPace,
  unregisterWorker,
  workerList,
  workerPace,
} from '../browser-workers'
import { detectBrowsers, scanForDevUrls } from '../chrome-import'
import {
  clearImportedCookies,
  cookieImportStatus,
  importCookies,
  listCookieSources,
} from '../cookie-import'
import { communityInstall, communityRemove, communityView, type CommunityStoreDeps } from '../store-install-ipc'
import { dataTools, importTools } from './browser-data-tools'
import { downloadTools } from './browser-download-tools'
import type { ExtensionToolDeps } from './extension-tools'
import { historyTools, profileTools } from './browser-history-tools'
import { passwordTools } from './browser-password-tools'
import { scrapingTools } from './browser-scraping-tools'
import { signInTools } from './browser-signin-tools'
import { windowTools, type WindowToolDeps } from './browser-window-tools'
import type { ToolSpec } from './catalogue'
import { communityTools } from './community-tools'
import { toolsStoreTools } from './tools-store-tools'

/**
 * Every 0.16.0 browser tool, wired to the functions the browser's own controls
 * call — so `src/main/index.ts` needs one spread in `extraTools` and nothing
 * else.
 *
 * ## Why this file exists rather than eleven blocks in `index.ts`
 *
 * The repository's rule for parallel work: a lane does not edit `index.ts`, it
 * hands back the smallest wiring it can. Each tool factory takes plain-function
 * deps so it can be tested with no Electron; this is the one place those deps
 * are closed over the real modules, and every line here is a call into an
 * exported function that the corresponding `ipcMain.handle` also calls. Where a
 * handler used to do its work inline, the work was moved out into that module
 * and the handler now calls it — never copied here.
 *
 * ## What `index.ts` still has to hand over
 *
 * Four things only it holds: how to push to the window (`send`, for opening a
 * pane), the drive (published after this is composed, so read per call — the
 * argument `machineBrowserHere` makes about `pick`), the reach ledger, and how
 * to tell which machine a session runs on. See {@link BrowserAreaWiring}.
 */

export interface BrowserAreaWiring {
  /** `send` in `index.ts` — the one sender, so a pane opens in the one window. */
  send(channel: string, payload: unknown): void
  /** `browserDrive()`, read per call. Null in a build whose browser never came up. */
  drive(): BrowserDrive | null
  /** The reach ledger `registerBrowserReachIpc` returned, read per call. */
  reach(): ReachLedger | null
  /** `machineOfSession` in `index.ts`: `''` for this Mac, a machine id, or null for no such session. */
  machineOfSession(sessionId: string): string | null
  /** The community store's deps, as `registerCommunityIpc` was given them. */
  community?: CommunityStoreDeps
}

const userData = (): string => app.getPath('userData')

/** The windows half, over `knownWindows`, the binding map and the drive. */
export function windowDeps(wiring: BrowserAreaWiring): WindowToolDeps {
  const slotOf = (tabId: string): { sessionId: string; machineId: string; slot: string } | null => {
    const binding = ownerOf(tabId)
    const window = binding?.windows.find((one) => one.browserTabId === tabId)
    if (!binding || !window) return null
    return { sessionId: binding.sessionId, machineId: binding.machineId, slot: slotName(window.n) }
  }
  const noDrive = (): never => {
    throw new Error('this app has no browser running')
  }
  return {
    windows: () =>
      knownWindows().map((window) => ({
        tabId: window.tabId,
        viewId: window.viewId,
        url: window.url,
        title: window.title,
        w: window.w,
        visible: window.visible,
        servedBy: window.machineId === '' ? '' : window.machineName || window.machineId,
      })),
    attachedTo: slotOf,
    slotWindow: (sessionId, slot) => windowNamed(sessionId, slot)?.browserTabId ?? null,
    page: (viewId) => {
      const state = browserTabState(viewId)
      if (state === null) return null
      return {
        url: state.url,
        title: state.title,
        loading: state.loading,
        canGoBack: state.canGoBack,
        canGoForward: state.canGoForward,
        zoom: state.zoom,
        error: state.error,
        inspecting: state.inspecting,
      }
    },
    profileOf: (viewId) => {
      const profileId = browserTabProfile(viewId)
      if (profileId === null) return null
      return profileId === '' ? '' : profileNameFor(profileId)
    },
    recording: (viewId) => {
      try {
        return browserViewRecording(viewId)
      } catch {
        return null
      }
    },
    isolatedCount: () => isolatedSessionCount(),
    drive: () => {
      const status = wiring.drive()?.status()
      return status === undefined ? null : { state: status.state, viewId: status.tabId, step: status.step }
    },
    ownView: () => wiring.drive()?.ownView() ?? null,
    driving: () => wiring.drive()?.driving() ?? [],
    open: (url) => openBarePane((channel, payload) => wiring.send(channel, payload), url),
    close: async (target) => (wiring.drive() ?? noDrive()).close(target),
    session: (sessionId) => {
      const machineId = wiring.machineOfSession(sessionId)
      return machineId === null ? null : { machineId }
    },
    attach: (input) => {
      const window = bindWindow(input)
      return window === null ? null : slotName(window.n)
    },
    detach: (tabId) => unbindWindow(tabId),
    reach: {
      list: () => wiring.reach()?.list() ?? [],
      hold: async (holder, machine, port) => {
        const ledger = wiring.reach()
        if (ledger === null) {
          return { answer: { ok: false, message: 'This build cannot reach another machine.' }, stranded: null }
        }
        return ledger.hold(holder, machine, port)
      },
      release: (holder, machineId, port) =>
        wiring.reach()?.release(holder, machineId, port) ?? {
          gone: false,
          holders: 0,
          message: 'This build cannot reach another machine.',
        },
    },
    navigate: (viewId, url) => {
      navigateBrowserTab(viewId, url)
    },
    steer: (viewId, move) => {
      steerBrowserTab(viewId, move)
    },
    stop: (viewId) => {
      stopBrowserTab(viewId)
    },
    zoom: (viewId, factor) => zoomBrowserView(viewId, factor),
    find: (viewId, text, options) => findInBrowserView(viewId, text, options),
    findStop: (viewId, keep) => stopFindInBrowserView(viewId, keep),
    print: (viewId) => printBrowserView(viewId),
    devtools: (viewId) => toggleBrowserViewDevtools(viewId),
    userAgent: (viewId, ua) => setBrowserViewUserAgent(viewId, ua),
    // `announce`: the toolbar's picker button has no call of its own waiting on this.
    inspect: (viewId, on) => {
      setBrowserTabInspecting(viewId, on, true)
    },
    record: (viewId, on) => setBrowserViewRecording(viewId, on),
    recordClear: (viewId) => clearBrowserViewRecording(viewId),
    screenshot: (target) => (wiring.drive() ?? noDrive()).screenshot(target),
    releaseWindow: (tabId) => wiring.drive()?.releaseWindow(tabId),
    reveal: (path) => revealBrowserScreenshot(path),
  }
}

/**
 * The extension store's other buttons, for the `extensionTools({...})` call
 * `index.ts` already makes. Spread into it; see `WIRING-browser.md`.
 */
export function extensionManageDeps(): Pick<
  ExtensionToolDeps,
  'catalogue' | 'install' | 'remove' | 'reload' | 'rename' | 'openWindow' | 'addOwn' | 'profiles'
> {
  return {
    catalogue: (profileId) => extensionListFor(profileId).view.extensions,
    install: (profileId, id) => installExtension(profileId, id),
    remove: (profileId, id) => removeExtension(profileId, id),
    reload: (profileId, id) => reloadOwnExtension(profileId, id),
    rename: (profileId, id, name) => renameOwnExtension(profileId, id, name),
    openWindow: (profileId, id, which) => openExtensionWindow(profileId, id, which),
    addOwn: (profileId, kind) => addOwnExtension(profileId, kind),
    profiles: () => profileState(userData()).profiles.map((profile) => ({ id: profile.id, name: profile.name })),
  }
}

/** Is this file marked executable? False when it cannot be read — the caller treats that as "ask". */
function executableBit(path: string): boolean {
  try {
    return existsSync(path) && (statSync(path).mode & 0o111) !== 0
  } catch {
    return false
  }
}

export function browserAreaTools(wiring: BrowserAreaWiring): ToolSpec[] {
  const windows = windowDeps(wiring)
  const profiles = (): ReturnType<typeof profileState> => profileState(userData())

  return [
    ...windowTools(windows),

    ...downloadTools({
      view: () => downloadsView(),
      cancel: (id) => cancelDownload(id),
      clear: () => clearDownloads(),
      open: (id) => openDownload(id),
      reveal: (id) => revealDownload(id),
      setDestination: (destination) => setDownloadDestination(destination),
      chooseFolder: () => chooseDownloadFolder(),
      executableBit,
    }),

    ...historyTools({
      profiles,
      list: (profileId, query, limit) => historyFor(allVisits(userData()), profileId, query, limit),
      suggest: (profileId, typed) => suggestFor(allVisits(userData()), profileId, typed),
      forget: (profileId, url) => historyFor(forgetVisit(userData(), profileId, url), profileId),
      clear: (profileId) => historyFor(clearHistory(userData(), profileId), profileId),
    }),

    ...profileTools({
      state: profiles,
      create: (name) => createProfile(userData(), name ?? undefined),
      rename: (id, name) => renameProfile(userData(), id, name),
      avatar: (id, avatar) => setProfileAvatar(userData(), id, avatar),
      activate: (id) => activateProfile(userData(), id),
      remove: (id) => deleteProfile(userData(), id),
    }),

    ...passwordTools({
      available: () => safeStorage.isEncryptionAvailable(),
      state: () => storeState(userData()),
      profiles,
      list: (profileId) => loginSummariesFor(userData(), profileId),
      forget: (profileId, origin, username) => forgetLogin(userData(), profileId, origin, username),
      forgetAll: () => forgetAllLogins(userData()),
      reveal: () => revealLoginsFile(userData()),
      offer: () => {
        const offer = pendingOffer()
        return offer === null ? null : summarizeLogin(offer)
      },
      answer: (save) => answerPendingOffer(userData(), save),
      signInOffer: (viewId) => signInOffer(viewId),
      fill: (viewId, username) => fillSavedLogin(viewId, username),
      windows,
    }),

    ...dataTools({
      profiles,
      info: (profileId) => browserSessionInfo(profileId),
      cookies: (profileId) => browserCookieDomains(profileId),
      clearCookies: (site, profileId) => clearBrowserCookies(site, profileId),
      clearStorage: (site, profileId) => clearBrowserStorage(site, profileId),
      clearCache: (profileId) => clearBrowserCache(profileId),
    }),

    ...importTools({
      browsers: () => detectBrowsers(),
      sources: () => listCookieSources(),
      status: () => cookieImportStatus(),
      run: (request) => importCookies(request),
      clear: () => clearImportedCookies(),
      scan: (request) => scanForDevUrls(request),
    }),

    ...signInTools({
      diagnose: (url) => diagnoseSignIn(url),
      handover: (url) => handOverSignIn(url),
      agents: () => staleAgentCli(),
    }),

    ...scrapingTools({
      profiles,
      config: (profileId) => scrapingConfig(userData(), profileId),
      setConfig: (profileId, patch) => setScrapingConfig(userData(), profileId, patch),
      status: (profileId) => scrapingStatus(userData(), profileId),
      clearCapture: (profileId) => clearScrapeCapture(userData(), profileId),
      revealCapture: (profileId) => revealScrapeCapture(userData(), profileId),
      clearLedgers: (profileId) => clearScrapeLedgers(userData(), profileId),
      blockShots: (profileId) => readBlockCapture(userData(), profileId),
      setBlockShots: (profileId, on) => setBlockCapture(userData(), profileId, on),
      workers: () => workerList(userData()).map((worker) => ({ profileId: worker.profileId, name: worker.name })),
      maxWorkers: MAX_WORKER_COUNT,
      ensureWorkers: (count) => ensureWorkers(userData(), count),
      addWorker: (profileId) => registerWorker(userData(), profileId),
      removeWorker: (profileId) => unregisterWorker(userData(), profileId),
      setPace: (raw: Partial<PaceSettings>) => {
        const stored = setWorkerPace(userData(), raw)
        // The clamp is said rather than applied in silence, exactly as
        // `browser-worker:pace` says it to the panel.
        return { pace: stored, note: paceNote(raw, cleanPace(raw)) }
      },
      pace: () => workerPace(userData()),
      liftRequests: () => listLiftRequests(),
      lifts: () => liftSummaries(),
      forgetLift: (id) => forgetLift(id),
    }),

    ...toolsStoreTools({
      list: () => browserStoreList(),
      install: (id) => browserStoreInstall(id),
      remove: (id) => browserStoreRemove(id),
    }),

    ...communityTools({
      view: () => communityView(wiring.community),
      install: (id, choice) => communityInstall(id, choice),
      remove: (id) => communityRemove(id),
    }),
  ]
}
