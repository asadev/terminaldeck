import { app, nativeImage, type IpcMain, type IpcMainInvokeEvent, type WebContents } from 'electron'
import { join } from 'node:path'
import { BRAND } from '../../shared/brand'
import { DeviceManager, type Viewer } from './manager'
import { readRound } from './round'

/**
 * The Simulators page's door into the main process.
 *
 * ## Channels
 *
 * All `invoke` unless marked. Every one takes a device id from
 * `devices:list` and checks it is shaped like one before anything runs — an id
 * ends up as a command-line argument to `xcrun` and `adb`.
 *
 * - `devices:list`       ()                    → `{ available, reason, devices }`
 * - `devices:boot`       (id)                  → `{ ok, id }` | `{ ok: false, message }`
 * - `devices:shutdown`   (id)                  → `{ ok }` | `{ ok: false, message }`
 * - `devices:open`       (id)                  → the device's details
 * - `devices:watch`      (id, on)              → live pictures to this window on or off
 * - `devices:tap`        (id, x, y, holdMs?)
 * - `devices:touch`      (id, phase, x, y)     — one phase of a drag
 * - `devices:swipe`      (id, from, to, ms?)
 * - `devices:type`       (id, text)
 * - `devices:key`        (id, key, modifiers?)
 * - `devices:button`     (id, button)
 * - `devices:rotate`     (id)                  → the new orientation
 * - `devices:screenshot` (id)                  → a screenshot result, saved to Pictures
 * - `devices:freeze`     (id)                  → the exact picture, the tree and where, for Annotate
 * - `annotate:save`      (png, round)          → `{ path, width, height }` of the marked picture
 * - `annotate:sent`      (roundId, sentTo)     — the round reached a session
 *
 * Pushed to the window: `devices:frame` (id, jpeg bytes) and `devices:closed`
 * (id, reason).
 */

const ID = /^(ios|android|avd):[A-Za-z0-9._:-]{1,120}$/

function deviceId(value: unknown): string {
  if (typeof value !== 'string' || !ID.test(value)) throw new Error('That is not a device this app listed.')
  return value
}

function unit(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error('A position must be a number.')
  return Math.min(Math.max(value, 0), 1)
}

function point(value: unknown): { x: number; y: number } {
  const p = (typeof value === 'object' && value !== null ? value : {}) as Record<string, unknown>
  return { x: unit(p.x), y: unit(p.y) }
}

const BUTTONS = new Set(['home', 'back', 'overview', 'lock', 'volume-up', 'volume-down', 'action'])
const KEYS = new Set([
  'delete',
  'return',
  'enter',
  'tab',
  'escape',
  'arrow-up',
  'arrow-down',
  'arrow-left',
  'arrow-right',
  'select-all',
])
const MODIFIERS = new Set(['command', 'shift', 'option', 'control'])

function viewerOf(contents: WebContents): Viewer {
  return {
    id: contents.id,
    send: (channel, ...args) => {
      if (!contents.isDestroyed()) contents.send(channel, ...args)
    },
    isDestroyed: () => contents.isDestroyed(),
  }
}

/** A short preview of a PNG for a popup, or empty when it cannot be made. */
function previewOf(png: Buffer, height = 900): string {
  try {
    const image = nativeImage.createFromBuffer(png)
    const size = image.getSize()
    if (size.height === 0) return ''
    const scaled = size.height > height ? image.resize({ height }) : image
    return scaled.toDataURL()
  } catch {
    return ''
  }
}

/** Where pictures go — the same folder as the browser's screenshots, so Reveal opens both. */
export function picturesDir(): string {
  return join(app.getPath('pictures'), BRAND.name)
}

let shared: DeviceManager | null = null

/** The one manager in this process. Created on first use. */
export function deviceManager(): DeviceManager {
  if (shared === null) {
    shared = new DeviceManager({
      resourcesPath: app.isPackaged ? process.resourcesPath : null,
      appPath: app.getAppPath(),
      picturesDir,
    })
  }
  return shared
}

/**
 * Register the channels, and stop every engine when the app quits.
 *
 * Returns the manager, so `src/main/index.ts` can hand the same object to the
 * tools in one line — see `deck-control/device-tools.ts`.
 */
