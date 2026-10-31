/**
 * The native macOS window, landing on this window's own actions.
 *
 * The native shell (`macos/`, with `src/native-web` as the page's bridge) draws
 * the toolbar and the side panel in AppKit and calls
 * `window.tdNative.run(name, arg?)` when something in them is pressed. Every
 * name is routed to the **same** function the app's own control for it calls —
 * never to a copy of what that function does.
 *
 * The toolbar:
 *
 *   new-session     → `run('session.new')`      ⌘T, File › New Session, the palette row
 *   toggle-sidebar  → `run('view.sidebar')`     ⌘B, View › Toggle Sidebar
 *   open-hoot       → `run('view.copilot')`     the pinned row at the top of the sidebar
 *   open-settings   → `run('app.preferences')`  ⌘, and the sidebar's Settings line
 *   open-tasks      → `showPanel('tasks')`      the sidebar's Tasks row
 *   open-memory     → `showPanel('memory')`     the sidebar's Memory row
 *
 * The side panel (ids are the ones `shell/native-sidebar.ts` publishes):
 *
 *   select(id)          a view → `showPanel`; 'hoot' → the pinned row; 'alerts'
 *                       → the bell; a session → the row's own press; a held
 *                       session → its retry
 *   close-session(id)   the row menu's Delete; a held session → its ✕
 *   new-session-in(id)  a heading's ＋: a project, a paired machine or a server
 *   open-project        the "Open" heading's ＋
 *   close-project(id)   a heading's Delete: a project, a machine or a server
 *   toggle-project(id)  folds a heading in the native panel
 *
 * The tabs in the native top bar (ids are the ones `shell/native-tabs.ts` publishes):
 *
 *   select-tab(id)      a tab's press — the strip's `onSelect`
 *   close-tab(id)       a tab's ✕, as the strip does it: a session is taken off
 *                       the bar and keeps running; a browser window is closed
 *                       down ⌘W's path
 *   new-terminal-tab    the strip's ›_ — the New session dialog
 *   new-browser-tab     the strip's globe (false when no window can open)
 *
 * The Electron menu's items, from the native menu bar:
 *
 *   menu-command(id)    `run(id)` — what the Electron menu's `menu:command` runs
 *
 * And `native-screens` with the list of screens the native window draws itself,
 * which the page then stops mounting underneath (`native-screens.ts`).
 *
 * Each answers `false` — and does nothing — for an id the panel was never shown,
 * or for a control the rail itself would not offer (a session it cannot close,
 * a machine whose build cannot end sessions).
 *
 * Inside Electron none of this is published: there is no native window to call
 * it, and a global nothing calls is a door left open for nothing.
 */

import { BRAND } from '../shared/brand'
import { isNativeShell, postToNative, type NativeHost } from '../shared/native-shell'
import { isPanelId, type PanelId } from './shell/panels'
import { ALERTS_ID, buildNativeSidebar, railTabIds, type NativeSidebarInput } from './shell/native-sidebar'
import { stripClose, stripHas, type NativeTabsInput } from './shell/native-tabs'
import { setNativeScreens } from './native-screens'

export type NativeCommandName =
  | 'new-session'
  | 'toggle-sidebar'
  | 'open-hoot'
  | 'open-tasks'
  | 'open-memory'
  | 'open-settings'

export type NativeAction = { run: string } | { panel: PanelId }

export const NATIVE_COMMANDS: Readonly<Record<NativeCommandName, NativeAction>> = {
  'new-session': { run: 'session.new' },
  'toggle-sidebar': { run: 'view.sidebar' },
  'open-hoot': { run: 'view.copilot' },
  'open-settings': { run: 'app.preferences' },
  'open-tasks': { panel: 'tasks' },
  'open-memory': { panel: 'memory' },
}

/** The side panel's commands, each taking the id of what was pressed (`open-project` takes none). */
export const NATIVE_SIDEBAR_COMMANDS = [
  'select',
  'close-session',
  'new-session-in',
  'open-project',
  'close-project',
  'toggle-project',
] as const

