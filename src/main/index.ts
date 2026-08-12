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

const ptys = new PtyManager(
  (id, data) => send('session:data', id, data),
  (id, exitCode) => send('session:exit', id, exitCode),
  (id, status) => send('session:status', id, status),
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

  ipcMain.handle('session:create', async (_e, input: CreateSessionInput) => {
    const path = await loginPath()
    const available = await detectProviders()
    // Fall back to a plain shell rather than spawning a binary that isn't there,
    // which would flash a dead tab with no explanation.
    const requested = input.provider ?? 'claude'
    const provider = available[requested] ? requested : 'shell'
    const spec = PROVIDERS[provider]

    return ptys.create(input, {
      provider,
      command: spec.bin,
      args: input.resume && spec.resumeArgs.length > 0 ? spec.resumeArgs : spec.args,
      path,
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
})
