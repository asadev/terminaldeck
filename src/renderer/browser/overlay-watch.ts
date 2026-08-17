/**
 * Which HTML surfaces are currently floating over the app, and whether any of
 * them lands on top of a browser page.
 *
 * ## Read this before "simplifying" it into a z-index
 *
 * You cannot fix this with CSS. Not with a bigger `z-index`, not with a portal,
 * not with a new stacking context, not with `isolation: isolate`. The reason is
 * structural rather than stylistic:
 *
 *   A browser page here is a `WebContentsView` — a **native child view of the
 *   window**, added with `window.contentView.addChildView(view)`. The window's
 *   view tree composites it ABOVE the renderer's entire surface. The renderer's
 *   DOM is one leaf of that tree; `z-index` orders boxes *within* that leaf and
 *   has no vocabulary at all for the sibling painted on top of it.
 *
 * So `z-index: 2147483647` on a tooltip puts it above every other piece of HTML
 * and still underneath the web page. This has been rediscovered twice: once for
 * the folder menu (see the long note on `.toolbar` in `shell.css`, which was a
 * genuine stacking-context bug and is a different fault with the same symptom),
 * and once in the screen recording of 2026-08-16 — *"whatever the message popup
 * is coming, it's hiding behind. I cannot even see what it shows"*, and, of the
 * peeked sidebar, *"this is behind the white page, it should be always front
 * layer"*.
 *
 * The only lever Electron offers is the native view's own visibility and its
 * bounds. There is no clip, no mask, and no way to put HTML above it.
 *
 * ## Why hiding, and not resizing
 *
 * Resizing the view to dodge an overlay changes the page's viewport, so its
 * media queries fire and its layout reflows — a tooltip would reflow somebody's
 * responsive site every time it appeared, which is far more disruptive than the
 * thing it was avoiding. `setVisible(false)` costs nothing on either side: the
 * WebContents keeps running, keeps its scroll position and its DOM, and is
 * simply not composited. Coming back is one call, with the same pixels.
 *
 * ## Why geometry, and not "an overlay is open"
 *
 * Parking the page for *every* floating surface would blank the whole website
 * whenever the pointer rested on a sidebar row. Most overlays in this app are
 * over the rail or the toolbar and never touch the page's rectangle, so the
 * decision is made by intersection: only a surface that actually lands on the
 * page hides it.
 *
 * ## What counts as a surface, and why that list needs no other file's help
 *
 * Two sources, both observable from here without a single edit elsewhere —
 * which matters, because the components that own these surfaces are `Modal`,
 * `Tooltips`, `FolderChip`, `AccountChip` and `Sidebar`, and asking each of them
 * to remember to call something is exactly how this bug comes back for whatever
 * floating surface somebody adds next.
 *
 *  1. **Portals.** Every floating surface in this renderer portals into
 *     `<body>` (`createPortal` in `Modal.tsx`, `Tooltips.tsx`, `FolderChip.tsx`,
 *     `AccountChip.tsx`), so they are element children of `<body>` that are not
 *     the React root. Watching `body`'s child list is one cheap observer that
 *     catches all of them, including ones written after this file.
 *  2. **The peeked sidebar.** The one floating surface that is *not* portalled:
 *     it is `position: absolute` inside the app root, and it is what he called
 *     "the session flyout". `App.tsx` already writes `data-sidebar-peek` on the
 *     root element while it is out, so its presence is readable without touching
 *     `Sidebar.tsx` — which another agent owns.
 *
 * There used to be a third source here — `holdOverlay`, a registry a surface
 * that is neither a portal nor the rail could push its rectangle into — and it
 * is gone. Not because a third source is impossible, but because that one was
 * never used and could not have been right: it took a *static* rectangle, and
 * the one surface it was written for, the peeked rail, moves and resizes, which
 * is why the rail is queried live above instead. The newest floating surface in
 * the app went the same way — read the long note at the top of `DriveLayer.tsx`,
 * which explains that the driving-mode overlay is deliberately mounted *inside*
 * `#root` so this module cannot see it at all. Every surface that could have
 * used the seam solved its problem another way, and an unused registry whose
 * entries live for the life of the process is a leak wearing an API's clothes.
 * If a fourth kind of surface ever does turn up, add a source that is *read*
 * from the DOM the way the two above are, at the same time as the surface that
 * needs it — not before.
 */

export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

