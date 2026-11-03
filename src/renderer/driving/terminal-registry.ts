import { rectOf, type Rect } from './geometry'
import type { BufferReader, TerminalMetrics } from './terminal-region'

/**
 * Where the focus overlay finds a live terminal.
 *
 * ## Why a registry and not a prop
 *
 * `TerminalView` keeps its `Terminal` in a ref and hands it to nobody. That is
 * the right shape for the component — one xterm per session, mounted for the
 * life of the session so scrollback survives tab switches — and the wrong shape
 * for anything that has to point at a terminal it does not own. The overlay is
 * a window-level surface: it is drawn once, over whichever pane is on screen,
 * and it has no React relationship with the terminal it is boxing. Threading a
 * ref from `TerminalView` up through the panes, the workspace and `App` to a
 * sibling overlay would put a terminal handle in four components that have no
 * use for one.
 *
 * A registry keyed by session id is what the rest of the app already thinks in
 * — `onSessionData(id, …)`, `resizeSession(id, …)`, `getScrollback(id)` all key
 * on the same string — so this adds no new vocabulary.
 *
 * ## The structural type, and why it is not `Terminal`
 *
 * `DriveTerminal` names the seven things this feature reads. A real xterm
 * `Terminal` satisfies it, and so does a plain object in a test — which is what
 * makes the geometry testable at all. vitest runs this project in Node with no
 * DOM and no canvas, so importing `@xterm/xterm` into a test file would be a
 * test that cannot run rather than a more faithful one.
 *
 * It also documents the blast radius: if xterm changes something outside these
 * seven members, this feature is untouched.
 */

export interface DriveBufferLine {
  /** `trimRight` — xterm pads every line to the full column count. */
  translateToString(trimRight?: boolean): string
}

export interface DriveBuffer {
  /**
   * `'alternate'` while a full-screen TUI (vim, less, an agent's own pager) has
   * taken the screen. There is no scrollback in that state and the content is
   * repainted wholesale, so a region cannot be anchored in it — see
   * {@link terminalUnavailable}.
   */
  type: 'normal' | 'alternate'
  /** Absolute line drawn at the top row right now. Scrolling changes this. */
  viewportY: number
  /** Absolute line of the top of the *live* screen, below the scrollback. */
  baseY: number
  /** Total lines retained, scrollback included. */
  length: number
  getLine(index: number): DriveBufferLine | undefined
}

export interface DriveDisposable {
  dispose(): void
}

export interface DriveTerminal {
  readonly cols: number
  readonly rows: number
  /** The `.xterm` container xterm built. Undefined before `open()`. */
  readonly element: HTMLElement | undefined
  readonly buffer: { readonly active: DriveBuffer }
  /** Fires for scrolling, for new output and for a repaint. */
  onRender(handler: (event: { start: number; end: number }) => void): DriveDisposable
  onResize(handler: (event: { cols: number; rows: number }) => void): DriveDisposable
  scrollToLine(line: number): void
}

export interface RegisteredTerminal {
  term: DriveTerminal
  /** The element `TerminalView` observes, i.e. the pane's own box. */
  host: HTMLElement
}

/**
 * One registry per *window*, not one per copy of this module.
 *
 * `Symbol.for` rather than a plain module-level `Map`, and the reason is a
 * failure that actually happened rather than a hypothesis. A second bundle in
 * the same page — a verification harness, a lazily-loaded chunk that rollup
 * decided not to share, a test that imports this module through two different
 * specifiers — gets its own module instance and therefore its own `Map`. The
 * terminals register into one and the overlay looks in the other, and the
 * symptom is `not-registered` for a session whose terminal is plainly on
 * screen: an error message that is true about the registry and a lie about the
 * world, with nothing on screen to suggest which.
 *
 * A registered symbol is not an exposed API. It is not enumerable on the global
 * object and cannot be reached by name; it exists so that "the terminals in
 * this window" is a single fact no matter how the code got loaded.
 */
const REGISTRY = Symbol.for('terminaldeck.driving.terminals')

type RegistryHost = { [REGISTRY]?: Map<string, RegisteredTerminal> }

function store(): Map<string, RegisteredTerminal> {
  const host = globalThis as RegistryHost
  const existing = host[REGISTRY]
  if (existing) return existing
  const created = new Map<string, RegisteredTerminal>()
  host[REGISTRY] = created
  return created
}

const terminals = store()

/**
 * Register a session's terminal. Call the returned function on unmount.
 *
 * Returns an unregister function rather than exposing a `remove` so a caller
 * cannot delete a newer registration for the same id — which happens for real:
 * React can mount the replacement `TerminalView` for a re-keyed session before
 * it runs the old one's cleanup, and an id-keyed delete would then wipe the
 * live entry. The closure checks identity before deleting.
 */
export function registerTerminal(sessionId: string, entry: RegisteredTerminal): () => void {
  terminals.set(sessionId, entry)
  return () => {
    if (terminals.get(sessionId) === entry) terminals.delete(sessionId)
  }
}

