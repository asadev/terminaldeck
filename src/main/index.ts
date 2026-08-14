import { join } from 'node:path'
import { app, BrowserWindow, dialog, ipcMain, powerMonitor, session, shell } from 'electron'
import { BRAND } from '../shared/brand'
import type { CreateSessionInput, SessionMeta } from '../shared/types'
import { PtyManager } from './pty-manager'
import { detectProviders, loginPath, PROVIDERS } from './providers'
import { store, type Preferences } from './store'
import { pinUserData } from './user-data'
import { registerCostIpc } from './cost-ipc'
import { registerGitIpc, stopAllGitWatches } from './git'
import { registerFsIpc } from './fs-tree'
import { registerSearchIpc } from './file-search'
import { registerBoardIpc } from './board-store'
import { registerInsightsIpc } from './session-insights'
import { registerChatIpc } from './chat-transcript'
import { registerDevPortsIpc } from './dev-ports'
import { autoUpdater } from 'electron-updater'
import { registerAgentControlsIpc } from './agent-controls'
import { registerUpdateIpc } from './updates/updater'
import { createManualStrategy } from './updates/manual-strategy'
import { registerTailnetIpc } from './remote/tailnet'
import { registerRemoteIpc } from './remote/server'
import { SessionFanout } from './remote/session-fanout'
import { remoteSessionCreator } from './remote/session-create'
import {
  dropPlanSession,
  notePlanOutput,
  notePlanResize,
  registerPlanLimitIpc,
} from './plan-limit'
import { registerGitHubIpc } from './github'
import { registerReadinessIpc } from './readiness'
import { registerDashboardIpc } from './dashboard-store'
import { registerSessionSearchIpc } from './session-search'
import { registerAlertsIpc } from './alerts'
import { registerProfilesIpc, getState as profilesState, resolveProfile, sessionEnv } from './profiles'
import { registerDeckignoreIpc } from './deckignore'
import { registerHooksIpc } from './hooks'
import { registerHookServer, stopHookServer } from './hook-server'
import { registerMcpIpc } from './mcp-client'
import { registerBrowserIpc } from './browser-tab'
import { registerChromeImportIpc } from './chrome-import'
import { registerPrerequisitesIpc } from './prerequisites'
import { registerSettingsIpc, clearBrowserDataIfNotPersisting, storedValue } from './settings-extra'
import { registerBrowserSessionIpc } from './browser-session'
import { registerBrowserViewIpc } from './browser-view'
import { registerDiagnosticsIpc } from './diagnostics'
import { registerLogIpc } from './app-log'
import { traceIpc, TRACE_SETTING } from './ipc-trace'
import { buildMenu } from './menu'
import { registerSetupIpc } from './setup'
import { registerCookieImportIpc } from './cookie-import'
import { registerBrowserIsolationIpc } from './browser-isolation'
import type { SessionStatus } from '../shared/types'

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

/**
 * Fans each session's output out to the window and to any attached phone.
 * Declared before `ptys` because the PtyManager callbacks below feed it, and
 * pointed at `ptys` afterwards — the two genuinely reference each other.
 *
 * `create` is the same call the window's own New Session makes, with the same
 * PATH, the same profile and the same provider detection — see `startSession`.
 * A remote-only spawn path would be a second way to start a session, and the
 * two would drift the first time either changed.
 */
const remoteSessions = new SessionFanout({
  list: () => ptys.list(),
  write: (id, data) => ptys.write(id, data),
  resize: (id, cols, rows) => ptys.resize(id, cols, rows),
  scrollback: (id) => ptys.scrollback(id),
  create: remoteSessionCreator({
    // Most-recently-opened first, so a phone that names nothing lands in the
    // project the user was last in rather than in a folder they have forgotten.
    // Live sessions come after: a session can be running in a folder that was
    // never added as a project, and the phone can see it in its own list, so
    // refusing to start a second one beside it would be arbitrary.
    folders: () => [
      ...store().getProjects().map((project) => project.path),
      ...ptys.list().map((session) => session.cwd),
    ],
    home: () => app.getPath('home'),
    spawn: async (input) => {
      const meta = await startSession({
        ...input,
        // The phone does not choose an agent — it has no honest way to know
        // which are installed. The desktop's own default is the answer, and it
        // falls back to a plain shell in `startSession` when that CLI is not
        // there, exactly as the window's button does.
        provider: store().getPreferences().defaultProvider,
      })
      // The window has to be told, or the session is running on this Mac and
      // only the phone knows about it.
      send(SESSION_CREATED_CHANNEL, meta)
      return meta
    },
  }),
})

