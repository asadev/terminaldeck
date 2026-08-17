import { existsSync } from 'node:fs'
import { join } from 'node:path'
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
import {
  conversationOnDisk,
  folderExists,
  planRestore,
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
import { registerUpdateIpc } from './updates/updater'
import { createManualStrategy } from './updates/manual-strategy'
import { registerTailnetIpc } from './remote/tailnet'
import { registerRemoteIpc } from './remote/server'
import { CopilotGrants } from './remote/copilot-grants'
import { CopilotRuns } from './remote/copilot-runs'
import {
  startCopilotRun,
  tailForPhone,
  toCopilotSessions,
  toPendingRow,
  watchRunChat,
} from './remote/copilot-wiring'
import { registerMachinesIpc } from './remote/machines/ipc'
import {
  dropPlanSession,
  notePlanOutput,
  notePlanResize,
  registerPlanLimitIpc,
} from './plan-limit'
import { dropUsageSession, registerUsageIpc } from './usage-ipc'
import { registerGitHubIpc } from './github'
import { registerReadinessIpc } from './readiness'
import { registerDashboardIpc } from './dashboard-store'
import { registerArtifactsIpc } from './artifacts'
import { registerSessionSearchIpc } from './session-search'
import { registerAlertsIpc } from './alerts'
import { registerProfilesIpc, getState as profilesState, resolveProfile } from './profiles'
import { registerSignInIpc } from './profiles-signin'
import { copilotState, registerCopilotIpc } from './copilot-session'
import { copilotPaths } from './copilot-home'
import { registerCopilotInspectIpc } from './copilot-inspect'
import { registerDeckControlIpc, type DeckControlHandle } from './deck-control'
import { registerDeckignoreIpc } from './deckignore'
import { defaultContext, registerHooksIpc, syncInstalledHooks } from './hooks'
import { registerHookServer, stopHookServer } from './hook-server'
import { registerMcpIpc } from './mcp-client'
import { registerBrowserIpc } from './browser-tab'
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
import { registerBrowserViewIpc } from './browser-view'
import { registerDiagnosticsIpc } from './diagnostics'
import { registerNotificationIpc } from './os-notifications'
import { registerLidAwakeIpc } from './lid-awake'
import { logger } from './app-log'
import { registerLogIpc } from './app-log-ipc'
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
function send(channel: string, ...args: unknown[]): void {
  if (quitting || !rendererAlive) return
  const window = mainWindow
  if (!window || window.isDestroyed()) return
  const contents = window.webContents
  if (!contents || contents.isDestroyed()) return
  contents.send(channel, ...args)
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

  // External links open in the real browser, never inside the app shell.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url)
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
async function hydrateRenderer(): Promise<void> {
  if (!restored) {
    // Set before the await, not after. `did-finish-load` can fire again while
    // the first restore is still spawning — a reload in dev does it routinely —
    // and a second pass would start a second copy of every session.
    restored = true
    const saved = store().getOpenSessions()

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
        plan: (sessions) =>
          planRestore(sessions, {
            // Asked about the folder as Windows can see it. Without the
            // translation every session that was running inside a distro is
            // planned as "its folder is gone" and dropped, which is the app
            // losing a day's tabs and explaining it with a sentence that is not
            // true.
            folderExists: (cwd) => folderExists(statablePath(cwd)),
            // `core.canContinue`, not `PROVIDERS[provider].resumeArgs`: the
            // table has only the agents this build ships, so a restored session
            // on an agent the person added threw a `TypeError` here and took
            // the whole restore — every other tab included — down with it.
            canContinue: core.canContinue,
            /*
             * Resolved exactly the way `startSession` resolves it, and that is
             * the point: the directory searched for a conversation has to be the
             * directory the restored session will then write to, or the answer is
             * about a different login than the one coming back.
             *
             * Passing `conversationOnDisk` by reference used to be enough — it
             * took an optional config directory and fell back to the app's own.
             * That fallback is `~/.claude`, so every session that ran as a
             * profile was asked about the wrong store, answered "no conversation"
             * and came back blank with its transcript sitting untouched on disk.
             * The profile is the whole reason the transcripts moved.
             */
            configDir: (session) =>
              resolveProfile(profilesState(), {
                sessionProfileId: session.profileId ?? undefined,
                projectPath: session.cwd,
              }).configDir,
            conversation: conversationOnDisk,
          }),
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
        report: reportRestore,
      })
    } catch (err) {
      // A restore that throws must not take the window's session list with it.
      logger.error('restore', 'restoring the previous sessions failed outright', {
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }

  for (const meta of ptys.list()) send(SESSION_CREATED_CHANNEL, meta)
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
  // `write` is what lets plan:refresh run /usage in the session; without it the
  // module reports 'unwired' and the strip hides the control rather than
  // offering a button that does nothing.
  registerPlanLimitIpc(ipcMain, { write: (id, data) => ptys.write(id, data) })
  // The read side of the same feature, with Codex's rollout numbers folded in
  // and every reading tagged with the account it describes. `PtyManager` is
  // asked which login a session resolved to rather than that answer being
  // recomputed — see `usage-ipc.ts`, where getting it wrong means two accounts
  // sharing one bar.
  registerUsageIpc(ipcMain, {
    describeSession: (id) => ptys.list().find((meta) => meta.id === id) ?? null,
  })
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
   * Remote copilot access, assembled — the store, and the runs it authorises.
   *
   * One `CopilotGrants` for the whole process, handed to both halves. The panel
   * in Settings edits it and the run manager enforces it, and a second instance
   * would give the panel a store that writes the same file and holds a different
   * copy of it in memory — the same rule `core.grants` follows one field down in
   * the call below, for the same reason.
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
  const copilotGrants = new CopilotGrants(remoteStorageDir())
  copilotRuns = new CopilotRuns({
    grants: copilotGrants,
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
    copilotRoot: () => copilotPaths(app.getPath('userData')).root,
    spawn: (request) =>
      startCopilotRun(
        {
          startSession,
          announce: announceSession,
          stop: (id) => ptys.kill(id),
          userData: () => app.getPath('userData'),
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
    pending: () => (deckControl?.consent.list() ?? []).map(toPendingRow),
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
     * Both fields, and the same store behind them: this one is the *enforcing*
     * side, `copilotGrants` is the *editing* side that the settings panel
     * writes through. Every device is off in it until somebody ticks a box on
     * this machine.
     */
    copilot: copilotRuns,
    copilotGrants,
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
    startSession,
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
  })
  /*
   * Looking at the copilot, which is a different job from running it.
   *
   * Registered as its own module so the one above can keep the promise its
   * header makes — every handler there takes no arguments. These take a memory
   * file name and a place key, both checked in `copilot-inspect.ts`, and mixing
   * the two sets would make that sentence false in the file that relies on it.
   */
  registerCopilotInspectIpc(ipcMain, { userData: () => app.getPath('userData') })
  registerRoutinesIpc(ipcMain, routines.api)
  registerDeckignoreIpc(ipcMain)
  registerHooksIpc(ipcMain)
  registerMcpIpc(ipcMain)
  registerBrowserIpc(ipcMain)
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
  // registerBrowserSessionIpc installs the recorder preload itself.
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

  ipcMain.handle('session:create', (_e, input: CreateSessionInput) => startSession(input))

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
     * Exactly one window may answer a confirmation, and it is this app's own.
     *
     * Identity, not a capability check: `webContents` for a browser tab's page,
     * or for any other frame this process ends up hosting, must never be able
     * to approve an alter-tier call. There is no default for this argument in
     * `DeckControlDeps` precisely so the question is answered here, where the
     * answer is known.
     */
    isApprover: (contents) => mainWindow !== null && contents === mainWindow.webContents,
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
