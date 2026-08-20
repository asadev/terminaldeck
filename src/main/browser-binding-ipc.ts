/**
 * The wiring between the binding store, the window that draws it, and the
 * shim that asks it questions.
 *
 * `browser-binding.ts` is a map and some arithmetic on purpose, so this is the
 * file that knows about Electron: it registers the channels a window reports
 * through, pushes the view back, builds the native attach menu, and hands
 * `browser-route.ts` the two things it needs — a page it can steer and a
 * renderer it can ask for a window.
 *
 * The same split `browser-drive-ipc.ts` uses, for the same reason: the decision
 * is testable without a window, and the part that cannot be is small enough to
 * read in one go.
 */

import { Menu, type BrowserWindow, type IpcMain, type MenuItemConstructorOptions } from 'electron'
import { BRAND } from '../shared/brand'
import type { LinkRoute, LinkTabRequest } from '../shared/types'
import {
  attach,
  bindingFor,
  detach,
  ownerOf,
  slotName,
  subscribe,
  view,
  windowClosed,
  windowMoved,
} from './browser-binding'
import { routeOpen, type OpenedReply, type SteerablePage } from './browser-route'
import { browserTabContents } from './browser-tab'
import { LINK_TAB_CHANNEL, openSystemUrl } from './link-open'
import type { OpenAnswer } from './hook-server'

/**
 * Every browser window this renderer has told us about, bound or not.
 *
 * Separate from the binding map, and deliberately: the binding map holds the
 * *relation*, and an unattached window is not in a relation. The menu still has
 * to list it — *"Attach a window"* over a list of what is actually open is the
 * whole gesture — and listing it greyed, or not listing it, is the "screen that
 * quietly shows a subset" failure `agent-target.ts` exists to stop.
 */
interface KnownWindow {
  tabId: string
  viewId: string | null
  url: string
  title: string
  /**
   * Which machine is really serving this page. Empty for this computer.
   *
   * Derived by the window from the tunnel it opened, not from the address bar:
   * a page reached on his PC wears a `localhost` address on **this** machine, so
   * the URL is exactly the thing that cannot answer the question. *"We always
   * need a truth."*
   */
  machineId: string
  machineName: string
  /** True while this is the page on screen, so the menu can say which one it is. */
  visible: boolean
  /**
   * A number for a window nobody has named.
   *
   * Four windows on the start page are four rows reading `New tab`, which is
   * what Asad was looking at when he said he could not attach an existing one —
   * the menu was full of windows and none of them was distinguishable from the
   * next. Allocated on first sight and never reused, so the number a window
   * wears does not change under him when another one closes.
   */
  w: number
}

const known = new Map<string, KnownWindow>()

/** The last window number handed out. Never decremented; see `KnownWindow.w`. */
let windowSeq = 0

/** Requests out on {@link LINK_TAB_CHANNEL} that are still waiting for an answer. */
const pending = new Map<string, (reply: OpenedReply) => void>()

let requestSeq = 0

/**
 * How long the renderer is given to open a window and name it.
 *
 * The renderer's side of this is synchronous — it mints the id, adds the tab and
 * answers in the same handler — so this is not a budget for the work, it is a
 * bound on how long an agent's `curl` is held open when the window is gone,
 * mid-reload, or otherwise not listening. Comfortably inside the shim's own
 * three seconds so that the shim's fallback is never the thing that fires first.
 */
const OPEN_WINDOW_TIMEOUT_MS = 2000

export interface BindingIpcDeps {
  /** Push to the window that draws the strip. */
  send(channel: string, payload: unknown): void
  /** The window a native menu should be popped over. */
  window(): BrowserWindow | null
  /**
   * Whether this app started that session.
   *
   * Asked of the pty manager, which is the only thing that knows. It is what
   * separates a session of ours that has no window yet — which should get one,
   * and which is the very first `open` of every session — from an id belonging
   * to somebody else's shell, which must not put a page in a browser holding his
   * logins. The hook and the shim are on the machine, not on this app, so the
   * second case arrives regularly and is not hypothetical.
   */
  knowsSession(sessionId: string, machineId: string): boolean
}

/**
 * Ask the renderer for a browser window, and hear back either way.
 *
 * The timeout answers `refused` with a sentence rather than resolving to
 * nothing, because the caller is going to print whatever comes back: silence
 * here would reach a person as a link that vanished.
 */
