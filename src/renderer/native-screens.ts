/**
 * The screens the native macOS window draws itself.
 *
 * The native window can draw some screens natively — Artifacts, Simulators, a
 * browser, a session's terminal — and tells the page which, with
 * `tdNative.run('native-screens', ['artifacts', 'simulators', 'browser', 'session', …])`
 * (ids: a sidebar view's id, `browser`, or `session`). The page keeps everything
 * about them that is state — which view is selected, which session is in front,
 * what the side panel and the tabs say — and stops mounting their heavy content
 * underneath, where nobody can see it: a view's page, a browser page, a
 * session's terminal. Otherwise the hidden page does the same work twice, as
 * Artifacts did, scanning transcripts behind the native Artifacts screen that
 * was scanning them too.
 *
 * Inside Electron nothing ever sets this, so nothing changes.
 */

import { useSyncExternalStore } from 'react'

const NONE: ReadonlySet<string> = new Set()
let current: ReadonlySet<string> = NONE
const listeners = new Set<() => void>()

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
