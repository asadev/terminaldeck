/**
 * A colour the reference CRM stores as a value — a dropdown option's swatch,
 * a field's tile — drawn in one of Terminal Deck's tokens instead.
 *
 * The stored value stays the CRM's own (its field rules check it is one of its
 * swatches); only the drawing changes, by the swatch's hue, the same families
 * the popup's stylesheet uses (`scripts/build-crm-task-css.mjs`).
 */
export function appColour(stored: string | null | undefined): string {
  const m = /^#?([0-9a-f]{6})$/i.exec((stored ?? '').trim())
  if (!m) return 'var(--accent)'
  const n = parseInt(m[1], 16)
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => c / 255)
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  const light = (max + min) / 2
  const chroma = max - min
  const saturation = chroma === 0 ? 0 : chroma / (1 - Math.abs(2 * light - 1))
  if (saturation < 0.15) return 'var(--text-muted)'
  let hue = max === r ? ((g - b) / chroma) % 6 : max === g ? (b - r) / chroma + 2 : (r - g) / chroma + 4
  hue = (hue * 60 + 360) % 360
  if (hue < 15 || hue >= 340) return 'var(--color-critical)'
  if (hue < 65) return 'var(--color-warning)'
  if (hue < 165) return 'var(--color-positive)'
  if (hue < 200) return 'var(--color-info)'
  if (hue < 265) return 'var(--accent)'
  if (hue < 300) return 'var(--bind-1)'
  return 'var(--bind-3)'
}

/** The app's text colour as the canvas can use it (a canvas cannot read a CSS variable itself). */
export function appInk(): string {
  const value = typeof document === 'undefined' ? '' : getComputedStyle(document.documentElement).getPropertyValue('--text-primary').trim()
  return value || 'black'
}