/**
 * The Electron menu's commands, from the native menu bar:
 * `run('menu-command', '<Electron command id>')`. Handed to the same `run` the
 * Electron menu's `menu:command` reaches (`onMenuCommand` in `App.tsx`), so a
 * native menu item does exactly what its Electron twin does; false for an id
 * nothing answers to.
 */
export const MENU_COMMAND = 'menu-command'

/**
 * Doors between views, for screens the native window draws (lanes A and V):
 * each does what the web view's own prop does, so a native door and a web door
 * land in the same place.
 *
 *   open-file      (relPath)          `showFile`: the Files view, with that file open
 *   show-panel     ([panelId, focus]) `showPanel(id, focus)`: Git on a group
 *                                     ('staged'…), GitHub on 'issues' or 'pulls'
 *   open-inspector                    the session inspector (`setInspectorOpen(true)`)
 *   show-sessions                     swarm view (`onShowSessions`); false while
 *                                     swarm is not installed, as the widget has no door then
 *
 * What they leave behind is published in the `sidebar` state: `openFile` and `focus`.
 */
export const NATIVE_DOOR_COMMANDS = ['open-file', 'show-panel', 'open-inspector', 'show-sessions'] as const

/**
 * Sessions drawn by the native window (lanes T and V), each `[tabId, …]`:
 *
 *   rename-session      [tabId, name]    a local session's name, as the rail's own rename:
 *                                        rail and title at once, and the engine told
 *   server-shell-write  [tabId, text]    `writeToServerShell(serverShellIds[tabId], text)`;
 *                                        false when that tab has no shell open
 *   server-shell-opened [tabId, shellId] a server shell the native window opened itself
 *   server-shell-ended  [tabId]          …and its end, as `ServerSessionPane`'s `onEnded`
 *
 * What a native window needs to open a server shell is in the `tabs` state (`server`).
 */
export const NATIVE_SESSION_COMMANDS = [
  'rename-session',
  'server-shell-write',
  'server-shell-opened',
  'server-shell-ended',
] as const

/**
 * The servers screens drawn natively (lane G), as `ServerSessions` does for the web ones:
 *
 *   open-server-session [serverId, serverName, startIn|""]  ServerPage's "Open a terminal", in that folder
 *   server-renamed      [serverId, name]                    the rename, so open tabs carry the new name
 */
export const NATIVE_SERVER_COMMANDS = ['open-server-session', 'server-renamed'] as const

/**
 * The session header's account chips, drawn natively (lane T): each does what
 * the web chip's own prop does.
 *
 *   new-session-as    [projectPath|"", accountId, provider|""]  AccountChip `onPick`:
 *                                        `newSession(path, false, accountId, provider)`
 *   switch-account    [sessionId, accountId]  AccountChip `onSwitchAccount`: `switcher.ask`
 *                                        (the confirm that follows is the native one)
 *   open-server-shell [serverId, agentId|""]  ServerAccountChip `onStartAgent`: a new
 *                                        terminal on that server with `agentCommand(agentId)` running
 *   add-account                          the chip's "Add account": `askForAddAccount()` then
 *                                        Settings → Accounts
 *   manage-accounts                      the chips' `onManage`: Settings → Accounts
 */
/**
 * Split and swarm drawn natively (lane T), as the page's own controls act:
 *
 *   set-mode     [mode]           ModeSwitch `onChange` ('terminal' | 'split'; split installs itself first)
 *   focus-pane   [paneId]         SplitView's focus (`focusPane`)
 *   resize-split [splitId, ratio] SplitView's divider (`resizeSplit`; ratio as text, 0 < ratio < 1)
 *   close-pane   [paneId]         `closePaneAt`
 *
 * The arrangement itself is in the `tabs` state (`layout`). Swarm's cells use
 * `select-tab` and its + uses `new-terminal-tab`.
 */
export const NATIVE_LAYOUT_COMMANDS = ['set-mode', 'focus-pane', 'resize-split', 'close-pane'] as const

export const NATIVE_ACCOUNT_COMMANDS = [
  'new-session-as',
  'switch-account',
  'open-server-shell',
  'add-account',
  'manage-accounts',
] as const

