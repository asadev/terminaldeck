/**
 * What a mark drawn over a page is, and how it is painted.
 *
 * ## Why this is a whole module and not a `<canvas>` with a mousemove handler
 *
 * He asked for it in one sentence, in passing, right after complaining that
 * record mode was not working: *"So this draw option we need to have also, and
 * we can send it to the agent like this."* That sentence is easy to read as "add
 * a paint program", and it is not one. What a person does when they report a
 * bug is circle the broken part, put an arrow at it, and hand the picture over.
 * So there are exactly three shapes, one colour, and an undo, and everything
 * else that a drawing tool could have is deliberately absent.
 *
 * The interesting half of that is testable and the canvas half is not, so they
 * are split: this file owns the model and the painting rules, `DrawLayer.tsx`
 * owns the element and the pointer. This project's test run has no DOM, which is
 * exactly why {@link paintMarks} takes a structural {@link MarkContext} rather
 * than a `CanvasRenderingContext2D` — a real context satisfies it, and so does a
 * recorder in a test, which is the only way the arrow head and the halo can be
 * held down at all.
 *
 * ## Coordinates are fractions, not pixels
 *
 * Every point is 0..1 of the frame it was drawn on. There are three different
 * pixel sizes in play — the CSS box the canvas is displayed at, the canvas'
 * backing store, and the PNG that ends up on disk — and storing pixels would
 * mean picking one and converting at every other boundary. Fractions mean the
 * same marks paint correctly at any size, and the picture the agent receives is
 * the picture he drew, which is the entire point of the feature.
 */

/** A point on the frame, as a fraction of its width and height. */
export interface Point {
  x: number
  y: number
}

/**
 * The three shapes, and why there are three.
 *
 * `free` is the circle-it-roughly gesture nobody can do with a rectangle.
 * `rect` is for "this region", which freehand does badly and everyone tries
 * anyway. `arrow` is for "that one, there" — the thing a rectangle round a 12px
 * icon cannot say. A fourth would be text, which needs a font, a size, an
 * editing caret and a colour picker, and that is the paint program.
 */
export type MarkKind = 'free' | 'rect' | 'arrow'

export interface Mark {
  kind: MarkKind
  /**
   * For `free`, every sampled point along the stroke. For `rect` and `arrow`,
   * exactly two: where the drag began and where it is now.
   */
  points: Point[]
}

/**
 * How far apart two sampled points must be before the second is kept, as a
 * fraction of the frame.
 *
 * A pointermove fires per frame while the pointer is down, so a slow careful
 * circle over four seconds is a few hundred points, most of them a third of a
 * pixel apart. Dropping the ones that add nothing keeps a stroke to a size that
 * survives being re-painted on every move without the line looking sampled —
 * 0.0015 of a 2000px frame is three pixels, which is under the width of the
 * stroke itself.
 */
const SAMPLE_STEP = 0.0015

/**
 * The shortest drag that counts as a mark, as a fraction of the frame.
 *
 * Below this it was a click, not a drag — the pointer moved while the button was
 * going down, which every trackpad does. Keeping those leaves invisible specks
 * in the picture that Undo then has to be pressed for, once each, with nothing
 * disappearing from the screen. That is the worst failure this tool could have:
 * a control that appears not to work.
 */
const MIN_DRAG = 0.004

function distance(a: Point, b: Point): number {
  return Math.hypot(b.x - a.x, b.y - a.y)
}

/** Clamp a point onto the frame. A drag can leave the canvas and come back. */
export function onFrame(point: Point): Point {
  return {
    x: Math.min(1, Math.max(0, point.x)),
    y: Math.min(1, Math.max(0, point.y)),
  }
}

/** A new mark of this kind, starting where the pointer went down. */
export function beginMark(kind: MarkKind, at: Point): Mark {
  const start = onFrame(at)
  return { kind, points: [start, start] }
}

/**
 * The mark as it is after the pointer has moved to `at`.
 *
 * A new object every time rather than a mutation, because this is React state
 * and a mutated array does not re-render. Freehand grows; the other two have two
 * points forever and the second one follows the pointer.
 */
export function extendMark(mark: Mark, at: Point): Mark {
  const next = onFrame(at)
  if (mark.kind !== 'free') return { kind: mark.kind, points: [mark.points[0], next] }

  const last = mark.points[mark.points.length - 1]
  if (distance(last, next) < SAMPLE_STEP) return mark
  return { kind: 'free', points: [...mark.points, next] }
}

/**
 * Is this worth keeping once the pointer comes up?
 *
 * Freehand is judged on the whole path rather than on end-to-end distance,
 * because a circle ends where it started and end-to-end would throw away the one
 * gesture this tool exists for.
 */
export function isDrawn(mark: Mark): boolean {
  if (mark.kind === 'free') {
    let travelled = 0
    for (let i = 1; i < mark.points.length; i++) travelled += distance(mark.points[i - 1], mark.points[i])
    return travelled >= MIN_DRAG
  }
  return distance(mark.points[0], mark.points[mark.points.length - 1]) >= MIN_DRAG
}

/** The last mark, gone. Undo, and the only editing this tool has. */
export function undoMark(marks: readonly Mark[]): Mark[] {
  return marks.slice(0, -1)
}

/* ----------------------------------------------------------------- painting -- */

/**
 * The slice of a 2D canvas context the painter uses.
 *
 * Structural, so that a plain object in a test satisfies it — this project runs
 * vitest in Node with no DOM, and a painter that could only be exercised against
 * a real canvas would be a painter with no tests. `strokeStyle` is `unknown`
 * because the real one is `string | CanvasGradient | CanvasPattern` and naming
 * it `string` here would make a real context fail to satisfy the interface.
 */
