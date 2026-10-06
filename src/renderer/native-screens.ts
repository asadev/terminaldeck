/**
 * The screens the native macOS window draws itself.
 *
 * The native window tells every page which screens it draws in Swift, with
 * `tdNative.run('native-screens', [ids…])`, and the page keeps everything about
 * them that is state — which view is selected, which session is in front, what
 * the side panel, the tabs, the title and the island say — and stops mounting
 * their content underneath, where nobody can see it. Otherwise the hidden page
 * does the same work twice (Artifacts once scanned transcripts behind the
 * native Artifacts screen that was scanning them too).
 *
 * The ids, as each page reads them:
 *
 *   <panel id>         a sidebar view: overview, files, git, mcp, store, tasks, …
 *   session            a local session's terminal
 *   machine-session    a session on a paired machine
 *   server-session     a terminal on a server
 *   hoot               Hoot's window
 *   browser            a browser page
 *   swarm, split       every session at once; the split window
 *   island             what Hoot's island holds when it opens (`?island=1`)
 *   settings:<id>      one Settings section (`settings:ai-apps`, `settings:plugins`, …)
 *
 * The shim answers `native-screens` on every page — the main window, Settings,
 * a screen in a window of its own, the island — and leaves the list on the
 * window (`NATIVE_SCREENS_GLOBAL`) with an event, so it is here before React
 * has mounted and whichever page this is. Inside Electron nothing sets it.
 */

import { useSyncExternalStore } from 'react'

/** Where the shim leaves the list, and the event it fires — `native-web/page-features.ts`. */
export const NATIVE_SCREENS_GLOBAL = '__tdNativeScreens'
export const NATIVE_SCREENS_EVENT = 'td:native-screens'

const NONE: ReadonlySet<string> = new Set()
let current: ReadonlySet<string> = NONE
const listeners = new Set<() => void>()

/** The list the shim left before this module loaded, and every one after. */
function adopt(host: Record<string, unknown> & { addEventListener?: (type: string, listener: () => void) => void }): void {
  const left = host[NATIVE_SCREENS_GLOBAL]
  if (left !== undefined) setNativeScreens(left)
  host.addEventListener?.(NATIVE_SCREENS_EVENT, () => setNativeScreens(host[NATIVE_SCREENS_GLOBAL]))
}

/** `native-screens`: the whole list each time. False for anything that is not a list of ids. */
export function setNativeScreens(value: unknown): boolean {
  if (!Array.isArray(value) || !value.every((entry) => typeof entry === 'string')) return false
  current = new Set(value as string[])
  for (const listener of [...listeners]) listener()
  return true
}

export function nativeScreens(): ReadonlySet<string> {
  return current
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/** The screens the native window draws, as React state. */
export function useNativeScreens(): ReadonlySet<string> {
  return useSyncExternalStore(subscribe, nativeScreens, nativeScreens)
}

/** Whether the native window draws this Settings section (`settings:<id>`). */
export function settingsScreenId(section: string): string {
  return `settings:${section}`
}

if (typeof globalThis !== 'undefined') adopt(globalThis as unknown as Record<string, unknown>)
