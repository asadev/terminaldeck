/**
 * The shape of Hoot's island, worked out as numbers.
 *
 * Asad, 2026-10-04, after a pill among the status items with a separate glass
 * panel under it: *"I want it to be like in center of the menu… not like next
 * to the other ones… should not be a separate drop down, should be part of it…
 * same color, same shape… attached, one single piece… From the upside it can
 * be smaller, from downside it can be bigger"* — and on a MacBook, *"should not
 * be hiding behind the notch… it will be in left and right of notch… when we
 * hover there then it comes outside."*
 *
 * So the island is one shape hanging from the top edge of the screen, in the
 * middle of the menu bar. At rest it is a small pill as tall as the menu bar —
 * around the notch, where there is one, with the owl on the notch's left and
 * the words on its right. On hover the same shape grows down and out into a
 * wide, short panel. Its top corners curve outward into the menu bar (a concave
 * "shoulder", the way a MacBook's notch meets the screen's edge) and its bottom
 * corners are round, so it reads as part of the top of the screen and not as a
 * window floating under it. The whole outline is one path ({@link islandPath}),
 * so the pill and the panel are never two pieces.
 *
 * ## One window that never moves
 *
 * His second recording (2026-10-04, frame by frame) caught the first version
 * resizing its window for each state: for one frame the resting pill was drawn
 * 315 points left of centre — the page had laid itself out for the small window
 * while the window server still showed the big one. Two processes can never be
 * made to agree on the same frame, so the window no longer changes at all while
 * anything moves: it is one fixed, transparent box ({@link islandWindow}), as big
 * as the grown panel and its shadow, centred at the top of the screen, and the
 * shape changes inside it. Nothing about it depends on how wide the window is
 * except where its middle is, and that is fixed.
 *
 * Shared because both halves need the same numbers: the page draws the shape and
 * animates it, and the main process sizes and places the window that holds it.
 * Pure, so every number is pinned by a test.
 */

/** The display the island lives on, as far as its shape cares. */
export interface IslandNotch {
  /** Points from the display's left edge to the notch's left edge. */
  left: number
  width: number
  height: number
}

export interface IslandGeometry {
  /** How tall the menu bar is on that display, in points. */
  barHeight: number
  displayWidth: number
  /** The camera housing, on a MacBook that has one. Null on every other screen. */
  notch: IslandNotch | null
}

/** One state of the shape: its body, the radius of its bottom corners, and its shoulders. */
export interface IslandShape {
  width: number
  height: number
  /** The bottom corners. */
  radius: number
  /** The concave curve at each top corner, flaring this far out into the menu bar. */
  shoulder: number
}

/** The resting pill's insides, in points. */
export const REST = {
  padLeft: 8,
  owl: 18,
  gap: 6,
  dot: 6,
  dotGap: 5,
  padRight: 12,
  /** Each side of the notch keeps this much past what it carries. */
  earPad: 10,
  minEar: 40,
  minWidth: 64,
  maxWidth: 300,
  radius: 12,
  shoulder: 6,
  minHeight: 22,
  maxHeight: 44,
} as const

/**
 * The grown panel. About a third of the screen across and short by default,
 * the way his reference reads — and his to resize, by the grips at its bottom
 * corners, between the smallest that still holds a conversation and the
 * largest the window was made for. The size he leaves it at is the size it
 * opens at.
 */
export const EXPANDED = {
  share: 1 / 3,
  /** The default width: a third of the screen, between these. */
  defaultMinWidth: 620,
  defaultMaxWidth: 720,
  defaultHeight: 260,
  /** What a drag may make it. */
  minWidth: 420,
  maxWidth: 960,
  minHeight: 180,
  maxHeight: 520,
  radius: 22,
  shoulder: 10,
  /** Kept clear of the screen's edges on a narrow display. */
  edge: 16,
} as const

/**
 * The soft shadow under the grown panel needs room in the window around the
 * shape: three of its blurs (12 points, a standard deviation) each side, and
 * its 8-point drop below — or the window's edge cuts it off in a hard line.
 */
export const SHADOW = { side: 44, bottom: 56 } as const

/** The widest resting pill stays this far inside the widest panel the window holds. */
const GROWS_BY = 48

const clamp = (value: number, low: number, high: number): number => Math.min(high, Math.max(low, value))

/** How tall the island's top row is: the menu bar, or the notch where there is one. */
export function barRow(geometry: IslandGeometry): number {
  return Math.round(clamp(geometry.notch?.height ?? geometry.barHeight, REST.minHeight, REST.maxHeight))
}

