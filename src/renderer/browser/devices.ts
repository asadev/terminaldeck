/**
 * Responsive sizing for the guest view.
 *
 * ## Why this is arithmetic and not a CSS transform
 *
 * The obvious way to build a device picker is to scale a screenshot, and it is
 * useless: the page never re-lays-out, so a media query never fires and what you
 * are looking at is a small picture of the desktop site. Here the numbers below
 * become the *bounds of the real Chromium view*, so a 390px phone frame is a
 * 390px viewport — `@media (max-width: 480px)` fires, the mobile nav appears,
 * and what is on screen is what a phone would render.
 *
 * The consequence is that a device cannot be bigger than the space it is being
 * shown in. A native view is a layer floating over the window, so an oversized
 * one would paint across the rest of the app rather than overflow with a
 * scrollbar. {@link fitInto} clamps instead, and says that it did — a device bar
 * claiming 1440px while showing 1100px is a lie the layout you are checking will
 * be built on.
 */

export interface Size {
  width: number
  height: number
}

export interface Rect extends Size {
  x: number
  y: number
}

export interface DevicePreset {
  id: string
  label: string
  /** Portrait dimensions. Landscape is the same numbers the other way up. */
  width: number
  height: number
  group: 'phone' | 'tablet' | 'desktop'
}

/**
 * Sizes rather than model names: a device list with brand names in it goes
 * stale every September and implies a fidelity this does not have. These are
 * the widths that CSS breakpoints are actually written against.
 */
export const DEVICE_PRESETS: DevicePreset[] = [
  { id: 'phone-sm', label: 'Phone, small', width: 375, height: 667, group: 'phone' },
  { id: 'phone', label: 'Phone', width: 390, height: 844, group: 'phone' },
  { id: 'tablet', label: 'Tablet', width: 768, height: 1024, group: 'tablet' },
  { id: 'tablet-lg', label: 'Tablet, large', width: 1024, height: 1366, group: 'tablet' },
  { id: 'laptop', label: 'Laptop', width: 1280, height: 800, group: 'desktop' },
  { id: 'desktop', label: 'Desktop', width: 1440, height: 900, group: 'desktop' },
]

/** The pseudo-preset that means "no frame, use whatever room there is". */
export const FIT_ID = 'fit'

export type Orientation = 'portrait' | 'landscape'

export function presetById(id: string): DevicePreset | null {
  return DEVICE_PRESETS.find((preset) => preset.id === id) ?? null
}

/** Rotating is swapping the two numbers. There is nothing else to it. */
export function sizeFor(size: Size, orientation: Orientation): Size {
  return orientation === 'landscape' ? { width: size.height, height: size.width } : { ...size }
}

export interface Fit {
  /** Where to put the guest view, in the same CSS pixels the container is in. */
  rect: Rect
  /** What the page will actually get, after clamping. */
  applied: Size
  /** The requested size did not fit and was cut down. */
  clamped: boolean
}

/**
 * Place a device-sized viewport inside the space available.
 *
 * Centred horizontally and pinned to the top: a page is read from the top down,
 * and vertically centring a phone frame in a short panel hides the header, which
 * is the part being checked.
 */
export function fitInto(container: Rect, size: Size | null): Fit {
  if (!size) {
    return {
      rect: { ...container },
      applied: { width: container.width, height: container.height },
      clamped: false,
    }
  }

  const width = Math.min(size.width, container.width)
  const height = Math.min(size.height, container.height)
  return {
    rect: {
      x: container.x + Math.round((container.width - width) / 2),
      y: container.y,
      width,
      height,
    },
    applied: { width, height },
    clamped: width < size.width || height < size.height,
  }
}

/** Narrower than this is not a phone, wider is not a screen anyone has. */
export const MIN_DIMENSION = 200
export const MAX_DIMENSION = 4000

/** Read a custom width or height out of a text field. Null while it is unusable. */
export function parseDimension(raw: string): number | null {
  const digits = raw.trim()
  if (!/^\d{1,5}$/.test(digits)) return null
  const value = Number(digits)
  if (value < MIN_DIMENSION || value > MAX_DIMENSION) return null
  return value
}

/**
 * A phone-shaped viewport is not a phone.
 *
 * Sites that branch on the User-Agent rather than on width — payment flows and
 * app-install banners especially — will still serve the desktop build at 390px.
 * This is offered as an explicit toggle rather than tied to the phone preset,
 * because changing the User-Agent can also break a session that was established
 * under the real one, and that surprise belongs to the user.
 */
export const MOBILE_USER_AGENT =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'

/** Zoom steps, matching what Chromium's own zoom menu offers. */
export const ZOOM_STEPS = [0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 2] as const

export function stepZoom(current: number, delta: number): number {
  const steps = ZOOM_STEPS
  // Nearest step, so a zoom restored from a previous session (Chromium persists
  // it per origin) still steps sensibly instead of jumping to 100%.
  let nearest = 0
  for (let i = 1; i < steps.length; i++) {
    if (Math.abs(steps[i] - current) < Math.abs(steps[nearest] - current)) nearest = i
  }
  const next = Math.min(steps.length - 1, Math.max(0, nearest + delta))
  return steps[next]
}