export interface MarkContext {
  lineWidth: number
  lineCap: string
  lineJoin: string
  strokeStyle: unknown
  beginPath(): void
  moveTo(x: number, y: number): void
  lineTo(x: number, y: number): void
  stroke(): void
}

/**
 * The halo drawn under every mark, and why it is a literal rather than a token.
 *
 * `tokens.css` is the only place a colour of *this app* may be written, and this
 * is not one. It is drawn on top of a photograph of somebody else's website, in
 * whatever colours that site happens to use, and it has one job: make a red line
 * legible on a red button. A near-opaque white outline does that on every
 * background there is, and it must not change with Terminal Deck's theme —
 * the page underneath does not change with it either. A dark-theme halo would
 * vanish over a dark site while the app looked right, which is the failure this
 * exists to prevent.
 */
const HALO = 'rgba(255, 255, 255, 0.92)'

/**
 * How wide a stroke is, in pixels of the frame being painted.
 *
 * Proportional rather than fixed: the same marks are painted onto a canvas the
 * size of the page on screen and onto a PNG at the capture's own resolution, and
 * a fixed 3px would be a hairline in the file that gets sent. A 2000px-wide
 * capture gets 4px, which is the weight a marker pen has against body text.
 */
export function strokeWidth(frameWidth: number): number {
  return Math.max(2, Math.round(frameWidth / 500))
}

/** How long an arrow's head is, in pixels, given the shaft it belongs to. */
export function headLength(shaftLength: number, frameWidth: number): number {
  // Proportional to the shaft so a short arrow is not all head, capped so a
  // long one does not grow a head the size of the thing it points at.
  return Math.min(shaftLength * 0.32, frameWidth * 0.035)
}

/** The angle an arrow head's barbs open at, either side of the shaft. */
const HEAD_SPREAD = 0.42

/** The two barb ends of an arrow head pointing from `from` to `to`, in pixels. */
export function arrowHead(from: Point, to: Point, frameWidth: number): [Point, Point] {
  const shaft = Math.hypot(to.x - from.x, to.y - from.y)
  const angle = Math.atan2(to.y - from.y, to.x - from.x)
  const length = headLength(shaft, frameWidth)
  return [
    { x: to.x - length * Math.cos(angle - HEAD_SPREAD), y: to.y - length * Math.sin(angle - HEAD_SPREAD) },
    { x: to.x - length * Math.cos(angle + HEAD_SPREAD), y: to.y - length * Math.sin(angle + HEAD_SPREAD) },
  ]
}

/** One mark's outline, in frame pixels, as the polylines that draw it. */
export function markPaths(mark: Mark, width: number, height: number): Point[][] {
  const at = (point: Point): Point => ({ x: point.x * width, y: point.y * height })
  const first = at(mark.points[0])
  const last = at(mark.points[mark.points.length - 1])

  if (mark.kind === 'free') return [mark.points.map(at)]
  if (mark.kind === 'rect') {
    return [
      [
        first,
        { x: last.x, y: first.y },
        last,
        { x: first.x, y: last.y },
        first,
      ],
    ]
  }
  const [left, right] = arrowHead(first, last, width)
  // The head as one unbroken polyline through the tip, so the join is mitred
  // rather than two lines crossing — a V drawn as two strokes has a notch at the
  // point, which is exactly where the eye is being sent.
  return [[first, last], [left, last, right]]
}

/**
 * Paint every mark onto a frame `width` x `height` pixels.
 *
 * Twice per mark, halo first: an outline nobody notices is what makes the colour
 * readable over an arbitrary website. Doing all the halos before all the colours
 * would be wrong — a later mark's halo would erase an earlier mark's line where
 * they cross, which is common, because people scribble over the same spot.
 */
export function paintMarks(
  ctx: MarkContext,
  marks: readonly Mark[],
  width: number,
  height: number,
  color: string,
): void {
  const line = strokeWidth(width)
  ctx.lineCap = 'round'
  ctx.lineJoin = 'round'

  for (const mark of marks) {
    const paths = markPaths(mark, width, height)
    for (const pass of [
      { style: HALO, weight: line + Math.max(2, Math.round(line * 0.9)) },
      { style: color, weight: line },
    ]) {
      ctx.strokeStyle = pass.style
      ctx.lineWidth = pass.weight
      for (const path of paths) {
        if (path.length < 2) continue
        ctx.beginPath()
        ctx.moveTo(path[0].x, path[0].y)
        for (let i = 1; i < path.length; i++) ctx.lineTo(path[i].x, path[i].y)
        ctx.stroke()
      }
    }
  }
}

/**
 * The colour marks are drawn in, read off the canvas element itself.
 *
 * Not a constant here, and not `getPropertyValue('--color-critical')` either.
 * The stylesheet gives `.bw-draw` a `color` of `var(--color-critical)`, and this
 * reads the *resolved* value back — so `tokens.css` remains the only place the
 * colour is written, the theme switch is followed for free, and there is no
 * second copy of a hex code in a TypeScript file to go stale. A canvas needs a
 * string rather than a class, which is the only reason this crosses over at all.
 *
 * Red because it is what every person marking up a screenshot reaches for, and
 * because it is the one colour in this palette that never means "fine".
 */
export function markColor(node: Element): string {
  if (typeof getComputedStyle !== 'function') return ''
  return getComputedStyle(node).color
}