/** The tab strip's commands. */
export const NATIVE_TAB_COMMANDS = ['select-tab', 'close-tab', 'new-terminal-tab', 'new-browser-tab'] as const

/**
 * What `App.tsx` hands over: its dispatcher, and the very functions it hands
 * the rail and the strip — each member names the prop it is.
 */
export interface NativeHandlers {
  run(id: string): boolean
  /** `onSelectPanel`; with a focus, `onNavigate(id, focus)` — the view opened on one part of it. */
  showPanel(id: PanelId, focus?: string | null): void
  /** `onOpenFile` (`showFile`): the Files view, with this file open. */
  showFile(relPath: string): void
  /** `onOpenInspector`: the session inspector. */
  openInspector(): void
  /** `onShowSessions`: swarm view. False when swarm is not installed (the widget offers no door then). */
  showSessions(): boolean
  /** `useSessionRename().rename`: false for a blank name or a session that is not a local one here. */
  renameSession(tabId: string, typed: string): boolean
  /** The tab's server shell, written to; false when it has none open. */
  writeServerShell(tabId: string, text: string): boolean
  /** `ServerSessionPane`'s `onOpened` / `onEnded`, for a shell the native window holds; false for an unknown tab. */
  serverShellOpened(tabId: string, shellId: string): boolean
  serverShellEnded(tabId: string): boolean
  /** AccountChip `onPick`. False for a provider this build does not know. */
  newSessionAs(projectPath: string | null, accountId: string, provider: string | null): boolean
  /** AccountChip `onSwitchAccount`; false for a session that is not a local one here. */
  switchAccount(sessionId: string, accountId: string): boolean
  /** ServerAccountChip `onStartAgent` (agent null: a plain shell); false for a server with no terminal here. */
  openServerShellWith(serverId: string, agentId: string | null): boolean
  /** Settings → Accounts; `add` first asks Accounts for its add popup (`askForAddAccount`). */
  manageAccounts(add: boolean): void
  /** `serverSessionOpener.open(serverId, serverName, startIn)`. */
  openServerSession(serverId: string, serverName: string, startIn: string | null): void
  /** `serverSessionOpener.renamed(serverId, name)`. */
  serverRenamed(serverId: string, name: string): void
  /** ModeSwitch `onChange`. */
  setLayoutMode(mode: 'terminal' | 'split'): void
  /** SplitView's focus / divider, and `closePaneAt`; false for a pane or split that is not there. */
  focusPaneById(paneId: string): boolean
  resizeSplitTo(splitId: string, ratio: number): boolean
  closePaneById(paneId: string): boolean
  /** What the rail is drawing right now — the input the published state is built from. */
  rail(): NativeSidebarInput
  /** `onOpenCopilot`, as the pinned row calls it. */
  openHoot(): void
  /** `onSelectTab`. */
  openTab(id: string): void
  /** `onCloseTab`. */
  closeTab(id: string): void
  /** `onRetryHeld` / `onForgetHeld`. */
  retryHeld(key: string): void
  forgetHeld(key: string): void
  /** `onNewSession(path)`, `onNewMachineSession`, `onNewServerSession`. */
  newSessionIn(path: string): void
  newMachineSession(machineId: string): void
  newServerSession(serverId: string): void
  /** `onOpenProject`. */
  openProject(): void
  /** `onCloseProject`, `onCloseMachine`, `onCloseServer`. */
  closeProject(path: string): void
  closeMachine(machineId: string): void
  closeServer(serverId: string): void
  /** The native panel's own fold for a heading. */
  toggleGroup(id: string): void
  /** `onOpenAlerts` — the bell. */
  openAlerts(): void
  /** What the strip is drawing right now — the input the published tabs are built from. */
  strip(): NativeTabsInput
  /** The strip's `onSelect`. */
  selectTab(id: string): void
  /** The strip's order store (`usePromotedOrder`), and its `onShowInstead`. */
  setStripOrder(order: readonly string[]): void
  showInstead(id: string | null): void
  /** The strip's `onCloseWindow`. */
  closeWindow(id: string): void
  /** The strip's `onNewSession` and `onNewBrowserTab`. */
  newTerminalTab(): void
  newBrowserTab(): void
}

