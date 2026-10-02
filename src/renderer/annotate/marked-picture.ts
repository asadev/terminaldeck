import type { Annotation } from '../../shared/annotate'
import type { NormRect } from '../../shared/device-tree'

/**
 * The picture an agent receives: the frozen screen with the numbered markers
 * drawn on it, at the screen's own resolution.
 *
 * ## Why the markers are burnt in
 *
 * The message names each note by its number — `#2 button "Pay" …` — and the
 * agent opens the picture to see which one that is. Markers drawn only on the
 * page, as HTML over an image, would be visible to the person and absent from
 * the file. So the file is drawn from scratch, here, from the same rectangles
 * the page draws, and the two pictures agree because they are made from one
 * list.
 *
 * Proportional sizes for the same reason `browser/marks.ts` gives: the outline
 * that reads as a marker pen on a 400px preview is a hairline on a 1206px
 * phone screenshot, so every size is a fraction of the picture's shorter side.
 */

export interface MarkerGeometry {
  /** The element's outline, in picture pixels. */
  box: { x: number; y: number; width: number; height: number }
  /** The numbered disc, at the outline's top-left corner and kept inside the picture. */
  badge: { cx: number; cy: number; r: number }
  stroke: number
}

export function markerGeometry(rect: NormRect, width: number, height: number): MarkerGeometry {
  const short = Math.max(1, Math.min(width, height))
  const stroke = Math.max(2, Math.round(short / 220))
  const r = Math.max(9, Math.round(short / 34))
  const box = {
    x: rect.x * width,
    y: rect.y * height,
    width: Math.max(rect.width * width, 1),
    height: Math.max(rect.height * height, 1),
  }
  // On the corner, but never off the picture: an element flush with the top of
  // the screen — a navigation bar, almost always — would otherwise have its
  // number cut in half by the edge, which is the one place the eye looks for it.
  const cx = Math.min(Math.max(box.x, r + stroke), width - r - stroke)
  const cy = Math.min(Math.max(box.y, r + stroke), height - r - stroke)
  return { box, badge: { cx, cy, r }, stroke }
}

/** Colours, resolved from the stylesheet so `tokens.css` stays the only place they are written. */
export interface MarkerInk {
  accent: string
  onAccent: string
}

/** What a canvas needs to be asked for, so the drawing is testable without one. */
export interface PictureContext {
  strokeStyle: string | CanvasGradient | CanvasPattern
  fillStyle: string | CanvasGradient | CanvasPattern
  lineWidth: number
  font: string
  textAlign: CanvasTextAlign
  textBaseline: CanvasTextBaseline
  beginPath(): void
  rect(x: number, y: number, w: number, h: number): void
  arc(x: number, y: number, r: number, start: number, end: number): void
  stroke(): void
  fill(): void
  fillText(text: string, x: number, y: number): void
}

/** A halo under every line, so a marker reads over a white page and a black one alike. */
const HALO = 'rgba(255, 255, 255, 0.9)'

export function paintMarkers(
  ctx: PictureContext,
  annotations: readonly Annotation[],
  width: number,
  height: number,
  ink: MarkerInk,
): void {
  for (const entry of annotations) {
    const { box, badge, stroke } = markerGeometry(entry.rect, width, height)
    for (const pass of [
      { style: HALO, weight: stroke + Math.max(2, stroke) },
      { style: ink.accent, weight: stroke },
    ]) {
      ctx.strokeStyle = pass.style
      ctx.lineWidth = pass.weight
      ctx.beginPath()
      ctx.rect(box.x, box.y, box.width, box.height)
      ctx.stroke()
    }
    ctx.beginPath()
    ctx.arc(badge.cx, badge.cy, badge.r + Math.max(1, stroke / 2), 0, Math.PI * 2)
    ctx.fillStyle = HALO
    ctx.fill()
    ctx.beginPath()
    ctx.arc(badge.cx, badge.cy, badge.r, 0, Math.PI * 2)
    ctx.fillStyle = ink.accent
    ctx.fill()
    ctx.fillStyle = ink.onAccent
    ctx.font = `600 ${Math.round(badge.r * 1.15)}px -apple-system, system-ui, sans-serif`
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillText(String(entry.n), badge.cx, badge.cy + 0.5)
  }
}

/** Load an image from a data URL. */
function load(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const image = new Image()
    image.onload = () => resolve(image)
    image.onerror = () => reject(new Error('The frozen picture could not be read.'))
    image.src = src
  })
}

/**
 * Draw the marked picture and answer it as a PNG `data:` URL, or null.
 *
 * Null rather than a throw: a picture that could not be drawn is a send that
 * does not happen, and `SendToAgent` already says so in one line.
 */
export async function drawMarkedPicture(
  src: string,
  annotations: readonly Annotation[],
  ink: MarkerInk,
): Promise<{ png: string; width: number; height: number } | null> {
  try {
    const image = await load(src)
    const width = image.naturalWidth
    const height = image.naturalHeight
    if (width === 0 || height === 0) return null
    const canvas = document.createElement('canvas')
    canvas.width = width
    canvas.height = height
    const ctx = canvas.getContext('2d')
    if (!ctx) return null
    ctx.drawImage(image, 0, 0, width, height)
    paintMarkers(ctx, annotations, width, height, ink)
    return { png: canvas.toDataURL('image/png'), width, height }
  } catch {
    return null
  }
}

/** The accent and the ink on it, read from a node that wears them. */
export function inkOf(node: Element | null): MarkerInk {
  // Keywords, never a hex: this only answers when there is no stylesheet at
  // all, which is a test, and the real colours live in `tokens.css`.
  if (!node || typeof getComputedStyle !== 'function') return { accent: 'blue', onAccent: 'white' }
  const style = getComputedStyle(node)
  // `--accent` and `--accent-fg` are resolved through `color` and
  // `background-color` on the element whose stylesheet sets them, the same
  // trick `browser/marks.ts` uses — a canvas needs a string, not a variable.
  return { accent: style.backgroundColor || 'blue', onAccent: style.color || 'white' }
}
