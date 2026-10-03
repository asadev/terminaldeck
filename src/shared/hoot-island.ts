/**
 * The shape of Hoot's island, worked out as numbers.
 *
 * Asad, 2026-10-04, after a pill among the status items with a separate glass
 * panel under it: *"I want it to be like in center of the menu… not like next
 * to the other ones… should not be a separate drop down, should be part of it…
 * same color, same shape… dark black… attached, one single piece… From the
 * upside it can be smaller, from downside it can be bigger"* — and on a MacBook,
 * *"should not be hiding behind the notch… it will be in left and right of
 * notch… when we hover there then it comes outside."*
 *
 * So the island is one black shape hanging from the top edge of the screen, in
 * the middle of the menu bar. At rest it is a small pill as tall as the menu
 * bar — around the notch, where there is one, with the owl on the notch's left
 * and the words on its right. On hover the same shape grows down and out into
 * a wide, short panel. Its top corners curve outward into the menu bar (a
 * concave "shoulder", the way a MacBook's notch meets the screen's edge) and its
 * bottom corners are round, so it reads as part of the top of the screen and
 * not as a window floating under it.
 *
 * Shared because both halves need the same numbers: the page draws the shape
 * and animates between two of these, and the main process sizes and places the
 * window that holds it. Pure, so every number is pinned by a test.
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
  /** Each side of the notch keeps this much black past what it carries. */
  earPad: 10,
  minEar: 40,
  minWidth: 64,
  maxWidth: 260,
  radius: 12,
  shoulder: 6,
  minHeight: 22,
  maxHeight: 44,
} as const

/** The grown panel. A third of the screen across and short, the way the reference reads. */
export const EXPANDED = {
  share: 1 / 3,
  /** About two fifths of a 14-inch MacBook — room for three columns that each say something. */
  minWidth: 620,
  maxWidth: 720,
  /** Under the menu-bar-high header row. */
  minBody: 92,
  maxHeight: 260,
  radius: 22,
  shoulder: 10,
  /** Kept clear of the screen's edges on a narrow display. */
  edge: 16,
} as const

/** The soft shadow under the grown panel needs room in the window around the shape. */
export const SHADOW = { side: 28, bottom: 40 } as const

const clamp = (value: number, low: number, high: number): number => Math.min(high, Math.max(low, value))

/** How tall the island's top row is: the menu bar, or the notch where there is one. */
export function barRow(geometry: IslandGeometry): number {
  return Math.round(clamp(geometry.notch?.height ?? geometry.barHeight, REST.minHeight, REST.maxHeight))
}

/**
 * The resting pill, for a label of this width.
 *
 * Without a notch: owl, the attention dot when something waits, the words —
 * as wide as they need. With one: as wide as the notch plus an "ear" each side,
 * the same on both so it stays centred on the camera; the owl sits in the left
 * ear and the words in the right one, and nothing is drawn where the housing
 * would hide it.
 */
export function restShape(geometry: IslandGeometry, label: { textWidth: number; attention: boolean }): IslandShape {
  const height = barRow(geometry)
  const dot = label.attention ? REST.dot + REST.dotGap : 0
  const text = Math.max(0, Math.ceil(label.textWidth))
  if (geometry.notch !== null) {
    const left = REST.owl + REST.earPad * 2
    const right = dot + text + REST.earPad * 2
    const ear = Math.max(REST.minEar, left, right)
    return { width: Math.round(geometry.notch.width + ear * 2), height, radius: REST.radius, shoulder: REST.shoulder }
  }
  const natural = REST.padLeft + REST.owl + REST.gap + dot + text + REST.padRight
  return {
    width: Math.round(clamp(natural, REST.minWidth, REST.maxWidth)),
    height,
    radius: Math.min(REST.radius, height / 2),
    shoulder: REST.shoulder,
  }
}

/** The grown panel, for content this tall (under the top row). */
export function expandedShape(geometry: IslandGeometry, bodyHeight: number, rest?: IslandShape): IslandShape {
  const row = barRow(geometry)
  const room = Math.max(320, geometry.displayWidth - EXPANDED.edge * 2 - EXPANDED.shoulder * 2)
  const wanted = clamp(Math.round(geometry.displayWidth * EXPANDED.share), EXPANDED.minWidth, EXPANDED.maxWidth)
  const width = Math.min(room, Math.max(wanted, (rest?.width ?? 0) + 48))
  const height = clamp(row + Math.max(EXPANDED.minBody, Math.ceil(bodyHeight)), row + EXPANDED.minBody, EXPANDED.maxHeight)
  return { width: Math.round(width), height: Math.round(height), radius: EXPANDED.radius, shoulder: EXPANDED.shoulder }
}

/** The window that holds a shape: the body, its shoulders, and the shadow's room when it has one. */
export function windowBox(shape: IslandShape, shadow: boolean): { width: number; height: number } {
  return {
    width: Math.ceil(shape.width + shape.shoulder * 2 + (shadow ? SHADOW.side * 2 : 0)),
    height: Math.ceil(shape.height + (shadow ? SHADOW.bottom : 0)),
  }
}

/** The smallest box holding both — the window while the shape moves between two sizes. */
export function unionBox(
  a: { width: number; height: number },
  b: { width: number; height: number },
): { width: number; height: number } {
  return { width: Math.max(a.width, b.width), height: Math.max(a.height, b.height) }
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
 * The window's frame: centred on the island's centre, its top on the top edge
 * of the display — inside the menu bar, not under it — and kept on the display.
 */
export function placeIsland(display: Rect, centre: number, box: { width: number; height: number }): Rect {
  const width = Math.min(Math.round(box.width), display.width)
  const height = Math.min(Math.round(box.height), display.height)
  const x = Math.round(clamp(centre - width / 2, display.x, display.x + display.width - width))
  return { x, y: display.y, width, height }
}

/* ------------------------------------------------------------------- motion -- */

export interface Spring {
  value: number
  velocity: number
}

export interface SpringConfig {
  stiffness: number
  damping: number
}

/** Growing: quick, with a little give at the end — the island's "bounce". */
export const SPRING_OPEN: SpringConfig = { stiffness: 420, damping: 30 }
/** Settling back: as quick, without the overshoot that would dip it under its resting size. */
export const SPRING_CLOSE: SpringConfig = { stiffness: 460, damping: 40 }

/**
 * One frame of a spring toward a target, in steps short enough to stay stable
 * however long the frame was — a frame missed under load becomes a few small
 * steps, not one wild one.
 */
export function springStep(spring: Spring, target: number, seconds: number, config: SpringConfig): Spring {
  let { value, velocity } = spring
  let left = Math.min(Math.max(0, seconds), 0.1)
  while (left > 0) {
    const dt = Math.min(left, 1 / 240)
    const force = -config.stiffness * (value - target) - config.damping * velocity
    velocity += force * dt
    value += velocity * dt
    left -= dt
  }
  return { value, velocity }
}

/** Close enough to stop: under half a point away and barely moving. */
export function springSettled(spring: Spring, target: number): boolean {
  return Math.abs(spring.value - target) < 0.5 && Math.abs(spring.velocity) < 4
}

/** How far a shape is from resting toward grown, 0 to 1, by height. */
export function grownness(height: number, rest: number, grown: number): number {
  if (grown <= rest) return height > rest ? 1 : 0
  return clamp((height - rest) / (grown - rest), 0, 1)
}
