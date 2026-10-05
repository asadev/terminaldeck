/**
 * The app's native menus, drawn by the native window.
 *
 * In Electron the page asks the main process for a menu and the main process
 * pops one up over the window (`Menu.popup`). The native shell has no window
 * there to pop it over, so the page's request is answered here instead: the
 * menu is described to the native side, which draws it where the pointer was,
 * and its answer comes back as `tdNative.run('context-menu-result', { id,
 * itemId })` — `itemId` null when it was dismissed.
 *
 *     post { type: 'context-menu', id, x, y, items: [{ id, label, enabled, checked?, separator?, submenu? }] }
 *
 * The menus, and what each item does, are the main process's — copied here
 * item for item, and held to the main process's wording by `menus.test.ts`:
 *
 *  - `link:menu` (`main/link-open.ts`): Open in System Browser, Copy Link.
 *  - `session:row-menu` (`main/session-row-menu.ts`): answered with the same
 *    choice the main process answers with, so the page acts on it unchanged.
 *  - `browser:bind-menu` (`main/browser-binding-ipc.ts`): the app's browser
 *    windows are the native window's in this shell, not this app's, so there
 *    are none to connect — said as the main process says it when none are open.
 *
 * `browser:connect-menu` is opened from a browser window's own chip, and there
 * are no such windows here, so it is left to the engine.
 */

import { BRAND } from '../shared/brand'

export interface NativeMenuItem {
  id: string
  label: string
  enabled: boolean
  checked?: boolean
  separator?: boolean
  submenu?: NativeMenuItem[]
}

export interface ContextMenuMessage {
  type: 'context-menu'
  id: string
  x: number
  y: number
  items: NativeMenuItem[]
}

let separators = 0
const separator = (): NativeMenuItem => ({ id: `separator-${(separators += 1)}`, label: '', enabled: false, separator: true })

/** What `main/browser-binding-ipc.ts` shows when there are no browser windows to connect. */
export const NO_BROWSER_WINDOWS: NativeMenuItem = { id: 'no-browser-windows', label: 'No browser windows are open.', enabled: false }

export function linkMenuItems(canOpenOutside: boolean): NativeMenuItem[] {
  return [
    ...(canOpenOutside ? [{ id: 'open-outside', label: 'Open in System Browser', enabled: true }] : []),
    { id: 'copy', label: 'Copy Link', enabled: true },
  ]
}

export interface SessionRowMenuRequest {
  sessionId: string
  promoted?: boolean
  promoteBlocked?: string | null
  close?: boolean
  copilotTurn?: boolean
  browser?: boolean
  window?: 'main' | 'own'
}

/** The row menu, item for item as `showSessionRowMenu` builds it; each id is the choice it answers with. */
export function sessionRowMenuItems(request: SessionRowMenuRequest): NativeMenuItem[] {
  const promoteBlocked = typeof request.promoteBlocked === 'string' && request.promoteBlocked !== '' ? request.promoteBlocked : null
  const items: NativeMenuItem[] = [
    {
      id: 'promote',
      label: request.promoted ? 'Fold back into the sidebar' : 'Show at the top',
      enabled: request.promoted === true || promoteBlocked === null,
    },
  ]
  if (request.window === 'main') items.push({ id: 'popout', label: 'Move to New Window', enabled: true })
  else if (request.window === 'own') {
    items.push({ id: 'show-window', label: 'Show Its Window', enabled: true })
    items.push({ id: 'dock', label: 'Move Back to Main Window', enabled: true })
  }
  if (request.copilotTurn) items.push({ id: 'copilot', label: `Started by ${BRAND.assistant} — open that turn`, enabled: true })
  if (!request.browser) {
    items.push(separator())
    items.push({ id: 'connect-browser', label: 'Connect browser', enabled: true, submenu: [NO_BROWSER_WINDOWS] })
  }
  if (request.close) {
    items.push(separator())
    items.push({ id: 'close', label: 'Delete', enabled: true })
  }
  return items
}

const ROW_CHOICES = new Set(['promote', 'close', 'copilot', 'popout', 'dock', 'show-window'])

/** Shows menus and waits for their answers. */
export function createMenus(post: (message: ContextMenuMessage) => void, at: () => { x: number; y: number }) {
  let next = 0
  const waiting = new Map<string, (itemId: string | null) => void>()
  return {
    show(items: NativeMenuItem[]): Promise<string | null> {
      next += 1
      const id = `menu-${next}`
      const { x, y } = at()
      return new Promise((resolve) => {
        waiting.set(id, resolve)
        post({ type: 'context-menu', id, x, y, items })
      })
    },
    /** `context-menu-result`: true when it answered a menu that was waiting. */
    settle(arg: unknown): boolean {
      if (typeof arg !== 'object' || arg === null) return false
      const { id, itemId } = arg as { id?: unknown; itemId?: unknown }
      if (typeof id !== 'string') return false
      const resolve = waiting.get(id)
      if (!resolve) return false
      waiting.delete(id)
      resolve(typeof itemId === 'string' ? itemId : null)
      return true
    },
    waiting: (): number => waiting.size,
  }
}

export interface MenuActions {
  show(items: NativeMenuItem[]): Promise<string | null>
  /** `link:system`'s outcome: the link, to the system. */
  openOutside(url: string): boolean
  /** Whether a URL may be handed to the system at all. */
  canOpenOutside(url: string): boolean
  copy(text: string): void
}

/**
 * The menu channels, answered here in the native shell; null for any other
 * channel, which then goes to the engine as usual. Each answers what the main
 * process's handler answers.
 */
export function answerMenu(channel: string, args: readonly unknown[], actions: MenuActions): Promise<unknown> | null {
  if (channel === 'link:menu') {
    const url = args[0]
    if (typeof url !== 'string' || url.trim() === '') return Promise.resolve(false)
    return actions.show(linkMenuItems(actions.canOpenOutside(url))).then((choice) => {
      if (choice === 'open-outside') actions.openOutside(url)
      else if (choice === 'copy') actions.copy(url)
      return true
    })
  }
  if (channel === 'session:row-menu') {
    const request = (args[0] ?? {}) as SessionRowMenuRequest
    if (typeof request.sessionId !== 'string' || request.sessionId === '') return Promise.resolve(null)
    return actions.show(sessionRowMenuItems(request)).then((choice) => (choice !== null && ROW_CHOICES.has(choice) ? choice : null))
  }
  if (channel === 'browser:bind-menu') {
    return actions.show([NO_BROWSER_WINDOWS]).then(() => true)
  }
  return null
}