export interface NativeCommands {
  /** True when this window did something; false for an unknown name or id, or before it has mounted. */
  run(name: string, arg?: unknown): boolean
}

const HELD_PREFIX = 'held:'

/** A heading id, resolved against what the rail has right now. */
function heading(
  rail: NativeSidebarInput,
  id: string,
):
  | { kind: 'project'; path: string }
  | { kind: 'machine'; machineId: string; canClose: boolean }
  | { kind: 'server'; serverId: string }
  | null {
  const project = rail.projects.find((entry) => entry.path === id)
  if (project) return { kind: 'project', path: project.path }
  const machine = rail.machines.find((entry) => `machine:${entry.machineId}` === id)
  if (machine) return { kind: 'machine', machineId: machine.machineId, canClose: machine.canClose }
  const server = rail.servers.find((entry) => `server:${entry.serverId}` === id)
  if (server) return { kind: 'server', serverId: server.serverId }
  return null
}

function select(handlers: NativeHandlers, id: string): boolean {
  const rail = handlers.rail()
  if (id === 'hoot') {
    handlers.openHoot()
    return true
  }
  if (id === ALERTS_ID) {
    if (!rail.alerts.shown) return false
    handlers.openAlerts()
    return true
  }
  if (isPanelId(id)) {
    // Only a view the rail is drawing: an uninstalled one has no row.
    if (!rail.panels.some((panel) => panel.id === id)) return false
    handlers.showPanel(id)
    return true
  }
  if (id.startsWith(HELD_PREFIX)) {
    const key = id.slice(HELD_PREFIX.length)
    // The rail's row is disabled while it is already opening.
    if (!rail.held.some((row) => row.key === key) || rail.heldRetrying.includes(key)) return false
    handlers.retryHeld(key)
    return true
  }
  if (!railTabIds(rail).has(id)) return false
  handlers.openTab(id)
  return true
}

function closeSession(handlers: NativeHandlers, id: string): boolean {
  const rail = handlers.rail()
  if (id.startsWith(HELD_PREFIX)) {
    const key = id.slice(HELD_PREFIX.length)
    if (!rail.held.some((row) => row.key === key)) return false
    handlers.forgetHeld(key)
    return true
  }
  const tab = [
    ...rail.tabs.filter((entry) => !entry.isCopilot),
    ...rail.machines.flatMap((group) => group.sessions),
    ...rail.servers.flatMap((group) => group.sessions),
  ].find((entry) => entry.id === id)
  // The row menu offers Delete only where the row says it can act.
  if (!tab || !tab.closable) return false
  handlers.closeTab(id)
  return true
}

function sidebarCommand(handlers: NativeHandlers, name: string, arg: unknown): boolean {
  if (name === 'open-project') {
    handlers.openProject()
    return true
  }
  if (typeof arg !== 'string' || arg === '') return false
  switch (name) {
    case 'select':
      return select(handlers, arg)
    case 'close-session':
      return closeSession(handlers, arg)
    case 'new-session-in': {
      const target = heading(handlers.rail(), arg)
      if (target === null) return false
      if (target.kind === 'project') handlers.newSessionIn(target.path)
      else if (target.kind === 'machine') handlers.newMachineSession(target.machineId)
      else handlers.newServerSession(target.serverId)
      return true
    }
    case 'close-project': {
      const target = heading(handlers.rail(), arg)
      if (target === null) return false
      if (target.kind === 'project') handlers.closeProject(target.path)
      else if (target.kind === 'machine') {
        if (!target.canClose) return false
        handlers.closeMachine(target.machineId)
      } else handlers.closeServer(target.serverId)
      return true
    }
    case 'toggle-project': {
      if (!buildNativeSidebar(handlers.rail()).projects.some((entry) => entry.id === arg)) return false
      handlers.toggleGroup(arg)
      return true
    }
    default:
      return false
  }
}

