import { BrowserWindow, nativeImage } from 'electron'
import { HOOT_TRAY_ICONS } from './hoot-tray-icons'

/**
 * Hoot's menu bar item, drawn as a pill: a near-black capsule — the shape of a
 * MacBook's notch — with the orange owl on the left and one short line on the
 * right.
 *
 * Asad, 2026-10-04, looking at the first menu bar version: *"i still dont see
 * hoot as notch style pill in the menu i see it only an icon like other normal
 * apps"*. A status item is an image and an optional title, and a title is drawn
 * by macOS in the menu bar's own colour on no background — so the pill has to
 * be the image. This file paints it.
 *
 * ## Painted in a renderer, because text needs one
 *
 * The main process has no canvas, and the line has to be set in the system's
 * own typeface at its real width. So a hidden, offscreen window holds an empty
 * page, and {@link PILL_PAINT_SOURCE} runs in it: measure the text, size the
 * capsule to fit, draw the owl and the words, and hand back PNGs at 1x and 2x.
 * Every result is kept by what it shows, so a blink — the same pill with the
 * eyes shut — costs one round trip the first time and an image swap after.
 *
 * ## Why its colours are fixed
 *
 * The rule against raw colours (`CLAUDE.md`) is about the app's chrome, which
 * must follow its theme. This is a status item drawn into the menu bar of every
 * app on the Mac, on light, dark and wallpaper-tinted bars alike, and it has to
 * be the same dark capsule on all of them — the way the notch it imitates is
 * black whatever the screen shows. A faint light edge is what keeps it from
 * vanishing on a dark bar. It is a non-template image so macOS leaves it alone.
 */

/** Points. A status item is at most 22 tall; the capsule uses all of it. */
export const PILL_HEIGHT = 22
/** Narrower than this and it reads as a dot, not a pill. */
export const PILL_MIN_WIDTH = 56
/** Wider than this and it crowds other people's icons off the menu bar. */
export const PILL_MAX_WIDTH = 190

/** One pill: what it says, whether it is asking for attention, and Hoot's eyes. */
export interface PillSpec {
  text: string
  attention: boolean
  eyes: 'open' | 'closed'
  /**
   * A fixed width, for the frames between two widths while it grows or
   * settles. Absent: as wide as its own text needs.
   */
  width?: number
}

/** A painted pill. `image` is opaque here so the controller can be tested without Electron. */
export interface PillFrame {
  width: number
  image: unknown
}

/**
 * The painter, as source text, run in the hidden page with `executeJavaScript`.
 *
 * A string rather than a function's `toString()`, because the bundler is free to
 * rewrite a function — rename it, wrap it in a helper — and the page would then
 * receive code that refers to things that do not exist there.
 */
export const PILL_PAINT_SOURCE = `async (input) => {
  const H = ${PILL_HEIGHT}, PAD_L = 3, OWL = 18, GAP = 5, PAD_R = 10, DOT = 6, DOT_GAP = 5
  const font = '600 12px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif'
  const probe = document.createElement('canvas').getContext('2d')
  probe.font = font
  const textW = Math.ceil(probe.measureText(input.text).width)
  const natural = PAD_L + OWL + GAP + (input.attention ? DOT + DOT_GAP : 0) + textW + PAD_R
  const W = Math.round(Math.min(input.max, Math.max(input.min, input.width ?? natural)))
  const blob = await (await fetch('data:image/png;base64,' + input.owl)).blob()
  const owl = await createImageBitmap(blob)
  const capsule = (ctx, x, y, w, h) => {
    const r = h / 2
    ctx.beginPath()
    ctx.moveTo(x + r, y)
    ctx.lineTo(x + w - r, y)
    ctx.arc(x + w - r, y + r, r, -Math.PI / 2, Math.PI / 2)
    ctx.lineTo(x + r, y + h)
    ctx.arc(x + r, y + r, r, Math.PI / 2, (3 * Math.PI) / 2)
    ctx.closePath()
  }
  const draw = (scale) => {
    const canvas = document.createElement('canvas')
    canvas.width = W * scale
    canvas.height = H * scale
    const ctx = canvas.getContext('2d')
    ctx.scale(scale, scale)
    capsule(ctx, 0.5, 0.5, W - 1, H - 1)
    ctx.fillStyle = '#121212'
    ctx.fill()
    ctx.lineWidth = 1
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.16)'
    ctx.stroke()
    ctx.save()
    capsule(ctx, 1, 1, W - 2, H - 2)
    ctx.clip()
    ctx.drawImage(owl, PAD_L, (H - OWL) / 2, OWL, OWL)
    let x = PAD_L + OWL + GAP
    if (input.attention) {
      ctx.beginPath()
      ctx.arc(x + DOT / 2, H / 2, DOT / 2, 0, Math.PI * 2)
      ctx.fillStyle = '#F7882F'
      ctx.fill()
      x += DOT + DOT_GAP
    }
    ctx.font = font
    ctx.textBaseline = 'middle'
    ctx.fillStyle = 'rgba(255, 255, 255, 0.94)'
    ctx.fillText(input.text, x, H / 2 + 0.5)
    // While it grows, the words run under a soft fade at the right-hand end
    // rather than being cut off square.
    if (W < natural) {
      const fade = ctx.createLinearGradient(W - PAD_R - 14, 0, W - 2, 0)
      fade.addColorStop(0, 'rgba(18, 18, 18, 0)')
      fade.addColorStop(1, 'rgba(18, 18, 18, 1)')
      ctx.fillStyle = fade
      ctx.fillRect(W - PAD_R - 14, 0, PAD_R + 14, H)
    }
    ctx.restore()
    return canvas.toDataURL('image/png')
  }
  return { width: W, natural, x1: draw(1), x2: draw(2) }
}`

