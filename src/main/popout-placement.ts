/**
 * Where a session's own window goes on screen, and where it goes back to after
 * a restart.
 *
 * Asad, 2026-10-03: *"session one I'm running right now in my screen one… I
 * have another monitor alongside. Session two I want to move in my another
 * screen in my another monitor."* So the placement a person gave a window is
 * the thing worth keeping, and the thing most likely to be wrong next time: a
 * laptop leaves its desk, a monitor is unplugged, the arrangement in System
 * Settings is changed. A window restored onto a display that is no longer there
 * opens off every screen — running, listed in the Window menu, and impossible to
 * reach with a pointer. That is a session nobody can see, which is worse than a
 * session that did not come back.
 *
 * ## Pure, on purpose
 *
 * Electron's `screen` is only usable after `ready` and only in the main process,
 * and the cases that matter — a display unplugged, a display whose id changed, a
 * window dragged half off the edge — cannot be produced on demand on whatever
 * machine runs the tests. So every decision here takes the displays as a value,
 * and `popout-windows.ts` is the only file that asks Electron for them.
 *
 * ## What is remembered, and what is not
 *
 * The window's bounds, the display it was on, and whether it was full screen.
 * Keyed by the session's **tab key**, not its id: a restored session is a new
 * process with a new id, and `session-restore.ts` already carries the one name a
 * tab keeps across a restart (`SavedSession.tabKey`). A session that has no tab
 * key — one a launch does not bring back — is still poppable; it simply has no
 * placement to restore, because it has nothing to be restored into.
 */

/** A rectangle in screen points, the way Electron reports one. */
export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

/** One display, as much of it as placement needs. */
export interface DisplayInfo {
  /** Electron's id. Stable for one monitor on macOS, but not promised — see {@link placeRestored}. */
  id: number
  /** The whole display. */
  bounds: Rect
  /** The display minus the menu bar and the Dock — where a window may sit. */
  workArea: Rect
  /** What a person calls it ("Built-in Retina Display", "DELL U2723QE"). Empty when unknown. */
  label: string
}

/** One session window's remembered placement. */
export interface PopoutPlacement {
  /** The session's tab key — the name that survives a restart. */
  key: string
  bounds: Rect
  /** The display it was on when last moved, or null when that was not known. */
  displayId: number | null
  fullScreen: boolean
}

/** The file's shape. A version so a later change can be told from a corrupt file. */
export interface PlacementFile {
  v: 1
  windows: PopoutPlacement[]
}

/** The smallest a session window may be. The main window's own floor, a size down. */
export const POPOUT_MIN_WIDTH = 480
export const POPOUT_MIN_HEIGHT = 320

/** What a fresh window is, before anybody resizes it. A terminal a person can work in. */
export const POPOUT_DEFAULT_WIDTH = 960
export const POPOUT_DEFAULT_HEIGHT = 640

/**
 * How much of a window has to be on a display for it to count as reachable.
 *
 * Not "any overlap": one pixel of a window on screen is a window that cannot be
 * grabbed. The title bar is what a person drags by, so what has to be visible is
 * a strip of it — this much height from the top, and this much width.
 */
const REACHABLE_TOP = 32
const REACHABLE_WIDTH = 120

/** The step between windows opened one after another without a place to go. */
const CASCADE = 28

function finite(n: unknown): n is number {
  return typeof n === 'number' && Number.isFinite(n)
}

function readRect(value: unknown): Rect | null {
  if (typeof value !== 'object' || value === null) return null
  const r = value as Record<string, unknown>
  if (!finite(r.x) || !finite(r.y) || !finite(r.width) || !finite(r.height)) return null
  if (r.width <= 0 || r.height <= 0) return null
  return { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) }
}

/**
 * The placements in a file, or none.
 *
 * Read from disk, so parsed rather than trusted. A row that does not read is
 * dropped and the others kept: one bad entry is not a reason to forget where
 * every other window was.
 */
