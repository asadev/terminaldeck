/**
 * The dots — what a machine working at speed looks like, in a browser tab.
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
 * then competes with the content — which is the mistake the desktop's browser
 * inspector made once and was rewritten on camera for. Here the field paints
 * everywhere the focus is not, and the focus rectangle is cut out of it
 * entirely, so the row being looked at is the one part of the page with nothing
 * over it at all.
 *
 * ## Why a 2D canvas rather than WebGL
 *
 * The desktop settled this in `src/renderer/driving/ScanField.tsx` and the
 * argument carries over with one term changed. There: the window already runs a
 * WebGL context per terminal, Chromium caps live contexts per process and evicts
 * the oldest, so a decoration would cost a terminal its renderer. Here: this
 * client's terminal is an `@xterm/xterm` canvas in the same tab, on a phone,
 * where the cap is lower and the eviction is the same. A 2D canvas has no such
 * cap, needs no shader, and at this particle count is nowhere near the expensive
 * thing on screen.
 *
 * This is a fresh implementation rather than an import of that file: it is a
 * React component with a `.css` import, and this client has neither. What is
 * shared is the *approach* — an even-odd clip cutting the hole at the measured
 * focus rect — and the four measured values below, which are facts about how a
 * field of dots reads rather than expression.
 *
 * ## Nothing here is pre-scripted, and that is a rule
 *
 * A canvas animation that looks like intelligence and is not would be the worst
 * thing in this client. Every input is a fact about a scan that is really
 * running:
 *
 *  - it exists only while a scan is playing, and is torn down when it ends;
 *  - the hole is the **measured rectangle of a real row on this page**, read
 *    every frame so it follows a list that scrolls or reflows;
 *  - the surge fires on a real arrival at a real stop, so a scan that is held,
 *    stalled or waiting produces a field that visibly stops pulsing;
 *  - the share drawn in the accent is `seen / count` — how much of the fleet has
 *    actually been visited. The field fills up because the scan is getting
 *    through the sessions, not because time is passing.
 *
 * If the scan is doing nothing, this shows nothing happening.
 */

import type { PauseReason } from '../../src/shared/scan'

export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

/**
 * How much window area each dot gets.
 *
 * The desktop measured this at 14 000 px² and the number is kept: a 1440 × 900
 * window carries about ninety dots and a large display about two hundred.
 * Chosen by what it has to *read* as rather than by cost — sparse enough that
 * the dots are legible as dots, dense enough that the links form a mesh rather
 * than a few stray threads. Below roughly sixty the mesh breaks into unrelated
 * specks; above two hundred and fifty it reads as noise and competes with the
 * text underneath, which the dulled area still has to let you read.
 *
 * A phone is the case that made the floor matter: a 390 × 700 viewport is
 * 273 000 px², which is nineteen dots without one.
 */
export const AREA_PER_DOT = 14_000
export const MIN_DOTS = 60
export const MAX_DOTS = 250

/**
 * How close two dots must be before a line is drawn between them.
 *
 * The mesh is what makes this read as a system rather than as falling snow. At
 * the density above, 130 px gives each dot two or three neighbours on average —
 * enough to see structure, few enough that it does not become a grey sheet.
 */
export const LINK_DIST = 130

/**
 * How long one surge takes to decay.
 *
 * A stop is held for `SCAN_HOLD_MS` (260 ms), so the surge has to be over before
 * the next one starts or they smear into a constant glow and stop marking
 * anything. 220 ms leaves a visible gap at the end of every stop, which is what
 * makes the field *pulse* per session rather than merely shimmer.
 */
export const PULSE_MS = 220

/** Fallbacks for the two tokens, used only if the stylesheet cannot be read. */
const FALLBACK_ACCENT = { r: 59, g: 143, b: 238 }
const FALLBACK_DIM = { r: 143, g: 143, b: 143 }

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
 * A CSS colour as three channels, for the two shapes `styles.css` actually uses.
 *
 * Hex and `rgb()` only, because those are the two `getComputedStyle` hands back
 * for a custom property holding a colour in this client. Anything else falls
 * back rather than throwing: a field in the wrong grey is cosmetic, and an
 * exception inside a canvas frame loop is a page that stops painting.
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
  if (rgb !== null) return { r: Number(rgb[1]), g: Number(rgb[2]), b: Number(rgb[3]) }
  return fallback
}

/** What the field reads, once a frame, from whoever is running the scan. */
export interface FieldReading {
  /** The hole, in viewport coordinates, or null while travelling. */
  hole: Rect | null
  seen: number
  count: number
  /** Bumped on every arrival. A change is what fires the surge. */
  arrivals: number
}

export interface ScanFieldHandle {
  /** Takes the canvas off the page and stops the loop. */
  destroy(): void
}

/**
 * Mount the field over the page and start drawing.
 *
 * `read` is called once per frame rather than the values being passed in, and
 * that is deliberate: the hole is re-measured from a real element on a list that
 * can scroll under a thumb, so it changes far more often than anything worth
 * re-rendering the page for. The canvas redraws anyway; the caller does not need
 * to know.
 */