/**
 * The element a native page view is painted into, as a selector.
 *
 * The other half of this module's subject, and the reason it is a constant
 * rather than a string typed wherever it is wanted. Everything above answers
 * "what is over the page"; a layer that *places* a floating surface wants the
 * opposite question — "where would the renderer's own pixels not be seen" — and
 * the honest answer is the same rectangle, read from the same DOM.
 *
 * `.bw-stage` is the div `BrowserWorkspace` measures and hands to
 * `browserBounds`, so its box is where a `WebContentsView` is, without anything
 * having to be published, registered or kept in sync. It is a slight
 * over-estimate on purpose: framed to a phone the view is a column inside the
 * stage rather than all of it, and a surface that avoids the whole stage has
 * avoided the view.
 *
 * `shell/Tooltips.tsx` is the reader. A tooltip hanging off the browser
 * toolbar has 9px of clearance above the page and needs 24, so it lands on the
 * page and is painted over — and {@link isCovered} cannot fix that, because
 * parking the page to reveal the bubble is the bug it just stopped doing. What
 * fixes it is putting the bubble somewhere it can be seen.
 */
export const NATIVE_VIEW_SELECTOR = '.bw-stage'

/* ------------------------------------------------------------- geometry -- */

/** Same rectangles, in the same order? */
export function sameRects(a: readonly Rect[], b: readonly Rect[]): boolean {
  if (a.length !== b.length) return false
  return a.every(
    (rect, index) =>
      rect.x === b[index].x &&
      rect.y === b[index].y &&
      rect.width === b[index].width &&
      rect.height === b[index].height,
  )
}

/**
 * The rectangle two boxes share, or `null` when they share none.
 *
 * Touching edges are not a share: a menu whose bottom edge is exactly the
 * page's top edge is beside the page, not on it, and a box with no area is
 * nowhere at all.
 */
export function overlap(a: Rect, b: Rect): Rect | null {
  if (a.width <= 0 || a.height <= 0 || b.width <= 0 || b.height <= 0) return null
  const x = Math.max(a.x, b.x)
  const y = Math.max(a.y, b.y)
  const right = Math.min(a.x + a.width, b.x + b.width)
  const bottom = Math.min(a.y + a.height, b.y + b.height)
  if (right <= x || bottom <= y) return null
  return { x, y, width: right - x, height: bottom - y }
}

/**
 * How far past one of the page's own edges a surface has to reach before it
 * counts as being *on* the page rather than clipping it.
 *
 * Measured, not guessed, in the built app on 2026-08-17 with a page loaded at
 * `{x: 845, y: 182, width: 587, height: 644}`:
 *
 *  - the tooltip on the browser toolbar's Cookies button lands at
 *    `{x: 1296, y: 179, width: 136, height: 24}`. The toolbar's buttons end 9px
 *    above the page and `placeTip` hangs a bubble 6px below its anchor, so the
 *    bubble starts 3px above the page and reaches **21px** into it.
 *  - the tooltip on the Shared/Isolated toggle, whose title is a three-line
 *    paragraph, lands at `{x: 1025, y: 179, width: 320, height: 68}` from the
 *    same row and reaches **64px** in.
 *
 * Those two are the whole judgement. The first is a corner clipped by the
 * arithmetic of where the toolbar happens to end; nothing is being *shown* on
 * the page. The second is a paragraph lying on the page, and a reader who
 * cannot see it has lost something real. 32 is the step of the 8pt grid
 * (`--sp-8`) that sits between them, with enough room above 21 that a longer
 * word wrapping a one-line bubble, or a larger type scale, does not tip it
 * over.
 */
const EDGE_GRAZE = 32

/**
 * Is the shared region only a shallow band flush with one of the page's edges?
 *
 * "Flush with an edge" is doing real work here and is not the same test as "the
 * shared region is small". A 1176×24 band lying across the *middle* of a page —
 * a banner, a toast, anything a future author portals into `<body>` — is just
 * as shallow and must still park the page, because every pixel of it would be
 * painted over. What makes the tooltip case different is not its size but its
 * position: it is hanging off the chrome above the page and has slipped over
 * the boundary, so the part of it that is on the page is the part nobody was
 * meant to be reading anyway.
 *
 * `shared` is already clipped into `stage` by {@link overlap}, so each of the
 * four distances below is zero or positive, and zero means "flush".
 */
function grazesTheEdge(stage: Rect, shared: Rect): boolean {
  const fromTop = shared.y - stage.y
  const fromBottom = stage.y + stage.height - (shared.y + shared.height)
  const fromLeft = shared.x - stage.x
  const fromRight = stage.x + stage.width - (shared.x + shared.width)

  if ((fromTop <= 0 || fromBottom <= 0) && shared.height <= EDGE_GRAZE) return true
  if ((fromLeft <= 0 || fromRight <= 0) && shared.width <= EDGE_GRAZE) return true
  return false
}

