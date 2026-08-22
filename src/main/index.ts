import { existsSync, mkdirSync } from 'node:fs'
import { basename, join } from 'node:path'
import {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  nativeTheme,
  powerMonitor,
  session,
  shell,
} from 'electron'
import { BRAND } from '../shared/brand'
import type { CreateSessionInput, SessionMeta } from '../shared/types'
import { createHostCore } from './host-core'
import { detectProviders } from './providers'
import { lookupCommand, registerCustomAgentsIpc } from './custom-agents'
import { currentPlatform } from './platform/host'
import { electronPaths, installPaths } from './platform/paths'
/*
 * Quitting no longer means "kill everything", and this module is where that
 * decision and its honesty live. See its header for the rule the feature
 * follows: a session belongs to the machine it runs on, not to the app window.
 */
import {
  ProcessKeepAlive,
  QUIT_BUTTONS,
  ResidentPresence,
  needsTrayToBeVisible,
  plannedQuit,
  quitAnswer,
  quitQuestion,
} from './resident'
/*
 * The held list travels on a channel named in the module that owns it — see
 * `SESSIONS_HELD_CHANNEL` there for why it is exported rather than declared
 * beside the handler down in this file, which is a fact about
 * `preload/contract.test.ts` as much as about the house rule.
 */
import { savedFrom, SESSIONS_HELD_CHANNEL } from './session-held'
import {
  personalSessions,
  restoreOpenSessions,
  type RestoreDecision,
} from './session-restore'
import { store, type Preferences } from './store'
import { pickerStartDirectory } from './project-picker'
import { pinUserData } from './user-data'
import { refreshCostWatchers, registerCostIpc } from './cost-ipc'
import { registerGitIpc, stopAllGitWatches } from './git'
import { registerFsIpc } from './fs-tree'
import { registerSearchIpc } from './file-search'
import { registerInsightsIpc } from './session-insights'
import { registerChatIpc } from './chat-transcript'
import { registerDevPortsIpc } from './dev-ports'
import {
  createDevServers,
  registerDevServerIpc,
  DEV_SERVER_STATE_CHANNEL,
  type DevServerState,
} from './dev-server'
import { autoUpdater } from 'electron-updater'
import { registerAgentControlsIpc } from './agent-controls'
import { registerVoiceIpc } from './voice'
import { registerUpdateIpc } from './updates/updater'
import { createManualStrategy } from './updates/manual-strategy'
import { registerTailnetIpc } from './remote/tailnet'
import { registerRemoteIpc } from './remote/server'
import { registerConfineIpc } from './confine/ipc'
import { CopilotAccess } from './remote/copilot-access'
import { CopilotRuns } from './remote/copilot-runs'
import { typeAndSubmit } from './remote/copilot-say'
import {
  startCopilotRun,
  tailForPhone,
  toCopilotSessions,
  watchRunChat,
} from './remote/copilot-wiring'
import { registerMachinesIpc, type MachinesIpc } from './remote/machines/ipc'
import { serveWindowCall } from './remote/machines/window-serve'
import { createWindowAsks } from './remote/window-asks'
import { routeWindowVerb, type WindowRoute } from './window-owner'
import { registerServersIpc, type ServersIpc } from './servers/ipc'
import { findHostPackage } from './servers/host-package'
import { registerServerReachIpc, type ServerReachIpc } from './servers/reach'
import { registerBrowserReachIpc, type ReachLedger } from './browser-reach'
import { ServerStore } from './servers/store'
import { ServerCredentials } from './servers/credentials'
import { ServerConnections } from './servers/connection'
import { serverTools } from './servers/tools'
import {
  dropPlanSession,
  notePlanOutput,
  notePlanResize,
  registerPlanLimitIpc,
} from './plan-limit'
import { dropUsageSession, registerUsageIpc } from './usage-ipc'
import { dropSessionAccount, registerSessionAccountIpc } from './session-account'
import { storedAccountLimits } from './account-limits'
import { registerGitHubIpc } from './github'
import { registerReadinessIpc } from './readiness'
import { registerDashboardIpc } from './dashboard-store'
import { registerArtifactsIpc } from './artifacts'
import { registerSessionSearchIpc } from './session-search'
import { registerAlertsIpc } from './alerts'
import { registerProfilesIpc, getState as profilesState } from './profiles'
/*
 * Switching the account a *running* session is on. The channels are named in
 * the module that owns the feature, for the same two reasons the held list's is
 * — the house rule, and `preload/contract.test.ts`, which can only resolve a
 * channel registered through an exported constant.
 */
import { SESSION_SWITCH_CHANNEL, SESSION_SWITCH_PLAN_CHANNEL } from './session-switch'
/*
 * The operations behind those channels — the switch itself, and the sign-in
 * that opens a terminal. In their own module because the headless build hands
 * the very same functions to its core; see `session-switch-run.ts`.
 */
import { createSessionSwitch, savedPlanner } from './session-switch-run'
/*
 * The same switch, deferred to the next message he sends. Kept in its own
 * module because the part that is hard is not the switch — that is the one
 * above — it is carrying the half-typed line across the restart.
 */
import {
  armedNote,
  PendingSwitches,
  replayWrites,
  REPLAY_SETTLE_MS,
  REPLAY_SUBMIT_GAP_MS,
  SESSION_SWITCH_ARMED_CHANNEL,
  SESSION_SWITCH_CANCEL_CHANNEL,
  SESSION_SWITCH_FAILED_CHANNEL,
  SESSION_SWITCH_LATER_CHANNEL,
  SESSION_SWITCHED_CHANNEL,
  switchedNote,
  type ArmedSwitch,
} from './switch-later'
import { adoptSharedHistory, registerSharedProjectsIpc } from './shared-projects'
import { registerSignInIpc } from './profiles-signin'
import { copilotState, registerCopilotIpc } from './copilot-session'
import { appendCopilotAction, copilotPaths } from './copilot-home'
import { COPILOT_HOME_SETTING, registerCopilotFolderIpc } from './copilot-folder'
import { registerCopilotInspectIpc } from './copilot-inspect'
import { registerDeckControlIpc, type DeckControlHandle } from './deck-control'
import { createSessionTools, type SessionTools } from './deck-control/session-tools'
import { registerDeckignoreIpc } from './deckignore'
import { defaultContext, registerHooksIpc, syncInstalledHooks } from './hooks'
import {
  currentHookEndpoint,
  hookConfigPath,
  registerHookServer,
  stopHookServer,
} from './hook-server'
import { registerMcpIpc } from './mcp-client'
import { registerStageIpc } from './local-stage'
import { registerBrowserIpc } from './browser-tab'
import { openAppLink, registerLinkIpc } from './link-open'
import {
  registerBrowserBindingIpc,
  openForSession,
  forgetKnownWindows,
  openBarePane,
  paneIsFree,
  paneView,
} from './browser-binding-ipc'
import { registerSessionRowMenuIpc } from './session-row-menu'
import {
  hookContext,
  hostReset,
  MID_TURN_EVENTS,
  sessionExited,
  sessionRemoved,
  subscribe as subscribeToBindings,
  takeAnnouncement,
  view as bindingView,
  windowsOf,
} from './browser-binding'
import { noVerbsLine } from './session-verbs'
import { currentOpenShim, removeOpenShim, writeOpenShim } from './open-shim'
import { bootMapFor, composeRemoteContext, writeAppContext } from './app-context'
import { describeThisMachine } from './remote/machines/guest'
import { browserDrive, registerBrowserDriveIpc } from './browser-drive-ipc'
import { browserNetworkTool } from './deck-control/browser-network-tool'
import { assetTools } from './deck-control/asset-tools'
import { probeAsset } from './browser-asset-probe'
import { assetFetchFor } from './browser-asset-session'
import {
  installBrowserStore,
  installedBrowserTools,
  registerBrowserStoreIpc,
} from './browser-store-ipc'
import { storeTools } from './deck-control/store-tools'
import { extensionTools } from './deck-control/extension-tools'
import {
  currentProfileId as currentBrowserProfileId,
  installBrowserExtensions,
  installedExtensionsFor,
  isLoaded as isExtensionLoaded,
  loadInstalledExtensions,
  profileNameFor as browserProfileNameFor,
  registerBrowserExtensionIpc,
  setExtensionEnabled,
} from './browser-extensions-ipc'
import { browserTools, type VerbForwarder } from './deck-control/browser-tools'
import { registerChromeImportIpc } from './chrome-import'
import { registerPrerequisitesIpc } from './prerequisites'
import { registerAttachBringInIpc } from './attach-bring-in'
import { registerAttachOutsideIpc } from './attach-outside'
import { boundaryFor } from './session-boundary'
import {
  registerSettingsIpc,
  clearBrowserDataIfNotPersisting,
  patchStoredSettings,
  storedValue,
  REMOTE_ENABLED_KEY,
} from './settings-extra'
import { registerBrowserSessionIpc } from './browser-session'
import { registerBrowserProfileIpc } from './browser-profiles'
import { leaseForCaller, registerBrowserWorkerIpc, workerOfView } from './browser-workers-ipc'
import { registerBrowserScrapingIpc } from './browser-scraping-ipc'
import { releaseWorker, renewWorker, workerList, workerPace, workerStatus } from './browser-workers'
import { injectionsFor } from './browser-session-lift'
import { workerTools } from './deck-control/worker-tools'
import {
  DOWNLOADS_CHANNEL,
  installDownloads,
  registerBrowserDownloadIpc,
  setDownloadWindow,
} from './browser-downloads'
import { registerBrowserPasswordIpc } from './browser-passwords'
import { flushHistory, registerBrowserHistoryIpc } from './browser-history'
import { registerBrowserSignInIpc } from './browser-signin'
import { registerBrowserViewIpc } from './browser-view'
import { registerDiagnosticsIpc } from './diagnostics'
import { registerNotificationIpc } from './os-notifications'
import { registerLidAwakeIpc } from './lid-awake'
import { logger } from './app-log'
import { registerLogIpc } from './app-log-ipc'
import { SESSION_REMOVED_CHANNEL } from './live-push'
import { traceIpc, TRACE_SETTING } from './ipc-trace'
import { buildMenu, hidesMenuBar } from './menu'
import { overlayFor, resolveAppearance, titleBarChrome, type Appearance } from './title-bar'
import { registerSetupIpc } from './setup'
import { registerCookieImportIpc } from './cookie-import'
import { registerBrowserIsolationIpc } from './browser-isolation'
import { distroPlacement } from './wsl-reach'
import { startedAsWslBridge } from './wsl-bridge'
import { linuxPathFromUnc, registerWslIpc } from './wsl'
import { createRoutines, registerRoutinesIpc } from './routines'
import { DEFAULT_GLOBAL_MAX_RUNS_PER_HOUR } from './routines/engine'
import type { SessionStatus } from '../shared/types'

/*
 * Say which shell this is, and pin the directory — both before any other line of
 * this module runs.
 *
 * These sat at the bottom of the file while everything that reads a path was
 * lazy. They cannot stay there now: `createHostCore` below is constructed at
 * module scope and its `FolderGrants` reads its file in its constructor, so a
 * pin that happened afterwards would have the grants loaded from the *unpinned*
 * directory — the "renaming the app silently moved everyone's data" failure that
 * `user-data.ts` exists to close, arriving through a different door.
 *
 * The store, the profiles, the log and the trust store all reach for
 * `platform/paths.ts`, which has no default and throws if nothing installed one
 * — see the header there for why a default would be worse than a crash. This is
 * the Electron answer; `src/headless/daemon.ts` installs the plain-Node one.
 *
 * `electronPaths` forwards on every call rather than capturing, which is what
 * lets `pinUserData` move the directory on the next line and still be obeyed.
 * Both are safe before `whenReady`: `getPath('userData')` and `setPath` do not
 * need a ready app.
 */
installPaths(electronPaths(app))
pinUserData(app)

const isDev = !!process.env.ELECTRON_RENDERER_URL

let mainWindow: BrowserWindow | null = null

/**
 * Content Security Policy, set here rather than in index.html.
 * Vite's dev server injects an inline module preamble that a strict
 * `script-src 'self'` blocks — which makes the React plugin throw and the
 * window render blank. Dev therefore permits inline/eval; production does not.
 */
function applySecurityPolicy(): void {
  const policy = isDev
    ? "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data:; connect-src 'self' ws: http://localhost:*"
    : "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data:; connect-src 'self'"

  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [policy],
      },
    })
  })
}

/**
 * True from the moment the app starts going away.
 *
 * Set before anything in `before-quit` does its work, because the first thing
 * that happens there is `ptys.killAll()` — and killing a PTY *generates*
 * traffic: the process flushes, `onData` fires, `onExit` fires, and
 * `markExited` pushes a status. All three of those want to talk to a renderer
 * that is already on its way out.
 */
let quitting = false

/**
 * Whether there is a render frame on the other end of `send`.
 *
 * Tracked from events rather than asked for on demand, and that is the whole
 * point — see `send` below for why nothing can be asked.
 */
let rendererAlive = false

/**
 * Broadcast to the renderer, if there is one.
 *
 * ## The bug
 *
 * A packaged v0.1.3 printed seven of these when it was stopped with a live
 * session — five from `PtyManager.onData`, one from `ActivityTracker.onChange`,
 * one from `onExit`:
 *
 *     Error sending from webFrameMain: Render frame was disposed before
 *     WebFrameMain could be accessed
 *
 * All seven came through this function, so the fix belongs here and not at
 * seven call sites. The PTYs are the cause: they keep producing output after
 * the render frame is gone, and killing them at quit *generates* a last burst
 * of exactly that traffic.
 *
 * ## Why the obvious guards do not work, all four of them
 *
 * This was measured rather than reasoned about. At the moment of a failing
 * send, with the frame already disposed, every question Electron will answer
 * says the renderer is healthy:
 *
 *     quitting=false winDestroyed=false wcDestroyed=false crashed=false
 *     mainFrame=obj detached=false
 *
 * And the send cannot be caught either: `webContents.send` and
 * `WebFrameMain.send` both swallow the failure and `console.error` it
 * themselves, so a `try`/`catch` around either one catches nothing and the
 * message is printed regardless. Reproduced both ways, still 32 errors.
 *
 * So there is no synchronous question worth asking. The only thing that knows
 * is Electron's own lifecycle, which is why liveness is a flag maintained by
 * `render-process-gone`, `destroyed` and the window's `close`/`closed` — set up
 * in `createWindow`, cleared before `killAll` in `before-quit`. With that in
 * place the same teardown that produced 32 errors produces none.
 *
 * The remaining checks below are not redundant with the flag: they cover the
 * ordinary case of a window that has gone while the app keeps running, which on
 * macOS is most of the time.
 */
/*
 * It answers whether it sent, and that answer is load-bearing for exactly one
 * caller.
 *
 * Every other push in this process ignores the return, and should: a status
 * update for a window that has gone is nothing to report. `settings.write` is
 * different — it has to tell the copilot whether the value it just saved is
 * *on the screen* or only on the disk, and those are different sentences. The
 * only thing that knows is this function, which is the one place that holds the
 * liveness flag and the window. See `live-push.ts`.
 *
 * `false` is never "the send failed": the four checks below are all forms of
 * "there is no window to tell", which is a true and ordinary state — on macOS an
 * app with every window closed is still running.
 */
function send(channel: string, ...args: unknown[]): boolean {
  if (quitting || !rendererAlive) return false
  const window = mainWindow
  if (!window || window.isDestroyed()) return false
  const contents = window.webContents
  if (!contents || contents.isDestroyed()) return false
  contents.send(channel, ...args)
  return true
}

/**
 * The two Electron things the session ↔ browser binding needs, and no more.
 *
 * Handed in rather than imported over there so that `browser-binding-ipc.ts`
 * has one window to push to and one window to pop a menu over, chosen here
 * where the window actually lives. `send` already refuses while quitting and
 * while the renderer is between documents, which is exactly the state in which
 * a push about browser windows would be a push about windows that no longer
 * exist.
 */
/**
 * Which machine a session is running on, in the vocabulary the binding key uses:
 * `''` for this computer, a machine id for a paired device, a server id for a
 * shell on a server — and `null` for an id this app has never started.
 *
 * ## Why one function rather than three checks at each call site
 *
 * Two different questions used to be answered by the same wrong assumption.
 * `knowsSession` asked *"is this one of ours"* of the local `PtyManager` alone,
 * so a session on his PC was never known, `resolve` took its
 * `known === false` branch and answered `system`, and the URL went to this Mac's
 * Chrome — which is the behaviour he filmed and called his biggest problem:
 *
 *   > *"If I tell a remote session to open a browser, they open the browser
 *   > inside wherever they are actually in the main machine, not in here in this
 *   > one."*
 *
 * And every caller that could not name a machine wrote `''`, which does not mean
 * "unknown" — it means "this computer" — so a window opened for a remote
 * session was filed under a key that session can never name.
 *
 * Both are the same missing fact, so it is looked up once, here, where all three
 * registries are in scope. The order is the order of authority: a pty this
 * process spawned is this machine's by construction, and only then are the two
 * remote registries asked. An id that two machines minted alike resolves to the
 * local one, which is the conservative direction — the local answer is the one
 * this process can verify.
 */
function machineOfSession(id: string): string | null {
  if (id === '') return null
  if (ptys.list().some((meta) => meta.id === id)) return ''
  for (const link of machinesIpc?.view().links ?? []) {
    if (link.sessions.some((session) => session.id === id)) return link.id
  }
  /*
   * And the third space of ids, which is why this parameter is not called
   * `sessionId`.
   *
   * `serverOfShell` is keyed by *shell* id, and a shell on a server is a session
   * to the binding map — `<machineId>\0<sessionId>` with the server standing in
   * for the machine (`servers/ipc.ts` says so where it mints the id). So a shell
   * id arriving here is the call working as intended, not a mix-up.
   *
   * The two spaces cannot collide, which is what makes asking all three in a row
   * safe. A session id is `randomUUID()`. A shell id is `` `${serverId} ${randomUUID()}` ``
   * — it contains a space, which a UUID never does — so a session id can never
   * match a shell and a shell id can never match a pty. `servers/ipc.test.ts`
   * pins both directions.
   */
  return servers?.serverOfShell(id) ?? null
}

const bindingDeps = {
  send: (channel: string, payload: unknown): void => {
    send(channel, payload)
  },
  window: (): BrowserWindow | null => mainWindow,
  /*
   * A session this app started, exited ones included — **on the machine the
   * caller named**.
   *
   * `ptys.list()` rather than a live-only check, inside {@link machineOfSession}:
   * a session whose process has ended keeps its tab, its scrollback and its
   * browser windows, and a URL can still arrive from something it left running.
   * What this excludes is the case that matters — an id from a shell this app
   * never started, whose hook fires anyway because the hook is installed for the
   * whole machine.
   *
   * The machine is compared rather than ignored, which it was until this round.
   * Ignoring it meant a session on a paired device was never known, so `resolve`
   * refused to mint it a window and every URL it opened went to this Mac's own
   * browser. Comparing it also closes the other direction: an id that happens to
   * match a local pty cannot be claimed by a caller naming somebody else's
   * machine.
   */
  knowsSession: (sessionId: string, machineId: string): boolean =>
    machineOfSession(sessionId) === machineId,
  /*
   * The same lookup, for the callers that were handed a session and no machine.
   * See {@link BindingIpcDeps.machineOfSession}.
   */
  machineOfSession,
  /*
   * Disconnecting a window ends whatever the copilot was doing in it.
   *
   * Read through `browserDrive()` rather than captured, because the drive is
   * created inside `registerIpc` and this object is built at module scope —
   * null until then, which is the honest answer for a window disconnected
   * before anything could have been driving it.
   */
  endDrive: (browserTabId: string): void => {
    browserDrive()?.releaseWindow(browserTabId)
  },
  /*
   * Why a row in the connect menu would attach and then be unable to do
   * anything, or null.
   *
   * Only the servers registry can answer it: it is the thing that decides, per
   * terminal, whether the agent in that shell was given a way to reach this
   * app's browser at all, and it holds the sentence saying why not. Read through
   * `servers` rather than captured for the reason `endDrive` is — this object is
   * built at module scope and the registry is created inside `registerIpc`, so
   * null is the honest answer before then.
   *
   * Every other kind of session answers null and the row is exactly as it was:
   * a session in this window has its windows here, and a session on a paired
   * machine reaches them over `window.call`.
   */
  whyNotDrive: (session: { sessionId: string; machineId: string }): string | null =>
    servers?.whyNotDrive(session.sessionId) ?? guestWindows?.refusal(session.machineId) ?? null,
  /*
   * And the tick that clears that refusal, offered in the menu it appears in.
   *
   * Read through `guestWindows` rather than captured for the reason `endDrive`
   * and `whyNotDrive` are: this object is built at module scope and the trust
   * store is created inside `registerIpc`. Null before then draws no row, which
   * is right — nothing can have dialled in yet.
   */
  windowGrantFor: (machineId: string) => guestWindows?.grant(machineId) ?? null,
  setWindowGrant: (machineId: string, allowed: boolean) => {
    guestWindows?.set(machineId, allowed)
  },
}

/**
 * Why a session on a device that dialled **in** would attach to a window here
 * and then be refused, or null.
 *
 * Set inside `registerIpc`, where the trust store and the grant store are, for
 * the reason `servers` above is read late: this object is built at module scope
 * and neither exists yet. Null until then, which is the honest answer for a menu
 * popped before the remote layer is assembled.
 *
 * ## Why the menu says it rather than the refusal
 *
 * Because the refusal happens on the other computer, some minutes later, in the
 * middle of an agent's turn. `window-serve.ts` writes a good sentence and names
 * this exact switch — but a person who ticked a row here and walked to the other
 * machine has already spent the trip. The grant defaults to off and always will,
 * so this is the ordinary path rather than an edge, and the place to say it is
 * the moment somebody is choosing the session.
 *
 * ## Why it answers null for everything it is not certain about
 *
 * The id it is given is the computer the session runs on, and three different
 * stores mint those. It answers only for an id the pairing store knows — a
 * device — and null for a machine this desktop dialled, a server, and this
 * computer. A warning printed against the wrong id space would be a row that
 * says it cannot drive a window it can drive, which is worse than the trip.
 */
let guestWindows: {
  /** The sentence, or null when there is nothing to warn about. */
  refusal(machineId: string): string | null
  /** The device's name and whether it may drive, or null when the id is not a device. */
  grant(machineId: string): { name: string; allowed: boolean } | null
  /** Write the tick. The same store the Settings panel writes. */
  set(machineId: string, allowed: boolean): void
} | null = null

/**
 * Latest status per live session. PtyManager only pushes status through its
 * callback, so anything that needs to *ask* (the alerts scanner) has nowhere
 * to read it from without this.
 */
const liveStatus = new Map<string, { status: SessionStatus; at: number }>()

/** Held so the recheck interval can be disarmed on quit. */
let updates: ReturnType<typeof registerUpdateIpc> | null = null

/**
 * The remote layer, once it is assembled, for the two session hooks below.
 *
 * At module scope for the same reason `copilotRuns` is: the core's callbacks are
 * written here, at module scope, and the remote server is built inside
 * `registerIpc`. Null until then — a session restored at launch can exist before
 * the wire does, and pushing a list to nobody is the correct answer rather than
 * a race to work around.
 */
let remoteLayer: { server: { sessionsChanged(): number } } | null = null

/**
 * The per-device copilot runs, once the remote layer is assembled.
 *
 * At module scope for one reason: `before-quit` has to be able to stop them, and
 * the assembly happens inside `whenReady`. `ptys.killAll()` on that path already
 * ends the processes, so this is not about the agents — it is about everything
 * *else* a run holds. Each one has a bearer token in `deck-control`'s caller
 * table and a config file on disk containing it, and a token surviving the run
 * it belonged to is a credential with no owner. Quitting is exactly when nobody
 * is watching for that.
 */
let copilotRuns: CopilotRuns | null = null

