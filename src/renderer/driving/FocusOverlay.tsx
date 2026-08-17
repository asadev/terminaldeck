import { useEffect, useRef, useState } from 'react'
import './FocusOverlay.css'
import { ringStyle, sameEdges, sameRect } from './geometry'
import {
  browserFocusDom,
  createAnchor,
  type FocusAnchor,
  type FocusDom,
  type FocusFailure,
  type FocusResolution,
  type FocusTarget,
  type Undimmable,
} from './focus-target'
import { findTerminal } from './terminal-registry'

/**
 * The box around the important thing, and the dulling of everything else.
 *
 * ## What "comes off cleanly" is enforced by
 *
 * This app has a recorded history of dismissed overlays leaving translucent
 * rectangles behind, so the teardown is the part designed first.
 *
 * **There is no exit animation and no unmount timer.** When there is nothing to
 * point at, this component returns `null` and the two elements leave the DOM in
 * the same commit. A fade-out would mean keeping a scrim mounted after the state
 * that justified it was gone, waiting on a `transitionend` — and that event does
 * not arrive when the element is `display: none`, does not arrive when the
 * duration is zero (which `prefers-reduced-motion` makes it, in `tokens.css`),
 * and does not arrive when the element is removed mid-transition. Three ways for
 * a scrim to be left at `opacity: 0.02` with a 9999-pixel shadow still painted.
 *
 * The `lit` prop is how a fade is expressed instead: the owner keeps the overlay
 * mounted for as long as it wants a fade and then stops. One place decides the
 * overlay exists, and that place is not a timer inside it.
 *
 * The document flag is written and cleared in the same effect for the same
 * reason, and it exists so a leak is *visible*: a stale `data-drive-focus` on
 * `<html>` is as easy to spot in the inspector as a stale rectangle is on
 * screen, and much easier to assert.
 */

interface Props {
  /** What to point at. `null` takes the overlay off, immediately and totally. */
  target: FocusTarget | null
  /**
   * Whether the scrim and ring are shown at full strength.
   *
   * False during travel — a scrim that slides across the window while the pane
   * underneath is also scrolling is two motions competing, and it repaints the
   * quad every frame of the journey.
   */
  lit?: boolean
  /** Told what the overlay can and cannot currently do. See {@link FocusReport}. */
  onReport?: (report: FocusReport) => void
  /** Test seam. The real DOM is used when this is absent. */
  dom?: FocusDom | null
}

/**
 * What the overlay managed, for a caller that has to say it out loud.
 *
 * Not a boolean, because every failure here is something a person needs told:
 * a session in `vim` cannot be boxed at all, a quote that has scrolled out of a
 * 10 000-line buffer is gone rather than hidden, and a browser page cannot be
 * dimmed by any HTML in this process.
 */
export interface FocusReport {
  drawn: boolean
  /** Present when `drawn` is false. */
  why?: FocusFailure
  /** Surfaces on screen the scrim does not reach. */
  undimmable: readonly Undimmable[]
}

/**
 * How long after a trigger the geometry keeps being re-checked.
 *
 * Events cover the sources that fire — scroll, resize, xterm's own render — but
 * a CSS transition moves a pane for a third of a second and emits nothing per
 * frame. The sidebar peeking out, a pane switching mode, a panel opening: each
 * is a `var(--dur-slow)` animation during which the box would sit at its old
 * coordinates if the geometry were only recomputed on events.
 *
 * So each trigger opens a window in which the rectangle is re-measured every
 * frame, and the window is one `--dur-slow` plus a little. This is not polling:
 * at rest, after the window closes, nothing runs at all. While a session
 * streams, `onRender` keeps re-opening it — which is correct, because the region
 * genuinely moves on every one of those frames.
 */
export const SETTLE_MS = 380

/** Reduced motion means no transitions to chase, so the window closes at once. */
function settleWindow(): number {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return SETTLE_MS
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : SETTLE_MS
}