/**
 * Is the page's rectangle covered by anything?
 *
 * ## Why this is not "does anything intersect it"
 *
 * It was, and that made a 21-pixel tooltip blank a 587×644 website. Photographed
 * on 2026-08-17: hovering the Cookies button in the browser toolbar put a
 * 136×24 bubble across the page's top edge, `isCovered` answered true, and the
 * whole page went white until the pointer moved. It came back on its own, so
 * nothing was stranded — but for that second the app was showing a blank where a
 * loaded site is, which is precisely the class of bug the rest of this file
 * exists to remove: the UI reporting something that is not happening.
 *
 * So the question is what "over it" means, and the answer is not an area
 * threshold. Parking has to stay total for anything a person is meant to read
 * against the page — a dialog, the command palette, a menu opened over it — and
 * some of those are small. A menu is 420×313 and a paragraph tooltip is 320×68;
 * both are a rounding error next to the page and both must park it. What
 * separates them from the Cookies bubble is *where* their overlap sits: theirs
 * is on the page, the bubble's is a band along the page's own edge, no deeper
 * than the gap between the toolbar and the page. See {@link grazesTheEdge}.
 *
 * ## What this costs, said plainly, and where the other half of it is
 *
 * This function chooses which of the two things is visible and can never make
 * both be. Not parking for a graze means the page paints over the part of the
 * surface that is on it — for the Cookies bubble, 21 of its 24 pixels, leaving a
 * 3px sliver, which was photographed too. Trading a blanked website for an
 * unreadable hint would have been trading one instance of the complaint at the
 * top of this file for another.
 *
 * So the other half was fixed where it belongs, in *placement*: `placeTip` in
 * `shell/tooltip.ts` hangs a bubble below its anchor and already flips above
 * when the window is out of room below. It now counts a page's rectangle as
 * "no room" as well — see {@link NATIVE_VIEW_SELECTOR} — so a bubble on the
 * browser toolbar flips above it instead of under it, and both the page and the
 * hint are on screen. That is a better answer than either half alone, and it is
 * the reason this rule can afford to be generous about a graze: what still
 * grazes after it is something with no better side to go to.
 *
 * A rectangle with no area is never covered — that is a panel on a hidden tab
 * whose stage has not been measured, and reporting it as covered would park a
 * page for a reason that has nothing to do with overlays.
 */
export function isCovered(stage: Rect, overlays: readonly Rect[]): boolean {
  if (stage.width <= 0 || stage.height <= 0) return false
  return overlays.some((overlay) => {
    const shared = overlap(stage, overlay)
    return shared !== null && !grazesTheEdge(stage, shared)
  })
}

/* ---------------------------------------------------------- the surfaces -- */

/**
 * The slice of `Element` this reads.
 *
 * Structural rather than `Element` itself, because vitest runs this project in
 * Node with no DOM at all — a real element satisfies this, and so does a plain
 * object in a test. That is the whole reason the interesting half of this module
 * is testable.
 */
export interface OverlayElement {
  getBoundingClientRect(): { left: number; top: number; width: number; height: number }
  querySelector(selectors: string): OverlayElement | null
}

export interface OverlayBody {
  children: ArrayLike<OverlayElement>
}

function boxOf(element: OverlayElement): Rect | null {
  const box = element.getBoundingClientRect()
  if (box.width <= 0 || box.height <= 0) return null
  return { x: box.left, y: box.top, width: box.width, height: box.height }
}

/**
 * Rectangles for everything currently floating over the app.
 *
 * `appRoot` is the **body child the application is mounted inside** — `#root`,
 * not `.app`. That distinction is not pedantry: `.app` is a grandchild of
 * `<body>`, so an exclusion written against it matches none of `body.children`,
 * `#root` is counted as an overlay covering the entire window, and every browser
 * page is parked forever with nothing on screen to explain it. Typechecks
 * perfectly. `browserOverlayDom` is where the right element is found.
 *
 * Every rectangle it answers with was measured from the DOM it was handed, on
 * this call. There is no registry behind it that a caller can push into and
 * forget to empty, which is why a page can never be parked by something that is
 * no longer on screen.
 */
export function overlayRects(body: OverlayBody, appRoot: OverlayElement | null): Rect[] {
  const rects: Rect[] = []

  for (let index = 0; index < body.children.length; index++) {
    const child = body.children[index]
    if (child === appRoot) continue
    // A portal's container is often present and empty between openings — React
    // keeps the node and swaps its contents. An empty container has no box, and
    // treating it as a surface would park every page permanently.
    const box = boxOf(child)
    if (box) rects.push(box)
  }

  // The peeked rail, which is inside the app rather than portalled out of it.
  // `data-peek` is set by `Sidebar.tsx` only while the rail is floating, so its
  // presence IS the state — there is nothing to gate on, and querying for it is
  // not a dependency on that file's markup so much as on the one attribute its
  // own stylesheet already selects.
  const rail = appRoot?.querySelector('[data-peek]') ?? null
  const railBox = rail ? boxOf(rail) : null
  if (railBox) rects.push(railBox)

  return rects
}

/* -------------------------------------------------------------- watching -- */

