/**
 * What a page needs from the native window that Electron gives a page for free,
 * wired once per page by the shim: Hoot's window readers, banners, menus,
 * links, and dropped files. Each part is its own module; this is only where
 * they meet the page and the bridge.
 */

import { postToNative, type NativeHost } from '../shared/native-shell'
import type { createDrops } from './drops'
import { canOpenOutside, createLinkOpener, installPageLinks } from './links'
import { answerMenu, createMenus } from './menus'
import { isMainPage, registerShimCommand } from './native-shell'
import { createNativeNotification } from './notifications'
import { installPageCalls } from './page-calls'

/** A session's link for a browser tab — `LINK_TAB_CHANNEL` in `main/link-open.ts`. */
export const LINK_TAB_CHANNEL = 'link:open-tab'

/** What the shim's bridge lets this take over. */
export interface BridgeHooks {
  /** Answer an invoke here instead of sending it to the engine; null to send it. */
  invoke: ((channel: string, args: readonly unknown[]) => Promise<unknown> | null) | null
  /** Take a push here instead of handing it to the page's listeners; true when taken. */
  push: ((channel: string, args: readonly unknown[]) => boolean) | null
}

export interface PageIpc {
  invoke(channel: string, ...args: unknown[]): Promise<unknown>
  send(channel: string, ...args: unknown[]): void
  on(channel: string, listener: (event: unknown, ...args: unknown[]) => void): unknown
}

export interface PageHost extends NativeHost {
  location: { href: string; origin: string; search: string }
  open?: unknown
  Notification?: unknown
  navigator?: { clipboard?: { writeText(text: string): Promise<void> } }
  addEventListener(type: string, listener: (event: { clientX?: number; clientY?: number }) => void, capture?: boolean): void
  document: {
    documentElement: { dataset: Record<string, string | undefined> }
    addEventListener(type: 'click', listener: (event: never) => void, capture?: boolean): void
  }
}

/** Copy text, the page's own way; a web view may refuse it when no key or click is in progress. */
function copyText(host: PageHost, text: string): void {
  void host.navigator?.clipboard?.writeText(text).catch(() => undefined)
}

export function installPageFeatures(
  host: PageHost,
  ipc: PageIpc,
  hooks: BridgeHooks,
  drops: ReturnType<typeof createDrops>,
): void {
  const main = isMainPage(host.location.search)

  // Where a menu opens: where the pointer last asked for one.
  let pointer = { x: 0, y: 0 }
  const track = (event: { clientX?: number; clientY?: number }): void => {
    if (typeof event.clientX === 'number' && typeof event.clientY === 'number') pointer = { x: event.clientX, y: event.clientY }
  }
  host.addEventListener('contextmenu', track, true)
  host.addEventListener('pointerdown', track, true)

  const menus = createMenus((message) => postToNative(message, host), () => pointer)
  registerShimCommand(host, 'context-menu-result', (arg) => menus.settle(arg))
  registerShimCommand(host, 'drop-paths', (arg) => drops.deliver(arg))

  const openLink = createLinkOpener((message) => postToNative(message, host))
  installPageLinks(host as unknown as Parameters<typeof installPageLinks>[0], (url) => openLink(url))

  hooks.invoke = (channel, args) => {
    if (channel === 'link:system') {
      const url = args[0]
      return Promise.resolve(canOpenOutside(url) ? openLink(url as string, 'external') : false)
    }
    return answerMenu(channel, args, {
      show: (items) => menus.show(items),
      openOutside: (url) => openLink(url, 'external'),
      canOpenOutside,
      copy: (text) => copyText(host, text),
    })
  }

  /*
   * A link from a session, routed to a browser tab. The native window's browser
   * answers that one itself — it opens the tab and tells the engine — so the
   * page takes no part: not the app's own handler (which would open a second,
   * Electron, tab) and not a page of this shim's (which would open it twice
   * more). Swallowed on every page.
   */
  hooks.push = (channel) => channel === LINK_TAB_CHANNEL

  if (main) installPageCalls(ipc, host as unknown as Record<string, unknown>)
  host.Notification = createNativeNotification(ipc)
}
