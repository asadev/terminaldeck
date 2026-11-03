/**
 * Rectangles, in window CSS pixels, and the four operations the focus overlay
 * needs on them.
 *
 * ## Why this is its own file, and why every function in it is pure
 *
 * The focus overlay has to point at three completely different kinds of thing —
 * a range of lines inside an xterm buffer, a React element in the chat view, and
 * a native browser page composited above the whole renderer. There is no
 * coordinate system those three share except the one the window itself has, so
 * every adapter's job is to end at a `Rect` in window CSS pixels and every
 * consumer's job is to start from one.
 *
 * That leaves the interesting arithmetic — clipping a region that has scrolled
 * half off the top of a terminal, deciding which of its four borders are still
 * real edges rather than cut lines, growing a box so it does not sit on the
 * glyphs it is pointing at — in one place with no DOM in it. Every one of those
 * has a wrong answer that looks right in a diff and is obvious on screen, which
 * is exactly the class of bug `CLAUDE.md` says compiling does not catch. Pure
 * functions are the only part of this feature a test can hold still.
 *
 * The unit is **window CSS pixels**, matching `getBoundingClientRect()` and
 * matching what `position: fixed` consumes, so the overlay never converts.
 * `overlay-watch.ts` uses the same convention and the same field names for the
 * same reason; this deliberately does not import its `Rect` because that module
 * is about parking native views and a shared type would tie a geometry helper to
 * a browser concern.
 */

export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

/**
 * Which sides of a clipped rectangle are the region's own edge rather than a
 * cut made by the container.
 *
 * This exists because of one specific visual defect. A terminal region that has
 * scrolled halfway off the top of the pane must not be drawn with a border
 * across its top: that border is not the top of anything, it is the top of the
 * *viewport*, and drawing it there tells the reader the highlighted passage
 * begins at a line where it does not. xterm's own decoration renderer hits the
 * same problem and answers it by hiding the decoration outright
 * (`display: none` once the marker line leaves the viewport) — which is worse,
 * because eighteen visible lines of a nineteen-line region vanish along with
 * the one that scrolled away.
 *
 * So: clip, then draw only the edges that survived the clip.
 */
export interface RectEdges {
  top: boolean
  right: boolean
  bottom: boolean
  left: boolean
}

export const ALL_EDGES: RectEdges = { top: true, right: true, bottom: true, left: true }

/** A rectangle plus which of its borders are genuine edges. */
export interface ClippedRect {
  rect: Rect
  edges: RectEdges
}

/** Does this rectangle enclose any pixels at all? */
export function hasArea(rect: Rect): boolean {
  return rect.width > 0 && rect.height > 0
}

/** Same rectangle, to within a pixel of `getBoundingClientRect()` noise? */
export function sameRect(a: Rect | null, b: Rect | null): boolean {
  if (a === null || b === null) return a === b
  /*
   * A tolerance, and it is load-bearing rather than sloppy.
   *
   * `getBoundingClientRect()` reports at 1/64 px, and xterm's row height here
   * measures 22.5078125 against a computed 22.5152 — a sixteenth of a pixel of
   * disagreement that arrives *every frame*. Comparing exactly would mean the
   * overlay set React state sixty times a second while nothing moved, which is
   * the polling loop this design is built to avoid. Half a pixel is below what
   * anyone can see and above what rounding can produce.
   */
  const EPSILON = 0.5
  return (
    Math.abs(a.x - b.x) < EPSILON &&
    Math.abs(a.y - b.y) < EPSILON &&
    Math.abs(a.width - b.width) < EPSILON &&
    Math.abs(a.height - b.height) < EPSILON
  )
}

export function sameEdges(a: RectEdges, b: RectEdges): boolean {
  return a.top === b.top && a.right === b.right && a.bottom === b.bottom && a.left === b.left
}

/** The smallest rectangle containing all of them, or null if there are none. */
export function unionRect(rects: readonly Rect[]): Rect | null {
  let out: Rect | null = null
  for (const rect of rects) {
    if (!hasArea(rect)) continue
    if (out === null) {
      out = { ...rect }
      continue
    }
    const left = Math.min(out.x, rect.x)
    const top = Math.min(out.y, rect.y)
    const right = Math.max(out.x + out.width, rect.x + rect.width)
    const bottom = Math.max(out.y + out.height, rect.y + rect.height)
    out = { x: left, y: top, width: right - left, height: bottom - top }
  }
  return out
}

/**
 * Grow (or, with a negative number, shrink) a rectangle on every side.
 *
 * The overlay grows every content rectangle by a few pixels before drawing,
 * and the reason is the whole lesson of `browser-preload.ts`: a highlight that
 * lands *on* what it is pointing at hides it. That file used to paint a 16 %
 * wash over the element and the note left behind when it was torn out says the
 * element read as "being *replaced* by a pale blue rectangle… You cannot see
 * what you are pointing at, which is the one thing an element picker exists
 * for." A one-pixel outline solves the fill half of that. The padding solves
 * the other half: an outline drawn exactly on a glyph's bounding box still
 * clips the descenders of the line above and below it.
 */
export function padRect(rect: Rect, pad: number): Rect {
  return {
    x: rect.x - pad,
    y: rect.y - pad,
    width: rect.width + pad * 2,
    height: rect.height + pad * 2,
  }
}

/**
 * The part of `rect` inside `bounds`, and which of its edges survived.
 *
 * Returns `null` when nothing survives — which is not an error but a state the
 * caller has to handle: a terminal region that has scrolled entirely out of the
 * viewport, or a chat message scrolled past. The overlay's answer is to stop
 * drawing rather than to draw at the edge, because a box clamped to the top of
 * a pane claims the content is there when it is not.
 */