/**
 * The document surface this needs, named rather than assumed.
 *
 * Everything in here is one call into a real browser API, which is what makes
 * it the part that is allowed to go untested in a Node test run.
 */
export interface OverlayDom {
  body: OverlayBody
  /**
   * The child of `<body>` the application is mounted inside.
   *
   * `#root`, not `.app`. See {@link overlayRects} for what happens when those
   * two are confused.
   */
  appRoot: OverlayElement | null
  observe(target: unknown, options: MutationObserverInit, run: () => void): () => void
  addEventListener(type: string, run: () => void): () => void
  frame(run: () => void): () => void
}

/**
 * The body child the application lives in.
 *
 * Found by containment rather than by name so it survives the harness, which
 * mounts the same `App` into a different container, and so it does not have to
 * know that `index.html` calls it `#root`.
 */
function appContainer(body: HTMLElement): Element | null {
  const app = body.querySelector('.app')
  if (app) {
    for (const child of Array.from(body.children)) {
      if (child === app || child.contains(app)) return child
    }
  }
  return body.firstElementChild
}

/** Build the real DOM surface. Null when there is no document to watch. */
export function browserOverlayDom(): OverlayDom | null {
  if (typeof document === 'undefined' || typeof window === 'undefined') return null
  const body = document.body
  if (!body) return null
  const appRoot = appContainer(body)

  return {
    body,
    appRoot,
    observe(target, options, run) {
      const observer = new MutationObserver(run)
      observer.observe(target as Node, options)
      return () => observer.disconnect()
    },
    addEventListener(type, run) {
      // Capturing: a menu that scrolls inside itself does not bubble its scroll
      // to the window, and the overlay it moves still has to be re-measured.
      window.addEventListener(type, run, true)
      return () => window.removeEventListener(type, run, true)
    },
    frame(run) {
      const handle = window.requestAnimationFrame(run)
      return () => window.cancelAnimationFrame(handle)
    },
  }
}

/**
 * Watch for floating surfaces and report their rectangles whenever they change.
 *
 * Two observers rather than one over the whole document, and that is not a
 * micro-optimisation: a subtree observer would fire on every character a
 * terminal prints, which is thousands of callbacks a second while an agent is
 * working.
 *
 *  - `body`'s child list catches portals opening and closing.
 *  - the app root's `data-sidebar-peek` catches the rail floating out.
 *
 * A scroll or a resize can move an overlay without changing either, so both are
 * listened for as well.
 *
 * The recompute is deferred a frame. A portal is mounted and *then* positioned
 * by a layout effect, so measuring it inside the mutation callback measures it
 * at 0,0 — which is over the sidebar, not over the page, and would have made
 * this miss every menu it exists to catch.
 */
export function watchOverlays(dom: OverlayDom, onChange: (rects: Rect[]) => void): () => void {
  let cancelFrame: (() => void) | null = null
  let stopped = false
  let last: Rect[] = []

  /*
   * Reported only when it genuinely changed.
   *
   * `scroll` is the reason this matters rather than being tidiness: it fires
   * continuously while any panel in the window is scrolled, and the consumer is
   * React state — so without this a scroll through a long file tree would be a
   * re-render of the browser workspace per frame, every frame, to arrive at the
   * same empty list each time.
   */
  const recompute = (): void => {
    cancelFrame = null
    if (stopped) return
    const rects = overlayRects(dom.body, dom.appRoot)
    if (sameRects(rects, last)) return
    last = rects
    onChange(rects)
  }

  const schedule = (): void => {
    if (stopped || cancelFrame) return
    cancelFrame = dom.frame(recompute)
  }

  const offBody = dom.observe(dom.body, { childList: true }, schedule)
  /*
   * `subtree`, and two attribute names, both of which are load-bearing.
   *
   * The rail is a descendant of the app container, not the container itself, so
   * a non-subtree observer would never see it. And `data-peek` alone is not
   * enough: the rail is *unmounted* while the sidebar is collapsed, so the first
   * peek from a collapsed state mounts an element that already has the
   * attribute — an insertion, never an attribute mutation. `data-sidebar-peek`
   * is written by `App.tsx` on an element that is never remounted, so it fires
   * for that case too. A filtered attribute observer is a string compare per
   * attribute write, which is why this can afford `subtree` where a childList
   * observer could not — that one would fire on every character a terminal
   * prints.
   */
  const offPeek = dom.appRoot
    ? dom.observe(
        dom.appRoot,
        { attributes: true, subtree: true, attributeFilter: ['data-sidebar-peek', 'data-peek'] },
        schedule,
      )
    : () => undefined
  const offScroll = dom.addEventListener('scroll', schedule)
  const offResize = dom.addEventListener('resize', schedule)

  schedule()

  return () => {
    stopped = true
    cancelFrame?.()
    cancelFrame = null
    offBody()
    offPeek()
    offScroll()
    offResize()
  }
}