/**
 * The copilot's tool surface, once its loopback server is listening.
 *
 * Held so `before-quit` can close it. Null until the start below resolves, and
 * null forever if it failed — which is a state the app runs in perfectly well,
 * because everything except the copilot's tools works without it. See the
 * header of `deck-control/index.ts` for why it starts at boot rather than when
 * somebody opens the copilot: a permission gate that has only ever run in the
 * case somebody was watching is a gate that has never run in the case that
 * matters.
 */
let deckControl: DeckControlHandle | null = null

/**
 * The per-session tool tokens, once there is an endpoint to mint them against.
 *
 * Null until `deck-control` comes up, and null forever in a run where it did
 * not: a session is then launched with no `--mcp-config` of ours and simply has
 * the tools it always had. See `deck-control/session-tools.ts`.
 */
let sessionTools: SessionTools | null = null

/**
 * The server room, once the window has been built.
 *
 * At module scope for the same reason `copilotRuns` is: `before-quit` has to be
 * able to close it, and a server connection is not a pty so `killAll` knows
 * nothing about it. Left open, each one is a live TCP socket and an
 * authenticated session on somebody else's computer, held by a process that has
 * gone — which is the state §5.4 spends its whole argument avoiding while the
 * app is *running*, and there is no reason to abandon it on the way out.
 */
let servers: ServersIpc | null = null

/**
 * The paired-device half of Machines, for the one question asked outside its
 * own panel: which machine is a given session running on.
 *
 * At module scope for the reason `servers` above it is — `bindingDeps` is built
 * here, before `registerIpc` has assembled anything — and read through the
 * variable rather than captured, so a build with no remote layer answers "not a
 * session I know" instead of throwing.
 */
let machinesIpc: MachinesIpc | null = null

/**
 * The listeners this machine holds on a server's behalf, so they go on quit.
 *
 * Its own handle rather than a field on `servers`, because it is registered
 * beside that module rather than inside it: `host-key-checked.test.ts` allows
 * exactly one file in that folder to reach the transport, and the two verbs the
 * browser needs are a different subject from the control room's. What it holds
 * is a loopback listener per open page plus one connection per server, and a
 * listener left behind by a process that has gone is an address in somebody's
 * browser that answers and then hangs.
 */
let serverReach: ServerReachIpc | null = null

/**
 * Which browser windows are reading which of those listeners.
 *
 * At module scope so that the two registrations above can tell it when a link
 * or a connection took its tunnels down without anybody in a browser asking.
 * The list itself is the browser's only source for the machine chip in the
 * address bar - it used to be a `useState` inside a component that is mounted
 * once per browser window, which is the whole story in `browser-reach.ts`.
 */
let browserReach: ReachLedger | null = null

/**
 * Held so the wake lock and the battery watch can be let go of on quit.
 *
 * `stop()` releases what *this process* holds and deliberately leaves the
 * system's own lid setting alone — see the comment on `LidAwakeController.stop`
 * for why reverting it at quit would be worse than leaving it.
 */
let lidAwake: ReturnType<typeof registerLidAwakeIpc> | null = null

/**
 * Main → renderer: a session appeared that this window did not ask for.
 *
 * Today that means a phone started one. The window keeps its own list of tabs,
 * built from what it asked `session:create` for, so without this a session
 * started from the phone is running on the Mac and invisible in the app that
 * owns it — the user's own machine is the last to know.
 *
 * Deliberately *not* fired for a session the renderer asked for itself: it is
 * about to be handed the same `SessionMeta` as the return value of its own
 * call, and a consumer that adds a tab on both would show two.
 */
const SESSION_CREATED_CHANNEL = 'session:created'

/** Everything remote access keeps on disk: the trust store, this Mac's relay identity, the grants. */
const remoteStorageDir = (): string => join(app.getPath('userData'), 'remote')

/** Which key the machine's WSL distribution is stored under. See `core` below. */
export const WSL_DISTRO_KEY = 'wsl.distro'

/**
 * The machine itself: sessions, the folder grants, the credential proxy, the WSL
 * boundary.
 *
 * All of it used to be written out here. It moved to `host-core.ts` when the
 * headless build arrived, because every line of it is about the computer this
 * process is running on and none of it is about a window — and a second copy for
 * a shell with no window would be a session that is subtly not the same kind of
 * session. `src/headless/host.ts` calls this same function. What stays here is
 * the wiring that only a window needs: the broadcasts below, and the plan-limit
 * and alert bookkeeping that only a renderer reads.
 *
 * Constructed at module scope, as its pieces were, and safe there for the same
 * reason: nothing in the constructor reads a file or binds a socket.
 */
/**
 * This machine's questions to a paired device about a browser window it holds.
 *
 * At module scope, and before `core`, because two things reach it and they are
 * built at different moments: `deck-control`'s browser tools forward through it,
 * and the remote endpoint gives it the wire to the devices. One desk, or a frame
 * goes out on a socket and the answer is matched against a table nobody sent
 * from.
 *
 * Safe here for the reason `core` is: the constructor is a `Map` and a number.
 * Nothing is sent until a session asks, and nothing can be asked until the
 * endpoint has handed it a wire.
 */
const windowAsks = createWindowAsks()

/**
 * And the same questions to a paired **machine** — the desk for the other
 * direction of the same conversation.
 *
 * Two desks rather than one, and it is the id space that forces it. `windowAsks`
 * above is keyed by *device* id and its wire is a connection in `server.ts`;
 * this one is keyed by *machine* id and its wire is a link in `machines/ipc.ts`.
 * The ids are minted by different stores and are meaningless to each other, so a
 * single table would be one lookup away from putting a browser verb on the wrong
 * computer's socket — see `WindowHolder` in `window-owner.ts`, which is the type
 * that keeps the two apart everywhere in between.
 *
 * What is *not* duplicated is anything else. Both are `createWindowAsks()`: the
 * deadline, the sentence for a computer that never answered, the sentence for
 * one that is not connected, and the rule that a question nobody can hear is
 * refused in milliseconds rather than waited out — one file, two instances.
 */
const machineWindowAsks = createWindowAsks()

const core = createHostCore({
  storageDir: remoteStorageDir(),
  userData: app.getPath('userData'),
  /*
   * The browser verbs, on every session's own command line — *"driving other
   * browsers should be for all of the sessions."*
   *
   * Read through the variable rather than captured, because this object is
   * built at module scope and the endpoint comes up a few hundred milliseconds
   * later. A session started in that window is launched without them, which is
   * the honest answer and the one this app already gives for the `open` shim.
   */
  sessionTools: {
    prepare: (inside) => sessionTools?.prepare(inside) ?? null,
    /*
     * And a session in a Linux folder may have them too, once the distribution
     * has said it can reach this endpoint.
     *
     * Read through `deckControl` rather than captured for the reason above it:
     * the endpoint comes up after this object is built. `wsl-reach.ts` asks the
     * distribution once per port and remembers, so this is a `wsl.exe` run on
     * the first WSL session of a run and nothing on any after it.
     */
    insideDistro: (target) =>
      distroPlacement(target, deckControl?.endpoint.url ?? '', {
        /*
         * And the second way in, for the distribution that cannot reach
         * loopback at all — which is WSL's default networking and therefore
         * most people's. `process.execPath` is this app's own executable, run
         * as plain Node from inside the distribution over Windows interop, and
         * `bridgeScript` is what it runs. Offered rather than assumed: the
         * probe tries the cheap direct path first and only starts a process
         * across the boundary when that answered nothing. `wsl-bridge.ts` holds
         * the argument for why this needs no `.wslconfig` edit and no restart.
         */
        bridge: { exe: process.execPath, script: sessionTools?.bridgeScript() ?? '' },
      }),
    /*
     * And yes, a session a device started may have them — to reach **that
     * device's** windows and nothing here.
     *
     * Asked of the *device*, not of this assembly, and that is the whole of the
     * difference from the constant `true` this was for one evening. A phone is
     * connected, holds no browser windows, and its client has never heard of
     * `window.call`: `true` handed it six verbs whose every call came back
     * *"the computer holding that browser window is not connected right now"* —
     * about a device sitting there connected, holding nothing. Before that it
     * had no verbs and an honest sentence saying why, which is strictly better
     * than six dead controls.
     *
     * So this is the one launch-time fact that can be established honestly:
     * whether there is a live channel to that device on a build that advertised
     * `windows`. Everything else — whether it still is a minute later, whether
     * it holds a window for this session, whether the person allowed it — is
     * answered per call on the far side, in sentences the agent can act on, and
     * a launch-time probe of any of those would bake a fact that changes by the
     * minute into a flag read once at exec.
     *
     * The headless host passes no `sessionTools` at all, so it answers no here
     * by not being asked.
     */
    reachesDeviceWindows: (deviceId) => windowAsks.reaches(deviceId ?? ''),
  },
  /*
   * Where the machine's WSL distribution is remembered.
   *
   * `settings.json` rather than a file of its own: it is one string, it belongs
   * to this machine rather than to a project or a device, and that is exactly
   * what `settings-extra.ts` is. It is deliberately not in the renderer's
   * settings schema — the schema declares controls with fixed options, and the
   * list of installed distributions is discovered rather than declared.
   */
  wslStore: {
    read: () => {
      const stored = storedValue(WSL_DISTRO_KEY)
      return typeof stored === 'string' && stored !== '' ? stored : null
    },
    write: (distro) => {
      patchStoredSettings({ [WSL_DISTRO_KEY]: distro })
    },
  },
  onData: (id, data) => {
    // Plan limits are read off the same bytes the terminal draws — the CLI
    // reports them in its own output, so there is nothing else to ask.
    notePlanOutput(id, data)
    send('session:data', id, data)
  },
  onExit: (id, exitCode) => {
    liveStatus.delete(id)
    dropPlanSession(id)
    // The usage report for a session outlives its screen reading otherwise: the
    // aggregator holds a Codex watcher and a plan subscription of its own, and
    // a dead session must stop costing an fs watch.
    dropUsageSession(id)
    // And the account established for it, which was read out of a process that
    // has just stopped existing. A remembered answer here would outlive its
    // evidence, which is precisely what this app was doing wrong.
    dropSessionAccount(id)
    // A dev server *is* a session, so its death is this event and nothing else.
    // Without this the row keeps a `url` for a server that is gone — the one
    // genuinely wrong thing this feature can put on screen.
    devServers.noteExit(id)
    // Two routine triggers are this one event: `session-finished` is a zero
    // exit and `session-failed` is anything else. Told here rather than from a
    // watcher of its own — the engine subscribes, it does not poll.
    routines.engine.noteSessionExit(id, exitCode)
    // Any browser window attached to this session is *kept*, and marked. The
    // page it left open is part of what it printed, and a window that can say
    // "this session has exited, and this is what it was looking at" is worth
    // more than one that goes quietly blank.
    sessionExited(id)
    // The menu-bar list is only correct if it is told, and this is one of the
    // three moments the set of running sessions changes. It is a no-op unless
    // the app is in the background, which is the only time anybody can see it.
    presence.refresh()
    send('session:exit', id, exitCode)
  },
  onStatus: (id, status) => {
    liveStatus.set(id, { status, at: Date.now() })
    // And `session-idle N` is this one: the engine arms a countdown when a
    // session goes quiet and cancels it the moment it says anything.
    routines.engine.noteSessionStatus(id, status)
    send('session:status', id, status)
  },
  /*
   * The row goes when the session goes, whoever ended it.
   *
   * The window only ever learned about an ending it caused: `closeTabNow` calls
   * `killSession` and removes the row in the same breath, and there was no
   * subscription for anything else. So a session ended from any other route
   * stayed in the sidebar forever, pointing at a pty this process had already
   * dropped.
   *
   * Watched on 2026-08-18 in the capability audit: the copilot ran
   * `sessions_stop`, `sessions_list` came back holding only the copilot, and
   * *"Copilot sessions → Session 1"* was still there — a row that could not be
   * typed into, re-attached or closed by anything except quitting the app.
   *
   * `replaced` is filtered out here rather than in the renderer, because this is
   * the side that knows: it is the account switch, which stops one process and
   * starts another *in the same tab*, and the swap the window does finds the old
   * row by id. See {@link RemovalReason}.
   */
  onSessionRemoved: (id, reason) => {
    if (reason === 'replaced') return
    // The other end of the same push: a row this Mac dropped has to leave the
    // phone's list too, not sit there until it reconnects.
    remoteLayer?.server.sessionsChanged()
    // And the paired machines, for the same reason and in the same breath: a
    // session that has gone must leave their attach menus, or somebody over there
    // ticks a row whose pty this process dropped.
    machinesIpc?.announceSessions()
    // The other half of the pair above: this is the app letting go of the
    // session entirely, so its rows go and its binding colour is free again.
    sessionRemoved(id)
    // And the token that let it drive its own windows. A session that is gone
    // must not leave a bearer token on the table pointing at a session id
    // nothing can resolve.
    sessionTools?.release(id)
    presence.refresh()
    send(SESSION_REMOVED_CHANNEL, id)
  },
  /*
   * Every session, so a routine can be refused when its own work would start it.
   *
   * Not `onSessionCreated` below, which deliberately only fires for sessions
   * this window did not ask for. The loop guard needs the complete set — see
   * `HostCoreOptions.onSessionStarted`.
   */
  onSessionStarted: (meta) => {
    routines.engine.noteSessionStarted(meta)
    presence.refresh()
    // And every device holding a socket, or its list is a snapshot from the
    // moment it connected. Nothing on the wire fired for a session started at
    // *this* keyboard until now — see `RemoteEndpoint.sessionsChanged`, which
    // carries the measurement. Guarded because a session restored at launch can
    // exist before the remote layer is assembled.
    remoteLayer?.server.sessionsChanged()
    // And every machine this desktop dialled, which is the same staleness one
    // wire over: over there this Mac is a device that dialled in, and its attach
    // menu is built from what this line sends. See `MachinesIpc.announceSessions`.
    machinesIpc?.announceSessions()
  },
  // The window has to be told, or a session a phone started is running on this
  // Mac and only the phone knows about it.
  onSessionCreated: (meta) => announceSession(meta),
  /*
   * The account chip on a window on one of his other machines — and the same
   * two verbs the headless build now hands over.
   *
   * Asad, 2026-08-20: *"Then also bring the account selection here for the remote
   * sessions too."* And, inside a session on a server: *"when I am inside the
   * server, I cannot even change the accounts."* The operations themselves —
   * the switch that starts a replacement, waits to see whether the agent
   * survived and only then ends the session it replaced, and the sign-in that
   * opens a terminal for a person to finish a login in — live in
   * `session-switch-run.ts` now, because they never needed a window and the
   * headless host needs them verbatim. This shell hands them to the core
   * exactly as `src/headless/host.ts` does.
   *
   * Late-bound through `sessionSwitch`, because that object is built *from* the
   * core this options bag constructs. The gap is one synchronous tick — nothing
   * can call these before the module finishes loading — and the arrow reads the
   * binding at call time.
   *
   * The new id travels because a switch replaces the process: the far window is
   * attached to the old session and has to follow, or it is looking at a pty that
   * no longer exists. The answered `session` is the id the session has afterwards.
   */
  signInAccount: (accountId) => sessionSwitch.signInAccount(accountId),
  switchAccount: (sessionId, accountId) => sessionSwitch.switchAccount(sessionId, accountId),
})

/**
 * Tell the window about a session it did not ask for.
 *
 * Two things start one: a paired device, through the core's own
 * `onSessionCreated`, and the copilot, through `sessions.start`. Both produce a
 * running process on this Mac that the window has no other way to learn about —
 * the tab list is built from what the window itself requested — so without this
 * the app that owns the session is the last thing to know it exists.
 *
 * A named function rather than the closure it used to be, because the second
 * caller arrived: `deck-control` is handed a `startSession` that calls this on
 * the way out. Two hand-written announcements would be two chances for one of
 * them to forget the cost watcher below.
 *
 * The cost pane has to be told where to look, and that is the second half. A
 * session a device started runs confined, with a home of its own, so its
 * transcript is written under that home rather than under `~/.claude`. The
 * first session a *new* device starts creates a store that every open cost pane
 * has already finished looking for — and this is the moment the app knows it
 * exists, because the app is what made it. Wired at the event rather than
 * behind a timer that re-reads the disk hoping to find one.
 */
function announceSession(meta: SessionMeta): void {
  send(SESSION_CREATED_CHANNEL, meta)
  refreshCostWatchers()
}

/*
 * The names the rest of this file already used, pointed at the core.
 *
 * Aliases rather than a rewrite on purpose: everything below reads `ptys`,
 * `startSession` and the rest exactly as it did, so the move is a move and not
 * seven hundred lines of incidental churn.
 */
const { ptys, wsl, sessions: remoteSessions, ledger, startSession, statablePath } = core

/**
 * Running a session as another login, and opening a sign-in terminal — the one
 * implementation on this machine, shared with the headless build.
 *
 * Built from the core the moment the core exists, which is what lets the
 * options bag above hand `switchAccount` and `signInAccount` to the fanout: the
 * window at this desk, a window on a paired machine and a phone talking to a
 * headless host all press this same object. See `session-switch-run.ts` for
 * why the operations live behind the seam.
 *
 * `onSessionOpened` is this shell's half of the sign-in: the terminal has to
 * become a tab in this window, or the session runs with only the far pane
 * knowing it exists.
 */
const sessionSwitch = createSessionSwitch(core, { onSessionOpened: (meta) => announceSession(meta) })

/**
 * How many routine runs this whole app may start in an hour, across every
 * routine there is.
 *
 * Kept in `settings.json` rather than in any routine file, and that is the
 * point: a routine sets its own ceiling within limits `format.ts` clamps to,
 * and the copilot can write a routine — so the ceiling that is not negotiable
 * has to live somewhere no routine and no tool can reach. This is that place.
 * It is not in the renderer's settings schema yet; until a control exists,
 * `DEFAULT_GLOBAL_MAX_RUNS_PER_HOUR` is what everybody gets, and a hand edit of
 * `settings.json` is the way to change it.
 */
export const ROUTINES_CEILING_KEY = 'routines.maxRunsPerHour'

/**
 * Routines: saved instructions that run on their own.
 *
 * Constructed at module scope beside the core, because the core's own
 * callbacks above feed it — and a routine engine that only existed once a
 * settings pane had been opened would be a set of automations that run while
 * you are looking at them. `engine.start()` happens in `whenReady`, once the
 * IPC channels exist.
 *
 * `runner` is deliberately absent. Routines run *through the copilot* — see
 * `COPILOT-DESIGN.md` — and until `copilot-session.ts` grows a way to hand it a
 * prompt and be told when the turn is done, there is nothing on the other end.
 * Every routine reports itself unarmed with that sentence attached rather than
 * sitting there looking ready, which is the honest state of a half-built
 * feature and the only one that cannot be mistaken for a working one.
 */
const routines = createRoutines({
  /*
   * Where a routine may run, and it is not "anywhere".
   *
   * `in:` is an absolute path out of a file anybody can edit, and in phase 2
   * out of a `routines.create` call the copilot makes. Without this a routine
   * could name `/` and this app would attach a recursive file watch to the
   * whole disk on its behalf. The answer is the same set the phone's folder
   * picker falls back to: the projects this desktop has open, plus the folders
   * sessions are actually running in.
   */
  allowFolder: (folder) => {
    const known = [
      ...store().getProjects().map((project) => project.path),
      ...ptys.list().map((session) => session.cwd),
    ]
    if (known.includes(folder)) return { ok: true }
    return {
      ok: false,
      reason: `${folder} is not one of this app's projects, so nothing is watching it.`,
    }
  },
  globalMaxRunsPerHour: () => {
    const stored = storedValue(ROUTINES_CEILING_KEY)
    return typeof stored === 'number' && stored > 0 ? stored : DEFAULT_GLOBAL_MAX_RUNS_PER_HOUR
  },
  // Which emitters this shell has actually hooked up. Declared rather than
  // assumed: a trigger nothing is subscribed to reports itself that way instead
  // of looking armed and never firing.
  wired: ['session-finished', 'session-failed', 'session-idle', 'alert'],
})

/**
 * The dev servers this window has started, one per project folder.
 *
 * Declared here rather than beside `core` because it needs `ptys`, and
 * referenced from `core`'s `onExit` above — which is safe, because that is a
 * closure the pty manager calls long after this line has run.
 *
 * All three dependencies are the *same* calls the window makes for an ordinary
 * session. That is deliberate and load-bearing: a dev server is a session, it
 * appears in the session list, and it is killed the ordinary way. There is no
 * second spawning path and no hidden process, which is the whole reason the
 * feature can be trusted to say a server is running.
 */
const devServers = createDevServers({
  type: (id, data) => ptys.write(id, data),
  read: (id) => ptys.scrollback(id),
  alive: (id) => ptys.list().some((meta) => meta.id === id),
})

/**
 * The appearance the window's own chrome has to be painted in.
 *
 * The renderer resolves this same rule for itself — it owns the `data-theme`
 * attribute — and the two are deliberately not one call: they are in different
 * processes, and this side needs the answer as a *colour* because the window
 * buttons on Windows are drawn by the OS outside the page, where no CSS
 * variable can reach. `nativeTheme.shouldUseDarkColors` is the same OS
 * preference the renderer's `prefers-color-scheme` media query reads.
 */
function appearance(): Appearance {
  return resolveAppearance(store().getPreferences().theme, nativeTheme.shouldUseDarkColors)
}

/** True once `nativeTheme` is being watched, so re-creating the window adds no second listener. */
let watchingAppearance = false

/**
 * Whether a dialog's scrim is lying over the window at this moment.
 *
 * Renderer state that the main process has to know, which is unusual enough to
 * say why. On Windows the minimise/maximise/close buttons are painted by the OS
 * into a strip *above* the page — so when `.modal-overlay` dims every pixel the
 * renderer draws, those three are untouched, and Settings opened onto a dimmed
 * window with the brightest thing on screen in its top-right corner. There is no
 * CSS that reaches them; the only lever is `setTitleBarOverlay`, and it is on
 * this side of the bridge. `window:dimmed` is the renderer saying which of the
 * two the strip should be wearing (see `renderer/shell/chrome-dim.ts`).
 *
 * A boolean rather than a count: the renderer keeps the count, because it is the
 * side that knows how many surfaces are open, and a count kept here would drift
 * the first time a window reloaded with a dialog up.
 */
let chromeDimmed = false

/**
 * Repaint the Windows window-controls overlay for the theme that is on now, and
 * for whether the window is dimmed under a dialog.
 *
 * Without this the strip keeps whatever colour it was given at launch: switch
 * to the light theme and the top-right corner of a white window stays a dark
 * grey rectangle with the buttons in it, which is a more obvious defect than
 * the stacked title bars this replaced. It is a no-op on every platform that
 * has no overlay — `overlayFor` returns null there, and `setTitleBarOverlay` is
 * not a method that exists on macOS, so the guard has to come first.
 *
 * One function for both inputs, rather than one per input. The strip wears a
 * single colour, so the theme and the scrim cannot each own half of it: a
 * "dim the buttons" call that did not also read the theme would brighten a
 * light-theme window back to the dark hex the moment a dialog closed.
 */
function syncTitleBarOverlay(): void {
  const overlay = overlayFor(process.platform, appearance(), chromeDimmed)
  if (!overlay || !mainWindow || mainWindow.isDestroyed()) return
  mainWindow.setTitleBarOverlay(overlay)
}

