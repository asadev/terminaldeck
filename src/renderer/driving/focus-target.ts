import {
  ALL_EDGES,
  clipRect,
  hasArea,
  padRect,
  rectOf,
  type ClippedRect,
  type Rect,
  type RectEdges,
} from './geometry'
import { locateQuote, normalizeLine, needleOf, regionRect, type BufferRegion } from './terminal-region'
import {
  bufferReader,
  findTerminal,
  terminalHostRect,
  terminalMetrics,
  terminalUnavailable,
  viewportLine,
} from './terminal-registry'

/**
 * What the focus overlay is allowed to point at.
 *
 * ## A closed set, and no CSS-selector escape hatch
 *
 * The obvious design is `{ selector: string }`, and it is wrong twice over.
 *
 * It is an **injection surface**: these arguments arrive over a tool call the
 * copilot composed, and the copilot composed them from *other sessions'
 * transcripts*, which `COPILOT-CAPABILITIES.md` §3.2 item 8 classifies as
 * evidence from an untrusted source. A selector is a small program. Handing one
 * to `querySelector` lets a transcript decide what the app measures, and — since
 * the overlay's hole is undimmed and everything else is not — lets it decide
 * what a person is directed to look at.
 *
 * It is also **silently broken by refactoring**. A selector that stops matching
 * fails as "the box is somewhere else", not as an error, and the next person to
 * rename a class has no way to know they broke a highlight. Every anchor below
 * is a `data-drive-anchor` attribute, which is a declaration that an element is
 * a named place in this app; a rename that drops one is a grep away from being
 * noticed, and `anchor-contract.test.ts` fails when the set drifts.
 */
export type DriveAnchor =
  /** A bubble in the chat view. The id is `ChatMessage.id`, already stable. */
  | { at: 'message'; messageId: string }
  /** A session's row in the sidebar. */
  | { at: 'session-row'; sessionId: string }
  /** One alert in the alerts panel. */
  | { at: 'alert'; alertId: string }
  /**
   * A changed file in the git panel.
   *
   * Keyed on the **project folder**, not on a session, and that is a
   * correction to the design note this feature was built from
   * (`DRIVING-MODE.md` §2c writes it as `{ sessionId, path }`). Source control
   * in this app is one of the ten project views: `PanelView` renders
   * `<GitPanel cwd={projectPath}/>` and has no session in scope at all, because
   * a folder with four sessions open in it has one working tree and one set of
   * changed files. Keying the anchor on a session would have meant either
   * threading an arbitrary one of those four down to a panel that has no use
   * for it, or an anchor that never matches anything.
   *
   * The note's own §4 already agrees where it counts: the `files-changed`
   * reason is defined there as "non-empty `RepoChanges.files` **for that cwd**".
   * The data was always folder-shaped; only the anchor disagreed.
   */
  | { at: 'git-file'; cwd: string; path: string }
  /**
   * A session's usage reading — the two stacked limit bars in the chrome.
   *
   * It was called `usage-strip` and pointed at `chat/usage/UsageStrip.tsx`,
   * which was the token and cost readout folded inside the chat composer. That
   * component is gone: the review asked for the composer's control row to be
   * *"removed from the chat box side completely"*, and the reading it drew moved
   * up into `shell/UsageBar.tsx`, which is mounted on every session screen
   * rather than only under a chat.
   *
   * So the kind is renamed rather than repointed, because the old name had
   * stopped describing anything. There is no strip; there is a session's usage,
   * and that is what a tour is pointing at when it stops here. A half-rename
   * would be the worst outcome available — `anchorSelector` would build
   * `[data-drive-anchor="usage-strip:…"]`, no element would carry it, and the
   * only symptom is a stop that quietly stops boxing. `anchor-contract.test.ts`
   * holds both ends of that together.
   */
  | { at: 'usage'; sessionId: string }

export type FocusTarget =
  /**
   * A passage of terminal output, found by its text. See `terminal-region.ts`
   * for why the text is the anchor and the line number is only a cache.
   */
  | { kind: 'terminal'; sessionId: string; quote: string }
  /** A named element in the app's own chrome. */
  | { kind: 'anchor'; anchor: DriveAnchor }
  /**
   * The embedded browser page, as a whole.
   *
   * There is no "an element inside the page" variant, and that is a hard limit
   * rather than an omission — see {@link PAGE_SELECTOR}.
   */
  | { kind: 'page' }

/** The attribute every chrome anchor carries. */
export const ANCHOR_ATTR = 'data-drive-anchor'