function askForWindow(
  deps: BindingIpcDeps,
  request: { url: string; sessionId: string; machineId: string },
): Promise<OpenedReply> {
  requestSeq += 1
  const requestId = `open:${Date.now()}:${requestSeq}`

  return new Promise<OpenedReply>((settle) => {
    let done = false
    const finish = (reply: OpenedReply): void => {
      if (done) return
      done = true
      pending.delete(requestId)
      settle(reply)
    }
    pending.set(requestId, finish)

    const timer = setTimeout(
      () =>
        finish({
          refused: `No ${BRAND.name} window answered — opening it in your default browser.`,
        }),
      OPEN_WINDOW_TIMEOUT_MS,
    )
    timer.unref?.()

    const payload: LinkTabRequest = {
      url: request.url,
      sessionId: request.sessionId,
      requestId,
      ...(request.machineId ? { machineId: request.machineId } : {}),
    }
    deps.send(LINK_TAB_CHANNEL, payload)
  })
}

/**
 * The one routing call, shared by the shim and by a click in a terminal.
 *
 * Exported so `index.ts` can hand it to the hook server as `onOpen` without
 * rebuilding the dependencies, and so both entrances provably use the same
 * answer — two copies of this is how the shim would land in the right window
 * and the terminal click in Safari again.
 */
export function openForSession(
  deps: BindingIpcDeps,
  request: { url: string; sessionId: string | null; machineId?: string; newWindow?: boolean },
): Promise<OpenAnswer> {
  return routeOpen(request, {
    // `browserTabContents` answers null for an id it does not know, for a view
    // that has gone and for one its renderer took down with it — all three of
    // which mean the same thing here, and all three of which are handled by
    // minting a window rather than by pretending one was navigated.
    pageFor: (viewId) => browserTabContents(viewId) as unknown as SteerablePage | null,
    knowsSession: (sessionId, machineId) => deps.knowsSession(sessionId, machineId),
    openWindow: (ask) => askForWindow(deps, ask),
  })
}

/* ------------------------------------------------------------------ menu -- */

/**
 * What to call a window in a menu.
 *
 * Whatever the page said about itself first, because that is what he would
 * recognise. `Window 3` only for a page that has told us nothing — and it is a
 * number rather than a fourth row reading `New tab`, which is the state he was
 * actually in: *"I cannot connect actually this one… I can only start a new
 * one."* Four identical rows are not a list you can choose from.
 */
function windowLabel(entry: KnownWindow): string {
  return entry.title || entry.url || `Window ${entry.w}`
}

/** How a machine is named in a menu heading. Empty id means this computer. */
function machineLabel(machineId: string, machineName: string): string {
  if (machineId === '') return 'This computer'
  return machineName || machineId
}

/**
 * The windows, in machine order, with a heading per machine — and no heading at
 * all when they are all in one place.
 *
 * Asad: *"if I open any browser here and if I connect it to, let's say, desktop,
 * now this is in desktop, it should come under this table, under the desktop
 * sessions. So all the desktop browser, including session, should be at one
 * place."* A heading is a label, not a sentence, so it survives the rule about
 * prose on screen; and it is absent in the ordinary one-machine case, where it
 * would be a heading over the only group there is.
 */
function byMachine(entries: KnownWindow[]): { label: string; windows: KnownWindow[] }[] {
  const groups = new Map<string, KnownWindow[]>()
  for (const entry of entries) {
    const list = groups.get(entry.machineId)
    if (list) list.push(entry)
    else groups.set(entry.machineId, [entry])
  }
  // This computer first, then the rest in the order they were first seen —
  // which is the order the machine list itself is built in.
  const keys = [...groups.keys()].sort((a, b) => (a === '' ? -1 : b === '' ? 1 : 0))
  return keys.map((machineId) => ({
    label: machineLabel(machineId, groups.get(machineId)?.[0]?.machineName ?? ''),
    windows: groups.get(machineId) ?? [],
  }))
}

/**
 * The attach/detach menu for one session.
 *
 * A **native** menu, and that is not a style preference. A `WebContentsView`
 * composites above the entire renderer — the whole subject of `overlay-watch.ts`
 * — so an HTML menu would be hidden behind the browser page in exactly the
 * situation this feature exists for. `link-open.ts`'s `showLinkMenu` made the
 * same call for the same reason.
 */
export function showBindMenu(
  deps: BindingIpcDeps,
  request: { sessionId: string; machineId?: string },
): boolean {
  const window = deps.window()
  if (!window || window.isDestroyed()) return false

  Menu.buildFromTemplate(bindMenuItems(deps, request)).popup({ window })
  return true
}

