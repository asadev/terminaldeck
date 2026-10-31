/**
 * Draw mode's half of the preload, which is allowed to be missing.
 *
 * Same reasoning as `isolation-bridge.ts`, and it is worth restating because
 * getting it wrong is a bricked panel rather than a missing button.
 * `resolveBrowserBridge` returns null — and the workspace renders "The browser is
 * not connected" instead of a browser — when *any* method in `BRIDGE_METHODS` is
 * absent. That is right for navigation, which the panel cannot do anything
 * without. It would be catastrophic for draw mode: adding these two names to
 * that list would blank the whole browser on every build whose preload had not
 * caught up yet, including the running one, the moment this file shipped.
 *
 * So they are declared here instead, resolved to a `Partial`, and the Draw
 * button asks {@link drawAvailable} before it offers itself. The `…BridgeMethods`
 * naming also keeps them out of the contract test's "every `*Bridge` interface
 * must be fully exposed" rule, which is exactly the distinction being drawn.
 */

/** Mirrors `PageFrame` in `src/main/browser-view.ts`. */
export interface PageFrame {
  /** The page as a lossless `data:image/png` URL, at most 2000px wide. */
  image: string
  width: number
  height: number
  /** The address the main process has for the page, never the page's own claim. */
  url: string
}

/** Mirrors `MarkedShot` in `src/main/browser-view.ts`. */
export interface MarkedShot {
  path: string
  width: number
  height: number
  url: string
}

/** Mirrors the two channels `registerBrowserViewIpc` added for draw mode. */
export interface DrawBridgeMethods {
  /** A capture to mark up. Saves nothing — see the handler for why. */
  browserFrame(id: string): Promise<unknown>
  /** Write the composed PNG into the screenshot folder and describe what landed. */
  browserScreenshotMarked(id: string, png: string): Promise<unknown>
}

export type DrawApi = Partial<DrawBridgeMethods>

const DRAW_METHODS: ReadonlyArray<keyof DrawBridgeMethods> = [
  'browserFrame',
  'browserScreenshotMarked',
]

/**
 * Pick whichever of them the preload actually exposes.
 *
 * Each call goes through the host object rather than being torn off it: a
 * detached method loses `this`, and the failure then shows up at the first click
 * instead of at mount.
 */
export function resolveDrawApi(host?: unknown): DrawApi {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}

  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  for (const name of DRAW_METHODS) {
    if (typeof record[name] !== 'function') continue
    api[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return api as DrawApi
}

/**
 * True only with **both** halves, unlike isolation's one-sided check.
 *
 * They are not independent here. Without `browserFrame` there is nothing to draw
 * on; without `browserScreenshotMarked` the marks can be drawn and can never
 * leave the screen — and sending it to the agent is the entire feature, not a
 * finishing touch. A Draw button that opens a canvas you cannot send is worse
 * than no Draw button, because it takes the page away to do it.
 */
export function drawAvailable(api: DrawApi): boolean {
  return typeof api.browserFrame === 'function' && typeof api.browserScreenshotMarked === 'function'
}

/**
 * Narrow whatever came back from `browserFrame`, or null.
 *
 * The bridge is typed `unknown` on purpose — the two sides mirror each other by
 * hand rather than sharing a type — so this is where a main process that
 * disagrees with this file becomes a caught null instead of a canvas painted
 * with `undefined`. The image has to be a PNG data URL specifically, because the
 * composite written to disk is a re-encode of it and the popup draws it directly.
 */
export function readFrame(value: unknown): PageFrame | null {
  if (typeof value !== 'object' || value === null) return null
  const record = value as Record<string, unknown>
  const { image, width, height, url } = record
  if (typeof image !== 'string' || !image.startsWith('data:image/')) return null
  if (typeof width !== 'number' || typeof height !== 'number') return null
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) return null
  return { image, width, height, url: typeof url === 'string' ? url : '' }
}

/**
 * Narrow whatever came back from `browserScreenshotMarked`, or null.
 *
 * A path is the one field with no sensible default: it is what the popup shows,
 * what Reveal opens and what the agent is told to look at, so an absent one has
 * to be a failure rather than an empty string in a prompt.
 */
export function readMarkedShot(value: unknown): MarkedShot | null {
  if (typeof value !== 'object' || value === null) return null
  const record = value as Record<string, unknown>
  const { path, width, height, url } = record
  if (typeof path !== 'string' || path === '') return null
  return {
    path,
    width: typeof width === 'number' && Number.isFinite(width) ? width : 0,
    height: typeof height === 'number' && Number.isFinite(height) ? height : 0,
    url: typeof url === 'string' ? url : '',
  }
}
