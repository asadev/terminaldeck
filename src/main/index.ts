import { join } from 'node:path'
import { app, BrowserWindow, dialog, ipcMain, session, shell } from 'electron'
import { BRAND } from '../shared/brand'
import type { CreateSessionInput } from '../shared/types'
import { PtyManager } from './pty-manager'
import { detectProviders, loginPath, PROVIDERS } from './providers'
import { store, type Preferences } from './store'
import { registerCostIpc } from './cost-ipc'
import { registerGitIpc, stopAllGitWatches } from './git'
import { registerFsIpc } from './fs-tree'
import { registerSearchIpc } from './file-search'
import { registerBoardIpc } from './board-store'
import { registerInsightsIpc } from './session-insights'
import { registerGitHubIpc } from './github'
import { registerReadinessIpc } from './readiness'
import { registerDashboardIpc } from './dashboard-store'
import { registerSessionSearchIpc } from './session-search'
import { registerAlertsIpc } from './alerts'
import { registerProfilesIpc, getState as profilesState, resolveProfile, sessionEnv } from './profiles'
import { registerPawlignoreIpc } from './pawlignore'
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

const ptys = new PtyManager(
  (id, data) => send('session:data', id, data),
  (id, exitCode) => {
    liveStatus.delete(id)
    send('session:exit', id, exitCode)
  },
  (id, status) => {
    liveStatus.set(id, { status, at: Date.now() })
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
  registerGitHubIpc(ipcMain)
  registerReadinessIpc(ipcMain)
  registerDashboardIpc(ipcMain)
  registerSessionSearchIpc(ipcMain)
  registerProfilesIpc(ipcMain)
  registerPawlignoreIpc(ipcMain)
  registerHooksIpc(ipcMain)
  registerMcpIpc(ipcMain)
  registerBrowserIpc(ipcMain)
  registerChromeImportIpc(ipcMain)
  registerPrerequisitesIpc(ipcMain)
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
  ipcMain.on('session:resize', (_e, id: string, cols: number, rows: number) =>
    ptys.resize(id, cols, rows),
  )
  ipcMain.handle('session:scrollback', (_e, id: string) => ptys.scrollback(id))
  ipcMain.handle('session:kill', (_e, id: string) => ptys.kill(id))
  ipcMain.handle('session:list', () => ptys.list())
}

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
  void stopHookServer()
  void clearBrowserDataIfNotPersisting()
})
