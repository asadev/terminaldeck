import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { request as httpRequest } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { registerSettingsIpc, resetSettingsCache } from './settings-extra'
import { PREFS_CHANGED_CHANNEL, SETTINGS_CHANGED_CHANNEL } from './live-push'
import { COOKIE_NAME, startBridgeServer, type BridgeServer } from './native-shell/bridge-server'

/**
 * Every save is told to every window — so a page that did not make a change
 * cannot keep the old value in memory and write it back with its next save.
 *
 * That was real in the native shell: Settings is a page of its own there, and
 * a native Settings screen saves through the engine too, so the main page (and
 * the hidden Settings page) held values that were no longer on disk. The fix is
 * in the save handlers, so it holds in the Electron window as well.
 */

const ROOT = mkdtempSync(join(tmpdir(), 'td-settings-broadcast-'))
installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: ROOT }, home: ROOT, appRoot: ROOT }))

vi.mock('electron', async () => {
  const { userDataDir: ud } = await import('./platform/paths')
  return {
    app: { getPath: () => ud(), getAppPath: () => ud(), getVersion: () => '0.0.0-test', isPackaged: false },
    shell: { openPath: async () => '', showItemInFolder: () => undefined },
    session: { fromPartition: () => ({ clearStorageData: async () => undefined, clearCache: async () => undefined }) },
  }
})

type Handler = (event: unknown, ...args: unknown[]) => unknown

function fakeIpcMain() {
  const handlers = new Map<string, Handler>()
  return {
    handlers,
    handle: (channel: string, handler: Handler) => void handlers.set(channel, handler),
    on: () => undefined,
    removeHandler: (channel: string) => void handlers.delete(channel),
  }
}

let server: BridgeServer | null = null
let site: string | null = null

beforeEach(() => resetSettingsCache())
afterEach(async () => {
  await server?.close()
  server = null
  if (site !== null) rmSync(site, { recursive: true, force: true })
  site = null
})
afterAll(() => {
  resetPaths()
  rmSync(ROOT, { recursive: true, force: true })
})

describe('the settings store', () => {
  it('tells every window the whole store after a save, and after a reset', async () => {
    const ipc = fakeIpcMain()
    const told: Array<[string, unknown]> = []
    registerSettingsIpc(ipc as never, (channel, payload) => told.push([channel, payload]))

    const saved = await ipc.handlers.get('settings:set')?.({}, { 'appearance.density': 'compact' })
    expect(told).toEqual([[SETTINGS_CHANGED_CHANNEL, saved]])
    expect(saved).toMatchObject({ values: { 'appearance.density': 'compact' } })

    const emptied = await ipc.handlers.get('settings:reset')?.({})
    expect(told.at(-1)).toEqual([SETTINGS_CHANGED_CHANNEL, emptied])
  })

  it('is wired to the window sender in the app, and preferences do the same', () => {
    const index = readFileSync(join(__dirname, 'index.ts'), 'utf8')
    expect(index).toContain('registerSettingsIpc(ipcMain, (channel, payload) => send(channel, payload))')
    const prefs = index.slice(index.indexOf("ipcMain.handle('prefs:set'"), index.indexOf('return preferences', index.indexOf("ipcMain.handle('prefs:set'")))
    expect(prefs).toContain('send(PREFS_CHANGED_CHANNEL, preferences)')
    expect(PREFS_CHANGED_CHANNEL).toBe('prefs:changed')
  })
})

describe('two pages of the native window', () => {
  const TOKEN = 'settings-broadcast-token-0123456789abcdef0123'

  /** One page's event stream, collecting `settings:changed`. */
  function listen(port: number, into: unknown[]): Promise<() => void> {
    return new Promise((resolve, reject) => {
      const req = httpRequest(
        { host: '127.0.0.1', port, path: '/__td/events', headers: { cookie: `${COOKIE_NAME}=${TOKEN}` } },
        (res) => {
          let buffered = ''
          res.on('data', (chunk: Buffer) => {
            buffered += chunk.toString('utf8')
            if (buffered.includes(': connected')) resolve(() => req.destroy())
            for (const line of buffered.split('\n')) {
              if (!line.startsWith('data: ')) continue
              const event = JSON.parse(line.slice('data: '.length)) as { channel: string; args: unknown[] }
              if (event.channel === SETTINGS_CHANGED_CHANNEL) into.push(event.args[0])
            }
            buffered = buffered.slice(buffered.lastIndexOf('\n') + 1)
          })
        },
      )
      req.on('error', (error) => {
        if ((error as NodeJS.ErrnoException).code !== 'ECONNRESET') reject(error)
      })
      req.end()
    })
  }

  /** One page's save, the way the shim sends it. */
  function save(port: number, patch: Record<string, unknown>): Promise<unknown> {
    const body = JSON.stringify({ channel: 'settings:set', args: [patch] })
    return new Promise((resolve, reject) => {
      const req = httpRequest(
        {
          host: '127.0.0.1',
          port,
          method: 'POST',
          path: '/__td/invoke',
          headers: { cookie: `${COOKIE_NAME}=${TOKEN}`, 'content-type': 'application/json' },
        },
        (res) => {
          let text = ''
          res.on('data', (chunk: Buffer) => (text += chunk.toString('utf8')))
          res.on('end', () => resolve(JSON.parse(text)))
        },
      )
      req.on('error', reject)
      req.end(body)
    })
  }

  it('a save from one page reaches the other', async () => {
    site = mkdtempSync(join(tmpdir(), 'td-settings-site-'))
    mkdirSync(join(site, 'renderer'), { recursive: true })
    writeFileSync(join(site, 'renderer', 'index.html'), '<!doctype html><html><head></head><body></body></html>')
    const ipc = fakeIpcMain()
    server = await startBridgeServer({
      rendererDir: join(site, 'renderer'),
      shimFile: join(site, 'shim.js'),
      token: TOKEN,
      invoke: async (channel, args) => ipc.handlers.get(channel)?.({}, ...args),
      send: () => undefined,
    })
    const bridge = server
    registerSettingsIpc(ipc as never, (channel, payload) => void bridge.emit(channel, [payload]))

    const atSettings: unknown[] = []
    const atMain: unknown[] = []
    const stopSettings = await listen(bridge.port, atSettings)
    const stopMain = await listen(bridge.port, atMain)

    // The Settings page saves; the main page is told.
    const answer = await save(bridge.port, { 'appearance.density': 'compact' })
    expect(answer).toMatchObject({ ok: true })
    await new Promise<void>((resolve, reject) => {
      const started = Date.now()
      const check = setInterval(() => {
        if (atMain.length > 0) {
          clearInterval(check)
          resolve()
        } else if (Date.now() - started > 3000) {
          clearInterval(check)
          reject(new Error('the main page was never told'))
        }
      }, 5)
    })
    expect(atMain[0]).toMatchObject({ values: { 'appearance.density': 'compact' } })
    stopSettings()
    stopMain()
  })
})
