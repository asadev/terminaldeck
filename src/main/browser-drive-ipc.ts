import { randomUUID } from 'node:crypto'
import type { IpcMain } from 'electron'
import { browserTabContents } from './browser-tab'
import type { DriveStatus } from './browser-drive'
import { BrowserDrive } from './browser-driver'

/**
 * The drive, wired to a window.
 *
 * One file so that `src/main/index.ts` gains two lines rather than forty, in
 * the shape the rest of this process already uses — `registerXIpc(ipcMain)`,
 * called once from `registerIpc()`.
 *
 * ## Why the agent's tab is opened by the renderer
 *
 * This is the one wiring decision worth arguing about, because the obvious
 * alternative is shorter: the main process could build its own
 * `WebContentsView`, add it to the window and drive that, with no round trip at
 * all.
 *
 * It would also be a page that exists, is doing things, and cannot be found. A
 * view created here is not in the tab strip, is not positioned by the browser
 * workspace's layout, and has no close button — so the person watching a
 * website move on its own would have no way to stop it except quitting. That is
 * exactly the object `catalogue.ts` already refuses to produce for sessions, in
 * its own words: *"a tab you did not open and cannot account for is the thing
 * this app must not produce"*.
 *
 * So the request goes to the window, the window opens an ordinary browser tab
 * through the ordinary path, and it comes back with the id. The tab is in the
 * strip, wears a chip saying who is driving, and closing it ends the drive with
 * no confirmation and no argument.
 *
 * **And when there is no browser workspace open, the answer is null and the
 * tool says so.** Not a hidden window, not a silently-created view: a sentence
 * telling the copilot to ask the person to open a browser tab. House rule
 * three — a control that cannot act must say so.
 */

/* -------------------------------------------------------------- channels -- */

/** Main → renderer: please open a tab for the copilot and tell me its id. */
export const DRIVE_OPEN_CHANNEL = 'browser:drive-open'
/** Renderer → main: here is the id, or null because there was no workspace. */
export const DRIVE_OPENED_CHANNEL = 'browser:drive-opened'
/** Main → renderer: the drive's state changed; redraw the banner. */
export const DRIVE_STATE_CHANNEL = 'browser:drive-state'
/** Renderer → main: read the state, for a window that opened mid-drive. */
export const DRIVE_READ_CHANNEL = 'browser:drive-status'
/** Renderer → main: "done, carry on" (true) or "stop, I'll take it" (false). */
export const DRIVE_RESUME_CHANNEL = 'browser:drive-resume'

/**
 * How long the main process waits for a window to answer with a tab id.
 *
 * Short, because the renderer's side of this is one state update and a
 * `browserCreate` — and because the failure it guards against is not a slow
 * window, it is *no window*: an app with no browser workspace open never
 * answers at all, and the copilot needs a sentence rather than a hang. Five
 * seconds is far beyond a real answer and far inside any tool timeout.
 */
export const OPEN_TAB_TIMEOUT_MS = 5_000

/* -------------------------------------------------------------- registry -- */

export interface BrowserDriveDeps {
  /** Push to the renderer. Pass the main process's own `send`. */
  send(channel: string, ...args: unknown[]): void
}

let drive: BrowserDrive | null = null

/**
 * Build the drive and claim its channels. Call once from `registerIpc()`.
 *
 * Returns the drive so the caller can hand `browserTools(drive)` to
 * `registerDeckControlIpc` — the tools are a closure over this object, which is
 * why they are contributed through `extraTools` rather than declared in
 * `catalogue.ts`.
 */
export function registerBrowserDriveIpc(ipcMain: IpcMain, deps: BrowserDriveDeps): BrowserDrive {
  /*
   * Requests in flight, by id.
   *
   * Keyed rather than a single slot because two `browser.open` calls can
   * overlap — the budget allows it and a model retrying does it — and a single
   * slot would resolve the second call with the first call's tab.
   */
  const pending = new Map<string, (tabId: string | null) => void>()

  drive = new BrowserDrive({
    openTab: (input) =>
      new Promise<string | null>((resolve) => {
        const id = randomUUID()
        let settled = false
        const finish = (tabId: string | null): void => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          pending.delete(id)
          resolve(tabId)
        }
        const timer = setTimeout(() => finish(null), OPEN_TAB_TIMEOUT_MS)
        timer.unref?.()
        pending.set(id, finish)
        deps.send(DRIVE_OPEN_CHANNEL, { id, url: input.url, isolate: input.isolate })
      }),
    contentsFor: (tabId) => browserTabContents(tabId),
    publish: (status: DriveStatus) => deps.send(DRIVE_STATE_CHANNEL, status),
    now: () => Date.now(),
  })

  ipcMain.on(DRIVE_OPENED_CHANNEL, (_event, id: unknown, tabId: unknown) => {
    const settle = typeof id === 'string' ? pending.get(id) : undefined
    if (!settle) return
    // A tab id is a string this process minted in `browser:create`; anything
    // else from a renderer is treated as "no tab", not as a tab called that.
    settle(typeof tabId === 'string' && tabId.length > 0 ? tabId : null)
  })

  ipcMain.handle(DRIVE_READ_CHANNEL, () => drive?.status() ?? null)

  ipcMain.on(DRIVE_RESUME_CHANNEL, (_event, carryOn: unknown) => {
    drive?.resume(carryOn === true)
  })

  return drive
}

/** The live drive, for anything assembled after `registerIpc`. Null before it. */
export function browserDrive(): BrowserDrive | null {
  return drive
}