/**
 * Tell Chromium which appearance the *app* has chosen, not just which one the OS
 * is in.
 *
 * From the recorded review of 2026-08-20, of the attach menu that drops out of a
 * session row:
 *
 *   > *"this window should be exactly same color as the application, white. It
 *   > is white. It should be also white from the background. If it is dark, it
 *   > should be dark."*
 *
 * That menu is a **native** one — `Menu.popup()` in `session-row-menu.ts` and
 * `browser-binding-ipc.ts`, and deliberately so: a browser page here is a
 * `WebContentsView` composited above the entire renderer, so an HTML menu would
 * open *behind* the page in exactly the situation the menu exists for. A native
 * menu is drawn by the OS and takes the OS appearance, so with the app on Light
 * and macOS on Dark it arrives dark over a white window. Nothing was wrong with
 * the menu; nothing had ever told the OS what the app had decided.
 *
 * `themeSource` is that missing line. It is Electron's one switch for "this
 * process is in dark/light mode", and it moves every native surface with it —
 * menus, message boxes, native scrollbars and `prefers-color-scheme` inside the
 * pages we host. The preference's three values are exactly the three the API
 * takes, so `'system'` hands the decision straight back to the OS, which is what
 * it means.
 *
 * Set here rather than in the renderer because there is no renderer API for it
 * and no second opinion to reconcile: this reads the same stored preference the
 * renderer resolves `data-theme` from, so the app's own chrome and the OS's
 * cannot disagree.
 */
function syncNativeAppearance(): void {
  nativeTheme.themeSource = store().getPreferences().theme
}

