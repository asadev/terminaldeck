import { randomUUID } from 'node:crypto'
import type { IpcMain } from 'electron'
import { browserTabContents } from './browser-tab'
import { BLANK_URL } from './browser-url'
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
 * ## The pane is asked for first, and it is the copilot's own
 *
 * This used to be a broadcast: the request went out, whichever
 * `BrowserWorkspace` was mounted claimed it, and if none was, the window was
 * asked to install one and the request went out again. The first half of that
 * fixed the defect it was written for — *"it is not capable to do the thing"*,
 * a `browser.open` on an app with no browser page open — and the second half
 * created a worse one.
 *
 * Measured on 2026-08-20, two calls from a cold start: a session was given a
 * window, `B1`, which is a **pane** in the shell. The next plain `browser.open`
 * from the copilot was claimed by `B1`'s panel, because it was the only one
 * mounted. The panel's own tab strip is gone — a browser page is a row in the
 * sidebar now — so the page he was looking at was not moved aside, it was
 * covered by a page in no strip anywhere; and the panel reports its active view
 * upward, so the binding map then pointed the session's own window at the
 * copilot's page. One page, two slots, two batons, two origin grants.
 *
 * So the order is inverted. A pane is obtained **before** anything is driven,
 * it is one the copilot asked for — never a session's, never one the person is
 * reading — and the drive request names it, so no other panel can answer.
 * `BrowserDriveDeps.pane` holds the three questions that decide it, and
 * `browser-binding-ipc.ts` answers all three, because "which panes exist" and
 * "which of them are attached" have one authority in this process.
 *
 * Two details make that cheap rather than clever:
 *
 *  - **A pane opens at the target URL** when nothing has to be isolated, and
 *    the drive adopts the one view that lands in it. No second request, no
 *    second page. Isolation is the exception: a partition is fixed when a view
 *    is constructed, so that one page has to be *created* by the renderer and
 *    its pane is opened blank first.
 *  - **The retry re-pushes the same request id.** `claimDriveOpen` in
 *    `renderer/browser/drive-bridge.ts` dedupes by id, so repeating the push
 *    while React mounts cannot produce one page per push.
 *
 * **If no window will open a pane, the answer is null and the tool says so.**
 * That state is real: somebody who has switched the browser off in Features has
 * said what they want, and `App.tsx` answers the request with a sentence rather
 * than installing a pane they turned off. House rule three — a control that
 * cannot act must say so. What it must never do instead is drive a pane
 * somebody else is using.
 */

/* -------------------------------------------------------------- channels -- */

/**
 * Main → renderer: please open a tab for the copilot and tell me its id.
 *
 * The payload carries `pane` — the shell tab id of the browser pane that may
 * answer — and no other pane may. See {@link BrowserDriveDeps.pane} for the
 * measurement that made an unaddressed broadcast unusable.
 */
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
 * Main → renderer: close this browser window, and say whether you did.
 *
 * The same argument as {@link DRIVE_OPEN_CHANNEL}, run backwards. A window is a
 * row in the shell's tab strip *and* a native view; the main process owns the
 * view and the renderer owns the row, so tearing the view down from here would
 * leave a row pointing at nothing — the ghost-id failure
 * `renderer/shell/workspace-strip.ts` documents at length, where a strip full of
 * dead ids looked empty and refused everything with no way to see why.
 *
 * So the request goes to the window and the window closes the tab through
 * `closeTabNow`, which is the same path its own ✕ takes: the pty rules do not
 * apply, `browser:window-closed` tells the binding map, and the selection moves
 * exactly as it would have if somebody had pressed it.
 *
 * The id is the **shell** tab id — `browser:<epoch>:<seq>` — because that is
 * what the renderer's list is keyed by and what the binding map already holds
 * beside every window. It is never printed at an agent; see `DriveTarget`.
 */
export const DRIVE_CLOSE_CHANNEL = 'browser:drive-close'
/** Renderer → main: that request id closed a window (true) or found none. */
export const DRIVE_CLOSED_CHANNEL = 'browser:drive-closed'
/**
 * Main → renderer: bring this browser window to the front of its pane.
 *
 * The same shape as the close request and for the same reason — the row is the
 * renderer's — but this one is not a convenience. A `WebContentsView` that is
 * not the tab on screen has no rectangle, so every click and keystroke aimed at
 * it is dropped and it cannot be photographed at all. `DriveHost.showWindow`
 * carries the measurement.
 */
export const DRIVE_SHOW_CHANNEL = 'browser:drive-show'
/** Renderer → main: that request id found the window and showed it. */
export const DRIVE_SHOWN_CHANNEL = 'browser:drive-shown'