/**
 * The same items, for a menu that is not only about the browser.
 *
 * The sidebar's ⋯ menu hangs these under one **Connect browser** entry — Asad
 * could not find the attach control at all, and said where he expected it:
 * *"three dot, then connect browser button. Then I can have the full list of the
 * browser. I can choose which ones to connect with this session."* That list is
 * this one, so it is built once and handed to both callers rather than written a
 * second time in the shape of a submenu. Two spellings of "which windows are
 * attached" is how the pane bar and the rail come to disagree about the same
 * window.
 */
export function bindMenuItems(
  deps: BindingIpcDeps,
  request: { sessionId: string; machineId?: string },
): MenuItemConstructorOptions[] {
  const machineId = request.machineId ?? ''
  const binding = bindingFor(request.sessionId, machineId)
  const items: MenuItemConstructorOptions[] = []

  /*
   * A checklist, not two lists with two verbs.
   *
   * It used to be attached windows over here with `Detach B1 from this session.
   * The page stays open.` written under each, and unattachable ones over there
   * with a second sentence under those. Both of those sentences are the prose
   * he ruled out this round — *"don't put any single statement in anywhere…
   * smart people knows how it works"* — and neither of them was the thing that
   * was missing. What was missing was being able to tell one window from the
   * next.
   *
   * A ticked row means "attached to this session" and clicking it toggles.
   * That is a shape everybody already knows, it needs no words at all, and it
   * puts every window in **one** list, in machine order, so a window this
   * session does not hold is still visible and still one click away.
   */
  const windows = [...known.values()]

  if (windows.length === 0) {
    // Never an empty menu. One line and an offer reads as a state; nothing at
    // all reads as a broken control.
    items.push({ label: 'No browser windows are open.', enabled: false })
  }

  const groups = byMachine(windows)
  for (const group of groups) {
    if (groups.length > 1) items.push({ label: group.label, enabled: false })
    for (const entry of group.windows) {
      const bound = binding?.windows.find((window) => window.browserTabId === entry.tabId)
      items.push({
        type: 'checkbox',
        checked: bound !== undefined,
        /*
         * The slot number leads when there is one, because `B2` is the word he
         * says out loud and the word the agent was told. A window this session
         * does not hold has no number *for this session* and so wears none —
         * inventing one here would print a name the agent has never been given.
         */
        label: bound ? `${slotName(bound.n)}   ${windowLabel(entry)}` : windowLabel(entry),
        click: () => {
          if (bound) detach(entry.tabId)
          else
            attach({
              sessionId: request.sessionId,
              machineId,
              browserTabId: entry.tabId,
              viewId: entry.viewId,
              url: entry.url,
              title: entry.title,
              hostMachineId: entry.machineId,
              hostMachineName: entry.machineName,
            })
        },
      })
    }
  }

  items.push({ type: 'separator' })
  items.push({
    label: 'New window, attached',
    click: () => {
      void openForSession(deps, {
        url: '',
        sessionId: request.sessionId,
        machineId,
        newWindow: true,
      })
    },
  })

  return items
}

/**
 * One session, as the window that draws it knows it.
 *
 * The names arrive from the renderer for the reason `session-row-menu.ts`
 * already gives at length: main has ids and no idea what any of them are
 * called, and re-deriving the rail's numbering here would be a second copy of it
 * that keeps the old spelling after the rail changes.
 */
export interface SessionChoice {
  sessionId: string
  /** Empty for a session on this computer. */
  machineId?: string
  /** What the rail calls it. */
  name: string
  /** What that machine is called. Empty for this computer. */
  machineName?: string
}

/**
 * The other direction: which **session** this browser window belongs to.
 *
 * Asad, looking at a browser window with no way to attach it from where he was
 * standing:
 *
 * > *"from the browser directly, I cannot connect to any session. It should be
 * > either here or somewhere. So I can actually directly choose a session to
 * > connect to the browser instead of from session to a browser. Both sides
 * > should be the option."*
 *
 * Both sides, **one relation**. This reads and writes the same map
 * `bindMenuItems` does and holds no state of its own, so a window ticked here is
 * ticked there in the same frame — two models of "which windows are attached" is
 * how the rail and the pane bar came to disagree about the same window before.
 *
 * It is a checklist for the same reason, read the other way round: the ticked
 * row is the session this window is attached to. Ticking another moves it, which
 * is what {@link attach} does and what the session-side menu has always done;
 * unticking the one that is ticked detaches.
 *
 * Sessions are grouped under the machine they run on, which is the other half of
 * *"all the desktop browser, including session, should be at one place"*.
 */