export function mountScanField(host: HTMLElement, read: () => FieldReading): ScanFieldHandle {
  const canvas = document.createElement('canvas')
  canvas.className = 'scan-field'
  // Announced to nobody. The field carries no information a screen reader could
  // use — everything it depicts is also in the status line and the trace, in
  // words — and a canvas that announced itself would interrupt a reader on every
  // stop.
  canvas.setAttribute('aria-hidden', 'true')
  host.append(canvas)

  const context = canvas.getContext('2d')
  if (context === null) {
    // A browser that will not give a 2D context still gets the scan; it simply
    // gets it without the decoration. Refusing to run the scan over a missing
    // canvas would trade the feature for its ornament.
    canvas.remove()
    return { destroy: () => undefined }
  }

  const reduced =
    typeof window.matchMedia === 'function' && window.matchMedia('(prefers-reduced-motion: reduce)').matches

  let dots: Dot[] = []
  let width = 0
  let height = 0
  let accent = FALLBACK_ACCENT
  let dim = FALLBACK_DIM
  let frame = 0
  let lastArrivals = -1
  let pulseAt = -Infinity
  let previous = 0

  /**
   * Re-read the two tokens.
   *
   * Canvas cannot resolve a CSS variable, so the values are pulled off the root
   * element — which means they follow the theme, since `styles.css` redefines
   * both under `[data-theme]` and under `prefers-color-scheme`. Re-read on every
   * resize as the cheapest place to catch a theme swap without a second
   * observer: this client stamps the appearance on the root and the layout is
   * regenerated with it.
   */
  const readTokens = (): void => {
    const style = getComputedStyle(document.documentElement)
    accent = readColour(style.getPropertyValue('--accent'), FALLBACK_ACCENT)
    dim = readColour(style.getPropertyValue('--text-muted'), FALLBACK_DIM)
  }

  const seed = (): void => {
    const target = Math.min(MAX_DOTS, Math.max(MIN_DOTS, Math.round((width * height) / AREA_PER_DOT)))
    const next: Dot[] = []
    for (let index = 0; index < target; index += 1) {
      const kept = dots[index]
      next.push(
        kept ?? {
          x: Math.random() * width,
          y: Math.random() * height,
          // Slow enough that the drift is felt rather than watched: about a
          // fifth of a screen width a minute. What reads as speed is the surge,
          // not the drift.
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
    const ratio = Math.min(2, window.devicePixelRatio || 1)
    width = window.innerWidth
    height = window.innerHeight
    canvas.width = Math.round(width * ratio)
    canvas.height = Math.round(height * ratio)
    canvas.style.width = `${width}px`
    canvas.style.height = `${height}px`
    context.setTransform(ratio, 0, 0, ratio, 0, 0)
    readTokens()
    seed()
  }

  const draw = (at: number): void => {
    frame = 0
    const state = read()
    const gap = previous === 0 ? 16 : Math.min(48, at - previous)
    previous = at

    context.clearRect(0, 0, width, height)

    if (state.arrivals !== lastArrivals) {
      lastArrivals = state.arrivals
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
     * Everything below paints into "the viewport minus the focus rectangle", in
     * one operation, rather than each dot testing whether it is inside the box —
     * which would be the same result at n times the arithmetic and would still
     * draw a link straight across the row. The margin keeps the field off the
     * ring itself, so the accent border stays the crispest thing on screen.
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

    if (!reduced) {
      for (const dot of dots) {
        dot.x += dot.vx * gap
        dot.y += dot.vy * gap
        if (surge > 0 && centre !== null) {
          /*
           * The surge: every dot is pulled a little toward where the machine
           * just landed. Normalised by distance so the whole field moves
           * together instead of the near dots snapping and the far ones
           * crawling — this reads as one system turning to look at something,
           * which is the honest picture of what is happening.
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

  return {
    destroy() {
      window.removeEventListener('resize', resize)
      if (frame !== 0) cancelAnimationFrame(frame)
      canvas.remove()
    },
  }
}

/* --------------------------------------------------------- the focus rect -- */

/**
 * How a row says it is scannable.
 *
 * An attribute rather than a class, because the value is the session id and the
 * lookup is by id. Every list that a scan can drive over stamps this on its rows,
 * and a screen that does not stamp anything is a screen the scan travels across
 * without focusing — which is honest: there is nothing on it to point at.
 */
export const SCAN_ATTRIBUTE = 'data-scan-session'

/**
 * Where a session's row is on screen right now, or null.
 *
 * Measured every frame rather than cached. The list scrolls, the panel opens and
 * closes, a session's status line grows a second row — and a hole drawn at a
 * remembered rectangle would sit over the wrong thing while the page moved
 * underneath it, which is precisely the failure a spotlight over a terminal has
 * in this product's own history.
 *
 * Null for a row that is not in the document at all, which is a real state: the
 * scan walks the fleet, and the fleet is longer than a phone screen. The field
 * then draws with no hole, which reads as the machine looking at something off
 * screen — true, and better than cutting a hole somewhere arbitrary.
 */
export function focusRect(sessionId: string, root: ParentNode = document): Rect | null {
  const element = root.querySelector(`[${SCAN_ATTRIBUTE}="${cssEscape(sessionId)}"]`)
  if (element === null) return null
  const box = element.getBoundingClientRect()
  if (box.width <= 0 || box.height <= 0) return null
  return { x: box.left, y: box.top, width: box.width, height: box.height }
}

/**
 * A session id, safe inside an attribute selector.
 *
 * Session ids are minted by the desktop and are not hostile, but they arrive off
 * a socket and end up in a selector — which is the exact shape of an injection
 * even when the source is friendly. `CSS.escape` is the browser's own answer and
 * has been everywhere since 2016; the fallback is for a test environment with no
 * `CSS` object rather than for a browser.
 */
function cssEscape(value: string): string {
  if (typeof CSS !== 'undefined' && typeof CSS.escape === 'function') return CSS.escape(value)
  return value.replace(/["\\]/g, '\\$&')
}

/* ------------------------------------------------------------ interruption -- */

export interface InterruptionWatch {
  stop(): void
}

/**
 * The screen belongs to the person in front of it.
 *
 * Touching anything stops the scan dead, and that mattered less when driving
 * mode was a paced read-along than it does now: at machine speed the movement is
 * harder to catch by hand, so the gestures that mean *wait* have to be the ones
 * people already make. Each reason is reported in words by
 * `pauseSentence` in the shared model, because a stopped scan that does not say
 * what stopped it looks like a hang — and the person will not have seen which of
 * their own gestures did it.
 *
 * ## What is deliberately not watched
 *
 * `mousemove`. A cursor crossing the page is not an instruction, and on a laptop
 * with a trackpad it fires continuously; watching it would mean the scan never
 * ran for more than one stop on a desktop browser. The desktop app's own
 * interruption watch makes the same exclusion.
 */
export function watchScanInterruption(
  target: Window,
  pause: (reason: PauseReason) => void,
  resume: () => void,
): InterruptionWatch {
  /**
   * Is this keystroke addressed to a field rather than to the page?
   *
   * `isContentEditable` as well as the two tags, because the terminal's own
   * helper textarea and any editable region are both places where a space is a
   * space. The check is on the event's target rather than on
   * `document.activeElement` so that it is answered by the element that actually
   * received the key.
   */
  const isTyping = (node: EventTarget | null): boolean => {
    if (node === null || !(node instanceof HTMLElement)) return false
    const tag = node.tagName
    return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || node.isContentEditable
  }

  const onScroll = (): void => pause('scrolled')
  const onPointer = (): void => pause('clicked')
  const onKey = (event: KeyboardEvent): void => {
    /*
     * Space carries on, and it is here because the screen promises it.
     *
     * `statusSentence` in the shared model ends every held scan with *"Space to
     * carry on"*, and that sentence was on screen with nothing listening for the
     * key — a claim the product could not keep, which is the one thing this whole
     * review is against. The desktop's own watch skips Space for the same reason
     * and its window binds it; a browser has no menu to bind it in, so it is
     * bound here.
     *
     * Not while somebody is typing. The composer is a textarea and a space in a
     * sentence is a space in a sentence — a scan resuming because a person put a
     * word between two others would be the app reading a keystroke that was not
     * addressed to it. Everything else is: a key pressed at a page with no field
     * focused is a key pressed at the page.
     */
    if (event.key === ' ' || event.key === 'Spacebar') {
      if (isTyping(event.target)) return
      // The page scrolls on Space by default, and a scan that resumed *and*
      // jumped the list a screen down would move the very row it is about to
      // point at.
      event.preventDefault()
      resume()
      return
    }
    if (isTyping(event.target)) return
    pause('typed')
  }
  const onSelect = (): void => {
    const selection = target.getSelection?.()
    if (selection !== null && selection !== undefined && selection.toString() !== '') pause('selected')
  }
  const onBlur = (): void => pause('left-window')
  const onVisibility = (): void => {
    if (target.document.visibilityState === 'hidden') pause('hidden')
  }

  // Capture, and passive where the listener never calls `preventDefault` — a
  // non-passive scroll listener on a touch surface delays the scroll itself,
  // which would make the very gesture that stops the scan feel like the app
  // hanging.
  const options = { capture: true, passive: true } as const
  target.addEventListener('scroll', onScroll, options)
  target.addEventListener('wheel', onScroll, options)
  target.addEventListener('pointerdown', onPointer, options)
  target.addEventListener('keydown', onKey, { capture: true })
  target.document.addEventListener('selectionchange', onSelect)
  target.addEventListener('blur', onBlur)
  target.document.addEventListener('visibilitychange', onVisibility)

  return {
    stop() {
      target.removeEventListener('scroll', onScroll, options)
      target.removeEventListener('wheel', onScroll, options)
      target.removeEventListener('pointerdown', onPointer, options)
      target.removeEventListener('keydown', onKey, { capture: true })
      target.document.removeEventListener('selectionchange', onSelect)
      target.removeEventListener('blur', onBlur)
      target.document.removeEventListener('visibilitychange', onVisibility)
    },
  }
}