export function clipRect(rect: Rect, bounds: Rect): ClippedRect | null {
  const left = Math.max(rect.x, bounds.x)
  const top = Math.max(rect.y, bounds.y)
  const right = Math.min(rect.x + rect.width, bounds.x + bounds.width)
  const bottom = Math.min(rect.y + rect.height, bounds.y + bounds.height)
  if (right <= left || bottom <= top) return null
  return {
    rect: { x: left, y: top, width: right - left, height: bottom - top },
    edges: {
      /*
       * An edge is real when the clip did not move it. The comparison is
       * `>=`/`<=` rather than `===` so a region that fits with room to spare
       * keeps all four, and one that lines up exactly with the container's edge
       * — a region at the very top of a full pane — also keeps them, because in
       * that case the region's edge and the container's edge are the same line
       * and it is the region's.
       */
      top: rect.y >= bounds.y,
      left: rect.x >= bounds.x,
      right: rect.x + rect.width <= bounds.x + bounds.width,
      bottom: rect.y + rect.height <= bounds.y + bounds.height,
    },
  }
}

/** A DOM element's box, in the same units as everything else here. */
export function rectOf(element: {
  getBoundingClientRect(): { left: number; top: number; width: number; height: number }
}): Rect {
  const box = element.getBoundingClientRect()
  return { x: box.left, y: box.top, width: box.width, height: box.height }
}

/**
 * Is every pixel this overlay paints outside `keepClear`?
 *
 * Exists for one caller and one rule, and the rule is physics rather than
 * taste. A browser page in this app is a `WebContentsView` — a native child of
 * the window, composited **above** the renderer's entire surface. Nothing in
 * the DOM can be painted on top of one; `overlay-watch.ts` is the essay and it
 * has been rediscovered twice.
 *
 * So when the thing being focused *is* a browser page, the overlay works around
 * it: the hole is the page's own rectangle, and the ring is drawn outside that
 * hole rather than inside it. Every pixel then lands on the app's own chrome,
 * where HTML does composite, and the page underneath stays live, interactive
 * and at full brightness — which is what "this is the thing to look at" is
 * supposed to mean.
 *
 * The check is here, and tested, because getting it wrong fails silently: the
 * misplaced pixels are simply not composited, so the bug is invisible on screen
 * and shows up later as "why is there a gap in the ring".
 */
export function outsideOf(paint: readonly Rect[], keepClear: Rect): boolean {
  return paint.every((rect) => {
    if (!hasArea(rect)) return true
    return (
      rect.x + rect.width <= keepClear.x ||
      rect.x >= keepClear.x + keepClear.width ||
      rect.y + rect.height <= keepClear.y ||
      rect.y >= keepClear.y + keepClear.height
    )
  })
}

/**
 * How the ring should be drawn when some of its edges are cuts rather than
 * edges.
 *
 * Suppressing the border colour on a cut side is not quite enough, and the gap
 * was only visible once it was on screen at 4x. The ring also carries a 3-pixel
 * glow, painted by a `box-shadow` that wraps all four sides — so a region
 * scrolled off the top of a pane still had a soft blue arc across its top, and
 * rounded corners under it, which together read as a closed box whose top
 * border had failed to paint rather than as a passage continuing off screen.
 *
 * Two changes, both derived from the same edge flags:
 *
 *  - **`clipPath`** trims the glow flush to any cut side. `inset()` with a
 *    negative value lets the shadow through, `0px` cuts it off at the border
 *    box, so the string is just the edge flags rendered as four numbers.
 *  - **`borderRadius`** squares the two corners either side of a cut. A rounded
 *    corner is the shape of something that ends; a square one is the shape of
 *    something that was sliced.
 */
export function ringStyle(
  edges: RectEdges,
  radius: number,
  glow: number,
): { clipPath: string | undefined; borderRadius: string } {
  const side = (whole: boolean): string => (whole ? `${-glow}px` : '0px')
  const clipPath = allEdges(edges)
    ? undefined
    : `inset(${side(edges.top)} ${side(edges.right)} ${side(edges.bottom)} ${side(edges.left)})`

  const corner = (a: boolean, b: boolean): string => (a && b ? `${radius}px` : '0px')
  const borderRadius =
    radius === 0
      ? '0px'
      : [
          corner(edges.top, edges.left),
          corner(edges.top, edges.right),
          corner(edges.bottom, edges.right),
          corner(edges.bottom, edges.left),
        ].join(' ')

  return { clipPath, borderRadius }
}

export function allEdges(edges: RectEdges): boolean {
  return edges.top && edges.right && edges.bottom && edges.left
}

/**
 * The four bands an outline of `weight` occupies around a rectangle.
 *
 * The overlay draws its ring with CSS `outline`, which paints *outside* the
 * border box and takes no part in layout — chosen over `border` for exactly the
 * reason above, since a border is inside the box and would land on a browser
 * page's first row of pixels. This returns the same four bands so a test can
 * assert the choice held rather than trusting the CSS to keep meaning what it
 * meant.
 */
export function outlineBands(rect: Rect, weight: number): Rect[] {
  return [
    { x: rect.x - weight, y: rect.y - weight, width: rect.width + weight * 2, height: weight },
    { x: rect.x - weight, y: rect.y + rect.height, width: rect.width + weight * 2, height: weight },
    { x: rect.x - weight, y: rect.y, width: weight, height: rect.height },
    { x: rect.x + rect.width, y: rect.y, width: weight, height: rect.height },
  ]
}