function createWindow(): void {
  /*
   * A window is back, so the background presence is not the app any more.
   *
   * The tray exists to answer "what is running, and how do I stop it" for
   * somebody who has no window. Beside a visible window it answers nothing and
   * is a second icon for one app, so it goes — and the keep-alive handle goes
   * with it, because from here on the window is what holds the process open and
   * `window-all-closed` is free to mean what it has always meant.
   */
  leaveBackground()
  const saved = store().getState().windowBounds
  /*
   * A fresh window has nothing open over it, whatever the last one had.
   *
   * `chromeDimmed` is renderer state held on this side, and the renderer is
   * about to be replaced — macOS re-creates the window on `activate`, and a
   * reload replaces the page. Quitting a window with Settings open and leaving
   * the flag set would construct the next one with `titleBarChrome`'s bright
   * strip and then repaint it dim on the first theme event, for a dialog that
   * is not there. The renderer re-announces the truth as soon as one opens.
   */
  chromeDimmed = false
  mainWindow = new BrowserWindow({
    width: saved?.width ?? 1440,
    height: saved?.height ?? 900,
    x: saved?.x,
    y: saved?.y,
    minWidth: 720,
    minHeight: 480,
    show: false,
    title: BRAND.name,
    /*
     * What Chromium paints before the renderer has produced a first frame, and
     * again in the gap while a resize outruns compositing. It has to be the
     * dark theme's --bg-primary, because index.html ships data-theme="dark" so
     * that is what the app will paint a moment later. It was #0e0f13 — a blue
     * black left over from a palette two revisions old — against a canvas that
     * was #1c1b19 at the time, so every launch and every fast drag of the
     * window edge flashed a different dark than the app itself. There is no way
     * to read tokens.css from the main process, so this is a copy by hand: if
     * --bg-primary in the dark theme changes, change this with it.
     */
    backgroundColor: '#191919',
    /*
     * The whole top edge of the window, per platform — see `title-bar.ts`.
     *
     * This used to be a `process.platform === 'darwin'` ternary written out
     * here, with `trafficLightPosition` passed on every platform whether it
     * meant anything or not, and the result was that Windows sat on the default
     * frame: an OS title bar, then a menu bar, then our own toolbar. Three
     * strips saying what one bar says. A branch written inline in a constructor
     * can only ever be read on the machine that takes it, which is why it lives
     * in a function that takes the platform as a value and has both answers
     * pinned side by side in `title-bar.test.ts`.
     */
    ...titleBarChrome(process.platform, appearance()),
    /*
     * Off macOS the application menu is a strip *inside* the window, and it was
     * the third of those bars. Hidden, not removed: Electron registers every
     * accelerator through the menu, so a null menu is an app with no Ctrl+C.
     * `menu.ts` makes that argument at length.
     */
    autoHideMenuBar: hidesMenuBar(process.platform),
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  })

  /*
   * The other half of the theme, which arrives without anybody asking.
   *
   * `prefs:set` covers the user changing the theme in Settings. This covers the
   * *system* changing underneath a window whose preference is 'system' — macOS
   * and Windows both flip appearance on a schedule by default, so this is not
   * an edge case, it is most evenings. Attached once for the life of the
   * process rather than per window: macOS re-creates the window on `activate`,
   * and a second listener would be a second repaint of the same strip.
   */
  if (!watchingAppearance) {
    watchingAppearance = true
    nativeTheme.on('updated', syncTitleBarOverlay)
  }

  // The stored preference, applied to Chromium's own appearance at launch.
  // Without this the first window of a session gets native menus in whatever
  // appearance the OS is in, until the theme is touched in Settings.
  syncNativeAppearance()

  // Liveness, from the events rather than by asking. `render-process-gone` is
  // the one that matters when the renderer dies under the app; `close` is the
  // ordinary path, and fires before the frame goes rather than after.
  rendererAlive = true
  const rendererGone = (): void => {
    rendererAlive = false
  }
  mainWindow.webContents.on('render-process-gone', rendererGone)
  mainWindow.webContents.on('destroyed', rendererGone)
  mainWindow.on('close', rendererGone)
  mainWindow.on('ready-to-show', () => mainWindow?.show())

  // The sessions you had open, put back — and, on any later reload, the ones
  // still running re-announced. This is the *only* trigger: a restore wired to
  // a button and not to launch is the bug class this repository has paid for
  // most, and `src/reachable.test.ts` opens by naming restore-on-launch as one
  // of five features that shipped with no way in.
  mainWindow.webContents.on('did-finish-load', () => {
    void hydrateRenderer() // first: see session-restore.test.ts
    /*
     * A page that has just loaded has nothing open over it.
     *
     * `chromeDimmed` is a fact about the *renderer*, kept here because only this
     * side can repaint the OS's window buttons — and a reload throws that
     * renderer away without unmounting anything, so a reload with Settings open
     * would leave the caption buttons dim over a window with no dialog in it.
     * That is the same defect this flag exists to fix, arriving through the one
     * door the renderer cannot close behind itself. The count on the other side
     * starts at zero too, so the two agree from here.
     */
    if (chromeDimmed) {
      chromeDimmed = false
      syncTitleBarOverlay()
    }
  })
  mainWindow.on('closed', () => {
    rendererGone()
    mainWindow = null
  })

  // Remember size and position. Debounced so a drag doesn't hammer the disk.
  let boundsTimer: NodeJS.Timeout | undefined
  const rememberBounds = () => {
    clearTimeout(boundsTimer)
    boundsTimer = setTimeout(() => {
      if (mainWindow && !mainWindow.isDestroyed() && !mainWindow.isMaximized()) {
        store().setWindowBounds(mainWindow.getNormalBounds())
      }
    }, 400)
  }
  mainWindow.on('resize', rememberBounds)
  mainWindow.on('move', rememberBounds)

  // Surface renderer errors in the terminal — without this a blank window
  // gives no clue what failed.
  if (isDev) {
    mainWindow.webContents.on('console-message', (event) => {
      if (event.level === 'error' || event.level === 'warning') {
        console.error(`[renderer] ${event.message}  (${event.sourceId}:${event.lineNumber})`)
      }
    })
    mainWindow.webContents.on('did-fail-load', (_e, code, desc) =>
      console.error(`[renderer] failed to load: ${desc} (${code})`),
    )
  }

  /*
   * A link this app's own UI asked to open.
   *
   * Deny is still the answer for a *window* — nothing in this app should ever
   * get a bare Chromium window, with no toolbar and none of this app's chrome
   * on it. What changed is where the URL goes afterwards. It used to go
   * straight to `shell.openExternal`, so pressing a repository, a pull request
   * or an issue in the GitHub panel launched Chrome while the app's own browser
   * sat one tab away — *"currently it's opening a separate window — I want it
   * to use the same window inside Terminal Deck for browser"*, 2026-08-17.
   *
   * `openAppLink` makes that decision in one place for every link in the
   * renderer, because `window.open` is the only door out of it: http(s) becomes
   * a tab in the workspace strip, and a `mailto:` or a `file://` reveal — the
   * things this app genuinely cannot render — still goes to the machine. See
   * `link-open.ts`, which also explains why a guest page gets a stricter answer
   * than this one.
   */
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (mainWindow) openAppLink(mainWindow.webContents, url)
    return { action: 'deny' }
  })

  /*
   * Every browser window in this window is gone, and the binding map has to
   * hear about it.
   *
   * ⌘R, a dev rebuild and a recovered crash all replace the document without
   * destroying the WebContents, so nothing else notices — which is precisely the
   * shape of bug `browser-tab.ts` documents at `watchHost`, and it destroys the
   * views on the same signal. The tab list is plain React state, so after a
   * reload there genuinely are no browser windows; keeping the bindings would
   * leave the next hook answer telling an agent to look at `B2`, which is a
   * window that no longer exists.
   *
   * Dropping them is the honest answer, and it is the one place where a naive
   * "persist it across reloads" would be actively wrong.
   */
  mainWindow.webContents.on(
    'did-start-navigation',
    (details: { isMainFrame: boolean; isSameDocument: boolean }) => {
      if (!details.isMainFrame || details.isSameDocument) return
      forgetKnownWindows()
      hostReset()
    },
  )

  if (process.env.ELECTRON_RENDERER_URL) {
    void mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    void mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

/** True once the sessions from the previous run have been dealt with, win or lose. */
let restored = false

/**
 * Bring the window level with the main process: every live session, announced.
 *
 * ## Why this is not simply called at launch
 *
 * `send` reaches a render *frame*; `onSessionCreated` is registered by a React
 * effect inside that frame. Broadcasting before the effect runs is a message
 * with no listener — it is not queued, it is dropped — and the session would be
 * running on this Mac with no tab. `did-finish-load` fires after the page's
 * scripts have run, which is the earliest point at which there is anything to
 * hear it.
 *
 * ## Why it announces every session and not just the new ones
 *
 * Re-announcing is free and fixes a second thing. The renderer's `addSession`
 * is idempotent by id — it says so at its own definition — so a session that is
 * already a tab is ignored. That makes this safe to run on *every*
 * `did-finish-load`, which is what a renderer reload is: today a reload leaves
 * every pty running and every tab gone, with no way back to a session that is
 * still alive. After this, the tabs come back with it.
 */
/**
 * How a remembered session is turned into a decision — at launch, and again
 * every time somebody presses Try again.
 *
 * A named function rather than the argument expression it used to be, because
 * there are now two callers and they must not diverge. The retry has to ask the
 * *same* questions in the *same* order as the launch did — is the folder there,
 * can this agent continue at all, which login's transcripts, is there a
 * conversation — or pressing the button would start a subtly different session
 * from the one that failed, which is the class of difference nobody notices
 * until it is a bug report.
 */
const planSaved = savedPlanner(core)

/**
 * Tell the window which sessions are being held.
 *
 * The window is allowed not to exist. This runs during launch, before there is
 * anything to draw a row, and `send` is already a no-op without a window — so
 * the three callers below do not have to know whether anybody is listening, and
 * the window gets the list again when it asks on mount.
 */
function announceHeld(): void {
  send(SESSIONS_HELD_CHANNEL, ledger.held.list())
}

async function hydrateRenderer(): Promise<void> {
  if (!restored) {
    // Set before the await, not after. `did-finish-load` can fire again while
    // the first restore is still spawning — a reload in dev does it routinely —
    // and a second pass would start a second copy of every session.
    restored = true
    /*
     * What a person had open — which is not always what the list says.
     *
     * The copilot is a singleton `ensureCopilot` starts, and it was being
     * written down like an ordinary tab; two entries for `<userData>/copilot`
     * were sitting in Asad's `state.json` on 2026-08-17 because it had been
     * restarted once. Restoring them would start two plain Claude sessions with
     * none of the copilot's instructions or tools, invisible in the sidebar
     * because the window filters that folder out, on every launch. `host-core.ts`
     * stops writing them; `personalSessions` drops the ones already there, and
     * the next `ledger.flush()` writes the list back without them.
     *
     * `copilotPaths(userData)` with no chosen folder on purpose — the app's own
     * storage, never wherever the copilot has been pointed. See the note on
     * `personalSessions` for why widening it would throw away real work.
     */
    const saved = personalSessions(store().getOpenSessions(), [
      copilotPaths(app.getPath('userData')).root,
    ])

    /*
     * Every restored folder has to be a known project before the window asks
     * for the list, or the tab arrives with nowhere to live.
     *
     * The sidebar groups sessions under projects, so a session in a folder that
     * was never added as a project — one started from a phone, most obviously —
     * comes back as a running pty with no row anywhere.
     *
     * Synchronous, and before the first `await`, on purpose. The renderer asks
     * for its projects from a React effect that is itself waiting on a settings
     * round trip, so in practice it asks long after this; but "in practice"
     * is how a losing race gets written, and the whole pass is a handful of
     * `existsSync` calls against folders on a path the user opens by hand.
     * Behind an `await` it would be genuinely racy for no gain.
     *
     * `existsSync` rather than the planner's async check because a folder that
     * is gone must not be added: the planner will skip that session anyway, and
     * a project row pointing at a deleted directory would outlive this launch.
     *
     * Existing projects are left alone rather than re-added — `addProject`
     * bumps `lastOpenedAt`, and that is what orders the sidebar, so restoring
     * would otherwise reshuffle it on every launch.
     */
    if (store().getPreferences().restoreSessions) {
      const known = new Set(store().getProjects().map((project) => project.path))
      for (const session of saved) {
        // `statablePath`, not the folder itself: a Linux path is invisible to
        // `existsSync` on Windows however real it is, and every restored WSL
        // session would come back as a tab with no project row to sit under.
        if (!known.has(session.cwd) && existsSync(statablePath(session.cwd))) {
          store().addProject(session.cwd)
          known.add(session.cwd)
        }
      }
    }

    try {
      await restoreOpenSessions({
        saved: () => saved,
        // Read now rather than captured at import: the switch can have been
        // turned off since the last launch.
        enabled: () => store().getPreferences().restoreSessions,
        plan: planSaved,
        /*
         * No picture is painted here, and that is a measured decision rather
         * than an omission.
         *
         * A restored session was briefly seeded with its own transcript so the
         * screen would not be empty. It was built, it worked, and it is
         * invisible: Claude Code switches to the ALTERNATE SCREEN
         * (`ESC[?1049h` then `ESC[2J`) the moment its interface starts, about
         * half a second after the spawn, so anything seeded into the normal
         * buffer is underneath it and unreachable for the life of the session.
         * There is no ordering that fixes that — the CLI owns the screen.
         *
         * And it is not needed: `--continue` re-reads the whole transcript and
         * the CLI repaints the conversation itself, which is what a user
         * actually sees. Proved by watching identical turns come back in the
         * CLI's own styling with fresh spinner verbs.
         *
         * A plain shell has no transcript to replay either — nothing records
         * what it printed, and its scrollback lives only in memory. Persisting
         * every terminal's output to disk was considered and rejected: no
         * terminal on any platform does it, the shell already saves the
         * COMMANDS, and a file holding everything a terminal ever printed is
         * the same liability as the three secret files this app just spent an
         * afternoon locking down.
         */
        // The same `startSession` the window's own button and a paired phone
        // use. A restore path with its own spawn would be a second kind of
        // session — different PATH, different profile handling — that only
        // appears after a restart, which is the hardest kind of difference to
        // ever notice.
        spawn: startSession,
        announce: (meta) => send(SESSION_CREATED_CHANNEL, meta),
        report: (decisions) => {
          reportRestore(decisions)
          /*
           * Keep the ones that did not come back.
           *
           * This is the line that stops a bad launch from being permanent. The
           * ledger is rebuilt from nothing every time the app starts and its
           * `flush` overwrites `openSessions` wholesale, so a session that
           * failed to restart used to survive only until the next tab opened —
           * at which point the app forgot it had ever existed. Asad lost four
           * Claude sessions in two WSL folders that way on 2026-08-16 and got
           * two plain terminals in their place. `session-held.ts` has the
           * account.
           *
           * `skip` is held as well as `failed`, and that is deliberate. "The
           * folder it ran in is no longer on this machine" is *also* usually
           * temporary — an unmounted volume, a network share not up yet, and,
           * on this very machine, a WSL distribution that had not started, which
           * makes `\\wsl.localhost\Ubuntu\…` unreadable for a few seconds after
           * login. Throwing a day's work away over a folder that is late is the
           * same mistake in a different coat. Each row can be dismissed, so the
           * cost of being wrong here is one click.
           */
          for (const decision of decisions) {
            if (decision.outcome === 'failed' || decision.outcome === 'skip') {
              ledger.held.hold(decision.session, decision.reason)
            }
          }
          announceHeld()
        },
      })
    } catch (err) {
      // A restore that throws must not take the window's session list with it.
      logger.error('restore', 'restoring the previous sessions failed outright', {
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }

  for (const meta of ptys.list()) send(SESSION_CREATED_CHANNEL, meta)
  // On every hydration, not only the first: a renderer reload throws away the
  // window's copy of this list exactly as it throws away its tabs, and the rows
  // it draws are the only place a person is told a session did not come back.
  announceHeld()
}

/**
 * Say what happened, but only where saying it is not noise.
 *
 * Nothing is announced for a session that came back — that is the entire point
 * of the feature, and a banner reading "3 sessions resumed" is the app
 * narrating its own plumbing at someone who just wanted their work back. What
 * *is* recorded is every session that did not come back and why, in the app log
 * the user can open from Settings, because a tab quietly missing with no
 * explanation anywhere is the version of this that lies.
 */
function reportRestore(decisions: readonly RestoreDecision[]): void {
  for (const decision of decisions) {
    if (decision.outcome === 'resume') continue
    const detail = { folder: decision.session.cwd, agent: decision.session.provider }
    if (decision.outcome === 'fresh') {
      logger.info('restore', `started clean: ${decision.reason}`, detail)
    } else {
      logger.warn('restore', `did not come back: ${decision.reason}`, detail)
    }
  }
}

/**
 * Where a session's browser verb actually goes.
 *
 * ## The question
 *
 * A browser window is a `WebContentsView` in the renderer of the app somebody is
 * looking at. A session can be running anywhere. So for every verb there is one
 * fact to establish first — *which app holds the window this session is attached
 * to* — and it has two answers, in this order.
 *
 * ## 1. A session a paired device started belongs to that device, always
 *
 * `host-core.ts`'s gate used to refuse such a session these verbs outright, and
 * its reason still binds: the session runs on **this** machine, so a verb served
 * locally would let a paired device drive the browser holding this account's
 * logins, through a token that says `session` rather than `remote` and therefore
 * slips past the refusal {@link mayDrive} makes to a device's face.
 *
 * That is why this branch has no local fallback and must never grow one. There
 * is no "unless a window here is attached to it" clause, because such a clause
 * *is* the door: attach one window on this machine to a guest's session and the
 * guest's agent has it. The windows on this screen stay exactly as unreachable
 * from a device's session as they were.
 *
 * ## 2. Any other session's window is wherever it was attached
 *
 * This is the half that was missing, and it is the whole of what Asad hit first.
 * `window-owner.ts` is written at the spawn, so it knows about sessions a device
 * *asked for* and about no others — and his test was a session already running
 * on his PC, with a window attached from his Mac. It answered null, the verb was
 * served on the PC, the PC's own map had nothing in it, and the agent said *"no
 * browser window is attached to this session"* about a page he was looking at.
 *
 * The app that holds the window is the only one that can know, so it says so:
 * `window.holds` carries the set on every welcome and every attach, and
 * `WindowAskDesk.holdersOf` is the table it lands in. Which makes ownership a
 * property of *where the window is* rather than of who spawned what.
 *
 * **This machine first.** Unlike branch 1, a local window wins here — and the
 * difference is not an inconsistency, it is the point. Branch 1 is about a
 * session belonging to somebody else, where a local window is a boundary being
 * walked around. This branch is about the person's own session, where a window
 * they attached in *this* app is simply the nearest true answer; serving it here
 * costs no frame, and it also means a paired machine cannot take a local
 * session's verbs away from the window on this screen by naming it.
 *
 * ## Two machines naming one session
 *
 * Refused, in a sentence, rather than sent to whichever answered first. Two
 * people can each attach a window of their own to one session here and neither
 * of them is wrong; a verb with two destinations has no correct one, and driving
 * the wrong person's browser is not a thing to do on a guess.
 */
const forwardBrowserVerb: VerbForwarder = {
  elsewhere: (session) => whereWindowIs(session).kind !== 'here',
  send: async (session, tool, args) => {
    const where = whereWindowIs(session)
    if (where.kind === 'here') {
      // Unreachable through `browserTools`, which asks `elsewhere` first, and
      // still answered rather than thrown: this is inside a tool call, and a
      // throw here would reach the model as a protocol error it can only retry.
      throw new Error('that session is not on another computer')
    }
    if (where.kind === 'ambiguous') {
      /*
       * Named as a count rather than as machine names, because the names are the
       * far computers' and this end holds ids. The action is the same either way
       * and it is one a person takes, which is why the sentence is addressed to
       * them through the agent rather than to the agent.
       *
       * The count spans both kinds of holder. A device that dialled in and a
       * machine this app dialled out to can each have a window attached to one
       * session here, and neither of them is wrong — so the sentence is the same
       * one and the remedy is the same one.
       */
      throw new Error(
        `${where.holders.length} computers have a browser window attached to this session, so there ` +
          'is no single one to act on. Ask the person to detach it everywhere except the computer they ' +
          'want you to drive.',
      )
    }
    /*
     * One id, two possible desks, and the holder's `kind` is what picks.
     *
     * The two desks are the same code with different wires — see
     * `machineWindowAsks` at the top of this file — so everything below this
     * line is identical whichever answered: the same deadline, the same
     * sentences, the same handling of a body that will not parse.
     */
    const holder = where.holder
    const answer = await (holder.kind === 'device' ? windowAsks : machineWindowAsks).call({
      deviceId: holder.id,
      sessionId: session.sessionId,
      tool,
      args: JSON.stringify(args),
    })
    let value: unknown
    try {
      value = JSON.parse(answer.body)
    } catch {
      throw new Error('the computer holding that browser window answered with something unreadable')
    }
    if (!answer.ok) {
      /*
       * The far side's sentence, unchanged, as this tool's error.
       *
       * Rewriting it here would be a second voice describing a refusal made
       * three files away — and the sentences over there are the actionable ones:
       * they name the switch to turn on, or the window that is not attached, or
       * the verb that does work across a link.
       */
      const message =
        typeof value === 'object' && value !== null && typeof (value as { message?: unknown }).message === 'string'
          ? (value as { message: string }).message
          : 'that could not be done on the computer holding that browser window'
      throw new Error(message)
    }
    return {
      value,
      /*
       * The log line says where it happened, and nothing about the page.
       *
       * `ToolOutput.summary` is the audit row, not a second copy of the answer —
       * `catalogue.ts` is explicit about that — and the answer here can be a
       * whole page outline. What is worth recording is that this app drove a
       * browser it does not own, on which computer, with which verb.
       */
      summary: { forwardedTo: holder.id, on: holder.kind, tool },
    }
  },
}

/**
 * The one decision {@link forwardBrowserVerb} makes, in one place so that its
 * two methods cannot come to disagree — `elsewhere` runs in a precheck and
 * `send` runs a moment later, and a rule written out twice is a call that is
 * prechecked as local and then sent, or the other way round.
 *
 * The rule itself is `window-owner.ts`'s, beside the map it reads and testable
 * without an Electron app around it. This is the two lookups it cannot do from
 * there: the binding map, which is this process's, and the desk, which the
 * remote endpoint fills in.
 */
function whereWindowIs(session: { sessionId: string; machineId: string }): WindowRoute {
  return routeWindowVerb(session, {
    attachedHere: (sessionId, machineId) => windowsOf(sessionId, machineId).length > 0,
    holders: (sessionId) => windowAsks.holdersOf(sessionId),
    machineHolders: (sessionId) => machineWindowAsks.holdersOf(sessionId),
  })
}

/**
 * The copilot's browser tools, or none of them.
 *
 * Empty when the drive was never registered, which cannot happen through the
 * ordinary boot path and is worth being explicit about anyway: a catalogue
 * missing five tools is a thing the copilot reports honestly when asked what
 * it can do, and a `!` here would be a crash at launch instead.
 */
function browserDriveTools(): ReturnType<typeof browserTools> {
  const drive = browserDrive()
  // `browser.network` is contributed here rather than from `browserTools()` so
  // that the harvesting capability lives in its own file — see
  // `deck-control/browser-network-tool.ts`. It closes over the same drive and is
  // gated by the same `mayDrive` as the six.
  return drive === null
    ? []
    : [...browserTools(drive, forwardBrowserVerb), browserNetworkTool(drive)]
}

/**
 * The worker verbs, closing over the pool this process holds.
 *
 * Handed in rather than imported by `worker-tools.ts` for the reason
 * `browserTools(drive)` is: the tool file states a surface and this file owns
 * the wiring, so the whole of that surface is driven from a test with no
 * Electron in the room.
 *
 * There is deliberately **no lift** in this list. The one action that copies a
 * credential is an `ipcMain` channel behind a button, and `session-tools.ts`
 * records at length why nothing here may reach it.
 */
function browserWorkerTools(): ReturnType<typeof workerTools> {
  const dir = (): string => app.getPath('userData')
  return workerTools({
    /*
     * The registry and the pool, joined here rather than through
     * `workersView()`.
     *
     * That function also enumerates every `WebContents` in the process to say
     * which pages are open in each jar, which is exactly right for a panel
     * somebody opened and wasteful for a tool that is asked several times per
     * call. The tool never uses the page list; it resolves a *window* through
     * the binding instead.
     */
    list: () => {
      const status = new Map(workerStatus(dir()).map((row) => [row.profileId, row]))
      return workerList(dir()).map((worker) => ({
        profileId: worker.profileId,
        name: worker.name,
        partition: worker.partition,
        busy: status.get(worker.profileId)?.busy ?? false,
        holder: status.get(worker.profileId)?.holder ?? '',
        readyInMs: status.get(worker.profileId)?.readyInMs ?? 0,
      }))
    },
    pace: () => workerPace(dir()),
    workerOfView: (viewId) => workerOfView(viewId),
    injectionsFor: (partition) => injectionsFor(partition),
    take: (input) => leaseForCaller(input),
    release: (input) => releaseWorker(dir(), input),
    renew: (input) => renewWorker(dir(), input),
  })
}

/**
 * The one tool every installed store tool comes through, or none of it.
 *
 * Same judgement as `browserDriveTools` one line up, and the same reason: a
 * catalogue missing a tool is something the copilot reports honestly when asked
 * what it can do, and a `!` here would be a crash at launch instead.
 *
 * `installedBrowserTools` is passed as a **function**, never a snapshot. The
 * argument is the one `callers.ts` makes about grants: a list read once at wiring
 * time would freeze whatever was installed at launch, so pressing Install would
 * change nothing until the app was restarted — a control that does nothing, which
 * is the exact defect this round is about.
 */
function browserStoreTools(): ReturnType<typeof storeTools> {
  const drive = browserDrive()
  return drive === null ? [] : storeTools({ drive, installed: installedBrowserTools })
}

/**
 * The last set of held windows this app told the paired machines about.
 *
 * See the subscription in {@link registerIpc}. A string rather than a structure
 * because the only question ever asked of it is whether it is the same as the
 * one just computed, and `''` — nothing held anywhere — is the honest starting
 * value: a link that comes up before the first attach announces its own empty
 * set on its welcome.
 */
let announcedWindows = ''

function registerIpc(): void {
  // Installed first so it wraps every handler registered below.
  // Off unless the user turned Debug mode on. Consulted per call rather than
  // captured, so toggling the setting takes effect without a relaunch.
  traceIpc(ipcMain, { enabled: () => storedValue(TRACE_SETTING) === true })

  ipcMain.handle('brand:get', () => ({ name: BRAND.name, tagline: BRAND.tagline }))

  ipcMain.handle('project:pick', async () => {
    if (!mainWindow) return null
    const { canceled, filePaths } = await dialog.showOpenDialog(mainWindow, {
      properties: ['openDirectory', 'createDirectory'],
      title: 'Open project',
      buttonLabel: 'Open',
      /*
       * Where the panel stands when it opens, and it must always be said.
       *
       * Omitting it does not mean "no preference" — AppKit then restores the
       * directory it was last left in, from a bookmark in the app's own user
       * defaults that nothing here writes and nobody can see. On the machine
       * this was recorded on that bookmark pointed at an empty folder, so the
       * picker listed nothing, four openings in a row, with `Open` greyed out.
       * `project-picker.ts` has the measurement and the reasoning for the
       * answer; the short version is that the parent of the newest project is
       * the one directory that cannot be empty.
       */
      defaultPath: pickerStartDirectory(store().getProjects(), app.getPath('home')),
    })
    if (canceled || filePaths.length === 0) return null
    /*
     * A folder picked inside a distro is stored as the Linux path it really is.
     *
     * Explorer lists the installed distributions in its sidebar, so the ordinary
     * folder dialog is already how a person browses to a project inside Ubuntu —
     * and it hands back `\\wsl.localhost\Ubuntu\home\asad\proj`. Storing that is
     * storing a path nothing can run in: cmd.exe refuses a UNC working directory
     * outright, and the folder rule that decides where a session runs would see
     * a Windows path and start the session on the wrong side of the boundary.
     *
     * Translated here, at the one point the path enters the app, so that every
     * copy of it downstream — the project list, a session's `cwd`, a folder
     * granted to a phone — is already the Linux path.
     */
    const picked = filePaths[0]
    return linuxPathFromUnc(picked)?.path ?? picked
  })

  /**
   * A folder to run in when there is genuinely no project — the home directory.
   *
   * Signing an account in means running that account's CLI so its own login
   * takes over, and a CLI has to run *somewhere*. On a machine that has never
   * opened a folder there is nothing to fall back on, so pressing **Sign in**
   * put a folder chooser on screen instead of a login, and cancelling it did
   * nothing at all. That is the state a new user is in the first time they add
   * an account.
   *
   * The distribution's own `$HOME` when there is one, for the reason
   * `host-core.ts` gives about the same fallback: on a Windows machine whose
   * work is all inside WSL, `C:\Users\…` is the one folder with nothing in it.
   */
  ipcMain.handle('project:home', () => wsl.home() ?? app.getPath('home'))

  /*
   * Which machine is being asked about.
   *
   * The renderer asks this to decide which agents to offer, with no folder in
   * hand, and on a machine with a usable distribution the honest answer is the
   * distribution's: that is where the folders are and where the sessions run,
   * so answering about the Windows PATH would grey out an agent that is
   * installed and working. `defaultTarget` is null everywhere else, which is
   * the Windows and macOS behaviour unchanged.
   *
   * `startSession` does not come through here. It knows the folder, so it asks
   * about that folder's own side — see the comment there.
   */
  /*
   * The added agents are merged on top, and they are asked a different question
   * from the shipped four.
   *
   * `detectProviders` runs each catalogue agent once to prove it starts, because
   * a `codex` that resolves on PATH and then dies is the bug that put a Node
   * stack trace in front of the user. That probe needs a version flag, and the
   * catalogue records which flag each agent has. An added agent has none
   * recorded — guessing `--version` would report a perfectly good CLI without
   * that flag as broken — so the honest question for it is the one the spawn
   * itself will ask: does this command resolve on the login PATH. `customEntry`
   * says as much by leaving `versionArgs` null, and `lookupCommand` is the same
   * function `startSession` re-checks with, so the picker and the spawn cannot
   * disagree about what is startable.
   */
  ipcMain.handle('providers:detect', async () => {
    const builtin = await detectProviders(currentPlatform(), wsl.defaultTarget())
    const added = await Promise.all(
      core.agents.list().map(async (agent) => {
        const found = await lookupCommand(agent.command, currentPlatform())
        return [agent.id, found !== null] as const
      }),
    )
    return { ...builtin, ...Object.fromEntries(added) }
  })

  /*
   * A dialog opened or closed over the window, so the OS's own buttons have to
   * follow it down and back up. See `chromeDimmed`.
   *
   * `on`, not `handle`: nothing waits for an answer, and a dialog opening must
   * not be gated on a round trip through this process. Idempotent, because the
   * renderer sends the state rather than a toggle — two "dimmed" in a row is a
   * second dialog over the first, and it is still one strip in one colour.
   */
  ipcMain.on('window:dimmed', (_e, dimmed: boolean) => {
    if (chromeDimmed === dimmed) return
    chromeDimmed = dimmed
    syncTitleBarOverlay()
  })

  ipcMain.handle('projects:list', () => store().getProjects())
  ipcMain.handle('projects:add', (_e, path: string) => store().addProject(path))
  ipcMain.handle('projects:remove', (_e, path: string) => store().removeProject(path))
  ipcMain.handle('prefs:get', () => store().getPreferences())
  ipcMain.handle('prefs:set', (_e, patch: Partial<Preferences>) => {
    const preferences = store().setPreferences(patch)
    // Two of these preferences are server-owned — the default coding tool and
    // whether the last layout is restored — so a change here has to reach a phone
    // watching this machine's settings. Fired unconditionally for the same reason
    // `syncTitleBarOverlay` below is: the patch is a partial and the renderer
    // sometimes writes the whole object back, so "did a server setting change" has
    // a wrong answer available; one extra push of two unchanged rows costs nothing.
    core.serverSettings.noteChanged()
    /*
     * The theme switch cannot reach the window buttons on its own.
     *
     * On Windows they are painted by the OS in a colour handed to it once, in a
     * strip that is outside the page — so the renderer flipping `data-theme`
     * repaints every pixel of the app except the three in the top-right corner.
     * Called for every preference change rather than only for `theme`, because
     * the patch is a partial and "did the theme change" is a question with a
     * wrong answer available (`'theme' in patch` is false when the renderer
     * writes the whole object back); repainting the strip in the colour it is
     * already wearing costs nothing.
     */
    syncTitleBarOverlay()
    // And the OS's own surfaces, which are the other half of the same switch —
    // see `syncNativeAppearance`. A native menu had no way to know the app had
    // gone light.
    syncNativeAppearance()
    return preferences
  })

  // Feature modules own their own channels; each registers in one line.
  // Against the core's store, not a second one: `startSession` reads that
  // instance, and two would be two in-memory copies of one file with the picker
  // adding to one and the spawn reading the other.
  registerCustomAgentsIpc(ipcMain, core.agents)
  registerCostIpc(ipcMain)
  registerGitIpc(ipcMain)
  registerFsIpc(ipcMain)
  // Restricting search to known projects stops any folder that merely looks
  // like a project from being enumerated over IPC.
  registerSearchIpc(ipcMain, {
    isAllowedRoot: (root) => store().getProjects().some((p) => p.path === root),
  })
  registerInsightsIpc(ipcMain)
  registerChatIpc(ipcMain)
  registerDevPortsIpc(ipcMain)

  /*
   * The dev-server channel.
   *
   * `projects` is the folders this desktop has open, and the handler will only
   * act on a folder that appears in it — so a compromised renderer cannot use
   * this channel to hunt for `package.json` files across the disk. Not a
   * boundary against the person at the keyboard, whose machine this is; it is
   * simply the narrowest input the channel can take and still do its job.
   *
   * `open` is `startSession` — the same call the New Session button makes — so a
   * dev server is an ordinary visible session that can be read and killed like
   * any other, rather than a hidden child process.
   */
  registerDevServerIpc(ipcMain, {
    servers: devServers,
    projects: () => store().getProjects().map((project) => project.path),
    open: async (folder) => {
      // A plain shell, not an agent: this session exists to run one command.
      // 120x30 because a dev server's output is read, not worked in — and a pty
      // with no size prints its progress bars into a single column.
      const meta = await startSession({ cwd: folder, cols: 120, rows: 30, provider: 'shell' })
      return { ok: true, sessionId: meta.id }
    },
    broadcast: (state: DevServerState) => send(DEV_SERVER_STATE_CHANNEL, state),
  })
  // Controls are read off the rendered screen and applied by typing, exactly as
  // a person would — and resolved against the account that session is running
  // as rather than this process's. See `HostCore.controlAccess`.
  registerAgentControlsIpc(ipcMain, core.controlAccess)
  // Dictation's transcription key and the request it is for. `userData` is a
  // thunk rather than a value because `pinUserData` can move the directory, and
  // a path captured at wiring time would outlive the move.
  registerVoiceIpc(ipcMain, () => app.getPath('userData'))
  // Which session is what, asked once and shared by both halves of the usage
  // feature. Two copies of this lookup would be two answers to "whose account is
  // this session on", and the write side and the read side disagreeing about
  // that is how one login's figure lands on another login's bar.
  const describeSession = (id: string): SessionMeta | null =>
    ptys.list().find((meta) => meta.id === id) ?? null
  // Read-only now, and takes nothing: this module watches session screens and
  // reports the limit lines Claude Code prints of its own accord. It used to be
  // handed a `write` as well, which is what let it type `/usage` into a session
  // and draw a panel over somebody's conversation — the thing Asad reported
  // three times. That whole path is gone; the figure now comes from
  // `usage-probe.ts`, which starts a `claude` of this app's own instead.
  registerPlanLimitIpc(ipcMain)
  // The read side of the same feature, with Codex's rollout numbers folded in
  // and every reading tagged with the account it describes. `PtyManager` is
  // asked which login a session resolved to rather than that answer being
  // recomputed — see `usage-ipc.ts`, where getting it wrong means two accounts
  // sharing one bar.
  // Its own refresh path, which is the whole of the 2026-08-18 change: the bar
  // is kept current by reading `.claude.json` and, when that has gone stale, by
  // one short-lived `claude` of this app's own — never by typing into a session
  // somebody is working in. `accounts` is shared with `plan-limit.ts` above on
  // purpose: "this login has no subscription limits" is one fact, and two
  // modules keeping two copies of it is how one of them starts spending four
  // seconds of CPU every half hour re-establishing what the other wrote down.
  registerUsageIpc(ipcMain, { describeSession, accounts: storedAccountLimits() })
  /*
   * Which login each session is *actually* on, established rather than assumed.
   *
   * Registered beside the usage window because they are two halves of one claim:
   * the account chip names the login and the bar draws that login's plan
   * figures, and the two must never be able to disagree about whose they are.
   * `pidOf` is the whole of what this needs from the session layer — a root to
   * walk down from — and `describeSession` is the same accessor the usage
   * registry is handed, so neither module holds a second, drifting copy of what
   * a session is.
   */
  registerSessionAccountIpc(ipcMain, { pidOf: (id) => ptys.pidOf(id), describeSession })
  // Checks on a delay after launch and then occasionally; never installs on its
  // own. An unsigned build reports that it cannot self-update rather than
  // checking forever — see updates/updater.ts.
  updates = registerUpdateIpc(ipcMain, {
    updater: autoUpdater,
    /*
     * An update is the one quit that cannot be talked out of leaving.
     *
     * The installer has been handed this bundle by the time the app is asked to
     * go, so `before-quit` must not cancel it and keep the app running with no
     * window — the swap would be happening underneath a live process. Sessions
     * do die here, and that is honest: the binary running them is being
     * replaced. `restoreSessions` puts them back on the other side.
     */
    beforeInstall: () => {
      stopping = true
      leaveBackground()
    },
    // Squirrel refuses an unsigned bundle, which is this build. The manual
    // path does the same job without it: read the public feed, verify the
    // archive's sha512, swap the bundle. Supplied on macOS only.
    manual:
      process.platform === 'darwin'
        ? createManualStrategy({
            feedUrl: 'https://github.com/asadev/terminaldeck/releases/latest/download/latest-mac.yml',
            userDataPath: app.getPath('userData'),
            currentVersion: app.getVersion(),
            platform: process.platform,
            exePath: app.getPath('exe'),
          })
        : undefined,
    environment: {
      platform: process.platform,
      isPackaged: app.isPackaged,
      execPath: process.execPath,
      feedConfigPath: app.isPackaged
        ? join(process.resourcesPath, 'app-update.yml')
        : join(app.getAppPath(), 'dev-app-update.yml'),
      // Set by electron-builder's portable launcher and by nothing else. The
      // portable exe and the installed one are the same build carrying the same
      // feed, so this is the only thing that tells them apart at runtime — and
      // an update on Windows is an installer, which is the one thing a portable
      // app must not run. See PORTABLE_REASON.
      portableExecutable: process.env.PORTABLE_EXECUTABLE_FILE ?? null,
    },
    broadcast: (channel, state) => send(channel, state),
  })
  registerTailnetIpc(ipcMain, { certDir: join(app.getPath('userData'), 'tailnet-certs') })
  /*
   * The one-time permission that lets Windows hold a device's session inside
   * its folder — the button `CONFINEMENT.md` said was the only thing missing.
   *
   * Registered on every platform and honest on each: macOS confines with no
   * grant at all, because seatbelt needs no prior permission from anybody, and
   * that asymmetry is exactly why only one of the two ever needed a button.
   * `confine/ipc.ts` carries the argument.
   */
  registerConfineIpc(ipcMain, {
    path: () => process.env.PATH ?? '',
    accountHome: () => app.getPath('home'),
  })
  /*
   * Remote copilot access, assembled — the store, and the runs it authorises.
   *
   * One `CopilotAccess` for the whole process, handed to both halves. It is
   * derived rather than stored — a device's kind is the whole answer — so there
   * is no file two instances could disagree about any more; what a second one
   * would still cost is a second copy of the *rule*, which is the thing this
   * codebase keeps having to unpick.
   *
   * Built here rather than inside `registerRemoteIpc` because the run manager
   * needs things only this file holds: the core's session starter, the caller
   * table on `deck-control`'s endpoint, and the copilot's own folder.
   *
   * **Every dependency that can be resolved late is a function**, and that is
   * not a style choice. `deck-control` starts asynchronously and can fail to
   * start at all; `deckControl` below is null until it does. Capturing its
   * endpoint here would mean either ordering this after an await that the
   * remote endpoint cannot wait for, or capturing null forever. Asked per call,
   * a run simply cannot be started until the tools exist — and the phone is told
   * exactly that, in a sentence, instead of being handed a Start button that
   * spawns an agent with nothing behind it.
   */
  /*
   * Who reaches the copilot, derived rather than stored.
   *
   * There was a `CopilotLinks` here until 2026-08-19 — a file of separate
   * connections, each minted with its own six-digit code. His instruction
   * deleted it: *"if we are connecting as my device, copilot automatically
   * comes; if we connect as guest then copilot don't come."* So the answer is
   * the kind chosen when the device was approved, read live, and there is
   * nothing on disk that can disagree with it. `copilot-access.ts` carries the
   * argument and the one it superseded.
   */
  const copilotLinks = new CopilotAccess({
    isMine: (deviceId) => core.kinds.kindOf(deviceId) === 'mine',
  })
  copilotRuns = new CopilotRuns({
    links: copilotLinks,
    /*
     * The confirmation gate, asked for per call rather than captured.
     *
     * `deck-control` starts asynchronously and can fail to start at all, so
     * `deckControl` is null at this line and may stay null. Capturing the broker
     * here would capture null forever, and a device would be told there is
     * nothing waiting no matter how many dialogs were on screen.
     */
    consent: () => deckControl?.consent ?? null,
    /*
     * Where a run's token is registered, and dropped.
     *
     * A shim rather than the table itself, for the reason above: the table is
     * minted with the endpoint and does not exist at this line. `false` from
     * `delete` on a dead endpoint is the honest answer — there was no token to
     * drop, because the process that would have held it never started.
     */
    callers: {
      set: (token, grant) => deckControl?.endpoint.callers.set(token, grant),
      delete: (token) => deckControl?.endpoint.callers.delete(token) ?? false,
    },
    endpoint: () => (deckControl === null ? null : { url: deckControl.endpoint.url }),
    copilotRoot: () =>
      copilotPaths(
        app.getPath('userData'),
        storedValue(COPILOT_HOME_SETTING) as string | null,
      ).root,
    spawn: (request) =>
      startCopilotRun(
        {
          startSession,
          announce: announceSession,
          stop: (id) => ptys.kill(id),
          userData: () => app.getPath('userData'),
          // A phone's run is the copilot, so it is told what it is by the same
          // generated file the desk copilot gets — see `startCopilotRun`.
          tools: () => deckControl?.control.tools() ?? [],
        },
        request,
      ),
    isAlive: (id) => ptys.list().some((meta) => meta.id === id && meta.exitCode === null),
    stop: (id) => ptys.kill(id),
    /*
     * Prose into a pty, on the phone's behalf, by the desktop.
     *
     * The submit is added here rather than expected on the wire: a `copilot.say`
     * frame carries a *sentence*, and making the client responsible for a
     * control character would mean a client that forgot it produced a run that
     * silently never answered.
     *
     * Which is what this line used to do itself. It wrote `${text}\n` — one
     * chunk, and a newline rather than a Return — so every message a phone ever
     * sent was typed into the run's prompt and left there unsubmitted. See
     * `remote/copilot-say.ts` for the two reasons that fails and the measurement.
     */
    say: (id, text) => typeAndSubmit((data) => ptys.write(id, data), text),
    // Ctrl-C. The one interrupt an agent CLI understands, and it reaches this
    // device's own run and nothing else.
    interrupt: (id) => ptys.write(id, '\x03'),
    desk: () => {
      /*
       * A *read* of the copilot's state, not a second way to run it.
       *
       * `copilotState` answers out of module-level state in `copilot-session.ts`
       * — whether a session is live, what the last failure was — and takes deps
       * only so it can resolve paths and ask whether that session is still
       * alive. So this literal is four fields and no policy: the account, the
       * folder and the boundary are all decided in that module, by the call that
       * started the copilot, and nothing here can disagree with it.
       *
       * A named const shared with `registerCopilotIpc` below would be tidier and
       * would couple a read on the relay's path to the object that owns the
       * desk copilot's lifecycle. This is the smaller of the two mistakes.
       */
      const state = copilotState({
        startSession,
        isAlive: (id) => ptys.list().some((meta) => meta.id === id && meta.exitCode === null),
        stop: (id) => ptys.kill(id),
        userData: () => app.getPath('userData'),
        // The chosen folder, or this read reports the copilot's paths as the
        // default ones while it is actually working somewhere else.
        home: () => storedValue(COPILOT_HOME_SETTING) as string | null,
        storageDir: remoteStorageDir,
      })
      return {
        status: state.status === 'running' ? 'running' : state.status === 'starting' ? 'starting' : 'stopped',
        profile: state.profile?.name ?? null,
        // Not asked here. Resolving a sign-in shells out to the CLI, and this
        // function is called on every state frame — a phone with the pane open
        // would spawn a probe per read. Null means "not asked", which the frame
        // is typed for.
        signedIn: null,
        // Available when the copilot could start at all. `problem` is the reason
        // the last attempt failed and is the honest sentence to forward.
        available: state.problem === null,
        reason: state.problem,
      }
    },
    cost: () => {
      const catalogue = deckControl?.control.cost()
      /*
       * `tokens` is what the tool list costs *every turn*, which is what the
       * phone's field is named after — the whole catalogue is re-sent to the
       * model on each one, so it is a standing cost rather than a one-off.
       *
       * Zero when `deck-control` is not up, and that is not a placeholder: a
       * copilot with no tool surface genuinely spends nothing on a tool list,
       * and the same state is already saying `available: false` with a reason
       * beside it.
       */
      return { tools: catalogue?.tools ?? 0, turnTokens: catalogue?.tokens ?? 0 }
    },
    sessions: () => toCopilotSessions(ptys.list(), (id) => liveStatus.get(id)?.status ?? 'unknown'),
    log: (options) => tailForPhone(deckControl?.log.tail(2000) ?? [], options),
    /*
     * The run's conversation, read from the transcript rather than the pty.
     *
     * Watched by **this run's own transcript**, which the app can name because
     * it named it: `host-core.ts` puts `--session-id <uuid>` on the fresh spawn
     * and records it as `SessionMeta.agentSessionId`, precisely so that nothing
     * downstream has to guess which of a folder's transcripts belongs to which
     * session.
     *
     * The comment that used to be here said there was nothing to key on at this
     * moment, and it was wrong: the spawn has resolved by the time `CopilotRuns`
     * calls this, so the meta is in the list. What the folder-newest reading
     * actually did was follow the *desk copilot's* conversation whenever one had
     * spoken more recently than the phone's run had — the phone then watched a
     * conversation it was not having, and its own answer, sitting in a file
     * beside it, never arrived. Measured on 2026-08-20; see `watchRunChat`.
     */
    chat: (sessionId, onUpdate) =>
      watchRunChat(
        copilotPaths(app.getPath('userData')).root,
        onUpdate,
        ptys.list().find((meta) => meta.id === sessionId)?.agentSessionId ?? null,
      ),
  })
  // On unless this Mac has been told otherwise.
  //
  // It used to be off until someone pressed a button, and nothing pressed it
  // again on the next launch — so a Mac that had been restarted held no relay
  // connection at all, and every phone paired to it was attaching to a host
  // that was not there. That is not a missing feature to a person holding a
  // phone; it is the app not working. Measured on this machine: the identity
  // and two paired devices on disk, and not one socket to the relay.
  //
  // The comment that used to sit here — "this serves a shell", "binds only to
  // the tailnet address" — was written before the relay existed, when starting
  // meant opening a listener. Dialling out opens nothing, and a phone still
  // has to be paired and approved before a byte moves.
  const remote = registerRemoteIpc(ipcMain, {
    sessions: remoteSessions,
    // The two settings this machine owns, reachable from a phone. One store, the
    // same one the settings pane at this desk writes — see `prefs:set`, which
    // calls `noteChanged` so a change here reaches a connected phone too.
    serverSettings: core.serverSettings,
    /*
     * The desk this machine's sessions ask a device through.
     *
     * Handed here so the endpoint can give it the wire to the live connections
     * and settle its outstanding questions when one goes. It is the same object
     * `forwardBrowserVerb` above sends into — one desk, or a frame goes out on a
     * socket and the answer is matched against a table nobody sent from.
     */
    windows: windowAsks,
    /*
     * And the serving half: a browser verb arriving **from** a device, for a
     * window in this app.
     *
     * `serveWindowCall` is the same function the machine links serve their asks
     * through — one decider, or the two come to allow what each other refuses.
     * What differs is only which store answers `allowed`: a device's grant is
     * `WindowGrants` here, a machine's is `MachineStore.drivesWindows` there, and
     * neither store may ever be asked about the other's ids.
     *
     * `machineId` in the caller below is this device's id. That is not a
     * category error: `deck-control`'s caller key is `<machineId>\0<sessionId>`
     * where the first half names *the computer the session is on*, whichever
     * store minted the id, and the far end supplied the second half. Neither end
     * holds the whole key and neither has to.
     */
    serveWindows: (deviceId, call) =>
      serveWindowCall(
        {
          allowed: (id) => core.windowGrants.drives(id),
          // A device has no card in Machines — it has a row in the remote
          // roster, and the switch is in the panel under it. Naming the wrong
          // one of the two would send somebody looking at a screen that does not
          // have the tick on it.
          grantSwitch: 'for this device in Settings → Remote, under “Devices that may act on browser windows here”',
          control: () => deckControl?.control ?? null,
          // The same question the machine side asks, and it has to be asked
          // rather than asserted for the same reason: the one thing `attended`
          // decides is whether a confirmation can be raised and waited on, and
          // on macOS an app with every window closed is still running.
          attended: () =>
            !quitting && rendererAlive && mainWindow !== null && !mainWindow.isDestroyed(),
        },
        deviceId,
        call,
      ),
    /*
     * And which of that device's sessions this app is holding a window for.
     *
     * The same read the machine side makes, against the same map, keyed on the
     * same field. `SessionBinding.machineId` is *the computer the session runs
     * on* as this app knows it — an id from whichever store named that computer
     * — so one filter answers for both directions and there is no second copy of
     * the binding map to keep in step.
     *
     * ## What this answers today, said plainly
     *
     * **Empty, for every device**, and that is a gap upstream of here rather
     * than a bug in this line. The only ids that have ever been written into
     * `SessionBinding.machineId` are machine ids and the empty string: the
     * session picker in `renderer/browser/agent-target.ts` is built from this
     * machine's own sessions and from the sessions of machines this desktop
     * *dialled out to*, so there is no way in the app to attach a window here to
     * a session that runs on a device which dialled *in*. Until there is, the
     * wire below carries a true empty set and the session over there is told,
     * correctly, that nothing here is holding a window for it.
     *
     * Written as the filter rather than as `[]` because the filter is the rule —
     * the day a window can be attached to a device's session, this is already
     * the right answer and there is nothing here to remember to change.
     */
    windowsHeldFor: (deviceId) =>
      bindingView()
        .sessions.filter((binding) => binding.machineId === deviceId && binding.windows.length > 0)
        .map((binding) => binding.sessionId),
    // The same tracker the window uses, so a dev server started from the phone
    // and one started from the desktop are one thing rather than two views that
    // can disagree. `server.ts` only advertises the `devserver` capability when
    // this is present, so a build without it says nothing rather than offering a
    // button that answers `unauthorized`.
    devServers,
    // The store half of revocation, wired to the one core the settings panels
    // write. `device-roster.ts` runs it as part of the cascade behind the wire,
    // the CLI and this window's own Remove button alike.
    forgetDevice: (id) => core.forgetDevice(id),
    autoStart: storedValue(REMOTE_ENABLED_KEY) !== false,
    onEnabledChange: (on) => {
      patchStoredSettings({ [REMOTE_ENABLED_KEY]: on })
    },
    onStartFailure: (reason) => {
      // Nobody is waiting on a reply to the launch dial, so this is the only
      // place it can surface. Loud on purpose.
      logger.error('remote', 'remote access did not come up at launch', { reason })
    },
    webRoot: join(app.getAppPath(), 'pwa', 'dist'),
    storageDir: remoteStorageDir(),
    // What this build calls itself, and that it is the desktop and not a
    // headless server, onto the `welcome`. `app.getVersion()` is the packaged
    // number — the same one the About pane and the updater read — so a phone
    // paired here can say which build the machine at the other end is running,
    // and the clients that are ahead of it can say so.
    appVersion: app.getVersion(),
    hostKind: 'desktop',
    // The same object the folder rule above closes over, never a second one:
    // the panel edits what `create` is checked against, or it edits a copy and
    // the phone keeps the folders the user just removed until the next launch.
    folders: core.grants,
    // And the same session-choice store the fanout's predicate closes over,
    // for the reason one line up: the panel ticks what `visible` is checked
    // against, or it ticks a copy and the phone keeps a session the user just
    // unticked until the next launch.
    sessionGrants: core.sessionGrants,
    // And the same login-choice store the endpoint's account filter closes
    // over, for the reason one line up: the approval screen and the panel write
    // what every `account.read` is filtered against, or they write a copy and
    // the machine over there keeps a login its owner just unticked until the
    // next launch.
    accountGrants: core.accountGrants,
    // And the fourth axis, on the same argument once more: the settings panel
    // writes what every forwarded browser verb is checked against. This is the
    // store whose empty state means *nobody*, so a second copy would not merely
    // drift — it would be a permission that exists in one file and not the other.
    windowGrants: core.windowGrants,
    // And the same kind store the reach rule closes over, for the same reason
    // one line up: the approval screen decides what a device is, and every
    // connection is checked against it, so two copies would agree until the
    // first approval and then not.
    kinds: core.kinds,
    /*
     * A page a device asked for opens **here**, as a tab of this app's own
     * browser.
     *
     * `openAppLink` is the same function the app's own links go through, against
     * the same window, so a localhost link tapped on a phone lands exactly where
     * a link clicked in this window lands — which is the whole of *"a browser
     * started from the phone must run on the machine you are inside."* It is
     * routed rather than handed to `shell.openExternal`: this app has a browser,
     * and launching Chrome instead is the behaviour Asad objected to by name.
     *
     * False when there is no window, which is the honest answer during a launch
     * or after a close — the server turns that into `unavailable` rather than
     * reporting an open that did not happen. The scheme has already been checked
     * on the way in; `routeAppLink` inside checks it again, because a rule that
     * holds only because of what a different file refused is a rule the next
     * caller does not have.
     */
    openUrl: (url: string): boolean => {
      const window = mainWindow
      if (!window || window.isDestroyed()) return false
      return openAppLink(window.webContents, url) === 'tab'
    },
    // Likewise the same proxy the spawn path above hands each guest session a
    // key from. This is also where it is brought into being: the endpoint binds
    // at launch, with nobody pressing anything, so the first push a phone makes
    // is not the one that discovers the feature had never been started.
    credentials: core.credentials,
    /*
     * The copilot, as a paired device may touch it — and the store that decides
     * whether it may.
     *
     * Passing the layer is what advertises the `copilot` capability, and that is
     * deliberate rather than incidental: `server.ts` reads it off this object
     * instead of a constant so that the advertisement cannot outlive the thing
     * it advertises. A build with no run manager tells a phone nothing, and the
     * phone draws no Copilot tab, rather than drawing one that answers
     * `unauthorized` to every frame it sends.
     *
     * Both fields, and the same derivation behind them: this one is the
     * *enforcing* side, `copilotLinks` is what the settings panel *reads* to
     * show which of your devices reach the copilot. Neither writes anything —
     * since 2026-08-19 the answer is the kind chosen when the device was
     * approved, and the panel has nothing to set.
     */
    copilot: copilotRuns,
    copilotLinks,
    // Where a photo or a file sent from a phone lands. The user's downloads
    // folder, in a folder named after the app — somewhere a person already looks,
    // rather than application support, which they never do and which an
    // uninstall takes with it. Passing it is also what advertises the capability;
    // see `RemoteEndpointOptions.uploadsDir`.
    uploadsDir: join(app.getPath('downloads'), BRAND.name),
    broadcast: (channel, payload) => send(channel, payload),
  })
  // Held for the core's session hooks, which are written at module scope and
  // run long after this. See `remoteLayer`.
  remoteLayer = remote
  /*
   * And the connect menu's warning for a session on a device that dialled in.
   *
   * Both halves are here and nowhere else: `remote.auth` is the only list of
   * paired devices, and `core.windowGrants` is the store the tick writes to. Read
   * per call rather than captured, the rule every window grant in this app is
   * read by — a person who ticks the box and pops the menu again must see the row
   * change, not the state it was in when the app launched.
   */
  guestWindows = {
    grant: (machineId) => {
      if (machineId === '') return null
      const device = remote.auth.listDevices().find((known) => known.id === machineId)
      if (device === undefined) return null
      return { name: device.name || 'that device', allowed: core.windowGrants.drives(machineId) }
    },
    refusal: (machineId) => {
      const grant = guestWindows?.grant(machineId) ?? null
      if (grant === null || grant.allowed) return null
      // Names the row directly below it rather than a panel across the app,
      // because that row is now in this menu. The panel is still where the whole
      // list lives and still says the same thing; this sentence is for the one
      // computer somebody is looking at.
      return `${grant.name} has not been allowed to act on browser windows here — the tick is at the bottom of this menu.`
    },
    set: (machineId, allowed) => {
      core.windowGrants.set(machineId, allowed)
    },
  }
  // Re-dial the relay the instant the machine wakes, rather than polling the
  // clock to work out that it did. A socket that slept through a suspend is
  // usually dead and TCP will not admit it for minutes — minutes in which a
  // phone cannot reach this Mac. `powerMonitor` already knows; asking it is
  // free, and it is exactly one event instead of a timer that runs forever.
  // The other half of remote access, and the half this app did not have: every
  // machine *this* one has paired to. Registering it dials each of them, which
  // is deliberate and is asserted by `machines/boot.test.ts` — a link that only
  // came up when somebody opened the Machines page would be a page that reports
  // its own screen as the state of the world.
  //
  // It shares the pairing desk with the host half above, because there is one
  // code on screen at a time whether a phone or a second desktop is about to
  // read it.
  machinesIpc = registerMachinesIpc(ipcMain, {
    storageDir: remoteStorageDir(),
    desk: remote.desk,
    status: () => remote.server.status(),
    broadcast: (channel, payload) => send(channel, payload),
    // A link that went took its loopback listeners with it. The browser's rows
    // are the only place those listeners were ever named, so they go too - a
    // chip naming a machine whose pages have stopped answering is worse than no
    // chip at all.
    tunnelsDropped: (machineId) => browserReach?.forget(machineId),
    /*
     * The other direction of the browser feature, and the only inbound question
     * a paired machine may ask this one.
     *
     * A session over there, attached to a window over **here**, calling one of
     * the six verbs. Every decision is `window-serve.ts`'s and none of it is
     * here: the grant is read off the machine store per call, the window is
     * resolved inside that session's own binding, and the verb goes through
     * `deck-control`'s dispatcher so it is tiered, confirmed, budgeted and
     * logged exactly like a call from a session in this window.
     *
     * `machinesIpc` is captured rather than passed, and it is null on the line
     * that builds this object: the closure runs on a frame from a socket, long
     * after the assignment. `false` before then is the conservative answer and
     * the true one — a machine cannot have sent a frame on a link that does not
     * exist yet.
     */
    /*
     * And the fact that makes the verb above fire for a session this app never
     * started: which of that machine's sessions has a browser window *here*.
     *
     * Read out of the binding map every time it is sent, because that map is the
     * only authority on it and a copy kept here would be a second one. Every
     * session with at least one window, ended or not — a window is kept when its
     * pty dies, deliberately (`SessionBinding.ended`), and a list that dropped it
     * would answer "no window" about a page still on screen.
     *
     * See `MachinesIpcDeps.windowsHeld`, and `window.holds` in `protocol.ts` for
     * why the whole set travels rather than a change.
     */
    windowsHeld: (machineId) =>
      bindingView()
        .sessions.filter((binding) => binding.machineId === machineId && binding.windows.length > 0)
        .map((binding) => binding.sessionId),
    /*
     * And the mirror of that fact, which is what makes the *fourth* arrangement
     * possible at all: what is running **here**, told to every machine this
     * desktop dialled.
     *
     * A paired computer sees the sessions on the machine it dialled, because the
     * host pushes them. It has never seen the sessions on a machine that dialled
     * *it* — over there this desktop is a device that dialled in, and its session
     * picker is built from its own ptys plus the machines it dialled out to. So a
     * person sitting at that computer could not put one of its browser windows
     * beside a session running here, however much they wanted to.
     *
     * The same list the devices get, off the same fanout, so `hidden-sessions.ts`
     * applies once and in one place: a session unlisted here is unlisted there.
     */
    ownSessions: () => remoteSessions.list(),
    serveWindows: (machineId, call) =>
      serveWindowCall(
        {
          allowed: (id) => machinesIpc?.drivesWindows(id) ?? false,
          // That machine has a card in Machines, and the switch is on it.
          grantSwitch: 'for this computer in Machines, beside its name',
          control: () => deckControl?.control ?? null,
          /*
           * Whether a confirmation raised by this call could reach anybody.
           *
           * The same three checks `send` above makes, and for the same reason:
           * this app with no window, or one on its way out, cannot draw the
           * dialog `browser.step`'s first change on a public website asks for —
           * so the call would hold the far machine's tool call open until the
           * broker timed out. `attended: true` was asserted here for one
           * evening with a comment arguing that a person must be present; on
           * macOS an app with every window closed is still running, which is
           * exactly the state that argument does not cover.
           */
          attended: () =>
            !quitting && rendererAlive && mainWindow !== null && !mainWindow.isDestroyed(),
        },
        machineId,
        call,
      ),
    /*
     * And the mirror, in three lines because the machinery is already there.
     *
     * `windowsHeldThere` is what that machine says it is holding for *this* one;
     * it lands on `machineWindowAsks`, the second `WindowAskDesk`, which is the
     * table `routeWindowVerb` reads through `machineHolders`. `windowAnswered`
     * settles a question this app asked. `windowsUnreachable` settles every
     * question outstanding to a link that has gone, in milliseconds rather than
     * at a fifty-five second deadline.
     *
     * Nothing here decides anything, and nothing here is a second copy of
     * anything: the desk is the same file the device side uses, and the only
     * difference between the two instances is the wire below.
     */
    windowsHeldThere: (machineId, sessions) => machineWindowAsks.held(machineId, sessions),
    windowAnswered: (result) =>
      machineWindowAsks.answer(result.id, { ok: result.ok, body: result.body }),
    windowsUnreachable: (machineId) => machineWindowAsks.gone(machineId),
  })
  /*
   * And the wire that desk sends on, given to it once the links exist.
   *
   * The same shape `server.ts` gives the device-side desk, one layer over: `ask`
   * puts the frame on that machine's link and says whether it was heard, and
   * `reaches` asks the same question without writing to anybody's network. Both
   * read through `machinesIpc` rather than closing over a link, because links
   * come and go and the desk outlives all of them.
   */
  machineWindowAsks.serve({
    ask: (machineId, message) => machinesIpc?.askWindow(machineId, message) ?? 0,
    reaches: (machineId) => machinesIpc?.servesWindows(machineId) ?? false,
  })
  /*
   * The other half of Machines: computers nobody sits at. §5.5.
   *
   * Assembled here, beside the paired-device half, because they are one panel
   * and one rail row. Everything below is A's three objects handed to B's
   * registration through the seam written into `ipc.ts`'s deps — the reason it
   * takes them as arguments rather than importing them is so the permission and
   * way-back logic can be exercised with a plain object and no `ssh2` anywhere
   * near it, and so the headless host can register the identical handlers
   * against its own transport.
   *
   * Its own folder under userData rather than `remote/`. What is stored is a
   * list of addresses and an encrypted blob of sign-ins, and those belong to a
   * different subject than the pairing bearer tokens beside them — the file
   * names collide otherwise, and a `--user-data-dir` scratch instance is meant
   * to be able to hold a completely separate set of servers.
   */
  const serversDir = join(app.getPath('userData'), 'servers')
  mkdirSync(serversDir, { recursive: true })
  const serverStore = new ServerStore(serversDir)
  const serverCredentials = new ServerCredentials(serversDir)
  const serverConnections = new ServerConnections(serverStore, serverCredentials)
  servers = registerServersIpc(ipcMain, {
    storageDir: serversDir,
    /*
     * Named fields rather than the stored row, so that a field added to the
     * store later has to be *chosen* to cross the bridge instead of arriving
     * because nobody stopped it. What crosses is the identity the server hands
     * every client that dials it — public, and the thing §3.6's screen exists
     * to let a person compare — and which *kind* of sign-in is kept, which is
     * not the sign-in.
     */
    servers: () =>
      serverStore.list().map((row) => ({
        id: row.id,
        name: row.name,
        address: row.address,
        username: row.username,
        credential: row.credential,
        ...(row.hostKey === null ? {} : { hostKey: row.hostKey }),
        // Whether sessions on it may act on browser windows here. Chosen to
        // cross, like the two above it: the page draws a tick for it, and a
        // permission the screen cannot see the state of is a control that
        // cannot be trusted.
        drivesWindows: row.drivesWindows,
      })),
    store: serverStore,
    credentials: serverCredentials,
    facts: (serverId) => serverConnections.probe(serverId),
    run: (serverId, argv) => serverConnections.run(serverId, argv),
    runScript: (serverId, script) => serverConnections.runScript(serverId, script),
    openShell: (serverId, size, startIn) => serverConnections.shell(serverId, size, startIn),
    // The folder picker's one question. It rides whatever connection is already
    // open and dials only if none is, which is the same bargain every other
    // verb here makes — there is still no timer and nothing connected to a
    // server nobody is looking at.
    listFolder: (serverId, path) => serverConnections.listDirectory(serverId, path),
    // The other half of the folder picker's channel: a file *onto* the server,
    // so a terminal running there can be handed a path its own machine can open.
    // The folder is this app's name, decided here rather than in `connection.ts`
    // — the SSH layer has no business knowing what this app is called.
    putFile: (serverId, localPath, name) =>
      serverConnections.putFile(serverId, localPath, name, BRAND.name),
    /*
     * And a range of bytes back off it, over the same SFTP channel.
     *
     * The chat view over a server terminal is the caller: a transcript on that
     * server is found by one script and then tailed by offset as the agent over
     * there appends to it. A range rather than a file because a transcript
     * reaches 154 MB on this machine and is being written while it is read —
     * `connection.ts` carries the argument, and `servers/chat.ts` the rule for
     * which file belongs to which shell.
     */
    readFileRange: (serverId, path, from, length) =>
      serverConnections.readFileRange(serverId, path, from, length),
    /*
     * And a command that is not expected to finish, for the one thing this app
     * needs a server to *tell* it rather than be asked.
     *
     * Chat over a server terminal re-read the same transcript every three
     * seconds — twelve hundred round trips an hour, almost all of them
     * answering "nothing new", and still up to three seconds late when there
     * was. His rule: *"events, not polling — they make the system heavier."*
     * A `tail -f` on this channel is the same fact arriving instead of being
     * asked for, and it costs nothing while the agent over there is quiet.
     * `servers/chat.ts` is the caller and `connection.ts` the argument.
     */
    follow: (serverId, argv) => serverConnections.follow(serverId, argv),
    /*
     * The headless host this app would install on a server, or null.
     *
     * Two roots and no search: a packaged app carries it under `Resources`, and
     * a checkout has it under `out/` once `npm run dist:headless` has been run.
     * Null is a first-class answer — `host-package.ts` says why it must never
     * fall back to `npm install -g terminaldeck`, which is a name reservation
     * and would leave a host that looks installed and answers nothing.
     */
    hostPackage: () =>
      findHostPackage(app.getVersion(), {
        resources: app.isPackaged ? process.resourcesPath : null,
        tree: app.isPackaged ? null : app.getAppPath(),
      }),
    /*
     * The last step of a host install: the code that host prints into the
     * terminal on this screen, redeemed here in the same second.
     *
     * `machinesIpc` is captured rather than passed, and it is not null by the
     * time this runs — it is registered above, and this closure is only reached
     * from a button on a server page. `false` before then is not a case: the
     * fallback is `ServerHosts.link` showing the code instead, which is what a
     * build with no machine channels does.
     *
     * The security argument for redeeming a code this app read out of an SSH
     * connection it authenticated, rather than showing it to somebody, is
     * written where it is spent — `servers/host.ts`, above `ServerHosts.link`.
     */
    linkThisComputer: async (code) =>
      (await machinesIpc?.linkWithCode(code)) ?? {
        ok: false,
        message: 'This build has no Machines list to link that host into.',
      },
    // And the question the panel asks before offering to link at all: is that
    // host already one of this desktop's machines, and is the link behind that
    // row up? Read per call off the same store and the same live links, never
    // cached here — a second copy is how a screen and the truth come to
    // disagree, which is precisely what a panel claiming a link that had not
    // carried a byte in two hours was.
    linkStanding: (hostId) => machinesIpc?.linkStanding(hostId) ?? null,
    // And the remedy for the one contradiction that panel can see by itself.
    redial: (hostId) => {
      machinesIpc?.redial(hostId)
    },
    // And the wait that keeps an install's last sentence true: pairing ends at
    // the far end's approval, and the channel comes up a beat after it.
    whenReaching: async (machineId, ceilingMs) =>
      (await machinesIpc?.whenReaching(machineId, ceilingMs)) ?? false,
    // §5.4 in one pair of lines: the page holds the connection while it is open
    // and lets go when it closes. There is no timer here and no keep-alive, and
    // a server nobody is looking at is not dialled at all.
    acquire: (serverId) => serverConnections.acquire(serverId),
    release: (serverId) => serverConnections.release(serverId),
    // The two the agent setup needs: one channel on the live connection to
    // carry a sign-in's redirect back to the server's own listener, and the
    // person's own browser to approve it in. Deliberately their browser rather
    // than this app's — the navigation that finishes a sign-in carries a
    // one-time code, and the bound browser records every navigation.
    withConnection: (serverId, fn) => serverConnections.withConnection(serverId, fn),
    openInBrowser: (url) => shell.openExternal(url),
    broadcast: (channel, payload) => send(channel, payload),
    /*
     * The panel for a key that is not in `~/.ssh` — a `.pem` a hosting company
     * gave somebody, which lands in Downloads.
     *
     * Injected because a panel needs a window to be a sheet on and windows live
     * here, which is the same split `copilot-folder.ts` and `project-picker.ts`
     * make. It stands in Downloads for the reason those two write down at
     * length: omitting `defaultPath` is not "no preference", it is "open
     * wherever this app was last left", which is a folder the person did not
     * choose and cannot predict.
     *
     * `showHiddenFiles` is on because `~/.ssh` is hidden on every platform this
     * ships to, and a panel for choosing a key that cannot show the folder keys
     * live in would be a control that cannot do its one job.
     */
    pickKeyFile: async () => {
      if (!mainWindow) return null
      const { canceled, filePaths } = await dialog.showOpenDialog(mainWindow, {
        properties: ['openFile', 'showHiddenFiles'],
        title: 'Choose a key file',
        buttonLabel: 'Use this key',
        defaultPath: app.getPath('downloads'),
      })
      return canceled || filePaths[0] === undefined ? null : filePaths[0]
    },
    /*
     * The last two: how a session on a server reaches the browser window
     * attached to it.
     *
     * Both are read at the moment they are needed rather than captured, because
     * neither exists yet. `deckControl` is assigned a few hundred milliseconds
     * after this line, when the control server has bound, and `sessionTools` a
     * line after that — so a terminal opened inside that window is opened
     * without the verbs and told so, exactly as a local session started in the
     * same moment is (`session-verbs.ts`'s `early`).
     */
    controlPort: () => deckControl?.endpoint.port ?? 0,
    mintSessionTools: (grant) => sessionTools?.prepareElsewhere(grant) ?? null,
    /*
     * And the other endpoint, which is the one his three complaints about a
     * server session all landed on.
     *
     * `deck-control` carries the browser *verbs*; this carries where a URL goes
     * and every answer an agent's own hooks are given, which is how a session
     * comes to know it is inside this app and that a window has been attached to
     * it. Read at the moment it is needed for the same reason `controlPort` is —
     * it binds after this line runs, and a terminal opened in that gap gets no
     * belonging half and says nothing about one.
     */
    hookEndpoint: () => {
      const live = currentHookEndpoint()
      return live === null ? null : { socketPath: live.socketPath, token: live.token }
    },
    /*
     * The documents a session on a server is given, composed here because this
     * is where the app's own version and this computer's name live.
     *
     * They are the same three pages a local session can read, said for a machine
     * that is not this one: the hooks over there come from a settings file in a
     * folder under `/tmp` rather than from an account's `~/.claude/settings.json`,
     * and the browser windows they describe are on this screen rather than on
     * that server. `app-context.ts` owns every word of it.
     */
    remoteContext: (serverName, opensInApp) =>
      composeRemoteContext({
        version: app.getVersion(),
        serverName,
        appMachineName: describeThisMachine().name,
        opensInApp,
      }),
  })
  /*
   * A server's own `localhost`, in the same one browser window.
   *
   * Registered here rather than inside `registerServersIpc` because of a fence
   * that folder puts up: `host-key-checked.test.ts` walks the syntax tree of
   * every source in `servers/` and fails the build unless `connection.ts` is
   * the only file that reaches the transport. So this module never names the
   * library — it is handed a connection somebody else opened, and it asks that
   * connection for one thing.
   *
   * `facts` is the probe that already runs, and only its list of what is
   * listening is read. A second question to the server would have been a second
   * way to be wrong about which tool a machine has for answering it.
   */
  serverReach = registerServerReachIpc(ipcMain, {
    servers: () => serverStore.list().map((row) => ({ id: row.id, name: row.name })),
    withConnection: (serverId, fn) => serverConnections.withConnection(serverId, fn),
    facts: (serverId) => serverConnections.probe(serverId),
    tunnelsDropped: (serverId) => browserReach?.forget(serverId),
  })
  /*
   * And the one list of those listeners, with a reader count on each.
   *
   * Registered after both bridges because it is the thing above them: it does
   * not open a tunnel, it decides which bridge to ask and remembers which
   * browser windows are still reading the answer. Before this, every browser
   * window kept its own list in React state while the listeners were single
   * and shared, so a second window drew no machine chip over a page it was
   * reading through a tunnel, and one window moving its page home closed the
   * listener under another. See `browser-reach.ts` for the whole of it.
   */
  browserReach = registerBrowserReachIpc(ipcMain, {
    open: (kind, machineId, port) =>
      kind === 'server'
        ? (serverReach?.reach(machineId, port) ??
          Promise.resolve({ ok: false as const, message: 'This build cannot reach a server.' }))
        : (machinesIpc?.reach(machineId, port) ??
          Promise.resolve({
            ok: false as const,
            message: 'This build cannot reach another machine.',
          })),
    // False when there is no bridge to ask, which is the honest answer: this
    // process cannot say the address is free, so the row stays and the badge
    // keeps naming the machine that may still be answering there.
    close: (kind, machineId, port) =>
      kind === 'server'
        ? (serverReach?.closeReach(machineId, port) ?? false)
        : (machinesIpc?.closeReach(machineId, port) ?? false),
    broadcast: (channel, payload) => send(channel, payload),
  })

  powerMonitor.on('resume', () => {
    remote.server.wake()
    // A guest link that slept through a suspend is as dead as a host one, and
    // for the same reason: TCP will not admit it for minutes. One event, both
    // halves.
    machinesIpc?.wake()
    /*
     * And a schedule that came due while the lid was shut.
     *
     * `setTimeout` does not run while a Mac is suspended and does not make up
     * the time when it wakes, so a routine due at 03:00 on a laptop that was
     * closed would fire whenever the timer eventually caught up — hours late,
     * with nothing on screen saying so. This is the same event, already being
     * listened to, rather than one more timer asking what the clock says.
     */
    routines.engine.wake()
  })
  // The GitHub sign-in stores a token of its own when the user connects from
  // inside the app, so this registration is the one that needs to know where
  // this build keeps its data. `registerGitHubIpc` wires the auth channels too.
  registerGitHubIpc(ipcMain, { userDataDir: app.getPath('userData') })
  registerReadinessIpc(ipcMain)
  registerDashboardIpc(ipcMain)
  registerSessionSearchIpc(ipcMain)
  registerArtifactsIpc(ipcMain)
  registerProfilesIpc(ipcMain)
  // The one profile question that cannot be answered by reading a directory:
  // whether an account is signed in. See `profiles-signin.ts`.
  registerSignInIpc(ipcMain)
  // One conversation history across several accounts — Option C. Three
  // channels rather than a toggle, because the state is read back off the disk
  // and never inferred from the fact that a button was pressed.
  registerSharedProjectsIpc(ipcMain)
  /*
   * And the accounts that predate it are brought onto it here, once, on the way
   * up.
   *
   * Option C was built, measured and then left switched off behind a control in
   * Settings, which meant every account anybody already had kept its own
   * conversation store and every switch lost the conversation — the exact
   * complaint the feature was built to answer, reported again with the fix
   * sitting unused in the same build. `adoptSharedHistory` is idempotent and
   * never throws, so this costs one `lstat` per account on every subsequent
   * launch and cannot stop the app coming up.
   */
  {
    const adopted = adoptSharedHistory(profilesState().profiles)
    if (adopted.joined.length > 0 || adopted.failed.length > 0) {
      logger.info('accounts', 'shared conversation history', {
        joined: adopted.joined,
        left: adopted.left,
        failed: adopted.failed,
      })
    }
  }
  /*
   * The copilot: one session, in a folder of its own, run as the person.
   *
   * Handed the core's own `startSession` rather than a starter of its own,
   * because the whole design rests on the copilot being an ordinary session —
   * that is what makes `sessions.list`, the transcript viewer, chat mode and
   * the cost pane work on it with no changes. `copilot-session.ts` decides
   * where it runs; it does not decide what a session is.
   *
   * Nothing here names an account or a boundary any more, and the absence is
   * the point: the copilot resolves its profile through the profile system like
   * every other session, and it is confined by nothing. What it *cannot* touch
   * is three of this app's own files, measured per start — see
   * `confine/records.ts`.
   */
  registerCopilotIpc(ipcMain, {
    /**
     * The same `startSession` everything else uses — announced, which it was
     * not.
     *
     * `session:created` is how a window learns about a session it did not ask
     * for through `session:create`, and the copilot has always been exactly
     * that: the renderer asks `copilot:ensure`, which answers with a
     * `CopilotState`, not with a `SessionMeta`. So the window knew the copilot's
     * *id* and nothing else about it — no title, no status, no account, no
     * `createdAt`. That did not matter while the copilot was a page that mounted
     * a terminal by id; it matters now that it is a window, because a pill needs
     * a status dot, a bar needs an account, and the control cluster is resolved
     * from the session record.
     *
     * The channel's own rule is kept, not bent: it is not fired for a session
     * the renderer asked for *and is about to be handed the meta of*, because a
     * consumer adding a tab on both would show two. Nothing here hands the meta
     * back to the renderer, so there is no second arrival to double up with.
     *
     * Announced after the spawn resolves and only on success, so a refused start
     * — no Claude Code on this machine — reaches the window as the refusal it
     * is, rather than as a tab for a session that does not exist.
     */
    startSession: async (...args) => {
      const meta = await startSession(...args)
      announceSession(meta)
      return meta
    },
    isAlive: (id) => ptys.list().some((meta) => meta.id === id && meta.exitCode === null),
    stop: (id) => ptys.kill(id),
    userData: () => app.getPath('userData'),
    storageDir: remoteStorageDir,
    /*
     * Where its tools come from, asked at the moment it starts.
     *
     * Read off the handle rather than composed from `mcpConfigPath()`, and the
     * difference is the whole point: the handle exists only when the loopback
     * server is actually listening and the config on disk actually holds that
     * server's live token. `deck-control` starts asynchronously at boot and can
     * fail to start — a port that will not bind, a token file that cannot be
     * made owner-only on Windows — and in every one of those cases the *path*
     * still exists while the server does not. Handing the CLI a config that
     * points at nothing would produce a copilot that starts, believes it has
     * tools, and cannot reach one.
     *
     * A function rather than a value because of the ordering: this registration
     * runs before the `.then` below that assigns `deckControl`, and the copilot
     * is started later still, by a window or by whoever opens it. Evaluated at
     * start time, the answer is the truth at start time.
     */
    mcpConfig: () => deckControl?.configPath ?? null,
    /*
     * Which folder it works in, read at every start rather than captured.
     *
     * `copilot-folder.ts` turns this into a usable path — a chosen folder that
     * has been unmounted or deleted falls back to the default and says why. All
     * this has to do is answer with what the setting holds.
     */
    home: () => storedValue(COPILOT_HOME_SETTING) as string | null,
    /*
     * The live tool catalogue, for the generated half of the copilot layer.
     *
     * `control.tools()` is the same array `tools/list` answers with, so the file
     * that tells the copilot what it can do is composed from the tools that
     * actually exist — including the ones contributed at assembly time, like the
     * browser tools, which a hard-coded list in a template would have missed.
     * Undefined until `deckControl` resolves, and empty is the honest answer for
     * a copilot started before the server is listening.
     */
    tools: () => deckControl?.control.tools() ?? [],
  })
  /*
   * Choosing the folder, and the native panel that does it.
   *
   * The panel is here because it needs a window to be a sheet on; every rule
   * about which folder is acceptable is in `copilot-folder.ts`, where it can be
   * tested without one. `defaultPath` is always passed, for the reason
   * `project-picker.ts` measures at length: omitting it means "open wherever
   * AppKit last left you", which on the machine that was recorded on meant an
   * empty directory and a picker listing nothing, four openings in a row.
   */
  registerCopilotFolderIpc(ipcMain, {
    userData: () => app.getPath('userData'),
    read: () => storedValue(COPILOT_HOME_SETTING) ?? null,
    write: (value) => {
      patchStoredSettings({ [COPILOT_HOME_SETTING]: value === null ? null : value })
    },
    runningIn: () =>
      copilotState({
        startSession,
        isAlive: (id) => ptys.list().some((meta) => meta.id === id && meta.exitCode === null),
        stop: (id) => ptys.kill(id),
        userData: () => app.getPath('userData'),
        home: () => storedValue(COPILOT_HOME_SETTING) as string | null,
        storageDir: remoteStorageDir,
      }).folder.runningIn,
    homeDir: () => app.getPath('home'),
    pick: async (defaultPath) => {
      /*
       * No parent window, and that is the fix rather than an omission.
       *
       * Asad, 2026-08-17, watching this open: *"Why does this open like this? It
       * should open just like normal windows."* — and then the panel's own
       * button landed outside the visible area, so he cancelled and tried again.
       *
       * Passing `mainWindow` makes the panel a **sheet**: on macOS it drops out
       * of that window's title bar and is clipped to that window's bounds. On a
       * window shorter than the panel wants to be, the row of buttons along its
       * bottom edge is not drawn at all — which is exactly what he hit, and it
       * is why cancelling and retrying sometimes appears to work (the sheet
       * remembers a smaller directory listing the second time).
       *
       * With no parent, Electron shows the free-standing Open panel every other
       * Mac application shows: its own window, its own size, its own buttons.
       * It is still application-modal, so nothing about the flow's ordering
       * changes, and the renderer still steps the dialog aside while it is up
       * (`Modal`'s `hidden`) because a native panel is above every pixel the
       * renderer draws either way.
       *
       * The `message` came off with it. On macOS that string is drawn as a block
       * of text inside the panel, which is what made it tall enough to have this
       * problem in the first place; the same sentence is one hover away on the
       * screen that opens it (`CHOOSING_A_FOLDER`, behind the ⓘ), which is where
       * somebody is deciding rather than mid-decision.
       *
       * `mainWindow` is no longer required for the panel, but the guard stays:
       * a folder chosen with no window open would have nowhere to report back
       * to, and the copilot's folder is not a thing to change from a menu bar.
       */
      if (!mainWindow) return null
      const { canceled, filePaths } = await dialog.showOpenDialog({
        properties: ['openDirectory'],
        title: 'Choose the copilot’s folder',
        buttonLabel: 'Use this folder',
        defaultPath,
      })
      return canceled || filePaths.length === 0 ? null : (filePaths[0] ?? null)
    },
    log: (entry) =>
      appendCopilotAction(
        copilotPaths(
          app.getPath('userData'),
          storedValue(COPILOT_HOME_SETTING) as string | null,
        ),
        entry,
      ),
  })
  /*
   * Looking at the copilot, which is a different job from running it.
   *
   * Registered as its own module so the one above can keep the promise its
   * header makes — every handler there takes no arguments. These take a memory
   * file name and a place key, both checked in `copilot-inspect.ts`, and mixing
   * the two sets would make that sentence false in the file that relies on it.
   */
  registerCopilotInspectIpc(ipcMain, {
    userData: () => app.getPath('userData'),
    home: () => storedValue(COPILOT_HOME_SETTING) as string | null,
  })
  registerRoutinesIpc(ipcMain, routines.api)
  registerDeckignoreIpc(ipcMain)
  registerHooksIpc(ipcMain)
  registerMcpIpc(ipcMain)
  /*
   * Bytes on the clipboard, written to a file on this machine so that the one
   * rule about handing files to sessions can run over a path like everything
   * else. Same folder a phone's upload lands in — see `local-stage.ts`.
   */
  registerStageIpc(ipcMain, { dir: () => join(app.getPath('downloads'), BRAND.name) })
  registerBrowserIpc(ipcMain)
  // Beside the browser, because that is where a link now lands. The two
  // channels are the explicit way *out* — `link:system` and the context menu —
  // which only exists because in-app became the default.
  registerLinkIpc(ipcMain)
  /*
   * Which browser window belongs to which session.
   *
   * Beside the link channels because it is the same subject seen one level up:
   * `registerLinkIpc` decides whether a URL opens inside the app at all, and
   * this decides *which* of the app's windows it lands in when it came from a
   * session. Both are needed for the two halves of what Asad reported on
   * 2026-08-19 — a clicked link leaving for the system browser, and an agent's
   * page opening somewhere he was not looking.
   */
  registerBrowserBindingIpc(ipcMain, bindingDeps)
  /*
   * And every paired machine hears about it.
   *
   * A window attached here to a session running on another computer is a fact
   * only this app has — the `WebContentsView` is in this renderer — and the
   * machine the pty is on needs it, or the six browser verbs on that session
   * resolve in that machine's own empty map and answer "no browser window is
   * attached to this session" about a page on this screen. That was the first
   * thing Asad tried.
   *
   * Subscribed rather than called from `attach`, because a detach, a window
   * closing, a session being removed and a renderer reload are all the same
   * event to the far machine — "here is the set now" — and there is exactly one
   * place all four already meet. `subscribe` fires once immediately with the
   * current view, which is also correct: a link that came up before this line
   * has already announced on its own welcome, and saying it twice costs one
   * frame and cannot be wrong.
   */
  subscribeToBindings((next) => {
    /*
     * Only when the *set* moved.
     *
     * This map publishes on every change to it, and most of them are not this
     * fact: `windowMoved` fires on every navigation and every title change, so a
     * subscriber that announced unconditionally would put a frame on every
     * paired machine's socket for each page a person clicks through. The far
     * end's table is a set of session ids; a URL is not in it.
     */
    const now = next.sessions
      .filter((binding) => binding.machineId !== '' && binding.windows.length > 0)
      .map((binding) => `${binding.machineId}\u0000${binding.sessionId}`)
      .sort()
      .join('\n')
    if (now === announcedWindows) return
    announcedWindows = now
    machinesIpc?.announceWindows()
    /*
     * And the same fact down the other kind of link.
     *
     * A device connected *to* this app is told the same set for the same reason
     * a machine this app dialled out to is: the window is in this process and
     * the pty is on that computer, so nothing over there can derive it. One
     * subscription and one change test for both, because they are one fact —
     * `SessionBinding.machineId` names the computer the session runs on and the
     * two announcements differ only in which wire carries it.
     */
    remote.server.windowsHeldChanged()
  })
  /*
   * The sidebar row's ⋯ menu, on the same dependencies.
   *
   * Here rather than inside `registerBrowserBindingIpc` because it is not a
   * binding channel — it happens to *contain* one. Hanging it off the same
   * `bindingDeps` is what makes its Connect browser submenu the same list the
   * pane bar's button pops, over the same window, rather than a second one built
   * from a second set of handles.
   */
  registerSessionRowMenuIpc(ipcMain, bindingDeps)
  /*
   * The copilot's hands on the browser.
   *
   * Registered here, beside the browser itself and before `deck-control`,
   * because the five tools are closures over the object this returns — a drive
   * created lazily when somebody first asks for it would be a drive whose
   * channels are claimed after the renderer has already subscribed to them.
   */
  registerBrowserDriveIpc(ipcMain, {
    send: (channel, ...args) => send(channel, ...args),
    /*
     * And the one route a URL from a session takes, so a page the copilot opens
     * *for* a session lands in that session's numbered windows rather than in
     * the copilot's own unnamed tab. Bound to the same `bindingDeps` the shim's
     * `open` uses, which is what makes the `B2` an agent is told about and the
     * `B2` the pane bar draws the same window.
     */
    openForSession: (request) => openForSession(bindingDeps, request),
    /*
     * And the copilot's own pane, which is the one thing it may drive that
     * belongs to nobody.
     *
     * Bound to the same three answers the binding wiring already holds, because
     * "which panes exist" and "which of them are attached" have exactly one
     * authority in this process and a second opinion is how a session's window
     * came to be seized by a plain `browser.open`. See `BrowserDriveDeps.pane`.
     */
    pane: {
      open: (url) => openBarePane(bindingDeps.send, url),
      free: (tabId) => paneIsFree(tabId),
      view: (tabId, timeoutMs) => paneView(tabId, timeoutMs),
    },
  })
  registerChromeImportIpc(ipcMain)
  registerPrerequisitesIpc(ipcMain)
  /*
   * Attaching something that is not in the open project.
   *
   * The project-scoped picker stays the default and keeps its own argument —
   * `renderer/chat/attach/AttachPicker.tsx` makes it, and it is a good one. This
   * is the escape hatch beside it: the real open panel, a drop target on the
   * composer, and a paste. `boundaryOf` is what stops it being offered to a
   * session that is held inside a folder and could not read the file anyway;
   * `session-boundary.ts` explains why that question has to be asked here.
   */
  registerAttachOutsideIpc(ipcMain, {
    window: () => mainWindow,
    pasteDir: join(app.getPath('userData'), 'pasted'),
    home: () => app.getPath('home'),
    boundaryOf: (sessionId) => boundaryFor(sessionId),
  })
  // The other half of that: a file from outside a confined session is copied
  // inside rather than refused. See `attach-bring-in.ts` for why the refusal
  // alone was the wrong whole answer.
  registerAttachBringInIpc(ipcMain, { boundaryOf: (sessionId) => boundaryFor(sessionId) })
  registerSetupIpc(ipcMain)
  registerCookieImportIpc(ipcMain)
  registerBrowserIsolationIpc(ipcMain)
  registerSettingsIpc(ipcMain)
  // Profiles first: everything below asks which one is switched on, and
  // `registerBrowserSessionIpc` hardens that profile's session as its first act.
  registerBrowserProfileIpc(ipcMain, () => app.getPath('userData'))
  /*
   * Worker profiles and the session lift, immediately after profiles: a
   * worker *is* a profile, and everything below reads the profile store.
   *
   * The lift half of this is the app's only channel that copies a live
   * credential, and it is an `ipcMain` handler on purpose — reachable from
   * the window and from nowhere else. `deck-control` gets the two worker
   * verbs below and no way to lift. See `browser-session-lift.ts`.
   */
  registerBrowserWorkerIpc(ipcMain)
  /*
   * And the settings the four scraping engines had nowhere to read from.
   *
   * Immediately after the workers because it reports the fleet as part of one
   * configuration read, and because its status push is fired by the worker
   * pool. See `browser-scraping-ipc.ts` for why the engines needed a store at
   * all: every one of them takes its configuration as an argument on a tool
   * call, so nothing a person set on that screen outlived the call.
   */
  registerBrowserScrapingIpc(ipcMain, { send: (channel, ...args) => send(channel, ...args) })

  /*
   * The browser's tools store.
   *
   * Built here and wired one line below, because this is the only place that
   * knows where `userData` is — everything else about it is in
   * `browser-store.ts`, which takes a root and a catalogue and touches no
   * Electron, so it can be tested without an app.
   */
  installBrowserStore({ userData: () => app.getPath('userData') })
  registerBrowserStoreIpc(ipcMain)

  /*
   * The extension store, and the replay that makes it mean anything.
   *
   * Electron does not remember a loaded extension across boots — its own note on
   * `loadExtension` is that it *"must be called on every boot of your app"* — so
   * what is installed lives on this app's disk and is loaded from there at every
   * launch. Not awaited: `registerIpc` is synchronous and a slow extension must
   * not hold the first window shut. Every failure is kept and shown on the row
   * rather than swallowed. See `browser-extensions-ipc.ts`.
   */
  installBrowserExtensions({ userData: () => app.getPath('userData') })
  registerBrowserExtensionIpc(ipcMain)
  void loadInstalledExtensions()

  /*
   * Downloads in the built-in browser, including the ones bound for a computer
   * that is not this one.
   *
   * `deliver` is the only part of the feature that has to be assembled here,
   * because it is the only part that needs both halves of "another machine":
   * a paired desktop reached over the relay, and a server reached over ssh. They
   * share no protocol and answer the same shape, which is what lets
   * `browser-downloads.ts` hold one code path for both and is why the choice
   * between them is made by id here rather than by a flag on the wire.
   *
   * Servers are asked first because the two id spaces are separate stores and a
   * server id is the narrower question — `serverStore.get` is a lookup in a file
   * this process owns, while `machinesIpc.sendFile` has to answer for a link that
   * may be reconnecting.
   */
  installDownloads({
    userData: () => app.getPath('userData'),
    defaultDir: () => join(app.getPath('downloads'), BRAND.name),
    broadcast: (view) => {
      send(DOWNLOADS_CHANNEL, view)
    },
    deliver: async (machineId, localPath, folder) => {
      if (serverStore.get(machineId) !== null) {
        try {
          // The same `putFile` the folder picker's handover uses, and
          // deliberately so — see its header. `folder` is whatever was chosen on
          // *that* machine, `''` meaning the account's own login directory, and
          // the file keeps the name it was downloaded under unless something is
          // already called that over there.
          return {
            ok: true,
            path: await serverConnections.putFile(machineId, localPath, basename(localPath), folder),
          }
        } catch (error) {
          return {
            ok: false,
            // The server's own sentence where there is one. `ServerProblem`
            // messages are written to be read by a person and are the only thing
            // that can say *why* — a full disk, a folder that is not writable by
            // this sign-in, an SFTP subsystem that is switched off.
            message: error instanceof Error ? error.message : 'That server would not take the file.',
          }
        }
      }
      // The relay half. Read through the variable rather than captured for the
      // reason `machinesIpc` is declared at module scope at all: a build with no
      // remote layer has none, and a delivery bound for a machine it cannot
      // reach is a sentence on the row rather than a throw into `deliver`.
      const links = machinesIpc
      if (links === null) {
        return { ok: false, message: 'This copy of the app cannot reach other machines.' }
      }
      return await links.sendFile(machineId, localPath, folder === '' ? undefined : folder)
    },
  })
  setDownloadWindow(() => mainWindow)
  registerBrowserDownloadIpc(ipcMain)
  registerBrowserPasswordIpc(ipcMain, () => app.getPath('userData'))
  registerBrowserHistoryIpc(ipcMain, () => app.getPath('userData'))
  registerBrowserSignInIpc(ipcMain)
  // registerBrowserSessionIpc hardens the active profile's session.
  registerBrowserSessionIpc(ipcMain)
  registerBrowserViewIpc(ipcMain)
  registerDiagnosticsIpc(ipcMain)
  registerLogIpc(ipcMain)
  registerNotificationIpc(ipcMain)
  // Attached at launch rather than when its settings pane is first opened, and
  // the difference is not academic: `disablesleep` is a *system* setting that
  // survives a restart, so the ordinary case is this app starting on a machine
  // that is already being held awake. If nothing ran until somebody went looking
  // for the switch, the app would be sitting on top of a battery drain it had no
  // opinion about — nothing holding the idle-sleep blocker, nothing watching the
  // battery, and a switch that had never read the machine it is describing.
  lidAwake = registerLidAwakeIpc(ipcMain, { broadcast: (channel, payload) => send(channel, payload) })

  registerWslIpc(ipcMain, wsl)

  registerAlertsIpc(ipcMain, {
    liveSessions: (projectPath) =>
      ptys
        .list()
        .filter((meta) => meta.cwd === projectPath)
        .map((meta) => ({
          sessionId: meta.id,
          cwd: meta.cwd,
          status: liveStatus.get(meta.id)?.status ?? 'idle',
          statusSince: liveStatus.get(meta.id)?.at,
          provider: meta.provider,
        })),
    defaultProvider: () => store().getPreferences().defaultProvider,
    /*
     * The `alert` trigger, and the one subscription that is worth a sentence.
     *
     * Alerts have no push side: the panel asks and `alerts.ts` answers. Rather
     * than give routines a scanner of their own — which would be a second
     * expensive pass over every transcript, on a timer, which is exactly what
     * "events, not polling" objects to — the engine overhears the answers
     * somebody else already asked for. The cost of that is real and the engine
     * reports it: on a machine where nothing ever opens the alerts panel, no
     * report is produced and no `alert` routine fires.
     */
    onReport: (report) => routines.engine.noteAlertReport(report),
  })

  /**
   * The window asking for a session — and what happens when it cannot have one.
   *
   * The rejection travels on, so the caller still knows; but a rejection alone
   * is what the renderer does nothing with, and doing nothing is what a person
   * experiences as a button that does not work. There was no visible failure
   * path here at all until now, because there did not need to be: `startSession`
   * used to answer "that agent cannot run" by starting a shell instead, which is
   * the downgrade this whole change removes.
   *
   * So a start that fails is *held*, exactly like a session that failed to come
   * back at launch, and appears as the same row in the same place with the same
   * sentence and the same Try again. One mechanism and one place to look, rather
   * than a second notification surface for the same fact — and one that survives
   * the window being closed, which matters most for the case that produced this:
   * a WSL distribution that is asleep answers "not installed" for a few seconds
   * after login and then works.
   *
   * Only this channel. A session a phone asked for is answered on the wire the
   * phone is listening to, and the copilot's own start has `refuse`, which puts
   * its reason on the copilot's row — neither of them is a tab of somebody's
   * that went missing from this rail.
   */
  ipcMain.handle('session:create', async (_e, input: CreateSessionInput) => {
    try {
      return await startSession(input)
    } catch (error) {
      const why = error instanceof Error ? error.message : String(error)
      ledger.held.hold(
        {
          cwd: input.cwd,
          // `input.provider ?? 'claude'` is what `startSession` resolves an
          // absent provider to, and the held entry has to be the request that
          // was actually made or Try again would attempt a different one.
          provider: input.provider ?? 'claude',
          profileId: input.profileId ?? null,
          cols: input.cols,
          rows: input.rows,
          lastSeenAt: Date.now(),
          // Only when the request carried one, which means this was itself a
          // tab coming back. A start that failed before `startSession` could
          // mint a key has no tab to be held as, and inventing one here would
          // put a name in the arrangement for a session that never existed.
          ...(input.tabKey !== undefined ? { tabKey: input.tabKey } : {}),
        },
        `it could not be started: ${why}`,
      )
      announceHeld()
      logger.warn('session', `could not start: ${why}`, {
        folder: input.cwd,
        agent: input.provider ?? 'claude',
      })
      throw error
    }
  })

  /* ------------------------------------------- sessions that did not start -- */
  /*
   * Three channels for the sessions being held, and no fourth for "start them
   * all".
   *
   * A retry is one row at a time on purpose. The reason a session did not come
   * back is frequently specific to it — this agent is not installed, that folder
   * is on a volume that is not mounted — and a single button that fires four
   * spawns produces one outcome for four different problems, which is exactly
   * the shape of report ("it didn't work") that cannot be acted on. One row, one
   * attempt, one answer in that row.
   */
  ipcMain.handle(SESSIONS_HELD_CHANNEL, () => ledger.held.list())

  /**
   * Try again, now.
   *
   * Everything about this goes through the same two functions the launch used —
   * `planSaved` and `startSession` — because a retry that resolved the
   * conversation differently, or spawned differently, would be a second kind of
   * restore that only ever runs when the first one has already failed. That is
   * the least-exercised code in the app and the worst place for a difference.
   *
   * The entry is released only once a session actually exists. A retry that
   * removed the row and then threw would be the original bug in miniature: press
   * the button, the row disappears, the session is gone.
   */
  ipcMain.handle('session:held-retry', async (_e, key: unknown) => {
    const held = typeof key === 'string' ? ledger.held.get(key) : null
    if (!held) return ledger.held.list()

    const [decision] = await planSaved([savedFrom(held)])
    if (!decision || decision.outcome === 'skip') {
      ledger.held.fail(held.key, decision?.reason ?? 'it could not be planned')
      announceHeld()
      return ledger.held.list()
    }

    try {
      const meta = await startSession({
        cwd: held.cwd,
        cols: held.cols,
        rows: held.rows,
        provider: held.provider,
        profileId: held.profileId,
        resume: decision.outcome === 'resume',
        // As the same tab it was before it failed, not as a new one on the end
        // of the bar. See `SavedSession.tabKey`.
        ...(held.tabKey !== undefined ? { tabKey: held.tabKey } : {}),
      })
      ledger.held.release(held.key)
      send(SESSION_CREATED_CHANNEL, meta)
      logger.info('restore', 'came back on a retry', {
        folder: held.cwd,
        agent: held.provider,
      })
    } catch (error) {
      const why = error instanceof Error ? error.message : String(error)
      ledger.held.fail(held.key, `it could not be started again: ${why}`)
      logger.warn('restore', `retry failed: ${why}`, { folder: held.cwd, agent: held.provider })
    }
    announceHeld()
    return ledger.held.list()
  })

  /**
   * Stop holding it.
   *
   * The only way a held session leaves the list without starting, and it is a
   * person's decision rather than a timeout, because the app has no way to know
   * whether a folder is gone for good or gone until Thursday. Nothing is deleted
   * beyond the entry itself: the conversation is in the agent's own transcript
   * and is not this app's to remove.
   */
  ipcMain.handle('session:held-forget', (_e, key: unknown) => {
    if (typeof key === 'string' && ledger.held.release(key)) announceHeld()
    return ledger.held.list()
  })

  /* ------------------------------------ running this session as somebody else -- */

  /**
   * The plan, the switch and the deferred switch, wired to the channels this
   * window speaks.
   *
   * The operations themselves live in `session-switch-run.ts` and are shared
   * with the headless build — see `sessionSwitch` at module scope. What stays
   * here is only what a *window* adds: the sheet that will not stop anything
   * until somebody has read it, and the deferred switch that fires on his next
   * message.
   */
  ipcMain.handle(SESSION_SWITCH_PLAN_CHANNEL, async (_e, sessionId: unknown, profileId: unknown) => {
    const { plan } = await sessionSwitch.subject(sessionId, profileId)
    return plan
  })

  ipcMain.handle(SESSION_SWITCH_CHANNEL, (_e, sessionId: unknown, profileId: unknown) =>
    sessionSwitch.perform(sessionId, profileId),
  )

  /* ------------------------------- the same switch, at his next message -- */

  /**
   * Switches waiting for the session they are on to be spoken to again.
   *
   * The default Asad described, and the one difference from the channel above
   * is *when*: the running agent is left alone to finish, and the restart
   * happens in the gap before his next message is delivered. `switch-later.ts`
   * carries the whole argument, including why the typed line has to be carried
   * across and what happens when this app cannot be sure it read it correctly.
   */
  const pending = new PendingSwitches()

  /**
   * Arm one. The plan is computed now, and shown now, for the reason the
   * immediate switch computes one: a person agrees to something they have read,
   * and nothing here may be the first they hear of a consequence.
   *
   * It is re-planned at the moment it fires, and this stored copy is never
   * acted on — the account could be removed, or another tab could take the
   * conversation, in between arming and sending. `sessionSwitch.perform` asks again.
   */
  ipcMain.handle(SESSION_SWITCH_LATER_CHANNEL, async (_e, sessionId: unknown, profileId: unknown) => {
    const { plan } = await sessionSwitch.subject(sessionId, profileId)
    if (plan.refusal !== null || plan.to === null) {
      throw new Error(plan.refusal ?? 'This session cannot be switched.')
    }
    const armed = pending.arm({
      sessionId: plan.sessionId,
      profileId: plan.to.id,
      accountName: plan.to.name,
      plan,
    })
    return { sessionId: armed.sessionId, profileId: armed.profileId, note: armedNote(armed) }
  })

  /** Changed his mind. Nothing was stopped, so nothing has to be put back. */
  ipcMain.handle(SESSION_SWITCH_CANCEL_CHANNEL, (_e, sessionId: unknown) =>
    typeof sessionId === 'string' && pending.cancel(sessionId),
  )

  /**
   * What is armed right now, so a chip can say so after a reload.
   *
   * Read from the register rather than remembered by the window: a switch that
   * fired while a settings window was open is gone, and a chip drawing from its
   * own memory would still be promising it.
   */
  ipcMain.handle(SESSION_SWITCH_ARMED_CHANNEL, () =>
    pending.list().map((armed) => ({
      sessionId: armed.sessionId,
      profileId: armed.profileId,
      accountName: armed.accountName,
      note: armedNote(armed),
    })),
  )

  /**
   * Run an armed switch, then deliver the message it was waiting for.
   *
   * The order is what makes it safe. `sessionSwitch.perform` starts the replacement,
   * proves it is alive and only then stops the old session — so a switch that
   * fails leaves the old session running with the typed line still in its
   * prompt, exactly where the person left it, and the window is told why.
   *
   * The Enter is replayed only when `switch-later.ts` is certain its copy of
   * the line is the line. Where it is not, the text is placed in the prompt and
   * left there: sending a message on somebody's behalf that is not the message
   * they typed is worse than making them press Enter.
   */
  const fireSwitch = async (armed: ArmedSwitch, line: string, submit: boolean): Promise<void> => {
    let meta: SessionMeta
    try {
      meta = await sessionSwitch.perform(armed.sessionId, armed.profileId)
    } catch (cause) {
      const why = cause instanceof Error ? cause.message : String(cause)
      // The account id travels with the reason so the window can reopen the
      // sheet naming the account that was not reached. A sentence on its own
      // would leave it saying "an account" about a switch he chose by name.
      send(SESSION_SWITCH_FAILED_CHANNEL, armed.sessionId, armed.profileId, why)
      return
    }
    send(
      SESSION_SWITCHED_CHANNEL,
      armed.sessionId,
      meta,
      switchedNote(armed.accountName, submit, line),
    )
    if (line === '') return
    // A short settle, then the line. `REPLAY_SETTLE_MS` says why this is not
    // zero and why it is not longer.
    await new Promise((done) => setTimeout(done, REPLAY_SETTLE_MS))
    /*
     * Two writes, never one. `replayWrites` carries the measurement: a single
     * chunk of about 64 bytes or more is read by the CLI as pasted text, where
     * the carriage return is a newline rather than submit — so `${line}\r`
     * silently fails to send for almost every real prompt, and `switchedNote`
     * would say it had been delivered.
     */
    const [typed, enter] = replayWrites(line, submit)
    ptys.write(meta.id, typed)
    if (!submit) return
    await new Promise((done) => setTimeout(done, REPLAY_SUBMIT_GAP_MS))
    ptys.write(meta.id, enter)
  }

  ipcMain.on('session:write', (_e, id: string, data: string) => {
    // Typing into a session is the only honest "you were using this one"
    // signal the main process gets — the active tab is renderer state and
    // never crosses the bridge. It decides which tab in a folder gets to
    // continue the conversation on the next launch, because `--continue` is
    // per folder and only one can (see `session-restore.ts`).
    //
    // Memory only. This runs per keystroke, and persisting on a keystroke
    // would turn typing into disk traffic for a field that is a tiebreak. The
    // freshened value reaches the file on the next open or close, and on
    // `before-quit` — which is where a clean shutdown makes it exact.
    ledger.touch(id)

    /*
     * The one place a deferred account switch can fire.
     *
     * Everything a person sends an agent arrives here, so this is where "his
     * next message" is a fact rather than a guess. Ordinary typing is passed
     * straight through and is only *copied* on the way past — `observe` answers
     * `pass` for every session with nothing armed, which is all of them almost
     * always.
     *
     * The Enter is the byte that is not passed on. Delivering it would submit
     * the message to the account he has already asked to leave, which is the
     * whole thing this feature exists to prevent; `fireSwitch` replays it into
     * the replacement instead.
     */
    const action = pending.observe(id, data)
    if (action.kind === 'switch') {
      // What he typed before the Enter still goes to the old session, so the
      // screen he is looking at does not lose characters in the moment before
      // it is replaced.
      if (action.before !== '') ptys.write(id, action.before)
      void fireSwitch(action.armed, action.line, action.submit)
      return
    }
    ptys.write(id, data)
  })
  ipcMain.on('session:resize', (_e, id: string, cols: number, rows: number) => {
    // The tracker parses a rendered screen, so it has to be the same size.
    notePlanResize(id, cols, rows)
    ptys.resize(id, cols, rows)
  })
  ipcMain.handle('session:scrollback', (_e, id: string) => ptys.scrollback(id))
  ipcMain.handle('session:kill', (_e, id: string) => {
    // Forgotten here as well as on exit. `onExit` does arrive after a kill and
    // would clean up on its own, but it arrives *later*: a closed tab would
    // stay in the remembered list for that gap, and a crash inside it would
    // reopen a session the user had just closed.
    ledger.forget(id)
    // A switch armed on a session that is being closed has nothing left to fire
    // on, and leaving it in the register would list a promise about a tab that
    // is gone.
    pending.cancel(id)
    return ptys.kill(id)
  })
  ipcMain.handle('session:list', () => ptys.list())
}


/*
 * One copy of this app per machine, and the reason is not tidiness.
 *
 * `pinUserData` rewrites userData to a fixed path, so a second copy — a dev
 * build, a second launch, an installer run while the app is open — lands on the
 * *same* `~/Library/Application Support/terminaldeck` as the first. They then
 * share `relay-identity.json`, and both present that one identity to the relay.
 *
 * `Rendezvous.attachHost` replaces an incumbent rather than refusing a
 * newcomer, which is correct: a reconnecting host must be able to take its name
 * back, and a second copy is indistinguishable from a reconnect. So the two
 * processes evict each other, measured here every 25–55 seconds, forever.
 *
 * The damage is not obvious from either window. The rendezvous slot is named by
 * the *code*, so it is claimed cleanly and every measurement aimed at it comes
 * back healthy — but the address inside the offer is the shared host id. A
 * phone dials it and the relay routes it to whichever copy holds the name at
 * that instant. Half the time that is the copy with no code on screen, which
 * refuses the sealed handshake silently and by design. The phone clears, no
 * machine appears, and no approval prompt is ever shown.
 *
 * That is a real bug report, from this machine, and it cost a long time to find
 * precisely because nothing anywhere is in an error state.
 *
 * They also share `state.json` and `remote-auth.json`, and contend for port
 * 8443. The guard belongs here rather than in the relay client: nothing further
 * down can tell a second copy from a reconnect, and it should not try.
 */
if (startedAsWslBridge(process.argv)) {
  /*
   * A copy started to *be* the WSL bridge, by an executable that came up as the
   * app instead — and therefore a copy that must not become one.
   *
   * It cannot happen down the path `wsl-reach.ts` measured, and it is checked
   * anyway because what would go wrong is a second instance started once per
   * session, silently, on somebody's Windows machine. Ahead of the lock rather
   * than relying on it: asking for the lock would fire `second-instance` in the
   * running copy and put its window on their screen once per session, which is
   * the visible half of the same bug. `wsl-bridge.ts` has the argument.
   */
  process.stderr.write(
    `[${BRAND.name}] started as its WSL bridge but came up as the app, which means ELECTRON_RUN_AS_NODE ` +
      'did not cross into Windows. Leaving rather than becoming a second copy.\n',
  )
  app.exit(0)
} else if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', () => {
    // Somebody tried to launch it again — almost always because they forgot it
    // was running. Show them the window they already have.
    //
    // And when there is no window, build one, which is the whole point of the
    // background mode: launching the app after quitting it is exactly how a
    // person comes back to sessions that kept running, and this is the line
    // that path arrives on. It used to `return` — so on Windows and Linux,
    // where a relaunch is a second process meeting the single-instance lock,
    // double-clicking the icon did nothing at all and the running agents were
    // unreachable from the machine they were running on.
    if (mainWindow === null) {
      createWindow()
      return
    }
    if (mainWindow.isMinimized()) mainWindow.restore()
    mainWindow.focus()
  })
}

app.whenReady().then(() => {
  if (process.platform === 'darwin') app.setName(BRAND.name)
  applySecurityPolicy()
  registerIpc()
  /*
   * Read the installed distributions at launch, not when a settings pane asks.
   *
   * This is the failure this repository cares most about — a feature wired to a
   * button and never wired to boot — and it has three concrete consequences
   * here. Restore-on-launch runs before any window has painted and has to know
   * which side each remembered folder is on. A phone can ask for a folder list
   * seconds after the app starts, and that list has to be the Linux one. And a
   * stored distribution that has since been unregistered has to be noticed and
   * fallen back on, rather than producing "there is no distribution with the
   * supplied name" in a terminal the first time somebody starts a session.
   *
   * Nothing is started by this: `wsl.exe -l -v` reads a registry list, so a
   * stopped distribution stays stopped. It is a no-op off Windows.
   */
  void wsl.refresh().then(() => wsl.resolveHome().catch(() => null))
  /*
   * The hook endpoint, and — the half that was missing — the repair that has to
   * follow it.
   *
   * A unix socket inside this app's own data directory, `chmod 0600`, with a
   * per-run token in a config file beside it. Started early so hooks installed
   * into a provider's config have somewhere to report to; failure is not fatal
   * because everything except hook callbacks still works without it.
   *
   * `syncInstalledHooks` runs the moment it is listening, and it is the whole
   * reason this is two statements instead of one. The endpoint address is stable
   * now, so on an ordinary restart this rewrites nothing — but an install left
   * behind by a build that baked the port into the command reads as stale, and
   * this is what quietly re-points it. Without a call here the only repair in
   * the app is a button in Settings, which is exactly the "built, and never
   * wired to boot" failure this file keeps a paragraph about.
   *
   * Best-effort by construction: `syncInstalledHooks` swallows a per-provider
   * failure and the panel still shows the real state, so a config we could not
   * rewrite cannot stop the app starting.
   */
  /*
   * The `open` a session finds first, written before anything can start a
   * session.
   *
   * Not inside the `then` below, and that ordering is the whole of it: sessions
   * are restored at launch and a session started before the shim exists would
   * spend its life with the machine's own opener on its PATH — a session that
   * silently does not have the feature, in a way nobody would think to check.
   * The endpoint's config path is a pure function of the data directory, so it
   * can be known now; what is on the far side of it is written a few
   * milliseconds later, and a shim whose config is not there yet simply falls
   * through to the real opener, which is the same thing it does when the app is
   * closed.
   */
  writeOpenShim(
    app.getPath('userData'),
    hookConfigPath(app.getPath('userData')),
    currentPlatform(),
  )
  /*
   * The app's map of itself, written before anything can start a session, for
   * the same reason and in the same breath as the shim above it.
   *
   * After the shim rather than before, because `opensInApp` is a claim about
   * what that call just did: a document telling an agent that `open <url>`
   * lands in this app, written on a platform where nothing was shimmed, would
   * be a confident falsehood in a file it goes and reads on purpose.
   */
  writeAppContext({
    dir: app.getPath('userData'),
    version: app.getVersion(),
    machineName: describeThisMachine().name,
    opensInApp: currentOpenShim() !== null,
    platform: currentPlatform(),
  })
  void registerHookServer(ipcMain, {
    dir: app.getPath('userData'),
    /*
     * A URL an agent opened inside a session, arriving from the shim.
     *
     * Answered here rather than in the renderer because this is where it lands
     * and because the answer has to come back on the same connection the
     * agent's `curl` is holding open. `openForSession` is the same call a click
     * on a link in a terminal makes, which is what stops the two entrances
     * drifting apart.
     */
    /*
     * No machine is named, and that is the request rather than an omission.
     *
     * The shim that made this call was written by *this* app instance into
     * *this* machine's data directory and put on the PATH of sessions this
     * instance spawned, so an id arriving here belongs to a pty on this
     * computer — or to nothing at all. Writing `machineId: ''` would say the
     * same thing, and would say it in a way that survives a session on his PC
     * arriving here one day through some other door. Leaving it out asks
     * `machineOfSession`, which answers `''` for a local pty and the right
     * machine for anything else. See `openForSession`.
     */
    onOpen: ({ url, sessionId }) => openForSession(bindingDeps, { url, sessionId }),
    /*
     * What the agent is told at the start of its turn, so that it knows where it
     * is running and what "look at B2" means, without a byte being typed into
     * his terminal.
     *
     * Synchronous, and the two facts this file is the only place that can answer
     * are both handed in rather than looked up over there:
     *
     *  - `known` is `ptys.list()`, so a `claude` he ran in his own terminal —
     *    whose hook fires anyway, because the hook is installed for the whole
     *    machine — is never told it is inside this app. That is the same test
     *    `onOpen` above already applies to a URL, deliberately.
     *  - `opensInApp` is whether this run actually wrote the `open` shim, which
     *    it does not do on Windows and cannot do without a real opener to fall
     *    back to. Without it the sentence about where a URL lands would be a
     *    confident falsehood.
     *
     * Null for a session this app did not start is the same empty 204 this
     * endpoint has always answered, so nothing outside the app changes.
     */
    /*
     * Two answers, and which one depends on when the agent knocked.
     *
     * `SessionStart` and `UserPromptSubmit` are the top of a turn, so they get
     * the standing description: where it is running, which windows are its own,
     * where a URL goes.
     *
     * `PostToolUse` is the middle of one, and it gets the *change* and nothing
     * else. That is the whole of Asad's *"whenever I just connect, it should get
     * a context"* — a window attached while the agent is working lands at its
     * very next tool call rather than waiting for his next prompt.
     * `takeAnnouncement` drains, so it is said once and then the standing answer
     * carries it from there; a session with nothing new gets `null`, which is
     * the empty 204 this endpoint has always answered.
     *
     * And one more thing rides the first of those, on the knocks that *build* a
     * context rather than continue one: the app's own map of itself, from
     * `app-context.ts`. `bootMapFor` owns which events those are and answers
     * null for every other one, so it stays an argument here rather than a
     * third branch. A session this app did not start still gets null out of
     * `hookContext` and so is still told nothing at all.
     */
    contextFor: ({ event, sessionId }) => {
      const machineId = sessionId === null ? '' : (machineOfSession(sessionId) ?? '')
      /*
       * Whether this knock came from a shell on a server, and what that shell
       * actually got.
       *
       * Null for every local session and every paired machine, which is every
       * caller this branch had before today, so those answers are byte for byte
       * what they were. Non-null only for a server shell whose belonging half
       * was arranged, and it carries the two facts this file would otherwise get
       * *wrong* for one:
       *
       *  - `opensInApp` is a claim about that shell's PATH, not this Mac's. This
       *    build always writes the local shim on macOS, so reading
       *    `currentOpenShim()` for a server session would have promised an agent
       *    on somebody's Ubuntu box that `open <url>` lands here — the exact
       *    confident falsehood these answers exist to avoid.
       *  - `map` names documents on **that** machine.
       *    `<userData>/context/INDEX.md` is a path that does not exist there, and
       *    telling an agent to read it is telling it to read nothing.
       */
      const belonging = sessionId === null ? null : (servers?.belongingOf(sessionId) ?? null)
      // Two spellings of the same moment: Claude's `PostToolUse` and Gemini's
      // `AfterTool`. See `MID_TURN_EVENTS` in `browser-binding.ts`.
      return MID_TURN_EVENTS.has(event)
        ? sessionId === null
          ? null
          : takeAnnouncement(sessionId, machineId, noVerbsLine(sessionId))
        : hookContext(sessionId, machineId, {
            known: sessionId !== null && machineOfSession(sessionId) !== null,
            opensInApp: belonging === null ? currentOpenShim() !== null : belonging.opensInApp,
            map: bootMapFor(event, sessionId, machineId, belonging?.map ?? null),
            /*
             * And whether this one may act on the windows it is about to be
             * told about.
             *
             * The third fact this file is the only place that can answer, on
             * the same terms as the two above it: `host-core.ts` wrote down why
             * a launch was not given the browser verbs, and null here is both
             * "it has them" and "not ours" — which want the same silence. See
             * `session-verbs.ts`.
             */
            cannotDrive: sessionId === null ? null : noVerbsLine(sessionId),
          })
    },
  })
    .then(() => syncInstalledHooks(defaultContext()))
    .catch((err) => {
      /*
       * A visible failure, not a console line.
       *
       * This used to be `console.error` alone, which on a packaged app is a
       * stream nobody has open — and the one failure it actually caught (a data
       * directory too long for `sun_path`) took the whole context channel and
       * every status dot with it while the app looked entirely normal.
       * `hook-server.ts` keeps the reason and serves it on `hooks:server`, so
       * the Setup panel's "the local endpoint is not running" now carries the
       * sentence; this puts the same sentence in the app's own log, which is a
       * surface a person can open without a terminal.
       */
      logger.error('hooks', 'the hook endpoint did not start, so hook callbacks are off', {
        error: err instanceof Error ? err.message : String(err),
      })
    })
  /*
   * `deck-control`: the copilot's view of this app, and the gate in front of it.
   *
   * Started here rather than when a window opens the copilot, for the reason
   * that module's own header gives at length — a routine can call a tool before
   * anybody has clicked anything, and a surface that has only ever come up in
   * the attended case has never been exercised in the one that matters.
   *
   * Two things make this safe to have listening from boot. The socket is
   * loopback-only behind a per-run bearer token that is rewritten on every
   * start; and the alter tier is closed until a window says otherwise —
   * `isApprover` names exactly one window, and with none attached every
   * confirmation is refused as `no-approver` rather than waved through.
   *
   * `void … .catch`, like the hook server above: the app is entirely usable
   * without it, and taking the launch down because a loopback port could not be
   * bound would be the wrong trade by a wide margin.
   */
  void registerDeckControlIpc(ipcMain, {
    ptys,
    /*
     * The browser tools, contributed rather than declared.
     *
     * They close over the drive built above, and `buildCatalogue()` takes no
     * arguments — but the reason they go through `extraTools` rather than
     * beside the dispatcher is the one `control.ts` gives in its own header:
     * everything that wants to give the copilot a capability comes through the
     * one door, so it is tiered, prechecked, escalated, budgeted, gated and
     * logged like the fourteen that were always there.
     */
    // `registerIpc()` has already run — it is a few lines above this whole
    // block — so the drive exists. A conditional rather than a non-null
    // assertion because a wiring order that changed underneath this should
    // cost the copilot its browser tools, visibly, in a catalogue a person can
    // read, rather than take the launch down.
    /*
     * And the server room's named actions, on the same terms. §6.1.
     *
     * `servers` is built in `registerIpc()` above, so it is present on the
     * ordinary boot path; the conditional rather than an assertion is the same
     * judgement `browserDriveTools` makes one line up — a wiring order that
     * changed underneath this should cost the copilot those tools visibly, in a
     * catalogue somebody can read, rather than take the launch down.
     *
     * There is no `servers.run` in that list and there must not be: an
     * arbitrary-command tool is the whole machine, and it would make every
     * consequence sentence and every way-back decorative.
     */
    extraTools: [
      ...browserDriveTools(),
      ...browserWorkerTools(),
      /*
       * The four that tell a run whether it actually got what it went for.
       *
       * Unconditional, unlike the two lists either side of them, because they
       * close over nothing a wiring order could take away: a userData path and
       * one function that makes an HTTP request. `asset-tools.ts` has the four
       * losses each of them was written from.
       */
      ...assetTools({
        userData: () => app.getPath('userData'),
        probe: (url, options) => probeAsset(url, options),
        /*
         * The same function the probe resolves its session with, so a `HEAD`
         * and the `GET` after it cannot go out of different cookie jars.
         */
        open: (profileId) => assetFetchFor(profileId),
      }),
      ...browserStoreTools(),
      /*
       * What is running in the browser the session drives, and the switch for it.
       *
       * Unconditional, unlike the two browser lists above, because it closes over
       * nothing a wiring order can take away: every dependency is a function in
       * `browser-extensions-ipc.ts` that answers honestly — an empty list — when
       * the store was never built. `extension-tools.ts` has the argument for why
       * this is two verbs and not one tool per extension.
       */
      ...extensionTools({
        installed: (profileId) => installedExtensionsFor(profileId),
        isLoaded: (profileId, id) => isExtensionLoaded(profileId, id),
        currentProfileId: () => currentBrowserProfileId(),
        profileName: (profileId) => browserProfileNameFor(profileId),
        setEnabled: (profileId, id, on) => setExtensionEnabled(profileId, id, on),
      }),
      ...(servers === null ? [] : serverTools({ room: servers.room, grants: servers.grants })),
    ],
    /*
     * The one session starter, shared with the window and with a paired phone —
     * with the announcement the window needs wrapped around it.
     *
     * `startSession` on its own is what `session:create` calls, and it
     * deliberately does not broadcast: the window is about to be handed the same
     * `SessionMeta` as the return value of its own call, and a consumer that
     * added a tab on both would show two. A copilot-started session is the other
     * case — nobody in the window asked for it — so it needs exactly the
     * announcement a phone's session gets, and for the same reason.
     *
     * Without this the copilot could start a session that ran on this Mac with
     * no row in the sidebar until somebody reloaded the renderer: a process
     * spending money, holding a pty, and unreachable from the app that started
     * it. Found by watching it happen.
     */
    startSession: async (input) => {
      const meta = await startSession(input)
      announceSession(meta)
      return meta
    },
    sessionStatus: (id) => liveStatus.get(id),
    /*
     * How a change made from outside the window reaches the window.
     *
     * `send` and nothing of its own: a second sender would be a second idea of
     * which window is the window, and would outlive `before-quit` — which is the
     * whole reason `send` holds a liveness flag rather than asking Electron.
     * Passing it here is also what makes `settings.write` able to say whether a
     * value it saved is on the screen, because `send` answers that.
     */
    tellWindow: (channel, payload) => send(channel, payload),
    // A copilot write of a server-owned preference has to reach a phone watching
    // this machine, exactly as `prefs:set` above makes the window's own write do.
    // One store, one push, whichever surface changed it.
    noteServerSettingsChanged: () => core.serverSettings.noteChanged(),
    /*
     * Exactly one window may answer a confirmation, and it is this app's own.
     *
     * Identity, not a capability check: `webContents` for a browser tab's page,
     * or for any other frame this process ends up hosting, must never be able
     * to approve an alter-tier call. There is no default for this argument in
     * `DeckControlDeps` precisely so the question is answered here, where the
     * answer is known.
     */
    isApprover: (contents) => mainWindow !== null && contents === mainWindow.webContents,
    /*
     * The second surface a confirmation can appear on, and be answered from.
     *
     * A connected device runs a copilot of its own and may answer that run's
     * questions — `COPILOT-REMOTE.md` §4, revised. What makes that honest is not
     * that the device is trusted, it is that connecting the copilot is a
     * *separate* authorisation from pairing for terminals: a phone that can open
     * ten terminals here has no copilot reach at all until somebody at this
     * machine mints a connect code for it.
     *
     * A closure over `copilotRuns` rather than the object, and the reason is the
     * same one every other late-resolved dependency in this file has: this
     * registration is a `void`ed promise, and the run manager is assembled above
     * it but reassigned to a module-level binding. Reading it per question also
     * means a build that never assembled one — the headless daemon — delivers to
     * the window and nowhere else, which is exactly what it did before this
     * existed.
     */
    remoteApprover: {
      ask: (request) => copilotRuns?.ask(request) ?? false,
      settled: (id, outcome) => copilotRuns?.settled(id, outcome),
    },
    broadcast: (channel, ...args) => send(channel, ...args),
  })
    .then((handle) => {
      deckControl = handle
      /*
       * And the per-session half of the same endpoint.
       *
       * Its own directory under `<userData>` rather than the copilot's folder:
       * the copilot's is a folder a person opens and reads, and one directory
       * per session in it would be a pile of machinery in the middle of their
       * files. Everything in here is a secret with a lifetime of one session.
       */
      sessionTools = createSessionTools(handle.endpoint, {
        dir: join(app.getPath('userData'), 'session-tools'),
      })
    })
    .catch((err) => console.error('[deck-control] failed to start, copilot tools disabled:', err))
  /*
   * Read the routines folder and arm everything in it — at launch, before any
   * window has painted.
   *
   * This is the one wiring decision in the whole feature that could be got
   * wrong invisibly. A routine engine started when its settings pane opens is a
   * set of automations that run only while you are watching them, which is the
   * exact opposite of what a routine is for, and it would look completely
   * correct in every test that opens the pane first.
   *
   * After `registerIpc`, because starting reads the folder and a routine can
   * fire on the first event that arrives.
   */
  routines.engine.start()
  createWindow()
  buildMenu(() => mainWindow)

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

/* ------------------------------------------------- quitting, or not quite -- */

/**
 * True while this process is running with no window and live sessions in it.
 *
 * The state the whole feature turns on, and the reason it is a flag rather than
 * "are there zero windows": an app between windows on macOS has zero windows for
 * a fraction of a second, and an app whose renderer crashed has zero windows and
 * is not doing this deliberately. This is set exactly once, by {@link goBackground},
 * and it means *the app chose this*.
 */
let inBackground = false

/**
 * True once a quit is really a quit, so nothing asks a second time.
 *
 * Three things set it: the person answering "Stop Everything", the tray's own
 * quit item, and an update about to replace this bundle. Without it, the
 * `app.quit()` those paths call would come straight back into the question they
 * were the answer to.
 */
let stopping = false

/** Nothing runs on it; it exists to say the process is deliberately still here. */
const keepAlive = new ProcessKeepAlive()

/**
 * The menu-bar icon, built once and shown only while there is no window.
 *
 * Constructed at module scope rather than when it is first needed because the
 * session callbacks on the core refresh it, and those are wired before this line
 * runs. Constructing a `ResidentPresence` creates no `Tray` — `show()` does —
 * so this costs nothing on a launch that never goes to the background.
 */
const presence = new ResidentPresence({
  sessions: () => ptys.list(),
  open: () => {
    if (mainWindow !== null && !mainWindow.isDestroyed()) {
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.focus()
      return
    }
    createWindow()
  },
  stop: (id) => {
    ptys.kill(id)
  },
  quitAll: () => {
    stopping = true
    app.quit()
  },
})

/** Every session that still has a process. Exited tabs keep their row and are not this. */
function liveSessions(): SessionMeta[] {
  return ptys.list().filter((meta) => meta.exitCode === null)
}

/**
 * Put the window away and keep the machine working.
 *
 * The sessions are not moved, re-parented or handed anywhere: they are already
 * ptys owned by this process, and this function's entire job is to make sure
 * this process is still here in a minute. Which is why it is four lines and no
 * teardown at all — the relay stays dialled so the phone keeps working, the hook
 * server stays up so the agents' hooks keep landing, and the routines keep
 * firing, because every one of those is something the machine does rather than
 * something the window does.
 *
 * `ledger.flush()` and *not* `ledger.freeze()`, which is the difference between
 * this and a real quit. The remembered list has to stay live: a session that
 * exits while the app is in the background must leave the list, or the next
 * launch tries to restore something the person watched finish.
 */
function goBackground(): void {
  inBackground = true
  ledger.flush()
  keepAlive.hold()
  presence.show()
  if (!presence.visible && needsTrayToBeVisible(process.platform)) {
    /*
     * No tray, no window, no Dock icon — that is an invisible process, and this
     * app will not leave one behind. A Linux session with no notification area
     * is the real case; the honest answer there is to stop rather than to keep
     * agents running where nobody can find them.
     */
    logger.warn('resident', 'no tray could be created, so quitting rather than hiding')
    inBackground = false
    keepAlive.release()
    stopping = true
    app.quit()
    return
  }
  /*
   * Server shells are the one thing that genuinely cannot outlive the window,
   * so they are closed here rather than left holding a socket nobody can see.
   *
   * A session on this machine is a pty this process owns, and a session on a
   * paired machine runs inside *that* machine's host — both survive a window
   * going away because something that is not the window is holding them. A
   * server shell is neither: it is a channel on an ssh2 connection this app
   * holds, and the roster of them lives in the renderer, which is what
   * `machines/servers/server-sessions.ts` means by "the window is the owner".
   * Keeping them open past the window would leave authenticated connections to
   * somebody else's computer running with nothing on any screen able to list or
   * close them, which is precisely the orphan this feature must not create.
   *
   * They are closed the same way quitting closes them — see the `before-quit`
   * teardown — so nothing new is being invented for this path.
   */
  servers?.stop()
  serverReach?.stop()
  for (const window of BrowserWindow.getAllWindows()) window.close()
}

/** Undo {@link goBackground}. Called by `createWindow` and by every real quit. */
function leaveBackground(): void {
  inBackground = false
  keepAlive.release()
  presence.hide()
}

/** Guards the dialog, so a second quit while it is open does not open a second one. */
let asking = false

/**
 * Ask, once, what quitting should mean — and act on the answer.
 *
 * Asynchronous, and therefore after `event.preventDefault()`: `showMessageBox`
 * is the only version of this dialog that reports its checkbox, and a checkbox
 * is the only way "and stop asking" can be offered at the moment the question is
 * actually in front of somebody. The synchronous variant returns a button index
 * and nothing else.
 */
async function askWhatQuittingMeans(): Promise<void> {
  if (asking) return
  asking = true
  try {
    const running = liveSessions()
    const { message, detail } = quitQuestion(running)
    const answer = await dialog.showMessageBox({
      type: 'question',
      buttons: [...QUIT_BUTTONS],
      defaultId: 0,
      cancelId: 2,
      title: `Quit ${BRAND.name}`,
      message,
      detail,
      checkboxLabel: 'Do this from now on, and stop asking',
      checkboxChecked: false,
    })
    const choice = quitAnswer(answer.response)
    if (choice === 'cancel') {
      /*
       * Cancelling means "do not quit", and off macOS this question is reached
       * *after* the last window has already gone — closing it is what asked for
       * the quit in the first place. Returning here would leave a running app
       * with no window, no tray and no way back to it, which is the exact
       * invisible process this feature is not allowed to create. So the window
       * comes back, which is also what the person just asked for.
       */
      if (BrowserWindow.getAllWindows().length === 0) createWindow()
      return
    }
    // Remembered only for the answer actually given, and only when asked for.
    if (answer.checkboxChecked) store().setQuitBehavior(choice)
    if (choice === 'keep') {
      goBackground()
      return
    }
    stopping = true
    app.quit()
  } finally {
    asking = false
  }
}

app.on('window-all-closed', () => {
  /*
   * The last window closing is not a reason to end somebody's work.
   *
   * Off macOS this line has always meant "no window, no app", and with sessions
   * that outlive the window that is now a lie by one word: no window, no
   * *window*. When the app has deliberately gone to the background there is a
   * tray icon saying what is running and offering to stop it, so the process
   * staying is visible and undoable, which is the whole bar this feature has to
   * clear. Every other case is unchanged.
   */
  if (inBackground) return
  if (process.platform !== 'darwin') app.quit()
})

app.on('before-quit', (event) => {
  /*
   * The one decision this whole feature is: does quitting end the machine's
   * work, or only put the window away?
   *
   * It is asked here rather than on the menu item because there are four ways to
   * reach a quit — the menu, the accelerator, the last window closing off macOS,
   * and `app.quit()` from inside this file — and a question wired to one of them
   * is a question that three paths walk straight past.
   *
   * Three outcomes, and the second one is the new behaviour:
   *
   *  - **stop** — nothing is running, or the person has said this is what quit
   *    means. Falls through to the teardown below, which is what quitting has
   *    always done.
   *  - **keep** — the sessions stay, the window goes, a tray icon appears saying
   *    what is running. The quit is cancelled outright; `goBackground` is the
   *    whole of it.
   *  - **ask** — the default, and only ever reached with something to lose. The
   *    quit is cancelled while the question is on screen and re-issued by the
   *    answer, because a dialog that reports its checkbox cannot be synchronous.
   *
   * `keep` is refused while the app is *already* in the background, and that is
   * deliberate rather than an oversight. At that point there is no window, so a
   * quit can only have come from the app menu, its accelerator or the Dock — a
   * person deliberately quitting something they can see is running. Honouring
   * "keep" there would make Quit do nothing, over and over, with no way out
   * except the tray. An app that cannot be quit is worse than one that asks.
   */
  if (!stopping) {
    const plan = plannedQuit(liveSessions().length, store().getQuitBehavior())
    if (plan === 'ask') {
      event.preventDefault()
      void askWhatQuittingMeans()
      return
    }
    if (plan === 'keep' && !inBackground) {
      event.preventDefault()
      goBackground()
      return
    }
    stopping = true
  }
  leaveBackground()

  // Before `quitting`, deliberately. Every session is still live at this
  // instant, which makes this the most accurate the remembered list ever gets —
  // and one line further down `ledger.freeze()` closes the list for the rest of
  // the run, because `killAll` fires an exit per session and reconciling on
  // those would write down that nothing was open. A crash never reaches this
  // line, which is fine: the list is already correct from the last open or
  // close, and that is the case this whole feature is for.
  ledger.flush()
  ledger.freeze()

  // The browsing history, which is held in memory and written on a short delay
  // so a page whose title ticks is not a file write a second. This is the
  // moment that delay has to be made exact — see `flushHistory`.
  flushHistory()

  // First, and before `killAll`. Killing a PTY makes it flush, exit and push a
  // status, and all three of those broadcast — into a render frame that is
  // already being torn down. See `send`.
  quitting = true
  rendererAlive = false
  /*
   * Before `killAll`, so each run is unwound rather than merely killed.
   *
   * `killAll` ends the processes; this ends everything that pointed at them — a
   * bearer token out of `deck-control`'s caller table, an abort fired so a tool
   * call in flight resolves as `caller-gone` instead of hanging, and the config
   * file that held the token removed from disk. Doing it afterwards would leave
   * the manager unwinding runs whose ptys had already gone, which works, and
   * doing it before means the credential dies with the thing that used it.
   */
  copilotRuns?.stopAll()
  ptys.killAll()
  // Before `stopAllGitWatches`, because the engine holds git watches of its own
  // and releasing them is how the reference counts stay honest — and it writes
  // its run counters out, which is what stops a relaunch handing every routine
  // a fresh budget.
  void routines.stop()
  stopAllGitWatches()
  /*
   * The copilot's tool surface, closed.
   *
   * `stop()` refuses every outstanding confirmation before it shuts the socket,
   * which is the ordering that matters: an alter-tier call waiting on a dialog
   * must not be able to land halfway through a teardown, and the window it was
   * asked in is already going. The bearer-token file goes with it, so nothing
   * is left on disk holding a token that authenticates a server that has gone.
   */
  // Every browser verb still waiting on another computer is answered now, with
  // a sentence, rather than left for a deadline this process will not live to
  // see. See `window-asks.ts`.
  windowAsks.stop()
  // And the other desk. Two instances, two shutdowns: a question left pending on
  // either one is a tool call somebody's turn is blocked on, waiting out a
  // deadline for an app that is already gone.
  machineWindowAsks.stop()
  void deckControl?.stop()
  /*
   * Every server connection and every server terminal, closed.
   *
   * Not covered by `killAll` above: a server shell is a channel on an
   * authenticated socket to somebody else's computer, not a pty on this one, so
   * nothing else on this path knows it exists.
   */
  servers?.stop()
  serverReach?.stop()
  /*
   * Every token minted for a session, and the file holding it.
   *
   * Here and not in `goBackground`, deliberately. Closing the last window on
   * macOS leaves every session running — that is the whole point of that
   * function — and a session whose token had been revoked underneath it would
   * lose its browser verbs the first time he closed the window, with nothing on
   * screen to say why.
   */
  sessionTools?.stop()
  updates?.stop()
  lidAwake?.stop()
  void stopHookServer()
  // The shim goes with the endpoint it talks to. A script left behind is not
  // dangerous — with no socket answering it falls through to the real opener —
  // but it is a file this app put on somebody's PATH and no longer owns, and an
  // upgrade that leaves one behind ends up with two.
  removeOpenShim(app.getPath('userData'))
  // Nothing of anybody's account is written down, so there is nothing here to
  // clean up — this only closes the loopback listener and answers anything a git
  // is still waiting on, rather than leaving it to time out against an app that
  // has gone.
  void core.credentials.stop()
  void clearBrowserDataIfNotPersisting()
})