/** The sizes the grown panel may take on this display — what a drag is held between. */
export function expandedLimits(geometry: IslandGeometry): {
  minWidth: number
  maxWidth: number
  minHeight: number
  maxHeight: number
} {
  const room = Math.max(320, geometry.displayWidth - EXPANDED.edge * 2 - EXPANDED.shoulder * 2)
  const maxWidth = Math.round(Math.min(room, EXPANDED.maxWidth))
  return {
    minWidth: Math.min(EXPANDED.minWidth, maxWidth),
    maxWidth,
    minHeight: Math.max(EXPANDED.minHeight, barRow(geometry) + 120),
    maxHeight: EXPANDED.maxHeight,
  }
}

/** The grown panel's size by default on this display: a third of it across, and short. */
export function defaultExpanded(geometry: IslandGeometry): { width: number; height: number } {
  const limits = expandedLimits(geometry)
  const third = clamp(Math.round(geometry.displayWidth * EXPANDED.share), EXPANDED.defaultMinWidth, EXPANDED.defaultMaxWidth)
  return { width: Math.min(limits.maxWidth, third), height: EXPANDED.defaultHeight }
}

/** A size held inside the limits — a drag past them, or a remembered size from a bigger screen. */
export function clampExpanded(
  geometry: IslandGeometry,
  size: { width: number; height: number },
): { width: number; height: number } {
  const limits = expandedLimits(geometry)
  return {
    width: Math.round(clamp(size.width, limits.minWidth, limits.maxWidth)),
    height: Math.round(clamp(size.height, limits.minHeight, limits.maxHeight)),
  }
}

/**
 * The resting pill, for a label of this width.
 *
 * Without a notch: owl, the attention dot when something waits, the words —
 * as wide as they need. With one: as wide as the notch plus an "ear" each side,
 * the same on both so it stays centred on the camera. The owl sits in the left
 * ear — with the first of the counts beside it, `leftWidth`, so the two ears
 * carry about the same and neither is a long empty stretch — and the rest of
 * the words in the right one; nothing is drawn where the housing would hide
 * it. Never wider than the window the island lives in.
 */
export function restShape(
  geometry: IslandGeometry,
  label: { textWidth: number; attention: boolean; leftWidth?: number },
): IslandShape {
  const height = barRow(geometry)
  const dot = label.attention ? REST.dot + REST.dotGap : 0
  const text = Math.max(0, Math.ceil(label.textWidth))
  const cap = expandedLimits(geometry).maxWidth - GROWS_BY
  if (geometry.notch !== null) {
    const beside = Math.max(0, Math.ceil(label.leftWidth ?? 0))
    const left = REST.owl + (beside > 0 ? REST.gap + beside : 0) + REST.earPad * 2
    const right = dot + text + REST.earPad * 2
    const ear = Math.max(REST.minEar, left, right)
    return {
      width: Math.round(Math.min(cap, geometry.notch.width + ear * 2)),
      height,
      radius: REST.radius,
      shoulder: REST.shoulder,
    }
  }
  const natural = REST.padLeft + REST.owl + REST.gap + dot + text + REST.padRight
  return {
    width: Math.round(Math.min(cap, clamp(natural, REST.minWidth, REST.maxWidth))),
    height,
    radius: Math.min(REST.radius, height / 2),
    shoulder: REST.shoulder,
  }
}

/** The grown panel: at the size he left it, or by default. */
export function expandedShape(geometry: IslandGeometry, size: { width: number; height: number } | null): IslandShape {
  const { width, height } = size ? clampExpanded(geometry, size) : defaultExpanded(geometry)
  return { width, height, radius: EXPANDED.radius, shoulder: EXPANDED.shoulder }
}

/**
 * The island's window: big enough for the largest panel a drag can make, its
 * shoulders and its shadow, whatever the shape is doing. Fixed for a display —
 * it changes only when the display does, never while the shape moves or is
 * dragged.
 */
export function islandWindow(geometry: IslandGeometry): { width: number; height: number } {
  const limits = expandedLimits(geometry)
  return {
    width: limits.maxWidth + EXPANDED.shoulder * 2 + SHADOW.side * 2,
    height: limits.maxHeight + SHADOW.bottom,
  }
}

/** The box a resting pill covers, shoulders included — where a pointer counts as "on it". */
export function restBox(shape: IslandShape): { width: number; height: number } {
  return { width: Math.ceil(shape.width + shape.shoulder * 2), height: Math.ceil(shape.height) }
}

export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

