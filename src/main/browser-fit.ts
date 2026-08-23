/**
 * Make a page fit the pane it was given, when the page refuses to.
 *
 * ## The measurement this file exists because of
 *
 * He reported, of the embedded browser, in the same breath as the store:
 *
 * > *"even when the Chrome store is there, when they browse the store it is not
 * > fitting in the frame, it is not according to our browser, it cannot support
 * > that — this kind of thing is an issue of our browser actually."*
 *
 * Reproduced on 2026-08-23 in a real window, 1440×900 with the sidebar open,
 * which gives the pane **1176 CSS pixels**. Five ordinary heavy sites were
 * loaded into it and measured: github.com, amazon.com, linkedin.com, bbc.com
 * and news.ycombinator.com all reflowed to exactly 1176 with **zero** overflow.
 * The Chrome Web Store did not:
 *
 * | page                                   | viewport | content | `body` min-width |
 * |----------------------------------------|---------:|--------:|-----------------:|
 * | chromewebstore.google.com              |     1176 |    1280 |           1280px |
 * | chromewebstore.google.com/category/…   |     1176 |    1249 |           1249px |
 *
 * So this is not a bounds bug and not a user-agent bug — the pane is exactly the
 * size the renderer says it is, and the page is served the desktop layout it
 * would be served in Chrome. It is that the store pins its own minimum width at
 * roughly 1250–1280px, and a browser *inside* an app never has the whole window
 * to spend: 264px of it is the sidebar. A 13-inch MacBook is 1440 wide, so the
 * store cannot fit in this app's pane on the machine it was reported from, at
 * any window size short of full screen.
 *
 * ## Why zoom, and not a scrollbar
 *
 * There already is a scrollbar — the overflow scrolls, measured, 104px of it.
 * On macOS it is an overlay scrollbar, so it is invisible until something is
 * already scrolling, which is why the page reads as *cut off* rather than as
 * *scrollable*. Zoom is the answer a browser actually has for "this layout is
 * wider than this window": it changes the size of a CSS pixel, so the page lays
 * out at the width it demands and the whole of that width is on screen. Nothing
 * is scaled after the fact and no media query is lied to — at 92% the store
 * lays out at 1280 CSS pixels inside 1176 device-independent ones, which is the
 * layout its designers wrote.
 *
 * ## What it will not do
 *
 * - It never zooms **in**. {@link fitFactor} is clamped above by the zoom the
 *   document started at, so a page that fits is left exactly as it was.
 * - It never goes below {@link ZOOM_FLOOR}. A 1250px store in a 568px pane of a
 *   split would need 45%, which is not a page anybody can read; the honest
 *   answer there is the scrollbar, and this stands down rather than pretending.
 * - It stops the moment the person sets a zoom themselves — see
 *   {@link noteManualZoom}. The toolbar's zoom chip is the escape hatch: it
 *   appears exactly because the zoom is not 100%, and pressing it puts the page
 *   back to 100% and leaves it there.
 */

/** Below this a fitted page is too small to read, so it is not fitted at all. */
export const ZOOM_FLOOR = 0.5

/** Zoom differences smaller than this are not worth a reflow. */
const EPSILON = 0.005

export interface FitInput {
  /**
   * The width the page actually has, in device-independent pixels.
   *
   * Measured as `clientWidth × zoom` rather than taken from the view's bounds,
   * because a platform with classic scrollbars (Windows, Linux) spends real
   * width on the vertical one and the page never gets it. On macOS the two are
   * the same number.
   */
  paneWidth: number
  /** The page's own minimum layout width, in CSS pixels. */
  contentWidth: number
  /** The zoom the document started at — the ceiling, never exceeded. */
  base: number
}

/**
 * The zoom that puts `contentWidth` inside `paneWidth`, within the limits.
 *
 * Pure, and the whole of the arithmetic, so the decision can be tested without
 * a window: everything else in this file is bookkeeping around it.
 *
 * Returns `base` for anything it will not or need not shrink — a page that fits,
 * a measurement that has not arrived yet, a pane of no width. Never above
 * `base`, so this can only ever undo its own zoom and never override the
 * person's.
 */
export function fitFactor({ paneWidth, contentWidth, base }: FitInput): number {
  if (!Number.isFinite(paneWidth) || paneWidth <= 0) return base
  if (!Number.isFinite(contentWidth) || contentWidth <= 0) return base
  if (!Number.isFinite(base) || base <= 0) return 1
  const wanted = paneWidth / contentWidth
  if (wanted >= base) return base
  /*
   * Two decimal places, rounded **down**, and the direction is the whole point.
   *
   * The chip in the address bar reads a whole percent, and a factor of
   * 0.9183673 would make every re-measure a fresh reflow for a pixel nobody can
   * see. But rounding to the *nearest* percent rounds up half the time, and up
   * is a viewport smaller than the layout: measured in a real window, 1176/1280
   * rounded to 0.92 gave a 1278px viewport for a 1280px page and left a 2px
   * sliver of the store still clipped — the whole fault, in miniature, after
   * doing all the work to fix it. Down always overshoots.
   */
  const stepped = Math.floor(wanted * 100) / 100
  // Rather than a 45% store nobody can read. The page keeps its scrollbar, which
  // is what a browser does when a layout genuinely does not fit.
  if (stepped < ZOOM_FLOOR) return base
  return stepped
}

/** Is the difference between two zooms worth acting on? */
export function worthApplying(current: number, next: number): boolean {
  return Math.abs(current - next) > EPSILON
}

/* ------------------------------------------------------------ per-tab state -- */

