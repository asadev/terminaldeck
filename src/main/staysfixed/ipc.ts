import { app, type IpcMain } from 'electron'
import { statSync } from 'node:fs'
import { homedir } from 'node:os'
import { isAbsolute, resolve } from 'node:path'
import type { FixedToolDeps } from '../deck-control/fixed-tools'
import { loginPath } from '../providers'
import { locateEngine } from './engine'
import { StaysFixedService } from './service'

/**
 * The Stays Fixed page's door into the main process.
 *
 * ## Channels
 *
 * All `invoke`. Every one takes the open project's absolute path first, and it
 * is checked to be an existing folder before anything runs — it becomes the
 * engine's working directory.
 *
 * - `staysfixed:status`    (project)            → `StaysFixedStatus`
 * - `staysfixed:readiness` (project, refresh?)  → `{ ok, readiness }` | `{ ok: false, message }`
 * - `staysfixed:setup`     (project)            → `FixedSetupOutcome`
 * - `staysfixed:check`     (project)            → `{ ok, results }` | `{ ok: false, message }`
 * - `staysfixed:stop`      (project)            → whether a check was running
 * - `staysfixed:results`   (project, full?)     → `FixedShownResults` | null
 * - `staysfixed:mark-good` (project, anyway?)   → `FixedMarkOutcome`
 * - `staysfixed:agents`    (project, on)        → `StaysFixedStatus`
 *
 * Pushed to the window: `staysfixed:changed` (project) — a step of a running
 * check, a finished one, a switch. The page answers by asking for the status
 * again; the push carries no data so there is one shape of the truth, not two.
 */

export const CHANGED_CHANNEL = 'staysfixed:changed'

function folder(value: unknown): string {
  if (typeof value !== 'string' || !isAbsolute(value)) throw new Error('That is not a project folder.')
  const path = resolve(value)
  let ok = false
  try {
    ok = statSync(path).isDirectory()
  } catch {
    ok = false
  }
  if (!ok) throw new Error('That project folder is not there any more.')
  return path
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function registerStaysFixedIpc(ipcMain: IpcMain, service: StaysFixedService): void {
  ipcMain.handle('staysfixed:status', (_event, project: unknown) => service.status(folder(project)))
  ipcMain.handle('staysfixed:readiness', async (_event, project: unknown, refresh: unknown) => {
    try {
      return { ok: true, readiness: await service.readiness(folder(project), refresh === true) }
    } catch (error) {
      return { ok: false, message: message(error) }
    }
  })
  ipcMain.handle('staysfixed:setup', (_event, project: unknown) => service.setup(folder(project)))
  ipcMain.handle('staysfixed:check', async (_event, project: unknown) => {
    try {
      return { ok: true, results: await service.check(folder(project), 'you') }
    } catch (error) {
      return { ok: false, message: message(error) }
    }
  })
  ipcMain.handle('staysfixed:stop', (_event, project: unknown) => service.stop(folder(project)))
  ipcMain.handle('staysfixed:results', (_event, project: unknown, full: unknown) =>
    service.results(folder(project), full === true),
  )
  ipcMain.handle('staysfixed:mark-good', (_event, project: unknown, anyway: unknown) =>
    service.markGood(folder(project), anyway === true),
  )
  ipcMain.handle('staysfixed:agents', (_event, project: unknown, on: unknown) => {
    if (typeof on !== 'boolean') throw new Error('Say on or off.')
    return service.setAgents(folder(project), on)
  })
}

/**
 * The one Stays Fixed for this app — built at module scope in `index.ts`,
 * because three callers need the **same** instance and one of them, the
 * session launcher (`createHostCore`'s `projectTools`), is itself built at
 * module scope. One instance is what makes "one check per project" true
 * whether the page, Hoot or an AI app asked.
 *
 * `send` is `index.ts`'s own `send`, so the push reaches every window the way
 * every other push does. Nothing here touches a window or a channel until the
 * first check runs, so building it early costs nothing.
 */
export function createStaysFixed(send: (channel: string, ...args: unknown[]) => unknown): StaysFixedService {
  const service = new StaysFixedService({
    userData: app.getPath('userData'),
    locate: () =>
      locateEngine({
        resourcesPath: app.isPackaged ? process.resourcesPath : null,
        appPath: app.getAppPath(),
      }),
    executable: process.execPath,
    loginPath: () => loginPath(),
    changed: (project) => {
      send(CHANGED_CHANNEL, project)
    },
    home: homedir(),
  })
  // A check left running would keep a browser and an old build alive after the
  // window is gone. `SIGTERM` lets Stays Fixed put its own things away.
  app.once('will-quit', () => service.dispose())
  return service
}

/**
 * The service, as the narrow set of closures `deck-control/fixed-tools.ts`
 * takes. One instance behind both doors — see {@link createStaysFixed}.
 */
export function fixedToolDeps(service: StaysFixedService): FixedToolDeps {
  return {
    status: (project) => service.status(project),
    readiness: (project, refresh) => service.readiness(project, refresh),
    setup: (project) => service.setup(project),
    check: (project, by) => service.check(project, by),
    progress: (project) => service.progress(project),
    stop: (project) => service.stop(project),
    waitFor: (project, ms) => service.waitFor(project, ms),
    results: (project, full) => service.results(project, full),
    markGood: (project, anyway) => service.markGood(project, anyway),
    setAgents: (project, on) => service.setAgents(project, on),
  }
}
