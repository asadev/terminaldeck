/**
 * The page-level half of being inside the native window, done before the
 * renderer's own scripts run.
 *
 *  1. `data-shell="native"` on `<html>`. The stylesheets read it to drop the
 *     chrome the native window draws itself, and the renderer reads it
 *     (`shared/native-shell.ts`) to talk to the native side instead of opening
 *     its own windows.
 *  2. `window.tdNative`, the one object the native side calls. Its `run(name,
 *     arg)` goes first to the commands the shim answers for every page (a menu's
 *     answer, dropped files — {@link registerShimCommand}), and otherwise to
 *     whatever the page has put there (`renderer/native-commands.ts` in the main
 *     window, Settings', the island's). Until a page has, the answer is `false`,
 *     not a `ReferenceError`.
 *
 * The window's title is not read from `document.title`: the app posts it from
 * its own heading, with the project under it (`nativeTitle`).
 */

import type { NativeHost } from '../shared/native-shell'

export interface ShellHost extends NativeHost {
  document: { documentElement: { dataset: Record<string, string | undefined> } }
}

type ShimCommand = (arg: unknown) => boolean
interface PageCommands {
  run?(name: string, arg?: unknown): unknown
}

const shimCommands = new WeakMap<object, Map<string, ShimCommand>>()

export function installNativeShell(host: ShellHost): void {
  host.document.documentElement.dataset.shell = 'native'
  if (shimCommands.has(host)) return
  const own = new Map<string, ShimCommand>()
  shimCommands.set(host, own)
  // Anything a page already put there is the page's (in practice nothing: this runs first).
  let page: unknown = host.tdNative
  const commands = {
    run(name: unknown, arg?: unknown): boolean {
      if (typeof name !== 'string') return false
      const handler = own.get(name)
      if (handler) return handler(arg)
      const target = page as PageCommands | null | undefined
      return typeof target?.run === 'function' ? target.run(name, arg) === true : false
    },
  }
  /*
   * An accessor rather than a value, so a page that writes `window.tdNative =
   * …` (as each page's publisher does) becomes the page half of this object
   * instead of replacing it — and the shim's own commands keep answering on
   * every page, whatever that page publishes.
   */
  Object.defineProperty(host, 'tdNative', {
    configurable: true,
    enumerable: true,
    get: () => commands,
    set: (value: unknown) => {
      page = value
    },
  })
}

/** A command the shim answers on every page, ahead of the page's own. */
export function registerShimCommand(host: object, name: string, handler: ShimCommand): void {
  shimCommands.get(host)?.set(name, handler)
}

/**
 * Whether this page is the main window — not Settings, the island, a screen in
 * a window of its own, or an Electron-only page. Only the main window answers
 * the engine's questions about "the window" and opens what a session asks to.
 */
export function isMainPage(search: string): boolean {
  const query = new URLSearchParams(search)
  return !['settings', 'island', 'screen', 'popout', 'hootpanel', 'hootcatcher'].some((key) => query.has(key))
}