/**
 * How long the window is given to close a tab and answer.
 *
 * The renderer's side is one state update in the same handler, so this is not a
 * budget for work — it is the bound on how long an agent's tool call waits when
 * no window is listening at all. Same reasoning and same order as
 * {@link OPEN_TAB_TIMEOUT_MS}.
 */
export const CLOSE_TAB_TIMEOUT_MS = 5_000

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
  /**
   * The copilot's own browser pane — opened, checked and read.
   *
   * ## The regression this exists to make impossible
   *
   * `browser:drive-open` is a broadcast and `claimDriveOpen` is first-come, so
   * the pane that answered it was whichever `BrowserWorkspace` happened to be
   * mounted. Measured on 2026-08-20, two calls from a cold start: a session was
   * given a window — `B1`, a pane in the shell — and the very next plain
   * `browser.open` from the copilot landed **inside it**. The panel's own tab
   * strip is gone, so the page he was looking at was not moved aside, it was
   * covered by a page in no strip anywhere; and the workspace reports its
   * active view upward, so the binding map then pointed the session's own
   * window at the copilot's page. One page, two slots, two batons, two origin
   * grants.
   *
   * The copilot's own tab and a session's attached window are different things.
   * The only pane the copilot will ever use is one **it asked for**, so it
   * cannot take a session's, and it cannot take one the person is reading
   * either. `browser-binding-ipc.ts` owns all three answers because it is the
   * one place that knows which panes exist and which of them are attached.
   *
   * Handed in rather than imported for the reason `openForSession` is: this
   * module keeps one dependency on the renderer and none on the binding wiring,
   * and the wiring is what a test replaces.
   */
  pane: {
    /** Open a pane belonging to nobody at `url`; answer its shell tab id. */
    open(url: string): Promise<string | null>
    /** Still open, and still nobody's? A pane he has attached is not ours. */
    free(tabId: string): boolean
    /** The view now inside it, waiting up to `timeoutMs` for one to appear. */
    view(tabId: string, timeoutMs: number): Promise<string | null>
  }
  /**
   * Open a window that belongs to a session, through the route the shim uses.
   *
   * Handed in rather than imported so this module keeps its one dependency on
   * the renderer and none on the binding wiring — and so the numbering an agent
   * sees is provably the numbering `open <url>` produces, because it is the
   * same function. `index.ts` passes `openForSession` bound to `bindingDeps`.
   */
  openForSession?(request: {
    url: string
    sessionId: string
    machineId: string
    newWindow?: boolean
  }): Promise<{ route: 'tab' | 'system'; line: string }>
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
    input: { url: string; isolate: boolean; pane: string },
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
        deps.send(DRIVE_OPEN_CHANNEL, {
          id,
          url: input.url,
          isolate: input.isolate,
          // Addressed. Every mounted workspace hears this and exactly one of
          // them is allowed to answer it — see `BrowserDriveDeps.pane`.
          pane: input.pane,
        })
      const timer = setTimeout(() => finish(null), wait.waitMs)
      timer.unref?.()
      const ticker = wait.repeatMs === undefined ? null : setInterval(push, wait.repeatMs)
      ticker?.unref?.()
      pending.set(id, finish)
      push()
    })

  /**
   * The pane the copilot's own tab lives in, made on first use.
   *
   * Reused for the life of the pane so that "the copilot's tab" is one place on
   * screen rather than a new row every time it opens a page — and given up the
   * moment the pane is closed or the person attaches it to a session, both of
   * which {@link BrowserDriveDeps.pane.free} answers in one call.
   *
   * `fresh` travels with it because the two cases wait for different things: a
   * pane that already exists has a mounted workspace listening now, and one
   * that has just been asked for is behind a React mount.
   */
  const ownPane = async (url: string): Promise<{ tabId: string; fresh: boolean } | null> => {
    if (mine !== null && deps.pane.free(mine)) return { tabId: mine, fresh: false }
    mine = null
    const made = await deps.pane.open(url)
    if (made === null) return null
    mine = made
    return { tabId: made, fresh: true }
  }

  /**
   * Ask the window to close a browser tab, and hear whether it did.
   *
   * Keyed by request id for the same reason `askForTab` is: two closes can
   * overlap, and a single slot would settle the second with the first's answer.
   * A false is a real answer — the window has no tab by that id, which is what
   * a window that has already gone looks like — and is reported rather than
   * retried.
   */
  /**
   * The shell tab id of the copilot's own browser pane, while it has one.
   *
   * In this closure rather than at module scope so that re-registering the
   * channels — a renderer replacement, ⌘R — starts from no pane, which is the
   * truth at that moment: `forgetKnownWindows()` drops every window this
   * process knew about in the same breath.
   */
  let mine: string | null = null

  const closing = new Map<string, (ok: boolean) => void>()
  const showing = new Map<string, (ok: boolean) => void>()

  /** One request id, one answer, one timeout. Shared by close and show. */
  const askWindow = (
    waiting: Map<string, (ok: boolean) => void>,
    channel: string,
    browserTabId: string,
  ): Promise<boolean> =>
    new Promise<boolean>((resolve) => {
      const id = randomUUID()
      let settled = false
      const finish = (ok: boolean): void => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        waiting.delete(id)
        resolve(ok)
      }
      const timer = setTimeout(() => finish(false), CLOSE_TAB_TIMEOUT_MS)
      timer.unref?.()
      waiting.set(id, finish)
      deps.send(channel, { id, tabId: browserTabId })
    })

  drive = new BrowserDrive({
    openTab: async (input) => {
      /*
       * A pane of the copilot's own, first — never one that is already on
       * screen. The seizure this replaces is written up on
       * {@link BrowserDriveDeps.pane}.
       *
       * A fresh pane is opened **at the target URL** when nothing has to be
       * isolated, and that is not a shortcut: the pane's workspace opens its
       * one page at the address it was given, so there is exactly one view and
       * the drive adopts it. Going through `drive-open` as well would put a
       * second page in the same pane and hide the first — the very shape being
       * fixed, one row further in.
       */
      const isolate = input.isolate
      const pane = await ownPane(isolate ? BLANK_URL : input.url)
      if (pane === null) return null

      if (pane.fresh && !isolate) {
        return deps.pane.view(pane.tabId, INSTALL_BROWSER_TIMEOUT_MS)
      }

      /*
       * Everything else goes through the renderer, because something has to be
       * *created*: an isolated view, whose partition is fixed when it is
       * constructed and cannot be applied to a page that already exists; or a
       * replacement for a view that died inside a pane that did not.
       *
       * A freshly-asked-for pane is behind a React mount, so its request is
       * repeated under one id until its workspace subscribes — `claimDriveOpen`
       * dedupes by id, so the repeats cannot become one page each.
       */
      return askForTab(
        { url: input.url, isolate, pane: pane.tabId },
        pane.fresh
          ? { waitMs: INSTALL_BROWSER_TIMEOUT_MS, repeatMs: INSTALL_REPUSH_MS }
          : { waitMs: OPEN_TAB_TIMEOUT_MS },
      )
    },
    contentsFor: (tabId) => browserTabContents(tabId),
    publish: (status: DriveStatus) => deps.send(DRIVE_STATE_CHANNEL, status),
    now: () => Date.now(),
    ...(deps.openForSession
      ? {
          openForSession: async (input: { url: string; sessionId: string; machineId: string }) => {
            const answer = await deps.openForSession!({ ...input, newWindow: true })
            /*
             * `route: 'system'` is the honest failure and is reported as one: it
             * means the URL went to the machine's own browser, so nothing was
             * attached to the session and an agent told otherwise would spend
             * the rest of the turn steering a window that does not exist. The
             * route's own sentence travels with it — it already says why.
             */
            return { line: answer.line, attached: answer.route === 'tab' }
          },
        }
      : {}),
    closeWindow: (browserTabId) => askWindow(closing, DRIVE_CLOSE_CHANNEL, browserTabId),
    showWindow: (browserTabId) => askWindow(showing, DRIVE_SHOW_CHANNEL, browserTabId),
  })

  ipcMain.on(DRIVE_OPENED_CHANNEL, (_event, id: unknown, tabId: unknown) => {
    const settle = typeof id === 'string' ? pending.get(id) : undefined
    if (!settle) return
    // A tab id is a string this process minted in `browser:create`; anything
    // else from a renderer is treated as "no tab", not as a tab called that.
    settle(typeof tabId === 'string' && tabId.length > 0 ? tabId : null)
  })

  ipcMain.on(DRIVE_CLOSED_CHANNEL, (_event, id: unknown, closed: unknown) => {
    const settle = typeof id === 'string' ? closing.get(id) : undefined
    settle?.(closed === true)
  })

  ipcMain.on(DRIVE_SHOWN_CHANNEL, (_event, id: unknown, shown: unknown) => {
    const settle = typeof id === 'string' ? showing.get(id) : undefined
    settle?.(shown === true)
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
