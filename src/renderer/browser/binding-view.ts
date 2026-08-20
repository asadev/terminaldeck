/**
 * The renderer's read-only copy of which browser windows belong to which
 * session.
 *
 * The relation itself lives in the main process — `main/browser-binding.ts` has
 * the argument, and the short form is that the two things which read it (a
 * shim's HTTP request, and a hook response an agent's turn is blocked on) both
 * arrive there and neither can wait for a renderer. So nothing here decides
 * anything. This is a store that holds the last pushed view and wakes the
 * components drawing it.
 *
 * ## Why a module store and `useSyncExternalStore`
 *
 * Because the same fact is drawn in four places that do not share a parent: a
 * chip on a browser pill, chips on a session pill, the same chip on the
 * sidebar's rows, and the attach button on `PaneBar`. Threading it through props
 * would mean `App.tsx` holding it and every one of those four taking a new prop
 * — which is how the strip and the pane bar come to disagree about the same
 * window.
 *
 * Two rules are copied wholesale from `shell/workspace-strip.ts`, and both of
 * them are there because they were measured rather than reasoned about:
 *
 *  - **`getSnapshot` must return an identity-stable value.** A fresh object per
 *    call is an infinite render loop, not a performance problem —
 *    `useSyncExternalStore` compares by identity and re-renders forever.
 *  - **A no-op `set` must wake nobody.** That guard is load-bearing, not an
 *    optimisation: the push arrives on every url and title change of every
 *    window, and waking every consumer for a view that did not change is a
 *    render storm behind a browser page nobody is looking at.
 */

import { useSyncExternalStore } from 'react'

/** One attached browser window, as main describes it. */
export interface BoundWindowView {
  n: number
  browserTabId: string
  url: string
  title: string
}

/** One session's attached windows. */
export interface SessionBindingView {
  sessionId: string
  machineId: string
  windows: BoundWindowView[]
  /** 0–3, an index into `--bind-1 … --bind-4`. */
  colour: number
  ended: boolean
}

export interface BindingsView {
  sessions: SessionBindingView[]
}

/**
 * The empty view, as one frozen object.
 *
 * A constant rather than `{ sessions: [] }` written where it is needed: it is
 * the value `getSnapshot` returns before the first push, and a fresh empty
 * object each time is the identity trap above in its purest form.
 */
const EMPTY: BindingsView = { sessions: [] }

let current: BindingsView = EMPTY
const watchers = new Set<() => void>()

/** Whether two views say the same thing, field by field. */
function same(a: BindingsView, b: BindingsView): boolean {
  if (a === b) return true
  if (a.sessions.length !== b.sessions.length) return false
  return a.sessions.every((session, index) => {
    const other = b.sessions[index]
    if (
      session.sessionId !== other.sessionId ||
      session.machineId !== other.machineId ||
      session.colour !== other.colour ||
      session.ended !== other.ended ||
      session.windows.length !== other.windows.length
    ) {
      return false
    }
    return session.windows.every((window, at) => {
      const twin = other.windows[at]
      return (
        window.n === twin.n &&
        window.browserTabId === twin.browserTabId &&
        window.url === twin.url &&
        window.title === twin.title
      )
    })
  })
}

/**
 * Narrow whatever came across the bridge.
 *
 * `unknown` in, because the preload carries feature payloads as `unknown` by
 * design and this is the consumer that owns the shape. A field that is not the
 * type it should be drops that row rather than the whole view: a malformed
 * window is one chip missing, and refusing the lot would empty a strip that is
 * mostly correct.
 */
export function readBindings(raw: unknown): BindingsView {
  if (typeof raw !== 'object' || raw === null) return EMPTY
  const sessions = (raw as { sessions?: unknown }).sessions
  if (!Array.isArray(sessions)) return EMPTY

  const read: SessionBindingView[] = []
  for (const entry of sessions) {
    if (typeof entry !== 'object' || entry === null) continue
    const row = entry as Record<string, unknown>
    if (typeof row.sessionId !== 'string' || row.sessionId === '') continue
    const windows: BoundWindowView[] = []
    if (Array.isArray(row.windows)) {
      for (const item of row.windows) {
        if (typeof item !== 'object' || item === null) continue
        const window = item as Record<string, unknown>
        if (typeof window.n !== 'number' || typeof window.browserTabId !== 'string') continue
        windows.push({
          n: window.n,
          browserTabId: window.browserTabId,
          url: typeof window.url === 'string' ? window.url : '',
          title: typeof window.title === 'string' ? window.title : '',
        })
      }
    }
    read.push({
      sessionId: row.sessionId,
      machineId: typeof row.machineId === 'string' ? row.machineId : '',
      windows,
      colour: typeof row.colour === 'number' ? row.colour : 0,
      ended: row.ended === true,
    })
  }
  return { sessions: read }
}

/** Take a pushed view. Wakes nobody when nothing changed. */
export function setBindings(raw: unknown): void {
  const next = readBindings(raw)
  if (same(current, next)) return
  current = next
  for (const watcher of watchers) watcher()
}

function subscribe(watcher: () => void): () => void {
  watchers.add(watcher)
  return () => {
    watchers.delete(watcher)
  }
}

function getSnapshot(): BindingsView {
  return current
}

/** Every session's attached windows. Re-renders only when they change. */
export function useBindings(): BindingsView {
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot)
}

/**
 * One session's attached windows, or null when it has none.
 *
 * Null rather than an empty binding, because "nothing attached" is drawn as
 * *nothing* — not a grey chip, not `B—`. A mark that means nothing is worse
 * than no mark, which is the reasoning `WorkspaceTabStrip.tsx` already used to
 * refuse a browser dot outright.
 */
export function useSessionBinding(
  sessionId: string | null | undefined,
  machineId = '',
): SessionBindingView | null {
  const view = useBindings()
  if (!sessionId) return null
  const found = view.sessions.find(
    (session) => session.sessionId === sessionId && session.machineId === machineId,
  )
  return found && found.windows.length > 0 ? found : null
}

/**
 * The session one browser window is attached to, or null.
 *
 * The inverse of the above, and it is the same map read the other way rather
 * than a second one — a window has at most one session, so *session → windows*
 * inverted is *window → session* for free. Two maps is how the pill and the
 * menu come to disagree.
 */
export function useWindowBinding(
  browserTabId: string | null | undefined,
): { session: SessionBindingView; window: BoundWindowView } | null {
  const view = useBindings()
  if (!browserTabId) return null
  for (const session of view.sessions) {
    const window = session.windows.find((entry) => entry.browserTabId === browserTabId)
    if (window) return { session, window }
  }
  return null
}

/** Test seam. Every real reset is a push from main. */
export function resetBindingsForTests(): void {
  current = EMPTY
  watchers.clear()
}