export function connectMenuItems(
  request: { browserTabId: string; sessions: SessionChoice[] },
): MenuItemConstructorOptions[] {
  const entry = known.get(request.browserTabId)
  const owner = ownerOf(request.browserTabId)
  const items: MenuItemConstructorOptions[] = []

  if (request.sessions.length === 0) {
    items.push({ label: 'No sessions are open.', enabled: false })
    return items
  }

  const groups = new Map<string, SessionChoice[]>()
  for (const session of request.sessions) {
    const key = session.machineId ?? ''
    const list = groups.get(key)
    if (list) list.push(session)
    else groups.set(key, [session])
  }
  const keys = [...groups.keys()].sort((a, b) => (a === '' ? -1 : b === '' ? 1 : 0))

  for (const key of keys) {
    const sessions = groups.get(key) ?? []
    if (keys.length > 1) {
      items.push({ label: machineLabel(key, sessions[0]?.machineName ?? ''), enabled: false })
    }
    for (const session of sessions) {
      const sessionMachine = session.machineId ?? ''
      const holds =
        owner !== null && owner.sessionId === session.sessionId && owner.machineId === sessionMachine
      const bound = holds
        ? owner.windows.find((window) => window.browserTabId === request.browserTabId)
        : undefined
      items.push({
        type: 'checkbox',
        checked: holds,
        // The slot this window has *in that session* leads when it has one, so
        // the row reads as the same fact the strip's chip and the agent's own
        // context are stating.
        label: bound ? `${slotName(bound.n)}   ${session.name}` : session.name,
        click: () => {
          if (holds) detach(request.browserTabId)
          else
            attach({
              sessionId: session.sessionId,
              machineId: sessionMachine,
              browserTabId: request.browserTabId,
              viewId: entry?.viewId ?? null,
              url: entry?.url ?? '',
              title: entry?.title ?? '',
              hostMachineId: entry?.machineId ?? '',
              hostMachineName: entry?.machineName ?? '',
            })
        },
      })
    }
  }

  return items
}

/** Pop {@link connectMenuItems} over the app window. */
export function showConnectMenu(
  deps: BindingIpcDeps,
  request: { browserTabId: string; sessions: SessionChoice[] },
): boolean {
  const window = deps.window()
  if (!window || window.isDestroyed()) return false
  Menu.buildFromTemplate(connectMenuItems(request)).popup({ window })
  return true
}

/* ------------------------------------------------------------------- ipc -- */

