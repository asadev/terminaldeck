import { existsSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  nativeTheme,
  powerMonitor,
  session,
} from 'electron'
import { BRAND } from '../shared/brand'
import type { CreateSessionInput, SessionMeta } from '../shared/types'
import { createHostCore } from './host-core'
import { detectProviders } from './providers'
import { lookupCommand, registerCustomAgentsIpc } from './custom-agents'
import { currentPlatform } from './platform/host'
import { electronPaths, installPaths } from './platform/paths'
/*
 * The held list travels on a channel named in the module that owns it — see
 * `SESSIONS_HELD_CHANNEL` there for why it is exported rather than declared
 * beside the handler down in this file, which is a fact about
 * `preload/contract.test.ts` as much as about the house rule.
 */
import { savedFrom, SESSIONS_HELD_CHANNEL } from './session-held'
import {
  conversationOnDisk,
  conversationScope,
  folderExists,
  personalSessions,
  planRestore,
  restoreOpenSessions,
  type RestoreDecision,
  type SavedSession,
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
import {
  startCopilotRun,
  tailForPhone,
  toCopilotSessions,
  watchRunChat,
} from './remote/copilot-wiring'
import { registerMachinesIpc } from './remote/machines/ipc'
import { registerServersIpc, type ServersIpc } from './servers/ipc'
import { registerServerReachIpc, type ServerReachIpc } from './servers/reach'
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
import { storedAccountLimits } from './account-limits'
import { registerGitHubIpc } from './github'
import { registerReadinessIpc } from './readiness'
import { registerDashboardIpc } from './dashboard-store'
import { registerArtifactsIpc } from './artifacts'
import { registerSessionSearchIpc } from './session-search'
import { registerAlertsIpc } from './alerts'
import {
  registerProfilesIpc,
  findProfile,
  getState as profilesState,
  resolveProfile,
} from './profiles'
/*
 * Switching the account a *running* session is on. The channels are named in
 * the module that owns the feature, for the same two reasons the held list's is
 * — the house rule, and `preload/contract.test.ts`, which can only resolve a
 * channel registered through an exported constant.
 */
import {
  planSwitch,
  SESSION_SWITCH_CHANNEL,
  SESSION_SWITCH_PLAN_CHANNEL,
  startFailed,
  survivedStart,
  switchRefusal,
  type SwitchPlan,
} from './session-switch'
import { registerSignInIpc } from './profiles-signin'
import { copilotState, registerCopilotIpc } from './copilot-session'
import { appendCopilotAction, copilotPaths } from './copilot-home'
import { COPILOT_HOME_SETTING, registerCopilotFolderIpc } from './copilot-folder'
import { registerCopilotInspectIpc } from './copilot-inspect'
import { registerDeckControlIpc, type DeckControlHandle } from './deck-control'
import { registerDeckignoreIpc } from './deckignore'
import { defaultContext, registerHooksIpc, syncInstalledHooks } from './hooks'
import { registerHookServer, stopHookServer } from './hook-server'
import { registerMcpIpc } from './mcp-client'
import { registerBrowserIpc } from './browser-tab'
import { openAppLink, registerLinkIpc } from './link-open'
import { browserDrive, registerBrowserDriveIpc } from './browser-drive-ipc'
import { browserTools } from './deck-control/browser-tools'
import { registerChromeImportIpc } from './chrome-import'
import { registerPrerequisitesIpc } from './prerequisites'
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
import { registerBrowserPasswordIpc } from './browser-passwords'
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
 * Latest status per live session. PtyManager only pushes status through its
 * callback, so anything that needs to *ask* (the alerts scanner) has nowhere
 * to read it from without this.
 */
const liveStatus = new Map<string, { status: SessionStatus; at: number }>()

/** Held so the recheck interval can be disarmed on quit. */
let updates: ReturnType<typeof registerUpdateIpc> | null = null

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
const core = createHostCore({
  storageDir: remoteStorageDir(),
  userData: app.getPath('userData'),
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
    // A dev server *is* a session, so its death is this event and nothing else.
    // Without this the row keeps a `url` for a server that is gone — the one
    // genuinely wrong thing this feature can put on screen.
    devServers.noteExit(id)
    // Two routine triggers are this one event: `session-finished` is a zero
    // exit and `session-failed` is anything else. Told here rather than from a
    // watcher of its own — the engine subscribes, it does not poll.
    routines.engine.noteSessionExit(id, exitCode)
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
  },
  // The window has to be told, or a session a phone started is running on this
  // Mac and only the phone knows about it.
  onSessionCreated: (meta) => announceSession(meta),
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
 * Repaint the Windows window-controls overlay for the theme that is on now.
 *
 * Without this the strip keeps whatever colour it was given at launch: switch
 * to the light theme and the top-right corner of a white window stays a dark
 * grey rectangle with the buttons in it, which is a more obvious defect than
 * the stacked title bars this replaced. It is a no-op on every platform that
 * has no overlay — `overlayFor` returns null there, and `setTitleBarOverlay` is
 * not a method that exists on macOS, so the guard has to come first.
 */
function syncTitleBarOverlay(): void {
  const overlay = overlayFor(process.platform, appearance())
  if (!overlay || !mainWindow || mainWindow.isDestroyed()) return
  mainWindow.setTitleBarOverlay(overlay)
}

function createWindow(): void {
  const saved = store().getState().windowBounds
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
    void hydrateRenderer()
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
const planSaved = (sessions: readonly SavedSession[]): Promise<RestoreDecision[]> =>
  planRestore(sessions, {
    // Asked about the folder as Windows can see it. Without the translation
    // every session that was running inside a distro is planned as "its folder
    // is gone" and dropped, which is the app losing a day's tabs and explaining
    // it with a sentence that is not true.
    folderExists: (cwd) => folderExists(statablePath(cwd)),
    // `core.canContinue`, not `PROVIDERS[provider].resumeArgs`: the table has
    // only the agents this build ships, so a restored session on an agent the
    // person added threw a `TypeError` here and took the whole restore — every
    // other tab included — down with it.
    canContinue: core.canContinue,
    /*
     * Resolved exactly the way `startSession` resolves it, and that is the
     * point: the directory searched for a conversation has to be the directory
     * the restored session will then write to, or the answer is about a
     * different login than the one coming back.
     *
     * Passing `conversationOnDisk` by reference used to be enough — it took an
     * optional config directory and fell back to the app's own. That fallback is
     * `~/.claude`, so every session that ran as a profile was asked about the
     * wrong store, answered "no conversation" and came back blank with its
     * transcript sitting untouched on disk. The profile is the whole reason the
     * transcripts moved.
     */
    configDir: (session) =>
      resolveProfile(profilesState(), {
        sessionProfileId: session.profileId ?? undefined,
        projectPath: session.cwd,
      }).configDir,
    conversation: conversationOnDisk,
  })

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
 * The copilot's browser tools, or none of them.
 *
 * Empty when the drive was never registered, which cannot happen through the
 * ordinary boot path and is worth being explicit about anyway: a catalogue
 * missing five tools is a thing the copilot reports honestly when asked what
 * it can do, and a `!` here would be a crash at launch instead.
 */
function browserDriveTools(): ReturnType<typeof browserTools> {
  const drive = browserDrive()
  return drive === null ? [] : browserTools(drive)
}

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

  ipcMain.handle('projects:list', () => store().getProjects())
  ipcMain.handle('projects:add', (_e, path: string) => store().addProject(path))
  ipcMain.handle('projects:remove', (_e, path: string) => store().removeProject(path))
  ipcMain.handle('prefs:get', () => store().getPreferences())
  ipcMain.handle('prefs:set', (_e, patch: Partial<Preferences>) => {
    const preferences = store().setPreferences(patch)
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
  // PtyManager is the SessionAccess: controls are read off the rendered
  // screen and applied by typing, exactly as a person would.
  registerAgentControlsIpc(ipcMain, ptys)
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
  // Checks on a delay after launch and then occasionally; never installs on its
  // own. An unsigned build reports that it cannot self-update rather than
  // checking forever — see updates/updater.ts.
  updates = registerUpdateIpc(ipcMain, {
    updater: autoUpdater,
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
     * The newline is what submits it, and it is added here rather than expected
     * on the wire: a `copilot.say` frame carries a *sentence*, and making the
     * client responsible for a control character would mean a client that forgot
     * it produced a run that silently never answered.
     */
    say: (id, text) => ptys.write(id, `${text}\n`),
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
     * Watched by folder, not by session id, and that is not laziness: the CLI
     * decides its transcript path when it starts writing, which is after the
     * spawn has already returned, so there is nothing to key on at this moment.
     * `watchRunChat` waits for the file to appear and then follows it — one
     * subscription that migrates, instead of a retry loop with a guessed delay.
     *
     * The id is unused here for that reason and is still on the signature,
     * because it is what `CopilotRuns` uses to drop a late update from a run
     * that has already ended.
     */
    chat: (_sessionId, onUpdate) =>
      watchRunChat(copilotPaths(app.getPath('userData')).root, onUpdate),
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
    // The same tracker the window uses, so a dev server started from the phone
    // and one started from the desktop are one thing rather than two views that
    // can disagree. `server.ts` only advertises the `devserver` capability when
    // this is present, so a build without it says nothing rather than offering a
    // button that answers `unauthorized`.
    devServers,
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
    // The same object the folder rule above closes over, never a second one:
    // the panel edits what `create` is checked against, or it edits a copy and
    // the phone keeps the folders the user just removed until the next launch.
    folders: core.grants,
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
  const machines = registerMachinesIpc(ipcMain, {
    storageDir: remoteStorageDir(),
    desk: remote.desk,
    status: () => remote.server.status(),
    broadcast: (channel, payload) => send(channel, payload),
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
      })),
    store: serverStore,
    credentials: serverCredentials,
    facts: (serverId) => serverConnections.probe(serverId),
    run: (serverId, argv) => serverConnections.run(serverId, argv),
    runScript: (serverId, script) => serverConnections.runScript(serverId, script),
    openShell: (serverId, size) => serverConnections.shell(serverId, size),
    // §5.4 in one pair of lines: the page holds the connection while it is open
    // and lets go when it closes. There is no timer here and no keep-alive, and
    // a server nobody is looking at is not dialled at all.
    acquire: (serverId) => serverConnections.acquire(serverId),
    release: (serverId) => serverConnections.release(serverId),
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
  })

  powerMonitor.on('resume', () => {
    remote.server.wake()
    // A guest link that slept through a suspend is as dead as a host one, and
    // for the same reason: TCP will not admit it for minutes. One event, both
    // halves.
    machines.wake()
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
  registerBrowserIpc(ipcMain)
  // Beside the browser, because that is where a link now lands. The two
  // channels are the explicit way *out* — `link:system` and the context menu —
  // which only exists because in-app became the default.
  registerLinkIpc(ipcMain)
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
  registerSetupIpc(ipcMain)
  registerCookieImportIpc(ipcMain)
  registerBrowserIsolationIpc(ipcMain)
  registerSettingsIpc(ipcMain)
  // Profiles first: everything below asks which one is switched on, and
  // `registerBrowserSessionIpc` hardens that profile's session as its first act.
  registerBrowserProfileIpc(ipcMain, () => app.getPath('userData'))
  registerBrowserPasswordIpc(ipcMain, () => app.getPath('userData'))
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
   * Everything the two channels below need to know about one session, gathered
   * once.
   *
   * A helper rather than two copies, because the plan and the switch have to
   * agree about every one of these or the sentence somebody read is not a
   * description of what then happened. That is the entire promise this feature
   * makes: *say what will happen before it happens.* Two independent lookups is
   * how the two would come to disagree — the account resolved twice, the folder
   * probed twice, the conversation asked about twice, in between which the
   * person has had time to read a paragraph and press a button.
   */
  const switchSubject = async (
    sessionId: unknown,
    profileId: unknown,
  ): Promise<{ plan: SwitchPlan; saved: SavedSession | null; resume: boolean }> => {
    const id = typeof sessionId === 'string' ? sessionId : ''
    const wanted = typeof profileId === 'string' ? profileId : ''
    const meta = ptys.list().find((session) => session.id === id) ?? null
    const saved = ledger.get(id)
    const target = wanted === '' ? null : findProfile(profilesState(), wanted)

    /*
     * The decision is only asked for once the cheap refusals have passed, and
     * that ordering is deliberate rather than an optimisation. `planSaved` stats
     * a folder and reads a directory; asking it about a session that is a plain
     * shell, or about an account of the wrong agent, would be doing work to
     * answer a question that has already been answered — and, on a WSL machine,
     * doing it across a filesystem boundary.
     */
    const refused = switchRefusal({ meta, saved, target })
    if (refused !== null || saved === null || target === null) {
      /*
       * `switchRefusal` and not `planSwitch` for the question itself, and that
       * distinction cost a live driving run to find. `planSwitch` treats a
       * *missing* decision as a refusal in its own right — deliberately, because
       * "nothing was decided" is not "start it fresh" — so asking it with
       * `decision: null` answers "cannot be started again" about every switch
       * that was going to work perfectly well. The refusals that can be reached
       * without touching a disk are their own function precisely so this pass
       * can ask only them.
       */
      return {
        plan: planSwitch({ sessionId: id, meta, saved, target, decision: null, occupied: false }),
        saved,
        resume: false,
      }
    }

    const switched: SavedSession = { ...saved, profileId: target.id }
    const [decision] = await planSaved([switched])

    /*
     * Is another tab already on the conversation this one would continue?
     *
     * `conversationScope` is the shared answer to "which transcript would
     * `--continue` attach to" — provider, config directory and folder, which is
     * narrower than a folder and was made narrower because keying on the folder
     * alone silently threw conversations away. Reused rather than re-derived, so
     * the switch and the launch cannot come to disagree about what counts as the
     * same conversation.
     *
     * `planRestore` cannot answer this for a switch: it reasons about a list of
     * *remembered* sessions being started together, and this one is about the
     * tabs open on screen right now. Hence the one extra fact, computed here
     * where the live list is, and applied by `planSwitch`.
     */
    const configDir = decision?.configDir ?? null
    const mine = configDir === null ? null : conversationScope(switched, configDir)
    const occupied =
      mine !== null &&
      ledger
        .entries()
        .filter((entry) => entry.id !== id)
        .some(
          (entry) =>
            conversationScope(
              entry.saved,
              resolveProfile(profilesState(), {
                sessionProfileId: entry.saved.profileId ?? undefined,
                projectPath: entry.saved.cwd,
              }).configDir,
            ) === mine,
        )

    const plan = planSwitch({ sessionId: id, meta, saved, target, decision: decision ?? null, occupied })
    return { plan, saved, resume: plan.resume }
  }

  /**
   * What a switch would do, before one is made.
   *
   * The window draws this as a sheet and will not stop anything until somebody
   * has read it. It is the whole of the answer to the complaint underneath this
   * feature — a restart nobody expected — and it is why the plan touches the
   * disk and the switch does not decide anything.
   */
  ipcMain.handle(SESSION_SWITCH_PLAN_CHANNEL, async (_e, sessionId: unknown, profileId: unknown) => {
    const { plan } = await switchSubject(sessionId, profileId)
    return plan
  })

  /**
   * Run this session as another account: same tab, same folder, new process.
   *
   * ## The order is start, then stop, and that is the point
   *
   * The obvious order is the wrong one. Stopping first and spawning afterwards
   * means a spawn that fails has already destroyed a working session — and
   * `AgentUnavailableError` is thrown *by* the spawn, after probing, so "could
   * this even start?" cannot be answered fully in advance. That is the exact
   * fault that was just fixed on the restore path in the other direction, and
   * the fix there was to keep the request rather than let it evaporate.
   *
   * Here it can be avoided outright, because the two processes cannot collide.
   * They are different accounts, so they are different config directories, so
   * they are different transcript stores — the measurement at the top of
   * `session-switch.ts` is exactly that — and the old session is stopped within
   * a moment of the new one existing. So a switch that cannot start leaves the
   * session it was asked about running, untouched, and the window says why.
   *
   * ## Which is why nothing is held
   *
   * `session:create` holds a request that failed, because there the alternative
   * is a tab that vanished with nothing to show for it. Here the session is
   * still there. A held row saying *"this could not be started"* beside a
   * session that is still running would be the app inventing a loss it did not
   * suffer, and the Try again beside it would start a *second* session rather
   * than retrying anything. The reuse that matters is the sentence:
   * `AgentUnavailableError`'s own message is what the window prints, unchanged,
   * because it is already written for the person who is reading it.
   */
  ipcMain.handle(SESSION_SWITCH_CHANNEL, async (_e, sessionId: unknown, profileId: unknown) => {
    const { plan, saved } = await switchSubject(sessionId, profileId)
    if (plan.refusal !== null || saved === null || plan.to === null) {
      throw new Error(plan.refusal ?? 'This session cannot be switched.')
    }

    const meta = await startSession({
      cwd: saved.cwd,
      cols: saved.cols,
      rows: saved.rows,
      provider: saved.provider,
      profileId: plan.to.id,
      resume: plan.resume,
    })

    /*
     * A spawn that succeeded is not yet a session that started.
     *
     * `startSession` resolves the moment the pty exists, and the agent can still
     * refuse a second later — `--continue` against a transcript the CLI declines
     * to continue is a real, reproduced case, and `survivedStart` carries it.
     * Stopping the old session before knowing would leave a dead tab where a
     * working agent was, which is the one outcome this feature must not produce.
     *
     * The replacement is cleaned up rather than left as a corpse: it never
     * became anybody's tab — this handler is the only thing that knows it exists
     * — so leaving it in the ledger would put a phantom session in `openSessions`
     * for the next launch to restore.
     */
    const started = await survivedStart(meta.id, {
      wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
      alive: (id) => ptys.list().some((session) => session.id === id),
      screen: (id) => ptys.scrollback(id),
    })
    if (!started.alive) {
      ledger.forget(meta.id)
      ptys.kill(meta.id)
      const why = startFailed(plan.to.name, started.said)
      logger.warn('session', `account switch did not take: ${why}`, {
        folder: saved.cwd,
        agent: saved.provider,
        to: plan.to.id,
      })
      throw new Error(why)
    }

    /*
     * Only now. `ledger.forget` as well as the kill, for the reason
     * `session:kill` gives: `onExit` arrives later, and a session that has been
     * deliberately replaced must not sit in the remembered list in the meantime,
     * where a crash inside that gap would bring it back beside its replacement.
     */
    ledger.forget(plan.sessionId)
    // `replaced`, not `stopped`: the tab is not going anywhere, only the process
    // inside it. Announcing a removal for the outgoing half would race the
    // window's own swap, which finds the old row by id and leaves the list alone
    // when it cannot — so the losing side of that race is a tab that vanishes in
    // the middle of a switch. See `RemovalReason`.
    ptys.kill(plan.sessionId, 'replaced')
    logger.info('session', 'switched account', {
      folder: saved.cwd,
      agent: saved.provider,
      from: plan.from?.id ?? null,
      to: plan.to.id,
      continued: plan.resume,
    })
    return meta
  })

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
if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', () => {
    // Somebody tried to launch it again — almost always because they forgot it
    // was running. Show them the window they already have.
    if (mainWindow === null) return
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
  void registerHookServer(ipcMain, { dir: app.getPath('userData') })
    .then(() => syncInstalledHooks(defaultContext()))
    .catch((err) =>
      console.error('[hook-server] failed to start, hook callbacks disabled:', err),
    )
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

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})

app.on('before-quit', () => {
  // Before `quitting`, deliberately. Every session is still live at this
  // instant, which makes this the most accurate the remembered list ever gets —
  // and one line further down `ledger.freeze()` closes the list for the rest of
  // the run, because `killAll` fires an exit per session and reconciling on
  // those would write down that nothing was open. A crash never reaches this
  // line, which is fine: the list is already correct from the last open or
  // close, and that is the case this whole feature is for.
  ledger.flush()
  ledger.freeze()

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
  updates?.stop()
  lidAwake?.stop()
  void stopHookServer()
  // Nothing of anybody's account is written down, so there is nothing here to
  // clean up — this only closes the loopback listener and answers anything a git
  // is still waiting on, rather than leaving it to time out against an app that
  // has gone.
  void core.credentials.stop()
  void clearBrowserDataIfNotPersisting()
})