function sameResolution(a: FocusResolution | null, b: FocusResolution): boolean {
  if (a === null) return false
  if (a.ok !== b.ok) return false
  if (!a.ok || !b.ok) {
    return (
      !a.ok &&
      !b.ok &&
      a.why === b.why &&
      a.undimmable.length === b.undimmable.length &&
      a.undimmable.every((item, i) => item === b.undimmable[i])
    )
  }
  return (
    sameRect(a.focus.rect, b.focus.rect) &&
    sameEdges(a.focus.edges, b.focus.edges) &&
    a.focus.radius === b.focus.radius &&
    a.focus.undimmable.length === b.focus.undimmable.length &&
    a.focus.undimmable.every((item, i) => item === b.focus.undimmable[i])
  )
}

/**
 * Keep a target's rectangle current.
 *
 * Exported so a test can drive it without rendering, and so a future driving
 * panel can read the same resolution the overlay is drawing without measuring a
 * second time — two measurements of the same thing is how a panel comes to
 * disagree with the box it is describing.
 */
export function useFocusResolution(
  target: FocusTarget | null,
  dom: FocusDom | null | undefined,
): FocusResolution | null {
  /*
   * Measured on the very first render, not one frame later.
   *
   * The obvious shape — start at null, fill it in from an effect — costs a
   * frame in which the target is set and nothing is drawn. That frame is the
   * whole window undimmed, immediately followed by the whole window dimmed,
   * which is a flash rather than a transition; on a tour that moves between
   * twelve stops it happens twelve times.
   *
   * It is also what makes this testable at all. vitest runs this project in
   * Node with no DOM, so component tests here render through
   * `renderToStaticMarkup`, which never runs an effect. A component whose only
   * output came from an effect would render as an empty string in every test
   * that tried to look at it.
   */
  const [resolution, setResolution] = useState<FocusResolution | null>(() =>
    target === null ? null : createAnchor(target).measure(dom === undefined ? undefined : dom),
  )
  const latest = useRef<FocusResolution | null>(resolution)

  useEffect(() => {
    if (target === null) {
      latest.current = null
      setResolution(null)
      return
    }
    const surface = dom === undefined ? browserFocusDom() : dom
    const anchor: FocusAnchor = createAnchor(target)

    let frame = 0
    let chaseUntil = 0
    let stopped = false

    const tick = (): void => {
      frame = 0
      if (stopped) return
      const next = anchor.measure(surface)
      if (!sameResolution(latest.current, next)) {
        latest.current = next
        setResolution(next)
      }
      if (now() < chaseUntil) schedule()
    }

    const schedule = (): void => {
      if (stopped || frame !== 0 || typeof requestAnimationFrame !== 'function') return
      frame = requestAnimationFrame(tick)
    }

    const trigger = (): void => {
      chaseUntil = now() + settleWindow()
      schedule()
    }

    /*
     * Measure now, then keep chasing.
     *
     * Synchronous, and inside the effect rather than only on the next frame,
     * because a target change has to land before the browser paints. Effects
     * run before paint, so this is the difference between the box arriving with
     * the new target and the box arriving one frame after it — which on a
     * terminal that is streaming means one frame of the ring around the wrong
     * lines.
     */
    const settle = (): void => {
      tick()
      trigger()
    }

    /*
     * Reflow, and the one case where the cache must be thrown away rather than
     * revalidated.
     *
     * A width change makes xterm re-wrap every wrapped line in the buffer, which
     * moves absolute line numbers for everything below the first wrap. The cheap
     * cache check would still pass for a region above the first wrapped line and
     * silently fail for one below it, so a resize forgets the cached line
     * outright and pays for one full scan.
     */
    const reflowed = (): void => {
      anchor.invalidate()
      settle()
    }

    const offs: Array<() => void> = []
    if (typeof window !== 'undefined') {
      // Capture phase: a chat pane that scrolls inside itself does not bubble
      // its scroll to the window, and the box it holds still has to move.
      window.addEventListener('scroll', trigger, true)
      window.addEventListener('resize', reflowed)
      offs.push(() => window.removeEventListener('scroll', trigger, true))
      offs.push(() => window.removeEventListener('resize', reflowed))
    }

    if (target.kind === 'terminal') {
      const entry = findTerminal(target.sessionId)
      if (entry) {
        // `onRender` is xterm's "something changed on screen": new output, a
        // scroll, a repaint, a theme swap. One subscription covers every way a
        // terminal region can move except a reflow, which has its own.
        const render = entry.term.onRender(trigger)
        const resize = entry.term.onResize(reflowed)
        offs.push(() => render.dispose())
        offs.push(() => resize.dispose())

        if (typeof ResizeObserver === 'function') {
          const observer = new ResizeObserver(reflowed)
          observer.observe(entry.host)
          offs.push(() => observer.disconnect())
        }
      }
    } else if (typeof ResizeObserver === 'function' && typeof document !== 'undefined') {
      // Everything else moves when the shell does. `documentElement` is the one
      // box that is always there and always the right size to watch.
      const observer = new ResizeObserver(trigger)
      observer.observe(document.documentElement)
      offs.push(() => observer.disconnect())
    }

    settle()

    return () => {
      stopped = true
      if (frame !== 0 && typeof cancelAnimationFrame === 'function') cancelAnimationFrame(frame)
      for (const off of offs) off()
    }
  }, [target, dom])

  return resolution
}