function str(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

/**
 * Register every channel this relation needs. Call once from `registerIpc()`.
 *
 * The pushes go out on `browser:bindings`, shaped like `machines:state` — the
 * whole view every time, because the view is a handful of rows and a diff
 * protocol for a handful of rows is a second thing to keep correct.
 */
export function registerBrowserBindingIpc(ipcMain: IpcMain, deps: BindingIpcDeps): () => void {
  ipcMain.on('browser:window-opened', (_event, raw: unknown) => {
    const input = (raw ?? {}) as Record<string, unknown>
    const tabId = str(input.tabId)
    if (!tabId) return
    const before = known.get(tabId)
    // Allocated once per window and never handed back. A number that shifted
    // when another window closed would rename the row he is reaching for; see
    // `KnownWindow.w`, and `SessionBinding.next` for the same argument made
    // about `B2`.
    if (!before) windowSeq += 1
    const entry: KnownWindow = {
      tabId,
      viewId: typeof input.viewId === 'string' ? input.viewId : (before?.viewId ?? null),
      url: str(input.url),
      title: str(input.title),
      machineId: str(input.machineId),
      machineName: str(input.machineName),
      visible: input.visible === true,
      w: before?.w ?? windowSeq,
    }
    known.set(tabId, entry)
    // Only what the window reported is passed on. A field the renderer left out
    // must not become an empty string in a hook answer an agent will read as
    // fact.
    windowMoved(tabId, {
      ...(input.viewId !== undefined ? { viewId: entry.viewId } : {}),
      ...(input.url !== undefined ? { url: entry.url } : {}),
      ...(input.title !== undefined ? { title: entry.title } : {}),
      ...(input.machineId !== undefined ? { hostMachineId: entry.machineId } : {}),
      ...(input.machineName !== undefined ? { hostMachineName: entry.machineName } : {}),
    })
  })

  ipcMain.on('browser:window-closed', (_event, raw: unknown) => {
    const tabId = str(raw)
    if (!tabId) return
    known.delete(tabId)
    windowClosed(tabId)
  })

  ipcMain.on('browser:bind', (_event, raw: unknown) => {
    const input = (raw ?? {}) as Record<string, unknown>
    const tabId = str(input.tabId)
    const sessionId = str(input.sessionId)
    if (!tabId || !sessionId) return
    const entry = known.get(tabId)
    attach({
      sessionId,
      machineId: str(input.machineId),
      browserTabId: tabId,
      viewId: entry?.viewId ?? null,
      url: entry?.url ?? '',
      title: entry?.title ?? '',
      hostMachineId: entry?.machineId ?? '',
      hostMachineName: entry?.machineName ?? '',
    })
  })

  ipcMain.on('browser:unbind', (_event, raw: unknown) => {
    const tabId = str(raw)
    if (tabId) detach(tabId)
  })

  ipcMain.on('link:opened', (_event, raw: unknown) => {
    const input = (raw ?? {}) as Record<string, unknown>
    const settle = pending.get(str(input.requestId))
    if (!settle) return
    const tabId = str(input.tabId)
    if (tabId) settle({ tabId })
    else
      settle({
        refused:
          str(input.refused) ||
          `${BRAND.name} could not open a window for that link — opening it in your default browser.`,
      })
  })

  ipcMain.removeHandler('browser:bindings')
  ipcMain.handle('browser:bindings', () => view())

  ipcMain.removeHandler('browser:bind-menu')
  ipcMain.handle('browser:bind-menu', (_event, raw: unknown) => {
    const input = (raw ?? {}) as Record<string, unknown>
    const sessionId = str(input.sessionId)
    if (!sessionId) return false
    return showBindMenu(deps, { sessionId, machineId: str(input.machineId) })
  })

  /*
   * The same relation, asked from the browser's end.
   *
   * The sessions arrive in the request rather than being looked up here,
   * because the names are the renderer's — the argument is the one
   * `session-row-menu.ts` makes for its own labels. Everything that *decides*
   * anything still happens against the one map in `browser-binding.ts`.
   */
  ipcMain.removeHandler('browser:connect-menu')
  ipcMain.handle('browser:connect-menu', (_event, raw: unknown) => {
    const input = (raw ?? {}) as Record<string, unknown>
    const browserTabId = str(input.tabId)
    if (!browserTabId) return false
    const rows = Array.isArray(input.sessions) ? input.sessions : []
    const sessions: SessionChoice[] = []
    for (const row of rows) {
      const one = (row ?? {}) as Record<string, unknown>
      const sessionId = str(one.sessionId)
      if (!sessionId) continue
      sessions.push({
        sessionId,
        machineId: str(one.machineId),
        name: str(one.name) || sessionId,
        machineName: str(one.machineName),
      })
    }
    return showConnectMenu(deps, { browserTabId, sessions })
  })

  /*
   * A link clicked inside a terminal.
   *
   * The half of Asad's report that was a one-line defect: `TerminalView` loaded
   * `WebLinksAddon` with no handler, so xterm's default called `window.open()`
   * with no argument, the app's window-open handler denied it, and the URL was
   * discarded while a blank tab opened in its place. It arrives here now, with
   * the session it was printed in, and goes wherever that session's other links
   * go.
   */
  ipcMain.removeHandler('link:open')
  ipcMain.handle('link:open', async (_event, raw: unknown): Promise<LinkRoute> => {
    const input = (raw ?? {}) as Record<string, unknown>
    const url = str(input.url)
    if (!url) return 'refused'
    const answer = await openForSession(deps, {
      url,
      sessionId: str(input.sessionId) || null,
      machineId: str(input.machineId),
    })
    if (answer.route === 'tab') return 'tab'
    /*
     * The one place this differs from the shim, and it has to.
     *
     * When the shim is told `system` it runs the real opener itself, so this
     * process must not also open the page — that would put it on screen twice.
     * A click in a terminal has no such second half: if nothing here opens it,
     * the URL is simply gone, which is the defect being fixed rather than a new
     * shape of it.
     */
    openSystemUrl(url)
    return 'system'
  })

  return subscribe((next) => deps.send('browser:bindings', next))
}

/** Test seam, and the reset a renderer replacement needs. Nothing else calls it. */
export function forgetKnownWindows(): void {
  known.clear()
  pending.clear()
  // Not `windowSeq`. The numbers are only ever shown beside each other, so
  // restarting the count would be harmless here and a trap the day anything
  // outside this file remembers one.
}
