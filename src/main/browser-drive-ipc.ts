import { randomUUID } from 'node:crypto'
import type { IpcMain } from 'electron'
import { browserTabContents } from './browser-tab'
import { BLANK_URL } from './browser-url'
import type { DriveStatus } from './browser-drive'
import { BrowserDrive } from './browser-driver'
import { LINK_TAB_CHANNEL } from './link-open'

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
 * ## And when there is no browser workspace open, it asks the window for one
 *
 * This used to be where the feature ended. The push went out, no
 * `BrowserWorkspace` was mounted to hear it, nobody answered, and the tool told
 * the copilot to ask the person to press the globe in the sidebar. That is an
 * honest sentence and it was still the whole of the defect Asad reported: *"it
 * is not capable to do the thing"* — he asked his copilot to go to a page, and
 * on an app with no browser page already open the answer was always a refusal.
 * Reproduced on 2026-08-18 against the packaged build, first ask of a fresh
 * window: `browser.open` refused, and the copilot fell back to fetching the URL
 * and said so.
 *
 * The fix is not a hidden window — the argument above still holds, and the tab
 * must land in the strip where somebody can see and close it. It is that the
 * *renderer* is asked to install a browser page first, through
 * {@link LINK_TAB_CHANNEL}, which is the one main→renderer channel a window
 * listens on for the whole of its life rather than only while a browser panel
 * happens to be mounted. `App.tsx` answers it exactly as it answers the globe:
 * it installs the browser feature if it is not installed and opens a page. Then
 * the drive request goes out again and the freshly-mounted workspace answers it.
 *
 * Two details make that safe rather than clever:
 *
 *  - **`about:blank`, not the target URL.** The link channel would otherwise
 *    open the page itself and the drive would then open a *second* tab at the
 *    same address. A blank page is what the globe gives you, so what the person
 *    sees is the sequence they would have produced by hand.
 *  - **The retry re-pushes the same request id.** `claimDriveOpen` in
 *    `renderer/browser/drive-bridge.ts` dedupes by id, so repeating the push
 *    while React mounts cannot produce one tab per push — the first panel to
 *    see it claims it and every later copy is ignored.
 *
 * **If nothing answers even then, the answer is still null and the tool still
 * says so.** That state is real: somebody who has switched the browser off in
 * Features has said what they want, and `App.tsx` routes the link outward
 * rather than installing a pane they turned off — `about:blank` is in
 * `link-open.ts`'s `NEVER_LEAVES`, so the outward route is a no-op and nothing
 * opens anywhere. House rule three — a control that cannot act must say so.
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

/**
 * How long the second attempt waits, after the window has been asked to install
 * a browser page.
 *
 * Longer than the first, because this one is not waiting for a round trip — it
 * is waiting for React to mount a `BrowserWorkspace` and for its subscription
 * effect to run, behind whatever else that render is doing. Still far inside the
 * sixty seconds an MCP client allows a tool call, which is the number that
 * actually bounds everything here (see `HANDOVER_WINDOW_MS`).
 */
export const INSTALL_BROWSER_TIMEOUT_MS = 8_000

/**
 * How often the second attempt repeats its push while it waits.
 *
 * A push is not a queue: a renderer that has not yet subscribed does not
 * receive it late, it does not receive it at all. So the request is repeated
 * rather than sent once and hoped for — with the *same* id, which is what stops
 * the repeats becoming one browser tab each. See the header.
 */
export const INSTALL_REPUSH_MS = 250

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

  /**
   * Ask the window for a tab, once, and wait for the answer.
   *
   * `repeatMs` is what makes the second attempt possible at all — see the
   * header. The id is minted here and reused by every repeat of the same
   * attempt, so a workspace that mounts halfway through hears the request once
   * and every other copy of it is discarded by the claim.
   */
  const askForTab = (
    input: { url: string; isolate: boolean },
    wait: { waitMs: number; repeatMs?: number },
  ): Promise<string | null> =>
    new Promise<string | null>((resolve) => {
      const id = randomUUID()
      let settled = false
      const finish = (tabId: string | null): void => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        if (ticker !== null) clearInterval(ticker)
        pending.delete(id)
        resolve(tabId)
      }
      const push = (): void =>
        deps.send(DRIVE_OPEN_CHANNEL, { id, url: input.url, isolate: input.isolate })
      const timer = setTimeout(() => finish(null), wait.waitMs)
      timer.unref?.()
      const ticker = wait.repeatMs === undefined ? null : setInterval(push, wait.repeatMs)
      ticker?.unref?.()
      pending.set(id, finish)
      push()
    })

  drive = new BrowserDrive({
    openTab: async (input) => {
      const answered = await askForTab(input, { waitMs: OPEN_TAB_TIMEOUT_MS })
      if (answered !== null) return answered
      /*
       * Nobody answered, which means no browser page is mounted in the window.
       * Ask for one on the channel a window listens to for its whole life, then
       * ask again. A null after this is the honest "there is no browser here"
       * the tool reports — see the header for why that state is still real.
       */
      deps.send(LINK_TAB_CHANNEL, BLANK_URL)
      return askForTab(input, {
        waitMs: INSTALL_BROWSER_TIMEOUT_MS,
        repeatMs: INSTALL_REPUSH_MS,
      })
    },
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