function now(): number {
  return typeof performance === 'object' && typeof performance.now === 'function'
    ? performance.now()
    : Date.now()
}

/** Set while a highlight is up, so a leak is visible rather than merely wrong. */
export const FOCUS_FLAG = 'data-drive-focus'

export function FocusOverlay({ target, lit = true, onReport, dom }: Props) {
  const resolution = useFocusResolution(target, dom)
  const drawn = resolution !== null && resolution.ok

  useEffect(() => {
    if (onReport === undefined || resolution === null) return
    onReport(
      resolution.ok
        ? { drawn: true, undimmable: resolution.focus.undimmable }
        : { drawn: false, why: resolution.why, undimmable: resolution.undimmable },
    )
  }, [resolution, onReport])

  useEffect(() => {
    if (!drawn || typeof document === 'undefined') return
    const root = document.documentElement
    root.setAttribute(FOCUS_FLAG, '')
    return () => root.removeAttribute(FOCUS_FLAG)
  }, [drawn])

  if (resolution === null || !resolution.ok) return null
  const { rect, edges, radius } = resolution.focus

  /*
   * The ring's box is the hole grown by exactly its own border weight, so the
   * one pixel of border lands entirely OUTSIDE the hole. For a browser page
   * that is not a nicety: a page is a native view composited above this whole
   * renderer, so any pixel drawn inside its rectangle is simply not composited
   * and vanishes. Growing the box is what keeps the ring on the app's chrome,
   * where it can be seen, with the live page untouched inside it.
   */
  const RING = 1
  /** Matching the `box-shadow` spread in `FocusOverlay.css`. */
  const GLOW = 3
  const ring = ringStyle(edges, radius === 0 ? 0 : radius + RING, GLOW)

  return (
    <div className="fo" aria-hidden="true" data-lit={lit || undefined}>
      <div
        className="fo-scrim"
        style={{
          left: rect.x,
          top: rect.y,
          width: rect.width,
          height: rect.height,
          borderRadius: radius,
        }}
      />
      <div
        className="fo-ring"
        style={{
          left: rect.x - RING,
          top: rect.y - RING,
          width: rect.width + RING * 2,
          height: rect.height + RING * 2,
          borderRadius: ring.borderRadius,
          clipPath: ring.clipPath,
        }}
        data-cut-top={edges.top ? undefined : ''}
        data-cut-right={edges.right ? undefined : ''}
        data-cut-bottom={edges.bottom ? undefined : ''}
        data-cut-left={edges.left ? undefined : ''}
      />
    </div>
  )
}
