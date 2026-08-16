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
 * Anything that is neither can register itself through {@link holdOverlay},
 * which is a real seam rather than a promise: it takes a rectangle, so it goes
 * through the same intersection test as everything else.
 */

export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

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

/** Do two rectangles share any area at all? Touching edges do not count. */
export function intersects(a: Rect, b: Rect): boolean {
  if (a.width <= 0 || a.height <= 0 || b.width <= 0 || b.height <= 0) return false
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

/**
 * Is the page's rectangle covered by anything?
 *
 * A rectangle with no area is never covered — that is a panel on a hidden tab
 * whose stage has not been measured, and reporting it as covered would park a
 * page for a reason that has nothing to do with overlays.
 */
export function isCovered(stage: Rect, overlays: readonly Rect[]): boolean {
  if (stage.width <= 0 || stage.height <= 0) return false
  return overlays.some((overlay) => intersects(stage, overlay))
}

/* ---------------------------------------------------------- the surfaces -- */

/**
 * Surfaces that are neither portalled nor the peeked rail.
 *
 * Empty today, and deliberately kept: the alternative to a seam is that the next
 * floating surface rediscovers this whole problem from scratch. A rectangle
 * rather than a boolean, so a registered surface is judged by the same
 * intersection rule as everything else instead of blanking the page outright.
 */
const held: Rect[] = []

/** Register a floating surface. Call the returned function when it closes. */
export function holdOverlay(rect: Rect): () => void {
  held.push(rect)
  return () => {
    const index = held.indexOf(rect)
    if (index >= 0) held.splice(index, 1)
  }
}

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

  return rects.concat(held)
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