const ptys = new PtyManager(
  (id, data) => {
    // Plan limits are read off the same bytes the terminal draws — the CLI
    // reports them in its own output, so there is nothing else to ask.
    notePlanOutput(id, data)
    remoteSessions.noteData(id, data)
    send('session:data', id, data)
  },
  (id, exitCode) => {
    liveStatus.delete(id)
    dropPlanSession(id)
    remoteSessions.noteExit(id, exitCode)
    send('session:exit', id, exitCode)
  },
  (id, status) => {
    liveStatus.set(id, { status, at: Date.now() })
    remoteSessions.noteStatus(id, status)
    send('session:status', id, status)
  },
)

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
    backgroundColor: '#0e0f13',
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    trafficLightPosition: { x: 14, y: 12 },
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  })

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

/**
 * Start a session. The one place that does, for the window and for a phone.
 *
 * Was inline in the `session:create` handler until a phone needed to start one
 * too. Everything here is load-bearing and none of it is obvious from the
 * outside — the login shell's PATH, the fallback when the requested CLI is not
 * installed, the profile's redirected config directory — so a second copy for
 * the remote path would be a session that is subtly not the same kind of
 * session: no agent CLI on PATH, or two "separate" logins quietly sharing one
 * config directory.
 */
async function startSession(input: CreateSessionInput): Promise<SessionMeta> {
  const path = await loginPath()
  const available = await detectProviders()
  // Fall back to a plain shell rather than spawning a binary that isn't there,
  // which would flash a dead tab with no explanation.
  const requested = input.provider ?? 'claude'
  const provider = available[requested] ? requested : 'shell'
  const spec = PROVIDERS[provider]

  // Resolve the profile the session should run as and hand the PTY its
  // config-dir override. Without this the picker records a choice that never
  // reaches the process, and two "separate" logins quietly share one.
  const profile = resolveProfile(profilesState(), {
    sessionProfileId: input.profileId ?? undefined,
    projectPath: input.cwd,
  })

  // `spec.spawn`, not `spec.bin`. They are the same thing on macOS and are not
  // on Windows, where the name that answers a PATH lookup for an npm-installed
  // agent CLI is a `.cmd` shim and `CreateProcess` will not run a batch file.
  // Spawning `bin` there failed with a bare "File not found:" and a tab that
  // died with no message — observed on Windows 11, which is what this comment
  // is replacing a guess with. `providers.ts` has carried the launchable form
  // in `spawn` the whole time, unread.
  return ptys.create(input, {
    provider,
    command: spec.spawn.command,
    args:
      input.resume && spec.spawn.resumeArgs.length > 0 ? spec.spawn.resumeArgs : spec.spawn.args,
    path,
    env: sessionEnv(profile, provider),
  })
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
    })
    return canceled || filePaths.length === 0 ? null : filePaths[0]
  })

  ipcMain.handle('providers:detect', () => detectProviders())

  ipcMain.handle('projects:list', () => store().getProjects())
  ipcMain.handle('projects:add', (_e, path: string) => store().addProject(path))
  ipcMain.handle('projects:remove', (_e, path: string) => store().removeProject(path))
  ipcMain.handle('prefs:get', () => store().getPreferences())
  ipcMain.handle('prefs:set', (_e, patch: Partial<Preferences>) => store().setPreferences(patch))

  // Feature modules own their own channels; each registers in one line.
  registerCostIpc(ipcMain)
  registerGitIpc(ipcMain)
  registerFsIpc(ipcMain)
  registerBoardIpc(ipcMain)
  // Restricting search to known projects stops any folder that merely looks
  // like a project from being enumerated over IPC.
  registerSearchIpc(ipcMain, {
    isAllowedRoot: (root) => store().getProjects().some((p) => p.path === root),
  })
  registerInsightsIpc(ipcMain)
  registerChatIpc(ipcMain)
  registerDevPortsIpc(ipcMain)
  // PtyManager is the SessionAccess: controls are read off the rendered
  // screen and applied by typing, exactly as a person would.
  registerAgentControlsIpc(ipcMain, ptys)
  // `write` is what lets plan:refresh run /usage in the session; without it the
  // module reports 'unwired' and the strip hides the control rather than
  // offering a button that does nothing.
  registerPlanLimitIpc(ipcMain, { write: (id, data) => ptys.write(id, data) })
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
    },
    broadcast: (channel, state) => send(channel, state),
  })
  registerTailnetIpc(ipcMain, { certDir: join(app.getPath('userData'), 'tailnet-certs') })
  // Off until the user turns it on: this serves a shell. The server itself
  // binds only to the tailnet address and refuses to start without one.
  const remote = registerRemoteIpc(ipcMain, {
    sessions: remoteSessions,
    webRoot: join(app.getAppPath(), 'pwa', 'dist'),
    storageDir: join(app.getPath('userData'), 'remote'),
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
  powerMonitor.on('resume', () => remote.server.wake())
  registerGitHubIpc(ipcMain)
  registerReadinessIpc(ipcMain)
  registerDashboardIpc(ipcMain)
  registerSessionSearchIpc(ipcMain)
  registerProfilesIpc(ipcMain)
  registerDeckignoreIpc(ipcMain)
  registerHooksIpc(ipcMain)
  registerMcpIpc(ipcMain)
  registerBrowserIpc(ipcMain)
  registerChromeImportIpc(ipcMain)
  registerPrerequisitesIpc(ipcMain)
  registerSetupIpc(ipcMain)
  registerCookieImportIpc(ipcMain)
  registerBrowserIsolationIpc(ipcMain)
  registerSettingsIpc(ipcMain)
  // registerBrowserSessionIpc installs the recorder preload itself.
  registerBrowserSessionIpc(ipcMain)
  registerBrowserViewIpc(ipcMain)
  registerDiagnosticsIpc(ipcMain)
  registerLogIpc(ipcMain)

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
  })

  ipcMain.handle('session:create', (_e, input: CreateSessionInput) => startSession(input))

  ipcMain.on('session:write', (_e, id: string, data: string) => ptys.write(id, data))
  ipcMain.on('session:resize', (_e, id: string, cols: number, rows: number) => {
    // The tracker parses a rendered screen, so it has to be the same size.
    notePlanResize(id, cols, rows)
    ptys.resize(id, cols, rows)
  })
  ipcMain.handle('session:scrollback', (_e, id: string) => ptys.scrollback(id))
  ipcMain.handle('session:kill', (_e, id: string) => ptys.kill(id))
  ipcMain.handle('session:list', () => ptys.list())
}

// Before anything reads userData — the store, the trace log and Chromium's own
// profile all resolve their paths from it.
pinUserData(app)

app.whenReady().then(() => {
  if (process.platform === 'darwin') app.setName(BRAND.name)
  applySecurityPolicy()
  registerIpc()
  // Bound to 127.0.0.1 with a per-run token. Started early so hooks installed
  // into a provider's config have somewhere to report to; failure is not fatal
  // because everything except hook callbacks still works without it.
  void registerHookServer(ipcMain).catch((err) =>
    console.error('[hook-server] failed to start, hook callbacks disabled:', err),
  )
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
  // First, and before `killAll`. Killing a PTY makes it flush, exit and push a
  // status, and all three of those broadcast — into a render frame that is
  // already being torn down. See `send`.
  quitting = true
  rendererAlive = false
  ptys.killAll()
  stopAllGitWatches()
  updates?.stop()
  void stopHookServer()
  void clearBrowserDataIfNotPersisting()
})
