import { execFile } from 'node:child_process'
import type { IslandNotch, Rect } from '../shared/hoot-island'

/**
 * Where a MacBook's camera notch is, so Hoot's island can sit around it rather
 * than behind it.
 *
 * Electron does not say. AppKit does: on a screen with a notch, `NSScreen`'s
 * `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` are the two strips of menu
 * bar either side of the housing, and what lies between them is the notch. On
 * every other screen both are empty. One short JavaScript-for-Automation script
 * asks AppKit for every screen at once — run when the island first appears and
 * again when a display is added, removed or changes, never on a timer.
 *
 * The answer is matched to Electron's displays by size and horizontal position,
 * because AppKit counts from the bottom of the main screen and Electron from
 * the top: the two agree on widths, heights and x, not on y.
 */

/** Run with `osascript -l JavaScript`. Prints one line of JSON: every screen, its frame and the two strips. */
export const NOTCH_SCRIPT = `ObjC.import('AppKit');
var out = [];
var screens = $.NSScreen.screens;
for (var i = 0; i < screens.count; i++) {
  var s = screens.objectAtIndex(i);
  var f = s.frame;
  var entry = { x: f.origin.x, width: f.size.width, height: f.size.height, left: 0, right: 0, top: 0 };
  try {
    var l = s.auxiliaryTopLeftArea;
    var r = s.auxiliaryTopRightArea;
    entry.left = l.size.width;
    entry.right = r.size.width;
    entry.top = Math.max(l.size.height, r.size.height);
  } catch (e) {}
  out.push(entry);
}
JSON.stringify(out);`

/** One screen as AppKit described it. */
export interface ScreenReport {
  x: number
  width: number
  height: number
  /** The menu bar strip left of the notch, and right of it; 0 on a screen without one. */
  left: number
  right: number
  top: number
}

const num = (value: unknown): number => (typeof value === 'number' && Number.isFinite(value) ? value : 0)

/** The script's output, read defensively: anything malformed is no screens, not a guess. */
export function parseScreens(raw: string): ScreenReport[] {
  let data: unknown
  try {
    data = JSON.parse(raw.trim())
  } catch {
    return []
  }
  if (!Array.isArray(data)) return []
  const out: ScreenReport[] = []
  for (const entry of data) {
    if (typeof entry !== 'object' || entry === null) continue
    const e = entry as Record<string, unknown>
    out.push({ x: num(e.x), width: num(e.width), height: num(e.height), left: num(e.left), right: num(e.right), top: num(e.top) })
  }
  return out
}

/**
 * The notch on this display, if it has one: both strips present, and a gap
 * between them that is plausibly a camera housing (not a rounding error, not
 * most of the screen).
 */
export function notchOf(display: Rect, screens: readonly ScreenReport[]): IslandNotch | null {
  const same = screens.find(
    (s) => Math.abs(s.x - display.x) < 1 && Math.abs(s.width - display.width) < 1 && Math.abs(s.height - display.height) < 1,
  )
  if (same === undefined || same.left <= 0 || same.right <= 0 || same.top <= 0) return null
  const width = same.width - same.left - same.right
  if (width < 40 || width > same.width / 2) return null
  return { left: Math.round(same.left), width: Math.round(width), height: Math.round(same.top) }
}

/** Ask AppKit. Resolves to no screens — never throws — if the script fails or takes too long. */
export function readScreens(
  run: (file: string, args: string[], timeoutMs: number) => Promise<string> = defaultRun,
): Promise<ScreenReport[]> {
  return run('/usr/bin/osascript', ['-l', 'JavaScript', '-e', NOTCH_SCRIPT], 4000)
    .then(parseScreens)
    .catch(() => [])
}

function defaultRun(file: string, args: string[], timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(file, args, { timeout: timeoutMs, encoding: 'utf8' }, (error, stdout) => {
      if (error) reject(error)
      else resolve(stdout)
    })
  })
}