export function registerDevicesIpc(ipcMain: IpcMain): DeviceManager {
  const manager = deviceManager()
  const seen = new Set<number>()

  const remember = (event: IpcMainInvokeEvent): Viewer => {
    const contents = event.sender
    if (!seen.has(contents.id)) {
      seen.add(contents.id)
      const forget = (): void => {
        seen.delete(contents.id)
        manager.forgetViewer(contents.id)
      }
      contents.once('destroyed', forget)
      // A reload is a new page that never asked for the old one's pictures.
      contents.on('did-start-navigation', (details) => {
        if (details.isMainFrame && !details.isSameDocument) manager.forgetViewer(contents.id)
      })
    }
    return viewerOf(contents)
  }

  const windows = new Set<WebContents>()
  manager.onClosed((id, reason) => {
    for (const contents of windows) if (!contents.isDestroyed()) contents.send('devices:closed', id, reason)
  })

  ipcMain.handle('devices:list', async (event) => {
    windows.add(event.sender)
    return await manager.list()
  })
  ipcMain.handle('devices:boot', async (_event, id: unknown) => await manager.boot(deviceId(id)))
  ipcMain.handle('devices:shutdown', async (_event, id: unknown) => await manager.shutDown(deviceId(id)))
  ipcMain.handle('devices:open', async (event, id: unknown) => {
    windows.add(event.sender)
    return await manager.open(deviceId(id))
  })
  ipcMain.handle('devices:watch', async (event, id: unknown, on: unknown) => {
    windows.add(event.sender)
    await manager.watch(remember(event), deviceId(id), on === true)
  })
  ipcMain.handle('devices:tap', async (_event, id: unknown, x: unknown, y: unknown, holdMs: unknown) => {
    await manager.tap(deviceId(id), unit(x), unit(y), typeof holdMs === 'number' ? Math.min(holdMs, 5_000) : undefined)
  })
  ipcMain.handle('devices:touch', async (_event, id: unknown, phase: unknown, x: unknown, y: unknown) => {
    if (phase !== 'down' && phase !== 'move' && phase !== 'up') throw new Error('A touch is down, move or up.')
    await manager.touch(deviceId(id), phase, unit(x), unit(y))
  })
  ipcMain.handle('devices:swipe', async (_event, id: unknown, from: unknown, to: unknown, ms: unknown) => {
    const duration = typeof ms === 'number' && Number.isFinite(ms) ? Math.min(Math.max(ms, 50), 5_000) : 300
    await manager.swipe(deviceId(id), point(from), point(to), duration)
  })
  ipcMain.handle('devices:type', async (_event, id: unknown, text: unknown) => {
    if (typeof text !== 'string' || text.length > 2_000) throw new Error('Text to type must be a short string.')
    await manager.type(deviceId(id), text)
  })
  ipcMain.handle('devices:key', async (_event, id: unknown, key: unknown, modifiers: unknown) => {
    if (typeof key !== 'string' || !KEYS.has(key)) throw new Error('That key is not one a device can be sent.')
    const mods = Array.isArray(modifiers) ? modifiers.filter((m): m is string => typeof m === 'string' && MODIFIERS.has(m)) : []
    await manager.key(deviceId(id), key, mods)
  })
  ipcMain.handle('devices:button', async (_event, id: unknown, button: unknown) => {
    if (typeof button !== 'string' || !BUTTONS.has(button)) throw new Error('That is not a hardware button.')
    await manager.button(deviceId(id), button)
  })
  ipcMain.handle('devices:rotate', async (_event, id: unknown) => await manager.rotate(deviceId(id)))
  ipcMain.handle('devices:screenshot', async (_event, id: unknown) => {
    const shot = await manager.screenshot(deviceId(id))
    return { path: shot.path, width: shot.width, height: shot.height, preview: previewOf(shot.png), url: '' }
  })
  ipcMain.handle('devices:freeze', async (_event, id: unknown) => {
    const frozen = await manager.freeze(deviceId(id))
    return {
      image: `data:image/png;base64,${frozen.png.toString('base64')}`,
      width: frozen.width,
      height: frozen.height,
      tree: frozen.tree,
      treeError: frozen.treeError,
      where: frozen.where,
    }
  })
  ipcMain.handle('annotate:save', async (_event, png: unknown, round: unknown) => {
    return await manager.saveRound(png, readRound(round))
  })
  ipcMain.handle('annotate:sent', (_event, roundId: unknown, sentTo: unknown) => {
    const to = (typeof sentTo === 'object' && sentTo !== null ? sentTo : {}) as Record<string, unknown>
    if (typeof roundId !== 'string') return
    manager.markSent(roundId, {
      sessionId: typeof to.sessionId === 'string' ? to.sessionId : '',
      label: typeof to.label === 'string' ? to.label.slice(0, 200) : '',
    })
  })

  app.on('will-quit', () => {
    void manager.closeAll()
  })
  return manager
}
