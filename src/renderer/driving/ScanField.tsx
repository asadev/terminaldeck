import { useEffect, useRef } from 'react'
import './ScanField.css'

/**
 * The dots — what the machine looks like while it is working.
 *
 * Asad, 2026-08-17, on what driving mode should look like once it stopped being
 * a read-along:
 *
 *   > *"Some dots around it or kind of things happening, interactive UI, maybe
 *   > WebGL… we can see like a machine is working, a proper feel of high-speed
 *   > intelligence."*
 *
 * and the sentence that decides the whole geometry:
 *
 *   > **The non-focused areas carry the dots treatment; the focus is what stays
 *   > clear.**
 *
 * That is the inverse of a spotlight and it is easy to build backwards. A
 * spotlight puts the effect *on* the thing it is pointing at, and the effect
 * then competes with the content — which is the mistake the browser inspector in
 * this app already made once and was rewritten on camera for: a wash over the
 * element meant *"you cannot see what you are pointing at, which is the one
 * thing an element picker exists for."* Here the field paints everywhere the
 * focus is not, and the focus rectangle is cut out of it entirely — so the
 * quoted words are the one part of the window with nothing over them at all.
 *
 * ## Why a 2D canvas rather than WebGL
 *
 * He said "maybe WebGL", which is a description of how it should feel rather
 * than a technology choice, so the choice is made on cost. This window already
 * runs one WebGL context per terminal — xterm's renderer — and browser tabs are
 * separate composited views on top. Chromium caps live WebGL contexts per
 * process and evicts the oldest when the cap is hit, which on this app means
 * *a terminal loses its renderer* to make room for a decoration. A 2D canvas has
 * no such cap, needs no shader, and at this particle count is not the expensive
 * thing on screen by any margin — the expensive thing is the fleet of terminals
 * underneath it, which is precisely why the scrim is a `box-shadow` and not a
 * `filter`.
 *
 * ## Nothing here is pre-scripted, and that is a rule
 *
 * A canvas animation that looks like intelligence and is not would be the worst
 * thing in this codebase. So every input to this component is a fact about a
 * scan that is actually happening:
 *
 *  - it only exists while a real scan is playing;
 *  - the hole is the **measured rectangle of the real quoted text**, chased by
 *    `useFocusResolution` as the pane scrolls and the terminal repaints;
 *  - a pulse fires on a real arrival at a real stop, so a scan that stalls, is
 *    held, or is waiting on a session that will not resolve produces a field
 *    that visibly stops surging;
 *  - the share of the field drawn in the accent colour is `seen / count` — how
 *    much of the fleet has actually been visited. The field fills up because the
 *    scan is getting through the sessions, not because time is passing.
 *
 * If the scan is doing nothing, this shows nothing happening. That is the whole
 * standard it has to meet.
 */

export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

interface Props {
  /**
   * The hole: the focus rectangle in window coordinates, or null for none.
   *
   * A **box read every frame**, not a prop value, and that is deliberate. The
   * rectangle is re-measured whenever a terminal repaints, which on a streaming
   * session is every frame; passing it as a prop would re-render this component
   * and the panel beside it sixty times a second to move a hole the canvas is
   * going to redraw anyway. The overlay writes into the box, this reads it.
   */
  hole: { readonly current: Rect | null }
  /** True while a scan is playing. False takes the field off. */
  active: boolean
  /** Stops arrived at so far, and how many there are. Drives the lit fraction. */
  seen: number
  count: number
  /**
   * Bumped on every arrival. A change is what fires the surge.
   *
   * A counter rather than the stop index, because a scan can revisit an index —
   * stepping back, or jumping into the trace — and a surge has to happen every
   * time the machine lands somewhere, not only when the number goes up.
   */
  pulse: number
}

/* ------------------------------------------------------------- constants -- */

/**
 * How much window area each dot gets.
 *
 * At 14 000 px² a 1440 × 900 window carries about 90 dots and a large external
 * display about 200. Chosen by what it has to *read* as rather than by cost: a
 * field sparse enough that the individual dots are legible as dots, dense enough
 * that the links between them form a mesh rather than a few stray threads. Below
 * roughly 60 the mesh breaks up into unrelated specks; above 250 it reads as
 * noise and starts to compete with the text underneath it, which is the one
 * thing the dulled area still has to let you do — see the contrast budget in
 * `dim-budget.ts`.
 */
export const AREA_PER_DOT = 14_000
export const MIN_DOTS = 60
export const MAX_DOTS = 250

/**
 * How close two dots must be before a line is drawn between them.
 *
 * The mesh is what makes this read as a system rather than as falling snow. 120
 * px against the density above gives each dot two or three neighbours on
 * average — enough to see structure, few enough that the whole thing does not
 * turn into a grey sheet over the app.
 */
export const LINK_DIST = 130

/**
 * How long one surge takes to decay.
 *
 * A stop is held for 260 ms (`shared/scan.ts`), so the surge has to be over
 * before the next one starts or they smear into a constant glow and stop
 * marking anything. 220 ms leaves a visible gap at the end of every stop, which
 * is what makes the field *pulse* per session rather than merely shimmer.
 */