export function readPlacements(raw: unknown): PopoutPlacement[] {
  if (typeof raw !== 'object' || raw === null) return []
  const file = raw as Record<string, unknown>
  if (file.v !== 1 || !Array.isArray(file.windows)) return []
  const out: PopoutPlacement[] = []
  const seen = new Set<string>()
  for (const entry of file.windows as unknown[]) {
    if (typeof entry !== 'object' || entry === null) continue
    const row = entry as Record<string, unknown>
    if (typeof row.key !== 'string' || row.key === '' || seen.has(row.key)) continue
    const bounds = readRect(row.bounds)
    if (bounds === null) continue
    seen.add(row.key)
    out.push({
      key: row.key,
      bounds,
      displayId: finite(row.displayId) ? row.displayId : null,
      fullScreen: row.fullScreen === true,
    })
  }
  return out
}

/** The file to write for these placements. */
export function placementFile(windows: readonly PopoutPlacement[]): PlacementFile {
  return { v: 1, windows: windows.map((w) => ({ ...w, bounds: { ...w.bounds } })) }
}

/** How much of `a` lies inside `b`, as a rectangle (possibly empty). */
function intersection(a: Rect, b: Rect): Rect {
  const x = Math.max(a.x, b.x)
  const y = Math.max(a.y, b.y)
  const right = Math.min(a.x + a.width, b.x + b.width)
  const bottom = Math.min(a.y + a.height, b.y + b.height)
  return { x, y, width: Math.max(0, right - x), height: Math.max(0, bottom - y) }
}

/**
 * Can a person reach this window's title bar on this display?
 *
 * Asked of the top strip only, because that is the part a window is moved by.
 * A window whose lower half hangs off the bottom of a screen is fine — that is
 * how people park windows. One whose title bar is off the top, or beyond the
 * edge, cannot be dragged back.
 */
export function reachableOn(bounds: Rect, display: DisplayInfo): boolean {
  const titleBar: Rect = { x: bounds.x, y: bounds.y, width: bounds.width, height: Math.min(bounds.height, REACHABLE_TOP) }
  const seen = intersection(titleBar, display.workArea)
  return seen.width >= Math.min(REACHABLE_WIDTH, bounds.width) && seen.height >= Math.min(REACHABLE_TOP, bounds.height) / 2
}

/**
 * Fit a rectangle onto a display's work area: no bigger than it, and inside it.
 *
 * Size first, then position, so a window from a larger monitor arrives as large
 * as this one allows rather than with its edge off screen.
 */
export function fitInto(bounds: Rect, area: Rect): Rect {
  const width = Math.max(Math.min(bounds.width, area.width), Math.min(POPOUT_MIN_WIDTH, area.width))
  const height = Math.max(Math.min(bounds.height, area.height), Math.min(POPOUT_MIN_HEIGHT, area.height))
  const x = Math.min(Math.max(bounds.x, area.x), area.x + area.width - width)
  const y = Math.min(Math.max(bounds.y, area.y), area.y + area.height - height)
  return { x: Math.round(x), y: Math.round(y), width: Math.round(width), height: Math.round(height) }
}

/** Centre a size on a display's work area. */
export function centreOn(size: { width: number; height: number }, area: Rect): Rect {
  return fitInto(
    {
      x: area.x + Math.round((area.width - size.width) / 2),
      y: area.y + Math.round((area.height - size.height) / 2),
      width: size.width,
      height: size.height,
    },
    area,
  )
}

/** The display a point is on, or null when it is between displays. */
export function displayAt(point: { x: number; y: number }, displays: readonly DisplayInfo[]): DisplayInfo | null {
  for (const display of displays) {
    const b = display.bounds
    if (point.x >= b.x && point.x < b.x + b.width && point.y >= b.y && point.y < b.y + b.height) return display
  }
  return null
}