function doorCommand(handlers: NativeHandlers, name: string, arg: unknown): boolean {
  if (name === 'open-inspector') {
    handlers.openInspector()
    return true
  }
  if (name === 'show-sessions') return handlers.showSessions()
  if (name === 'open-file') {
    if (typeof arg !== 'string' || arg === '') return false
    handlers.showFile(arg)
    return true
  }
  // show-panel: [panelId, focus]. Only a view the rail is drawing, as `select`.
  if (!Array.isArray(arg) || !isPanelId(arg[0])) return false
  const id: PanelId = arg[0]
  const focus = typeof arg[1] === 'string' && arg[1] !== '' ? arg[1] : null
  if (!handlers.rail().panels.some((panel) => panel.id === id)) return false
  handlers.showPanel(id, focus)
  return true
}

function sessionCommand(handlers: NativeHandlers, name: string, arg: unknown): boolean {
  if (!Array.isArray(arg) || typeof arg[0] !== 'string' || arg[0] === '') return false
  const tabId: string = arg[0]
  const value: unknown = arg[1]
  if (name === 'server-shell-ended') return handlers.serverShellEnded(tabId)
  if (typeof value !== 'string') return false
  switch (name) {
    case 'rename-session':
      return handlers.renameSession(tabId, value)
    case 'server-shell-write':
      return handlers.writeServerShell(tabId, value)
    case 'server-shell-opened':
      return value !== '' && handlers.serverShellOpened(tabId, value)
    default:
      return false
  }
}

function accountCommand(handlers: NativeHandlers, name: string, arg: unknown): boolean {
  if (name === 'add-account' || name === 'manage-accounts') {
    handlers.manageAccounts(name === 'add-account')
    return true
  }
  if (!Array.isArray(arg) || !arg.every((part) => typeof part === 'string')) return false
  const parts = arg as string[]
  const orNull = (text: string | undefined): string | null => (text === undefined || text === '' ? null : text)
  switch (name) {
    case 'new-session-as':
      if (!parts[1]) return false
      return handlers.newSessionAs(orNull(parts[0]), parts[1], orNull(parts[2]))
    case 'switch-account':
      if (!parts[0] || !parts[1]) return false
      return handlers.switchAccount(parts[0], parts[1])
    case 'open-server-shell':
      if (!parts[0]) return false
      return handlers.openServerShellWith(parts[0], orNull(parts[1]))
    default:
      return false
  }
}

function serverCommand(handlers: NativeHandlers, name: string, arg: unknown): boolean {
  if (!Array.isArray(arg) || !arg.every((part) => typeof part === 'string')) return false
  const [serverId, second, third] = arg as string[]
  if (!serverId || !second) return false
  if (name === 'open-server-session') {
    handlers.openServerSession(serverId, second, third ? third : null)
    return true
  }
  handlers.serverRenamed(serverId, second)
  return true
}

function layoutCommand(handlers: NativeHandlers, name: string, arg: unknown): boolean {
  if (!Array.isArray(arg) || typeof arg[0] !== 'string' || arg[0] === '') return false
  const first: string = arg[0]
  switch (name) {
    case 'set-mode':
      if (first !== 'terminal' && first !== 'split') return false
      handlers.setLayoutMode(first)
      return true
    case 'focus-pane':
      return handlers.focusPaneById(first)
    case 'close-pane':
      return handlers.closePaneById(first)
    case 'resize-split': {
      const ratio = typeof arg[1] === 'string' && arg[1].trim() !== '' ? Number(arg[1]) : Number.NaN
      if (!Number.isFinite(ratio) || ratio <= 0 || ratio >= 1) return false
      return handlers.resizeSplitTo(first, ratio)
    }
    default:
      return false
  }
}

function tabCommand(handlers: NativeHandlers, name: string, arg: unknown): boolean {
  if (name === 'new-terminal-tab') {
    handlers.newTerminalTab()
    return true
  }
  if (name === 'new-browser-tab') {
    if (!handlers.strip().canNewBrowser) return false
    handlers.newBrowserTab()
    return true
  }
  if (typeof arg !== 'string' || arg === '') return false
  const strip = handlers.strip()
  if (name === 'select-tab') {
    if (!stripHas(strip, arg)) return false
    handlers.selectTab(arg)
    return true
  }
  // close-tab
  const close = stripClose(strip, arg)
  if (close === null) return false
  if (close.kind === 'close-window') handlers.closeWindow(arg)
  else {
    handlers.setStripOrder(close.order)
    if (close.select !== undefined) handlers.showInstead(close.select)
  }
  return true
}