/**
 * The stage a browser page is composited over.
 *
 * `.bw-stage` is described in `BrowserWorkspace.tsx` as "an empty div whose only
 * job is to be measured", and the main process is given exactly this rectangle
 * for the native view's bounds. So measuring it here is measuring the page.
 *
 * A page framed to a phone size occupies a column inside the stage rather than
 * all of it, and the hole is still the whole stage. That is deliberate: the
 * framed backdrop around a 390 px page belongs to the page, not to the app, and
 * a hole that hugged the phone column would leave a dimmed gutter that reads as
 * a rendering seam.
 */
export const PAGE_SELECTOR = '.bw-stage'

/**
 * The value of `data-drive-anchor` for an anchor, and the only place a selector
 * is ever built.
 *
 * Values are joined with a colon and escaped by `CSS.escape` at the call site,
 * so a session id or a file path containing a quote, a bracket or a backslash
 * cannot end the attribute selector early.
 */
export function anchorId(anchor: DriveAnchor): string {
  switch (anchor.at) {
    case 'message':
      return `message:${anchor.messageId}`
    case 'session-row':
      return `session-row:${anchor.sessionId}`
    case 'alert':
      return `alert:${anchor.alertId}`
    case 'git-file':
      return `git-file:${anchor.cwd}:${anchor.path}`
    case 'usage':
      return `usage:${anchor.sessionId}`
  }
}

/**
 * A value as a quoted CSS string.
 *
 * Deliberately not `CSS.escape`: that escapes for an *identifier*, while this
 * lands inside quotes, and it does not exist at all under vitest, which runs
 * this project in Node. The two characters that can end a quoted CSS string
 * early are the backslash and the quote, and both are escaped here — the same
 * `cssStringOf` that `browser-preload.ts` already uses, for the same reason: the
 * value is a session id, an alert id or a **file path**, none of which this file
 * gets to assume anything about.
 */