/** The display holding most of a rectangle, or null when it is on none. */
export function displayMostlyHolding(bounds: Rect, displays: readonly DisplayInfo[]): DisplayInfo | null {
  let best: DisplayInfo | null = null
  let bestArea = 0
  for (const display of displays) {
    const seen = intersection(bounds, display.bounds)
    const area = seen.width * seen.height
    if (area > bestArea) {
      best = display
      bestArea = area
    }
  }
  return best
}

/** Why a restored window landed where it did. Said in the log and the tool answer, never on screen. */
export type RestoreOutcome = 'same-display' | 'moved-display' | 'fallback-primary'

/**
 * Where a remembered window goes now, given the displays there are now.
 *
 * In order, and each step is the next-best answer when the one before it fails:
 *
 *  1. **The same display, by id, if the title bar is still reachable on it.**
 *     The ordinary restart: nothing about the desk changed.
 *  2. **Any display the remembered bounds are still reachable on.** Display ids
 *     are not promised to survive a reconnect, and a monitor that came back with
 *     a new id is still the monitor the window is sitting on. Geometry is the
 *     truth when the id is not.
 *  3. **The main screen**, at the same size where it fits, centred. The monitor
 *     is gone; the window comes to where the person is rather than to where the
 *     monitor was.
 *
 * In steps 1 and 2 the window is also fitted into the work area, which only
 * changes anything when the display shrank (a resolution change) — and then it
 * is the difference between a window that fits and one whose edge is off screen.
 */
export function placeRestored(
  saved: { bounds: Rect; displayId: number | null },
  displays: readonly DisplayInfo[],
  primary: DisplayInfo,
): { bounds: Rect; display: DisplayInfo; outcome: RestoreOutcome } {
  const byId = saved.displayId === null ? null : displays.find((d) => d.id === saved.displayId) ?? null
  if (byId !== null && reachableOn(saved.bounds, byId)) {
    return { bounds: fitInto(saved.bounds, byId.workArea), display: byId, outcome: 'same-display' }
  }
  for (const display of displays) {
    if (reachableOn(saved.bounds, display)) {
      return {
        bounds: fitInto(saved.bounds, display.workArea),
        display,
        outcome: display.id === saved.displayId ? 'same-display' : 'moved-display',
      }
    }
  }
  return { bounds: centreOn(saved.bounds, primary.workArea), display: primary, outcome: 'fallback-primary' }
}

/**
 * Where a window opened just now goes.
 *
 *  - **Dropped somewhere** (a tab dragged off the bar): on the display under the
 *    drop, with the title bar under the pointer, the way a browser tab that is
 *    torn off lands where it was let go.
 *  - **Sent to a named display** (the tool can ask for one): centred on it.
 *  - **Otherwise**: beside the main window, stepped down and right so it does
 *    not land exactly on top of it, which would look as though nothing had
 *    happened. `open` counts the windows already out so two in a row cascade.
 */
export function placeNew(options: {
  at?: { x: number; y: number } | null
  display?: DisplayInfo | null
  main: Rect | null
  displays: readonly DisplayInfo[]
  primary: DisplayInfo
  open: number
}): { bounds: Rect; display: DisplayInfo } {
  const size = { width: POPOUT_DEFAULT_WIDTH, height: POPOUT_DEFAULT_HEIGHT }
  if (options.at) {
    const display = displayAt(options.at, options.displays) ?? options.primary
    const bounds = fitInto(
      { x: Math.round(options.at.x - size.width / 2), y: Math.round(options.at.y - 14), ...size },
      display.workArea,
    )
    return { bounds, display }
  }
  if (options.display) {
    return { bounds: centreOn(size, options.display.workArea), display: options.display }
  }
  const step = CASCADE * (options.open + 1)
  if (options.main) {
    const display = displayMostlyHolding(options.main, options.displays) ?? options.primary
    const bounds = fitInto(
      { x: options.main.x + step, y: options.main.y + step, ...size },
      display.workArea,
    )
    return { bounds, display }
  }
  const area = options.primary.workArea
  return {
    bounds: fitInto({ x: area.x + step, y: area.y + step, ...size }, area),
    display: options.primary,
  }
}