/** Read through a getter, so the handlers are this render's rather than the first one's. */
export function nativeCommands(current: () => NativeHandlers | null): NativeCommands {
  return {
    run(name, arg) {
      if (typeof name !== 'string') return false
      // Which screens the native window draws itself — state of the page, so it
      // is taken even before the window has mounted.
      if (name === 'native-screens') return setNativeScreens(arg)
      const toolbar = Object.hasOwn(NATIVE_COMMANDS, name)
      const sidebar = (NATIVE_SIDEBAR_COMMANDS as readonly string[]).includes(name)
      const tabs = (NATIVE_TAB_COMMANDS as readonly string[]).includes(name)
      const menu = name === MENU_COMMAND
      const door = (NATIVE_DOOR_COMMANDS as readonly string[]).includes(name)
      const session = (NATIVE_SESSION_COMMANDS as readonly string[]).includes(name)
      const account = (NATIVE_ACCOUNT_COMMANDS as readonly string[]).includes(name)
      const layout = (NATIVE_LAYOUT_COMMANDS as readonly string[]).includes(name)
      const server = (NATIVE_SERVER_COMMANDS as readonly string[]).includes(name)
      if (!toolbar && !sidebar && !tabs && !menu && !door && !session && !account && !layout && !server) return false
      const handlers = current()
      if (handlers === null) return false
      if (menu) return typeof arg === 'string' && arg !== '' && handlers.run(arg)
      if (door) return doorCommand(handlers, name, arg)
      if (session) return sessionCommand(handlers, name, arg)
      if (account) return accountCommand(handlers, name, arg)
      if (layout) return layoutCommand(handlers, name, arg)
      if (server) return serverCommand(handlers, name, arg)
      if (sidebar) return sidebarCommand(handlers, name, arg)
      if (tabs) return tabCommand(handlers, name, arg)
      const action = NATIVE_COMMANDS[name as NativeCommandName]
      if ('panel' in action) {
        handlers.showPanel(action.panel)
        return true
      }
      return handlers.run(action.run)
    },
  }
}

const announced = new WeakSet<object>()

/**
 * Leave `window.tdNative` on the page and tell the native window it can use it.
 *
 * Returns the cleanup, so `useEffect(() => publishNativeCommands(get), [])` is
 * the whole of the wiring. `ready` is posted once per page load: React's strict
 * mode mounts, unmounts and mounts again in development, and the native side
 * should not be told twice that one page is ready.
 */
export function publishNativeCommands(
  current: () => NativeHandlers | null,
  host: NativeHost = globalThis as NativeHost,
): () => void {
  if (!isNativeShell(host)) return () => {}
  const previous = host.tdNative
  const commands = nativeCommands(current)
  host.tdNative = commands
  if (!announced.has(host)) {
    announced.add(host)
    postToNative({ type: 'ready' }, host)
  }
  return () => {
    if (host.tdNative === commands) host.tdNative = previous
  }
}

/* ------------------------------------------------------------- the title -- */

export interface NativeTitleMessage {
  type: 'title'
  value: string
  subtitle?: string
}

/**
 * The native window's title: what the window's own heading says (a session's
 * name, a page's name — the app's name when the heading has none), and under
 * it the project that is about, when there is one and it is not the same words.
 */
export function nativeTitle(title: string | null, project: string | null): NativeTitleMessage {
  const value = title ?? BRAND.name
  return project !== null && project !== '' && project !== value ? { type: 'title', value, subtitle: project } : { type: 'title', value }
}

/** Posts a title only when it differs from the last one posted. */
export function createTitlePublisher(post: (message: NativeTitleMessage) => void): {
  update(message: NativeTitleMessage): void
} {
  let last = ''
  return {
    update(message) {
      const text = JSON.stringify(message)
      if (text === last) return
      last = text
      post(message)
    },
  }
}