function cssString(value: string): string {
  return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

export function anchorSelector(anchor: DriveAnchor): string {
  return `[${ANCHOR_ATTR}=${cssString(anchorId(anchor))}]`
}

/* --------------------------------------------------------------- results -- */

/** Why a target could not be pointed at. Every value is something to say aloud. */
export type FocusFailure =
  /** No `TerminalView` has registered for that session. */
  | 'not-registered'
  /** The pane is mounted but has no size — a hidden tab. */
  | 'not-rendered'
  /** A full-screen TUI owns the screen; there is no scrollback to anchor in. */
  | 'alternate-buffer'
  /** The text is no longer anywhere in the retained buffer. */
  | 'quote-not-found'
  /** Found, but scrolled entirely out of the pane. */
  | 'off-screen'
  /** No element carries that anchor right now. */
  | 'anchor-missing'
  /** There is no browser page on screen. */
  | 'no-page'

/**
 * Something the overlay knows it cannot dim, named so the panel can say so.
 *
 * Today there is exactly one, and it is a fact about Electron rather than a
 * shortcoming of this code: a browser page is a `WebContentsView` composited
 * **above** the entire renderer, so no HTML can be painted over it — not with a
 * larger `z-index`, not with a portal, not with a new stacking context.
 * `overlay-watch.ts` is the essay and it has been rediscovered twice.
 *
 * The overlay does not pretend otherwise and does not reach for the two things
 * that would hide the problem. It does not **park** the page (`setVisible(false)`)
 * — that would make a dull region vanish outright, which is censorship rather
 * than emphasis and is exactly what the requirement rules out. And it does not
 * photograph the page and dim the photograph — the `DrawLayer` trade, which is
 * right for a deliberate annotation and wrong for a highlight that moves on in
 * four seconds, because the page is frozen and still live underneath.
 *
 * So it reports. A caller that shows "the page below is not dimmed" has told the
 * truth; one that silently leaves a bright rectangle in a dimmed window has
 * shipped a bug.
 */
export type Undimmable = 'browser-page'

export interface FocusRect {
  /** The hole: bright inside, everything else scrimmed. Window CSS pixels. */
  rect: Rect
  /** Which borders are the region's own — see `geometry.ts`. */
  edges: RectEdges
  /** Corner radius for hole and ring. */
  radius: number
  undimmable: readonly Undimmable[]
}

export type FocusResolution =
  | { ok: true; focus: FocusRect }
  | { ok: false; why: FocusFailure; undimmable: readonly Undimmable[] }

/** The DOM this needs, named so a test can supply four lines instead of a browser. */
export interface FocusDom {
  find(selector: string): { getBoundingClientRect(): DOMRectLike } | null
  viewport(): Rect
}

interface DOMRectLike {
  left: number
  top: number
  width: number
  height: number
}

export function browserFocusDom(): FocusDom | null {
  if (typeof document === 'undefined' || typeof window === 'undefined') return null
  return {
    find: (selector) => document.querySelector(selector),
    viewport: () => ({ x: 0, y: 0, width: window.innerWidth, height: window.innerHeight }),
  }
}

/* ------------------------------------------------------------------ pads -- */

/**
 * How far the hole is grown past the content it is pointing at.
 *
 * Terminal output is set on a 1.35 line-height, so a box drawn exactly on the
 * cell grid clips the descenders of the line above and below; three pixels puts
 * the ring in the leading rather than on the glyphs. Chrome elements get four,
 * because a chat bubble's own padding already stops short of its text and the
 * ring needs to read as being around the bubble rather than inside it.
 *
 * A browser page gets **zero**, and that is the important one. Every pixel the
 * overlay paints for a `page` target has to land outside the native view's
 * rectangle or it is not composited at all; the ring is a CSS `outline`, which
 * paints outward from the border box, so a pad of zero puts the hole exactly on
 * the page and the ring exactly outside it. See `outsideOf` in `geometry.ts`,
 * which is the assertion form of this sentence.
 */
export const PAD_TERMINAL = 3
export const PAD_ANCHOR = 4
export const PAD_PAGE = 0

/** Matching `--radius-sm`; 0 for a page, whose corners are square and native. */
export const RADIUS_DEFAULT = 6
export const RADIUS_PAGE = 0

/* ------------------------------------------------------------- the anchor -- */

/**
 * A target, plus the small amount of state that stops it costing a scrollback
 * scan on every frame.
 *
 * The cache is one integer — the absolute buffer line the quote was last found
 * at — and it is validated in O(1) before it is used: read that one line, and
 * check the needle is still in it. That catches the three things that move a
 * line out from under a cached index, and catches all of them without the scan:
 *
 *  - **trimming**, when the scrollback passes 10 000 lines and every absolute
 *    index shifts down;
 *  - **reflow**, when a width change re-wraps the buffer;
 *  - **overwriting**, when an agent CLI repaints the region with something else.
 *
 * A failed check falls through to a full backwards scan, which is the same code
 * path the first resolve takes, so there is exactly one way a quote is found.
 */
export interface FocusAnchor {
  readonly target: FocusTarget
  measure(dom?: FocusDom | null): FocusResolution
  /** Forget the cached line. Called on resize, where reflow is guaranteed. */
  invalidate(): void
}

export function createAnchor(target: FocusTarget): FocusAnchor {
  let cached: BufferRegion | null = null

  const invalidate = (): void => {
    cached = null
  }

  const measure = (dom: FocusDom | null = browserFocusDom()): FocusResolution => {
    /*
     * A null `dom` is not a failure for every kind of target, and treating it as
     * one was a real bug in the first draft. A terminal region is resolved
     * entirely out of the registry — the buffer, the grid, the screen element's
     * own box — so it works with no document surface at all, which is what makes
     * it testable in this project's DOM-free test run. Only the two kinds that
     * genuinely have to query the document fail here.
     */
    const undimmable = dom === null ? [] : undimmableSurfaces(target, dom)

    if (target.kind === 'page') {
      if (dom === null) return { ok: false, why: 'no-page', undimmable }
      const stage = dom.find(PAGE_SELECTOR)
      if (stage === null) return { ok: false, why: 'no-page', undimmable }
      const rect = rectOf(stage)
      if (!hasArea(rect)) return { ok: false, why: 'no-page', undimmable }
      return {
        ok: true,
        focus: {
          rect: padRect(rect, PAD_PAGE),
          edges: ALL_EDGES,
          radius: RADIUS_PAGE,
          undimmable,
        },
      }
    }

    if (target.kind === 'anchor') {
      if (dom === null) return { ok: false, why: 'anchor-missing', undimmable }
      const element = dom.find(anchorSelector(target.anchor))
      if (element === null) return { ok: false, why: 'anchor-missing', undimmable }
      const rect = padRect(rectOf(element), PAD_ANCHOR)
      if (!hasArea(rect)) return { ok: false, why: 'anchor-missing', undimmable }
      /*
       * Clipped to the window, not to the scroll container.
       *
       * A chat bubble scrolled half out of `.cv-scroll` has its own clipping
       * already — the browser does it — and the pane's box is not reachable
       * from an anchor id without teaching this file about every pane in the
       * app. The window is the bound that is always right and never needs a
       * lookup; a bubble scrolled off the top reports the part still visible,
       * which is what the reader sees.
       */
      const clipped = clipRect(rect, dom.viewport())
      if (clipped === null) return { ok: false, why: 'off-screen', undimmable }
      return { ok: true, focus: withRadius(clipped, RADIUS_DEFAULT, undimmable) }
    }

    const blocked = terminalUnavailable(target.sessionId)
    if (blocked !== null) return { ok: false, why: blocked, undimmable }

    const region = locate(target.sessionId, target.quote, cached)
    if (region === null) {
      cached = null
      return { ok: false, why: 'quote-not-found', undimmable }
    }
    cached = region

    const metrics = terminalMetrics(target.sessionId)
    const top = viewportLine(target.sessionId)
    if (metrics === null || top === null) {
      return { ok: false, why: 'not-rendered', undimmable }
    }

    const placed = regionRect(region, top, metrics)
    if (placed === null) return { ok: false, why: 'off-screen', undimmable }

    /*
     * Padded, then re-clipped to the pane.
     *
     * Order matters and the wrong order is invisible in a diff: padding after
     * the clip pushes the ring three pixels *past* the terminal's own edge, so
     * a region flush with the top of the pane draws its border over the session
     * bar above it. Re-clipping puts it back, and the edge flags computed by
     * the first clip are the ones that survive — they describe the region, and
     * the padding is not part of the region.
     */
    const padded = clipRect(padRect(placed.rect, PAD_TERMINAL), metrics.screen)
    const finalRect = padded === null ? placed.rect : padded.rect
    return {
      ok: true,
      focus: { rect: finalRect, edges: placed.edges, radius: RADIUS_DEFAULT, undimmable },
    }
  }

  return { target, measure, invalidate }
}

function withRadius(
  clipped: ClippedRect,
  radius: number,
  undimmable: readonly Undimmable[],
): FocusRect {
  return { rect: clipped.rect, edges: clipped.edges, radius, undimmable }
}

/**
 * Is the cached line still the right one, and if not, where is the quote now?
 *
 * The cheap check first, always. `locateQuote` walks up to 4 000 lines and this
 * runs on every frame a terminal renders on — which, while a session is
 * streaming, is every frame.
 */
function locate(sessionId: string, quote: string, cached: BufferRegion | null): BufferRegion | null {
  const reader = bufferReader(sessionId)
  if (reader === null) return null

  if (cached !== null && cached.line >= 0 && cached.line < reader.end) {
    const text = reader.line(cached.line)
    if (text !== null && normalizeLine(text).includes(needleOf(quote))) return cached
  }
  return locateQuote(reader, quote)
}

/**
 * What is on screen that the scrim will not reach.
 *
 * Checked per measure rather than once, because a browser tab can be opened
 * while a highlight is up. Cheap: one `querySelector` on a class that appears
 * at most once.
 */
function undimmableSurfaces(target: FocusTarget, dom: FocusDom): readonly Undimmable[] {
  if (target.kind === 'page') return []
  const stage = dom.find(PAGE_SELECTOR)
  if (stage === null) return []
  return hasArea(rectOf(stage)) ? ['browser-page'] : []
}

/**
 * Put the terminal's viewport where the region is.
 *
 * Separate from measuring, and called by a caller that has decided to travel
 * rather than by the measure loop, because scrolling a terminal the reader is
 * watching is an action and measuring is not. `scrollToLine` takes an absolute
 * buffer line, which is what a `BufferRegion` already holds.
 *
 * Three lines of headroom above the region so it does not arrive flush against
 * the top edge, where a box reads as clipped even when it is not.
 */
export const SCROLL_HEADROOM = 3

export function scrollToFocus(anchor: FocusAnchor): boolean {
  const target = anchor.target
  if (target.kind !== 'terminal') return false
  const entry = findTerminal(target.sessionId)
  if (entry === null) return false
  const resolved = anchor.measure()
  // Only when it is genuinely not visible: scrolling a region that is already
  // on screen moves the reader's page for no reason, and during a tour that
  // reads as the app twitching.
  if (resolved.ok) return false
  const reader = bufferReader(target.sessionId)
  if (reader === null) return false
  const region = locateQuote(reader, target.quote)
  if (region === null) return false
  entry.term.scrollToLine(Math.max(0, region.line - SCROLL_HEADROOM))
  anchor.invalidate()
  return true
}

/** The pane a terminal target lives in, for callers that need to inset travel. */
export function focusHostRect(target: FocusTarget): Rect | null {
  return target.kind === 'terminal' ? terminalHostRect(target.sessionId) : null
}