/** What the page answers. */
interface Painted {
  width: number
  natural: number
  x1: string
  x2: string
}

export interface PillPainter {
  paint(spec: PillSpec): Promise<PillFrame | null>
  /** The PNGs of one painted pill, for a look at it outside the menu bar. */
  png(spec: PillSpec): Promise<{ x1: Buffer; x2: Buffer; width: number } | null>
  dispose(): void
}

/** How many painted pills are kept. A blink is two; a moment's growth, a handful more. */
const KEEP = 48

/**
 * The painter on a hidden offscreen window, made on first use and remade if it
 * is closed — going to the background closes every window, this one included.
 */
export function createPillPainter(): PillPainter {
  let window: BrowserWindow | null = null
  let loading: Promise<void> | null = null
  const kept = new Map<string, { frame: PillFrame; painted: Painted }>()

  async function page(): Promise<BrowserWindow> {
    if (window === null || window.isDestroyed()) {
      window = new BrowserWindow({
        show: false,
        width: 64,
        height: 32,
        skipTaskbar: true,
        focusable: false,
        webPreferences: { offscreen: true, contextIsolation: true, sandbox: true, nodeIntegration: false },
      })
      loading = window.loadURL('data:text/html;charset=utf-8,<!doctype html><title>pill</title>').then(() => undefined)
    }
    await loading
    return window
  }

  async function painted(spec: PillSpec): Promise<{ frame: PillFrame; painted: Painted } | null> {
    const key = JSON.stringify(spec)
    const hit = kept.get(key)
    if (hit) return hit
    try {
      const target = await page()
      const input = {
        text: spec.text,
        attention: spec.attention,
        width: spec.width,
        min: PILL_MIN_WIDTH,
        max: PILL_MAX_WIDTH,
        owl: HOOT_TRAY_ICONS[spec.eyes].colour2x,
      }
      const result = (await target.webContents.executeJavaScript(
        `(${PILL_PAINT_SOURCE})(${JSON.stringify(input)})`,
      )) as Painted
      const image = nativeImage.createEmpty()
      image.addRepresentation({ scaleFactor: 1, dataURL: result.x1 })
      image.addRepresentation({ scaleFactor: 2, dataURL: result.x2 })
      image.setTemplateImage(false)
      const entry = { frame: { width: result.width, image }, painted: result }
      kept.set(key, entry)
      while (kept.size > KEEP) {
        const oldest = kept.keys().next().value
        if (oldest === undefined) break
        kept.delete(oldest)
      }
      return entry
    } catch {
      // A pill that could not be painted leaves the last one showing — the
      // owl is still there to hover. Nothing to tell anybody.
      return null
    }
  }

  return {
    paint: async (spec) => (await painted(spec))?.frame ?? null,
    png: async (spec) => {
      const entry = await painted(spec)
      if (entry === null) return null
      const decode = (url: string): Buffer => Buffer.from(url.slice(url.indexOf(',') + 1), 'base64')
      return { x1: decode(entry.painted.x1), x2: decode(entry.painted.x2), width: entry.painted.width }
    },
    dispose: () => {
      if (window !== null && !window.isDestroyed()) window.destroy()
      window = null
      kept.clear()
    },
  }
}

/** Ease out, so a pill that grows arrives gently rather than stopping dead. */
function easeOut(t: number): number {
  return 1 - (1 - t) ** 3
}

/** The widths a pill passes through on its way from one width to another, ending at the second. */
export function widthsBetween(from: number, to: number, steps: number): number[] {
  if (steps <= 1 || from === to) return [to]
  return Array.from({ length: steps }, (_, i) => Math.round(from + (to - from) * easeOut((i + 1) / steps)))
}
