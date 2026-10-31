import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

/**
 * Which sessions are in a window of their own — the renderer's half of
 * `main/popout-windows.ts`, used by both kinds of window.
 *
 * The main window reads it to stop drawing a terminal for a session that is
 * out (two terminals on one pty would both type into it and both resize it),
 * to draw "open in its own window" where the terminal was, and to offer the
 * two moves. A session's own window reads it to find out which session it is
 * holding — by its window id, because an account switch can replace the
 * session under it.
 *
 * Everything that crosses the bridge is `unknown` and is narrowed here: the
 * main process owns the shape, and a field this build does not know is dropped
 * rather than drawn as something else.
 */

export interface SessionWindowRow {
  sessionId: string
  windowId: number
  /** The main window's own name for the session — the strip's label. */
  label: string
  status: string | null
  displayId: number | null
  displayLabel: string
  fullScreen: boolean
  minimized: boolean
  focused: boolean
}

export interface SessionWindowDisplay {
  id: number
  label: string
  primary: boolean
}

export interface SessionWindowsView {
  windows: SessionWindowRow[]
  displays: SessionWindowDisplay[]
  /** The window asking, when it is a session's own window. Null in the main window. */
  self: number | null
}

export type SessionWindowEvent =
  | { kind: 'opened'; sessionId: string }
  | { kind: 'docked'; sessionId: string; select: boolean }
  | { kind: 'replaced'; previousId: string; sessionId: string }