export const PULSE_MS = 220

/** Fallbacks for the two tokens, used only if the stylesheet cannot be read. */
const FALLBACK_ACCENT = { r: 59, g: 143, b: 238 }
const FALLBACK_DIM = { r: 140, g: 140, b: 140 }

interface Rgb {
  r: number
  g: number
  b: number
}

interface Dot {
  x: number
  y: number
  vx: number
  vy: number
  /** 0…1, fixed per dot. Below the lit fraction it is drawn in the accent. */
  rank: number
  radius: number
}

/**
 * A CSS colour as three channels, for the two shapes tokens.css actually uses.
 *
 * Hex and `rgb()` only, because those are the two `getComputedStyle` hands back
 * for a custom property holding a colour in this app. Anything else falls back
 * rather than throwing: a field in the wrong grey is a cosmetic fault, and an
 * exception inside a canvas frame loop is a window that stops painting.
 */
export function readColour(value: string, fallback: Rgb): Rgb {
  const text = value.trim()
  const hex = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(text)
  if (hex !== null) {
    const digits = hex[1]
    const wide =
      digits.length === 3
        ? digits
            .split('')
            .map((d) => d + d)
            .join('')
        : digits
    return {
      r: parseInt(wide.slice(0, 2), 16),
      g: parseInt(wide.slice(2, 4), 16),
      b: parseInt(wide.slice(4, 6), 16),
    }
  }
  const rgb = /^rgba?\(\s*([0-9.]+)[\s,]+([0-9.]+)[\s,]+([0-9.]+)/i.exec(text)
  if (rgb !== null) {
    return { r: Number(rgb[1]), g: Number(rgb[2]), b: Number(rgb[3]) }
  }
  return fallback
}

export function ScanField({ hole, active, seen, count, pulse }: Props) {
  const canvas = useRef<HTMLCanvasElement | null>(null)
  /*
   * Everything the frame loop reads lives in a ref, deliberately.
   *
   * The props change several times a second — the hole is re-measured whenever
   * a terminal repaints — and restarting the loop on each one would throw the
   * dots away and re-seed them mid-scan, which on screen is the field blinking
   * every time a session prints a line. So the effect that owns the loop runs
   * once, and the props are handed to it through a box it reads each frame.
   */
  const live = useRef({ active, seen, count, pulse })
  live.current = { active, seen, count, pulse }

  /*
   * `active` is the only dependency, and it has to be one.
   *
   * The canvas is not in the tree while nothing is scanning — an always-mounted
   * frame loop over a fleet of terminals is exactly the cost this feature is
   * careful about everywhere else — so an effect with an empty dependency list
   * would run once, find no canvas, and never run again. Every scan after the
   * first would then draw nothing, which is the kind of defect that survives a
   * clean typecheck and a clean console and is only ever found by looking.
   *
   * Re-seeding per scan is correct rather than tolerated: a new scan is a new
   * field, and dots left over from the last one carry no information about this
   * one.
   */
  useEffect(() => {
    if (!active) return
    const element = canvas.current
    if (element === null) return
    const context = element.getContext('2d')
    if (context === null) return

    const reduced =
      typeof window.matchMedia === 'function' &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches

    let dots: Dot[] = []
    let width = 0
    let height = 0
    let ratio = 1
    let accent = FALLBACK_ACCENT
    let dim = FALLBACK_DIM
    let frame = 0
    let lastPulse = live.current.pulse
    let pulseAt = -Infinity
    let previous = 0

    /**
     * Re-read the two tokens.
     *
     * Canvas cannot resolve a CSS variable, so the values are pulled off the
     * root element — which means they follow the theme, since `tokens.css`
     * redefines both under `[data-theme]`. Re-read on every resize as the
     * cheapest place to catch a theme swap without a second observer: a theme
     * change in this app also changes the window's own painting, and the field
     * is regenerated whenever the layout does.
     */
    const readTokens = (): void => {
      const style = getComputedStyle(document.documentElement)
      accent = readColour(style.getPropertyValue('--accent'), FALLBACK_ACCENT)
      dim = readColour(style.getPropertyValue('--text-muted'), FALLBACK_DIM)
    }

    const seed = (): void => {
      const target = Math.min(
        MAX_DOTS,
        Math.max(MIN_DOTS, Math.round((width * height) / AREA_PER_DOT)),
      )
      const next: Dot[] = []
      for (let index = 0; index < target; index += 1) {
        const kept = dots[index]
        next.push(
          kept ?? {
            x: Math.random() * width,
            y: Math.random() * height,
            // Slow enough that the drift is felt rather than watched: about a
            // fifth of a screen width a minute. The motion that reads as speed
            // is the surge, not the drift.
            vx: (Math.random() - 0.5) * 0.11,
            vy: (Math.random() - 0.5) * 0.11,
            rank: Math.random(),
            radius: 1.1 + Math.random() * 1.3,
          },
        )
      }
      dots = next
    }

    const resize = (): void => {
      ratio = Math.min(2, window.devicePixelRatio || 1)
      width = window.innerWidth
      height = window.innerHeight
      element.width = Math.round(width * ratio)
      element.height = Math.round(height * ratio)
      element.style.width = `${width}px`
      element.style.height = `${height}px`
      context.setTransform(ratio, 0, 0, ratio, 0, 0)
      readTokens()
      seed()
    }

    const draw = (at: number): void => {
      frame = 0
      const state = { ...live.current, hole: hole.current }
      const gap = previous === 0 ? 16 : Math.min(48, at - previous)
      previous = at

      context.clearRect(0, 0, width, height)
      if (!state.active) {
        frame = requestAnimationFrame(draw)
        return
      }

      if (state.pulse !== lastPulse) {
        lastPulse = state.pulse
        pulseAt = at
      }
      // 1 at the instant of an arrival, 0 once the surge has decayed. Squared so
      // the fall-off is fast at the start and long in the tail, which is what a
      // pulse looks like rather than a fade.
      const surge = reduced ? 0 : Math.max(0, 1 - (at - pulseAt) / PULSE_MS) ** 2

      const centre =
        state.hole === null
          ? null
          : { x: state.hole.x + state.hole.width / 2, y: state.hole.y + state.hole.height / 2 }

      /*
       * The hole, cut with an even-odd clip.
       *
       * Everything below paints into "the window minus the focus rectangle", in
       * one operation, rather than each dot testing whether it is inside the box
       * — which would be the same result at n times the arithmetic and would
       * still draw a link straight across the quoted text. The margin keeps the
       * field off the ring itself, so the one-pixel accent border stays the
       * crispest thing on screen.
       */
      context.save()
      if (state.hole !== null) {
        const margin = 10
        const path = new Path2D()
        path.rect(0, 0, width, height)
        path.rect(
          state.hole.x - margin,
          state.hole.y - margin,
          state.hole.width + margin * 2,
          state.hole.height + margin * 2,
        )
        context.clip(path, 'evenodd')
      }

      const lit = state.count === 0 ? 0 : Math.min(1, state.seen / state.count)

      for (const dot of dots) {
        if (!reduced) {
          dot.x += dot.vx * gap
          dot.y += dot.vy * gap
          if (surge > 0 && centre !== null) {
            /*
             * The surge: every dot is pulled a little toward where the machine
             * just landed.
             *
             * Normalised by distance so the whole field moves together instead
             * of the near dots snapping and the far ones crawling — this is
             * meant to read as one system turning to look at something, which is
             * the honest picture of what the app is doing.
             */
            const dx = centre.x - dot.x
            const dy = centre.y - dot.y
            const distance = Math.max(24, Math.hypot(dx, dy))
            const pull = (surge * gap * 0.06) / distance
            dot.x += dx * pull
            dot.y += dy * pull
          }
          // Wrap rather than bounce. A bounce accumulates dots along the edges
          // over a long scan and leaves the middle bare.
          if (dot.x < -20) dot.x = width + 20
          if (dot.x > width + 20) dot.x = -20
          if (dot.y < -20) dot.y = height + 20
          if (dot.y > height + 20) dot.y = -20
        }
      }

      // Links first, so the dots sit on top of their own mesh.
      context.lineWidth = 1
      for (let a = 0; a < dots.length; a += 1) {
        for (let b = a + 1; b < dots.length; b += 1) {
          const dx = dots[a].x - dots[b].x
          const dy = dots[a].y - dots[b].y
          const distance = Math.hypot(dx, dy)
          if (distance > LINK_DIST) continue
          const strength = 1 - distance / LINK_DIST
          const alpha = strength * (0.17 + surge * 0.28)
          if (alpha < 0.02) continue
          const colour = dots[a].rank < lit && dots[b].rank < lit ? accent : dim
          context.strokeStyle = `rgba(${colour.r}, ${colour.g}, ${colour.b}, ${alpha.toFixed(3)})`
          context.beginPath()
          context.moveTo(dots[a].x, dots[a].y)
          context.lineTo(dots[b].x, dots[b].y)
          context.stroke()
        }
      }

      for (const dot of dots) {
        const isLit = dot.rank < lit
        const colour = isLit ? accent : dim
        const alpha = (isLit ? 0.66 : 0.4) + surge * 0.34
        context.fillStyle = `rgba(${colour.r}, ${colour.g}, ${colour.b}, ${Math.min(1, alpha).toFixed(3)})`
        context.beginPath()
        context.arc(dot.x, dot.y, dot.radius + surge * 0.7, 0, Math.PI * 2)
        context.fill()
      }

      context.restore()
      frame = requestAnimationFrame(draw)
    }

    resize()
    window.addEventListener('resize', resize)
    frame = requestAnimationFrame(draw)

    return () => {
      window.removeEventListener('resize', resize)
      if (frame !== 0) cancelAnimationFrame(frame)
    }
  }, [active, hole])

  if (!active) return null
  return <canvas ref={canvas} className="scan-field" aria-hidden="true" />
}