export function findTerminal(sessionId: string): RegisteredTerminal | null {
  return terminals.get(sessionId) ?? null
}

/**
 * Every terminal this window has mounted, with its session id.
 *
 * The registry already knows the one fact nothing else in the renderer does:
 * which sessions actually have a pane in this window. `where.ts` uses it to
 * answer *"which session am I looking at"* — the app keeps every open session
 * mounted and hides the ones that are not in front, so the visible one is a
 * property of these elements and not of any state variable.
 *
 * A fresh array rather than the map's own iterator, so a caller cannot hold on
 * to a live view of the registry and read it after the terminals it names have
 * been unmounted.
 */
export function registeredTerminals(): Array<{ id: string; entry: RegisteredTerminal; host: HTMLElement }> {
  return [...terminals.entries()].map(([id, entry]) => ({ id, entry, host: entry.host }))
}

/** Test seam. Nothing in the app calls this. */
export function clearTerminals(): void {
  terminals.clear()
}

/* --------------------------------------------------------------- reading -- */

/**
 * Why a terminal cannot be boxed right now, or null if it can.
 *
 * A string rather than a boolean because every one of these is something the
 * driving panel has to be able to *say*. `DRIVING-MODE.md` puts it well: "a
 * tour that quietly stops boxing is worse than one that says 'this one is in
 * `vim`; here is the text.'"
 */
export type TerminalUnavailable = 'not-registered' | 'not-rendered' | 'alternate-buffer'

export function terminalUnavailable(sessionId: string): TerminalUnavailable | null {
  const entry = findTerminal(sessionId)
  if (entry === null) return 'not-registered'
  if (screenElement(entry) === null) return 'not-rendered'
  if (entry.term.buffer.active.type === 'alternate') return 'alternate-buffer'
  return null
}

/**
 * xterm's `.xterm-screen`, which is the element whose box is exactly
 * `cols × cellWidth` by `rows × cellHeight`.
 *
 * Not `.xterm` and not `.xterm-viewport`: both of those include the scrollbar
 * gutter, measured here at 18 px on a 868 px pane — so using either would put
 * every column about a sixth of a cell to the left of where it belongs, which
 * is invisible at column 0 and half a character out by column 100.
 */
function screenElement(entry: RegisteredTerminal): { getBoundingClientRect(): DOMRect } | null {
  const root = entry.term.element
  if (!root) return null
  const screen = root.querySelector('.xterm-screen')
  /*
   * Duck-typed, not `instanceof HTMLElement`.
   *
   * `HTMLElement` is not a global in Node, so an `instanceof` check here throws
   * a `ReferenceError` rather than returning false — and it throws inside the
   * measure path, which is the path every test of this feature runs through.
   * The same fault would fire in any non-browser consumer of the renderer
   * bundle. What this actually needs is one method, so that is what it checks
   * for.
   */
  if (screen === null || typeof screen.getBoundingClientRect !== 'function') return null
  const box = screen.getBoundingClientRect()
  // A hidden tab keeps its terminal mounted under `display: none`, where every
  // rectangle is zero. That is "not rendered", not "at the origin".
  if (box.width <= 0 || box.height <= 0) return null
  return screen
}

/** The screen rectangle plus the grid size, or null if the pane is not laid out. */
export function terminalMetrics(sessionId: string): TerminalMetrics | null {
  const entry = findTerminal(sessionId)
  if (entry === null) return null
  const screen = screenElement(entry)
  if (screen === null) return null
  return { screen: rectOf(screen), cols: entry.term.cols, rows: entry.term.rows }
}

/** The pane's own box, used to keep the overlay inside the session's area. */
export function terminalHostRect(sessionId: string): Rect | null {
  const entry = findTerminal(sessionId)
  return entry === null ? null : rectOf(entry.host)
}

/**
 * A {@link BufferReader} over a live terminal.
 *
 * `first` is `length - viewportSpan` rather than 0 because xterm trims the head
 * of the scrollback in place: absolute indices below that have been discarded
 * and `getLine` returns undefined for them. Asking anyway would work — the scan
 * skips nulls — but it would walk thousands of dead indices on every relocate.
 */
export function bufferReader(sessionId: string): BufferReader | null {
  const entry = findTerminal(sessionId)
  if (entry === null) return null
  const buffer = entry.term.buffer.active
  return {
    first: 0,
    end: buffer.length,
    cols: entry.term.cols,
    line: (index: number): string | null => {
      if (index < 0 || index >= buffer.length) return null
      return buffer.getLine(index)?.translateToString(true) ?? null
    },
  }
}

/** The absolute line drawn at the terminal's top row right now. */
export function viewportLine(sessionId: string): number | null {
  const entry = findTerminal(sessionId)
  return entry === null ? null : entry.term.buffer.active.viewportY
}