export const NO_SESSION_WINDOWS: SessionWindowsView = Object.freeze({ windows: [], displays: [], self: null }) as SessionWindowsView

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function num(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

export function readSessionWindows(raw: unknown): SessionWindowsView {
  if (!isRecord(raw)) return NO_SESSION_WINDOWS
  const windows: SessionWindowRow[] = []
  for (const entry of Array.isArray(raw.windows) ? (raw.windows as unknown[]) : []) {
    if (!isRecord(entry) || typeof entry.sessionId !== 'string' || entry.sessionId === '') continue
    const windowId = num(entry.windowId)
    if (windowId === null) continue
    windows.push({
      sessionId: entry.sessionId,
      windowId,
      label: typeof entry.label === 'string' ? entry.label : '',
      status: typeof entry.status === 'string' ? entry.status : null,
      displayId: num(entry.displayId),
      displayLabel: typeof entry.displayLabel === 'string' ? entry.displayLabel : '',
      fullScreen: entry.fullScreen === true,
      minimized: entry.minimized === true,
      focused: entry.focused === true,
    })
  }
  const displays: SessionWindowDisplay[] = []
  for (const entry of Array.isArray(raw.displays) ? (raw.displays as unknown[]) : []) {
    if (!isRecord(entry)) continue
    const id = num(entry.id)
    if (id === null) continue
    displays.push({ id, label: typeof entry.label === 'string' ? entry.label : '', primary: entry.primary === true })
  }
  return { windows, displays, self: num(raw.self) }
}

export function readSessionWindowEvent(raw: unknown): SessionWindowEvent | null {
  if (!isRecord(raw) || typeof raw.sessionId !== 'string') return null
  if (raw.kind === 'opened') return { kind: 'opened', sessionId: raw.sessionId }
  if (raw.kind === 'docked') return { kind: 'docked', sessionId: raw.sessionId, select: raw.select === true }
  if (raw.kind === 'replaced' && typeof raw.previousId === 'string') {
    return { kind: 'replaced', previousId: raw.previousId, sessionId: raw.sessionId }
  }
  return null
}

/**
 * Where a tab dragged off the bar was let go, when that was outside the window.
 *
 * The strip already has a meaning for a drag that ends off the strip but inside
 * the window — the tab folds back into the rail — and that stays. Only a drop
 * past the window's own edge means "give it a window of its own", the way a
 * browser tab torn off its window does.
 *
 * Chromium reports a `dragend` that left the window with client coordinates
 * outside the viewport (negative, or past its size) and the screen point it
 * ended at. A `dragend` with every coordinate zero is one that did not say
 * where it ended — some cancellations do that — and is not a drop anywhere.
 */
export function tearOffPoint(
  event: { clientX: number; clientY: number; screenX: number; screenY: number },
  viewport: { width: number; height: number },
): { x: number; y: number } | null {
  if (event.clientX === 0 && event.clientY === 0 && event.screenX === 0 && event.screenY === 0) return null
  const outside =
    event.clientX < 0 || event.clientY < 0 || event.clientX > viewport.width || event.clientY > viewport.height
  return outside ? { x: Math.round(event.screenX), y: Math.round(event.screenY) } : null
}

/** The preload's half, every method optional: a build without them draws no moves. */
export interface SessionWindowsBridge {
  sessionWindows?(): Promise<unknown>
  onSessionWindows?(cb: (view: unknown, event: unknown) => void): () => void
  popOutSession?(sessionId: string, options?: { at?: { x: number; y: number }; displayId?: number }): Promise<unknown>
  dockSession?(sessionId: string): Promise<unknown>
  focusSessionWindow?(sessionId: string): Promise<unknown>
  labelSessionWindows?(labels: Record<string, string>): void
  /** A session window following its session through an account switch that restarted it. */
  followSessionSwitch?(previousId: string, nextId: string): Promise<unknown>
  /** Bring the main window forward, running one of `MAIN_COMMANDS` there. */
  showMainWindow?(command?: string): void
}

export interface SessionWindows {
  /** True when this build can move sessions between windows at all. */
  available: boolean
  view: SessionWindowsView
  /** Ids of the sessions that are out. */
  popped: ReadonlySet<string>
  rowFor(sessionId: string): SessionWindowRow | null
  /** Move a session into its own window. Resolves with a sentence when it was refused. */
  popOut(sessionId: string, at?: { x: number; y: number } | null): Promise<string | null>
  dock(sessionId: string): void
  focus(sessionId: string): void
  /** Hand the main process the names this window shows, for the windows that are out. */
  label(labels: Record<string, string>): void
}

/**
 * The preload, read as this module's own narrow shape.
 *
 * Not through `DeckApi` in `shared/types.ts`: this feature's methods cross the
 * bridge as `unknown` and are typed here, beside the code that reads them, the
 * way `DevServerPanel` and the other optional features do it.
 */
export function sessionWindowsBridge(): SessionWindowsBridge | null {
  return (globalThis as { deck?: SessionWindowsBridge }).deck ?? null
}

function bridgeOf(): SessionWindowsBridge | null {
  return sessionWindowsBridge()
}

/**
 * The list, kept current from the main process's pushes.
 *
 * `onEvent` hears the moves as they happen — the main window uses "docked with
 * select" to bring a session it just got back to the front.
 */
export function useSessionWindows(
  options: { onEvent?(event: SessionWindowEvent): void; bridge?: SessionWindowsBridge | null } = {},
): SessionWindows {
  const [deck] = useState<SessionWindowsBridge | null>(() => (options.bridge === undefined ? bridgeOf() : options.bridge))
  const [view, setView] = useState<SessionWindowsView>(NO_SESSION_WINDOWS)
  const onEvent = useRef(options.onEvent)
  onEvent.current = options.onEvent
  // The window's own id comes back once, on the first read; the pushes are the
  // same for every window and cannot carry it.
  const self = useRef<number | null>(null)
  const available =
    deck !== null &&
    typeof deck.sessionWindows === 'function' &&
    typeof deck.onSessionWindows === 'function' &&
    typeof deck.popOutSession === 'function' &&
    typeof deck.dockSession === 'function'

  useEffect(() => {
    if (!available || deck === null) return
    let live = true
    const off = deck.onSessionWindows?.((raw, rawEvent) => {
      if (!live) return
      setView({ ...readSessionWindows(raw), self: self.current })
      const event = readSessionWindowEvent(rawEvent)
      if (event) onEvent.current?.(event)
    })
    void deck
      .sessionWindows?.()
      .then((raw) => {
        if (!live) return
        const read = readSessionWindows(raw)
        self.current = read.self
        setView(read)
      })
      .catch(() => undefined)
    return () => {
      live = false
      off?.()
    }
  }, [available, deck])

  const popped = useMemo(() => new Set(view.windows.map((row) => row.sessionId)), [view])

  const rowFor = useCallback(
    (sessionId: string) => view.windows.find((row) => row.sessionId === sessionId) ?? null,
    [view],
  )

  const popOut = useCallback(
    async (sessionId: string, at?: { x: number; y: number } | null): Promise<string | null> => {
      if (!available || deck === null) return 'This build cannot give a session its own window.'
      try {
        const raw = await deck.popOutSession?.(sessionId, at ? { at } : {})
        const result = isRecord(raw) ? raw : {}
        return result.ok === true ? null : typeof result.message === 'string' ? result.message : 'It could not be moved.'
      } catch {
        return 'It could not be moved.'
      }
    },
    [available, deck],
  )

  const dock = useCallback(
    (sessionId: string) => {
      void deck?.dockSession?.(sessionId)
    },
    [deck],
  )

  const focus = useCallback(
    (sessionId: string) => {
      void deck?.focusSessionWindow?.(sessionId)
    },
    [deck],
  )

  const lastLabels = useRef('')
  const label = useCallback(
    (labels: Record<string, string>) => {
      // Sent only when it changed: this is called from a render effect, and an
      // IPC message per render is a message per keystroke in a terminal.
      const key = JSON.stringify(labels)
      if (key === lastLabels.current) return
      lastLabels.current = key
      deck?.labelSessionWindows?.(labels)
    },
    [deck],
  )

  return { available, view, popped, rowFor, popOut, dock, focus, label }
}