interface FitState {
  /**
   * The zoom this document started at, and the ceiling for every fit on it.
   *
   * Read once per document rather than per fit, because reading it after we
   * have already zoomed would ratchet the ceiling down: a 92% fit would become
   * the new base, the next measure would fit *that*, and the page would walk
   * itself to the floor.
   */
  base: number
  /**
   * The page's own minimum layout width in CSS pixels, once it has been seen to
   * overflow — and the reason this is remembered rather than re-measured.
   *
   * `scrollWidth` is never smaller than `clientWidth`, so a page that has been
   * zoomed until it fits measures as "fits" forever, and there would be no way
   * back to 100% when the window is made wider. Holding the width the page
   * asked for keeps the restore honest: the pane growing past it puts the zoom
   * back to `base` on the next measure.
   */
  need: number | null
  /** The person set the zoom by hand; leave the page alone until it navigates. */
  manual: boolean
}

const states = new Map<string, FitState>()

function stateFor(tabId: string, zoomNow: number): FitState {
  const found = states.get(tabId)
  if (found) return found
  const fresh: FitState = { base: zoomNow, need: null, manual: false }
  states.set(tabId, fresh)
  return fresh
}

/**
 * A new document in this tab: fitting starts over.
 *
 * `base` is deliberately *not* reset to the live zoom here — the caller restores
 * the document's own zoom before calling, and re-reading a zoom we had changed
 * ourselves is precisely the ratchet {@link FitState.base} warns about.
 */
export function resetFit(tabId: string): void {
  const found = states.get(tabId)
  if (!found) return
  found.need = null
  found.manual = false
}

/**
 * The person moved the zoom themselves. Their number becomes the new ceiling
 * and nothing here touches the page again until it navigates.
 */
export function noteManualZoom(tabId: string, factor: number): void {
  if (!Number.isFinite(factor) || factor <= 0) return
  const found = states.get(tabId)
  if (found) {
    found.base = factor
    found.need = null
    found.manual = true
    return
  }
  states.set(tabId, { base: factor, need: null, manual: true })
}

/** The zoom this tab's document started at, or null for a tab never seen here. */
export function baseZoom(tabId: string): number | null {
  return states.get(tabId)?.base ?? null
}

export function forgetFit(tabId: string): void {
  states.delete(tabId)
}

/* ---------------------------------------------------------------- the page -- */

/**
 * As little of a `WebContents` as the fitting needs.
 *
 * Structural rather than Electron's type so the decision can be exercised
 * against a fake page — `executeJavaScript` against a real Chromium is the one
 * part of this that a unit test cannot have, and it is one line.
 */
export interface FittablePage {
  isDestroyed(): boolean
  getZoomFactor(): number
  setZoomFactor(factor: number): void
  executeJavaScript(code: string): Promise<unknown>
}

/**
 * What the page is, in one round trip.
 *
 * `documentElement.scrollWidth` and the body's, because a page can overflow
 * through either — the store overflows through `body`, which carries the
 * `min-width`. Read in the page's own main world: it touches nothing, changes
 * nothing and returns two numbers.
 */
const MEASURE = `(() => {
  const d = document.documentElement
  if (!d) return null
  const body = document.body
  return {
    client: d.clientWidth,
    content: Math.max(d.scrollWidth, body ? body.scrollWidth : 0),
  }
})()`

interface PageWidths {
  client: number
  content: number
}

function readWidths(raw: unknown): PageWidths | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  const client = value.client
  const content = value.content
  if (typeof client !== 'number' || typeof content !== 'number') return null
  if (!Number.isFinite(client) || !Number.isFinite(content)) return null
  if (client <= 0) return null
  return { client, content }
}

/**
 * Measure this page against its pane and zoom it if it does not fit.
 *
 * Resolves to the zoom now in force, or null when nothing was decided — a dead
 * page, a page the person has taken the zoom of, or a measurement that did not
 * come back. Callers use the number to tell the window what the zoom chip
 * should say; null means "leave what you are showing alone".
 *
 * Every failure is swallowed on purpose. This runs on a resize frame and after
 * every load, and there is no version of "the page could not be measured" that
 * should surface to the person or stop the page being shown.
 */
export async function fitPageToPane(tabId: string, page: FittablePage): Promise<number | null> {
  if (page.isDestroyed()) return null
  let zoom: number
  try {
    zoom = page.getZoomFactor()
  } catch {
    return null
  }
  const state = stateFor(tabId, zoom)
  if (state.manual) return null

  let widths: PageWidths | null
  try {
    widths = readWidths(await page.executeJavaScript(MEASURE))
  } catch {
    return null
  }
  if (widths === null || page.isDestroyed()) return null

  // Both in the same units the arithmetic wants: the pane in device-independent
  // pixels, the page's demand in CSS ones. `clientWidth` is CSS pixels at the
  // current zoom, so multiplying by it is what converts.
  const paneWidth = widths.client * zoom
  const overflows = widths.content > widths.client + 1
  if (overflows) state.need = widths.content
  // A page that has never overflowed has nothing to fit to, and `scrollWidth`
  // would answer `clientWidth` — the measurement that cannot tell a page that
  // fits from one this file has already made fit. See `FitState.need`.
  const need = state.need
  if (need === null) return zoom

  const next = fitFactor({ paneWidth, contentWidth: need, base: state.base })
  if (!worthApplying(zoom, next)) return zoom
  try {
    page.setZoomFactor(next)
  } catch {
    return null
  }
  // Back at the ceiling means the pane grew past what the page asked for, so
  // there is nothing left to remember — and forgetting it is what lets a page
  // whose layout changes under it (a store that swaps its own `min-width` per
  // route) be measured afresh rather than held to an old number.
  if (next >= state.base) state.need = null
  return next
}