/** Where the island is centred across: on the notch where there is one, else the display's middle. */
export function islandCentre(display: Rect, notch: IslandNotch | null): number {
  return notch === null ? display.x + display.width / 2 : display.x + notch.left + notch.width / 2
}

/**
 * A window's frame: centred on the island's centre, its top on the top edge of
 * the display — inside the menu bar, not under it — and kept on the display.
 */
export function placeIsland(display: Rect, centre: number, box: { width: number; height: number }): Rect {
  const width = Math.min(Math.round(box.width), display.width)
  const height = Math.min(Math.round(box.height), display.height)
  const x = Math.round(clamp(centre - width / 2, display.x, display.x + display.width - width))
  return { x, y: display.y, width, height }
}

/**
 * The island's outline as one SVG path, centred on `centre`, hanging from y = 0:
 * the left shoulder curving in from the menu bar, down the side, the round
 * bottom corners, up the other side and out along the right shoulder. One path
 * is one piece — there is no edge anywhere for a seam to be.
 */
export function islandPath(shape: IslandShape, centre: number): string {
  const w = Math.max(0, shape.width)
  const h = Math.max(0, shape.height)
  const r = Math.max(0, Math.min(shape.radius, h, w / 2))
  const s = Math.max(0, Math.min(shape.shoulder, h - r))
  const left = centre - w / 2
  const right = centre + w / 2
  const n = (value: number): string => (Math.round(value * 100) / 100).toString()
  return [
    `M ${n(left - s)} 0`,
    `A ${n(s)} ${n(s)} 0 0 1 ${n(left)} ${n(s)}`,
    `L ${n(left)} ${n(h - r)}`,
    `A ${n(r)} ${n(r)} 0 0 0 ${n(left + r)} ${n(h)}`,
    `L ${n(right - r)} ${n(h)}`,
    `A ${n(r)} ${n(r)} 0 0 0 ${n(right)} ${n(h - r)}`,
    `L ${n(right)} ${n(s)}`,
    `A ${n(s)} ${n(s)} 0 0 1 ${n(right + s)} 0`,
    'Z',
  ].join(' ')
}

/* ------------------------------------------------------------------- motion -- */

/**
 * The timings, in milliseconds: when each part starts and stops moving.
 *
 * Asad, 2026-10-04, second round: *"quick expand and quick collapse but
 * smoothly"*. Growing takes 220 ms; the panel's words fade in only once the
 * shape is most of the way there, so text is never seen being cut. Settling
 * takes 240: the words fade first, the shape eases in, the pill's own words
 * come back as it lands. A change of the pill's words — a moment, a count —
 * reshapes it in 220.
 *
 * They are CSS transitions — the outline (`clip-path`), the shadow
 * (`transform`, `opacity`) and the words (`opacity`) — so the browser runs them
 * on its own clock, with nothing laid out again and nothing in this app's
 * JavaScript on the way. A busy Mac slows a page's scripts long before it
 * slows that.
 */
export const TIMING = {
  open: { shape: [0, 220], full: [120, 220], rest: [0, 60] },
  close: { shape: [40, 240], full: [0, 70], rest: [180, 240] },
  reshape: { shape: [0, 220], rest: [0, 140] },
} as const

/** Growing: fast away, gentle landing, never past the target. */
export const EASE_OPEN = 'cubic-bezier(0.22, 1, 0.36, 1)'
/** Settling: as gentle away as it lands, never past the target. */
export const EASE_CLOSE = 'cubic-bezier(0.45, 0, 0.2, 1)'

/** One CSS transition for a property over a span [from, to]. */
export function transition(property: string, span: readonly [number, number], easing: string): string {
  const [from, to] = span
  return `${property} ${Math.max(0, to - from)}ms ${easing} ${from}ms`
}

/** A shape between two others, `t` of the way — what a transition between two outlines passes through. */
export function mixShape(from: IslandShape, to: IslandShape, t: number): IslandShape {
  const mix = (a: number, b: number): number => a + (b - a) * t
  return {
    width: mix(from.width, to.width),
    height: mix(from.height, to.height),
    radius: mix(from.radius, to.radius),
    shoulder: mix(from.shoulder, to.shoulder),
  }
}

/**
 * The outline one point bigger all round — the hairline drawn behind the shape,
 * so it keeps its edge on a menu bar of its own colour. The same commands as
 * the shape's own outline, so the two move together.
 */
export function edgeShape(shape: IslandShape): IslandShape {
  return { width: shape.width + 2, height: shape.height + 1, radius: shape.radius + 1, shoulder: shape.shoulder }
}
