import { join } from 'node:path'
import { app, BrowserWindow, dialog, ipcMain, session, shell } from 'electron'
import { BRAND } from '../shared/brand'
import type { CreateSessionInput } from '../shared/types'
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
import { registerSettingsIpc, clearBrowserDataIfNotPersisting } from './settings-extra'
import { registerBrowserSessionIpc } from './browser-session'
import { registerBrowserViewIpc } from './browser-view'
import { registerDiagnosticsIpc } from './diagnostics'
import { registerLogIpc } from './app-log'
import { traceIpc } from './ipc-trace'
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

/** Broadcast to the renderer, guarding against a destroyed window during teardown. */
function send(channel: string, ...args: unknown[]): void {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, ...args)
  }
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
 * Fans each session's output out to the window and to any attached phone.
 * Declared before `ptys` because the PtyManager callbacks below feed it, and
 * pointed at `ptys` afterwards — the two genuinely reference each other.
 */
const remoteSessions = new SessionFanout({
  list: () => ptys.list(),
  write: (id, data) => ptys.write(id, data),
  resize: (id, cols, rows) => ptys.resize(id, cols, rows),
  scrollback: (id) => ptys.scrollback(id),
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

  mainWindow.on('ready-to-show', () => mainWindow?.show())
  mainWindow.on('closed', () => {
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

function registerIpc(): void {
  // Installed first so it wraps every handler registered below.
  traceIpc(ipcMain)

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
  registerRemoteIpc(ipcMain, {
    sessions: remoteSessions,
    webRoot: join(app.getAppPath(), 'pwa', 'dist'),
    storageDir: join(app.getPath('userData'), 'remote'),
    broadcast: (channel, payload) => send(channel, payload),
  })
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

  ipcMain.handle('session:create', async (_e, input: CreateSessionInput) => {
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

    return ptys.create(input, {
      provider,
      command: spec.bin,
      args: input.resume && spec.resumeArgs.length > 0 ? spec.resumeArgs : spec.args,
      path,
      env: sessionEnv(profile, provider),
    })
  })

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
  ptys.killAll()
  stopAllGitWatches()
  updates?.stop()
  void stopHookServer()
  void clearBrowserDataIfNotPersisting()
})
