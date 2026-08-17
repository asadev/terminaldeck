import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { NATIVE_VIEW_SELECTOR } from '../browser/overlay-watch'
import './tooltip.css'
import {
  OPEN_DELAY_MS,
  isWarm,
  pathLike,
  placeTip,
  saysSomethingNew,
  splitChord,
  titleHold,
  type Placed,
  type Rect,
} from './tooltip'

/**
 * One tooltip for the whole window.
 *
 * ## Delegated, not per component
 *
 * There are close to two hundred `title=` attributes in this renderer, across
 * sixty-odd files. A `<Tooltip>` wrapper component would mean editing every one
 * of them and — worse — would mean the next person who adds a control has to
 * remember to reach for it. Nobody remembers. So this listens on the document
 * instead: anything with a `title` gets the app's tooltip, including markup
 * written after this file and markup nobody thought about.
 *
 * ## The part that has to be right
 *
 * Drawing a bubble is easy. Making the OS *stop* drawing its own means taking
 * the `title` attribute off the element, and `title` doubles as the accessible
 * name for a control that has no other one. `tooltip.ts` owns that trade and
 * explains it at length; what this file owes is the other half — every path out
 * puts the attribute back.
 *
 * The failure that would be invisible in review is a title that never returns.
 * React will not repair it: the element's `title` prop has not changed between
 * renders, so React's diff writes nothing and the attribute stays gone for the
 * life of the element. That is why the hold lives in a ref that survives every
 * render rather than in state, and why the effect's cleanup releases it.
 *
 * ## Two lifetimes, not one
 *
 * The strip and the bubble end at different moments, and the state machine
 * below is mostly that distinction.
 *
 *   - **The bubble** is dismissed by anything that means "you are doing
 *     something else now": a click, Escape, a scroll. That is ordinary tooltip
 *     behaviour and nobody would question it.
 *   - **The strip** outlives all of those, because the pointer has not moved.
 *     Give the title back on click and then rest the pointer where it already
 *     is, and the OS draws its own tooltip a second later — the yellow box in
 *     the wrong font, arriving after the app's own has been dismissed. The
 *     title only goes back when the pointer genuinely leaves the control, or
 *     the window, or this component unmounts.
 *
 * `muted` is what carries that: it hides the bubble without releasing, and it
 * is cleared when the hold moves to a different element.
 *
 * ## Why it is a portal
 *
 * The same reason the folder menu is one, and `finish.test.ts` records what
 * happened when it was not: the toolbar carries `backdrop-filter`, which makes
 * it a *backdrop root*, so glass rendered inside it has nothing to frost and a
 * positioned descendant of the panes paints straight over it. Under `<body>`
 * the bubble's backdrop is the document, and its z-index is in the same race as
 * the modals it has to appear above.
 */

/** What the bubble is drawing. */
interface Bubble {
  label: string
  chord: string | null
  /** Measured when it opened; a tooltip does not chase a moving anchor. */
  anchor: DOMRect
  /** Keyboard focus opened it, so keyboard focus has to close it. */
  via: 'pointer' | 'focus'
}

/**
 * Is any text inside this control cut off by an ellipsis?
 *
 * The one thing `saysSomethingNew` cannot answer on its own: a label that is
 * clipped is not on screen, however much of it is in `textContent`, so its
 * tooltip is the only way to read it. Measured on the control and everything
 * under it, because the clipping is nearly always on an inner span — the
 * sidebar's `.sb-label` — and not on the button.
 *
 * The single-pixel tolerance is for sub-pixel text metrics: an element that
 * fits exactly can report a `scrollWidth` a fraction over its `clientWidth`,
 * and rounding up would put a tooltip back on every row in the window.
 */
function textIsClipped(el: HTMLElement): boolean {
  if (el.scrollWidth > el.clientWidth + 1) return true
  for (const kid of el.querySelectorAll<HTMLElement>('*')) {
    if (kid.scrollWidth > kid.clientWidth + 1) return true
  }
  return false
}

/**
 * The parts of the window a bubble would be invisible in.
 *
 * A browser page is a native view composited above the whole renderer, so a
 * bubble that lands on one is painted over however it is styled —
 * `browser/overlay-watch.ts` is the long version and `placeTip`'s `blind`
 * parameter is what does something about it. Read fresh each time a bubble
 * opens, rather than watched: a tooltip is placed once and does not chase a
 * moving anchor, so one `querySelectorAll` of a handful of elements at the
 * moment of placement is both cheaper and more honest than a subscription that
 * has to be kept current between them.
 *
 * `DOMRect` already has the `left`/`top`/`width`/`height` this wants, so there
 * is nothing to convert and nothing to get wrong in converting.
 */
function blindRegions(): Rect[] {
  return Array.from(document.querySelectorAll(NATIVE_VIEW_SELECTOR), (el) =>
    el.getBoundingClientRect(),
  ).filter((box) => box.width > 0 && box.height > 0)
}

export function Tooltips() {
  const [bubble, setBubble] = useState<Bubble | null>(null)
  const [at, setAt] = useState<Placed | null>(null)
  const bubbleRef = useRef<HTMLDivElement>(null)

  /*
   * The document listeners are created once, so everything they reason about
   * has to be a ref — a closure built at mount would otherwise read the first
   * render's state forever.
   */
  const hold = useRef(titleHold<HTMLElement>())
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const closedAt = useRef<number | null>(null)
  const showing = useRef(false)
  /** The bubble is dismissed, but the hold stands. See the header. */
  const muted = useRef(false)

  /** Take the bubble down. The title stays taken. */
  const dismiss = useCallback(() => {
    if (timer.current !== null) {
      clearTimeout(timer.current)
      timer.current = null
    }
    if (!showing.current) return
    showing.current = false
    closedAt.current = Date.now()
    setBubble(null)
    setAt(null)
  }, [])

  /** Take the bubble down and keep it down until the pointer moves on. */
  const mute = useCallback(() => {
    dismiss()
    muted.current = true
  }, [dismiss])

  /** Take the bubble down and give the title back. */
  const release = useCallback(() => {
    dismiss()
    hold.current.release()
    muted.current = false
  }, [dismiss])

  useEffect(() => {
    const current = hold.current

    const show = (via: Bubble['via']): void => {
      const text = current.text()
      const el = current.element()
      if (text === null || el === null) return
      const { label, chord } = splitChord(text)
      showing.current = true
      setBubble({ label, chord, anchor: el.getBoundingClientRect(), via })
    }

    const schedule = (via: Bubble['via']): void => {
      if (timer.current !== null) clearTimeout(timer.current)
      // Focus never waits. A tooltip is the only label a keyboard user gets on
      // an icon-only button, and half a second of nothing after Tab reads as a
      // control with no name rather than as a considered delay.
      const delay = via === 'focus' || isWarm(closedAt.current, Date.now()) ? 0 : OPEN_DELAY_MS
      timer.current = setTimeout(() => {
        timer.current = null
        // The control may have been unmounted while the timer ran — a session
        // closing under the pointer is the ordinary way that happens — and a
        // bubble anchored to a detached node would open in the corner.
        if (current.element()?.isConnected !== true) {
          release()
          return
        }
        show(via)
      }, delay)
    }

    const onPointerOver = (event: PointerEvent): void => {
      const target = event.target
      if (!(target instanceof Element)) return

      // Moving between an element's own children is not leaving it. Without
      // this the bubble would close and reopen every time the pointer crossed
      // the glyph inside a button — and, worse, a muted hold would un-mute.
      const heldEl = current.element()
      if (heldEl !== null && heldEl.contains(target)) return

      // `closest('[title]')` cannot find the element we are already holding,
      // because its title is the one thing that is currently missing. That is
      // fine: the line above has already answered for it.
      const next = target.closest<HTMLElement>('[title]')
      if (next === null) {
        release()
        return
      }
      release()
      /*
       * Grabbed either way, scheduled only when it has something to say.
       *
       * The grab is what removes the `title` attribute, and that has to happen
       * even for a tooltip this layer decides not to draw — otherwise the OS
       * draws its own instead, which is the pale yellow box in the wrong font
       * this whole layer exists to replace. So a label that only repeats the
       * control gets *no* tooltip at all, rather than the native one.
       */
      if (!current.grab(next)) return
      const text = current.text()
      if (text !== null && !saysSomethingNew(text, next, textIsClipped(next))) return
      schedule('pointer')
    }

    /**
     * Keyboard focus gets a tooltip; a mouse click does not leave one behind.
     *
     * `:focus-visible` is the browser's own answer to "did the keyboard do
     * this". A click that focuses a button is deliberately ignored here — not
     * only so the button does not sit there wearing a label, but because
     * releasing the pointer's hold on the way past would hand the title back
     * under a stationary pointer, which is the leak the header describes.
     */
    const onFocusIn = (event: FocusEvent): void => {
      const target = event.target
      if (!(target instanceof HTMLElement)) return
      if (!target.matches(':focus-visible')) return
      const el = target.closest<HTMLElement>('[title]')
      if (el === null) {
        release()
        return
      }
      release()
      if (current.grab(el)) schedule('focus')
    }

    const onFocusOut = (): void => {
      if (showing.current) release()
    }

    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') mute()
    }

    /*
     * `pointerdown` in the capture phase, so the bubble is gone before whatever
     * was clicked reacts — the same reasoning as the folder menu's dismissal.
     * Scroll is captured because a scroll inside a panel does not bubble to the
     * document. All three mute rather than release: the pointer has not moved.
     */
    document.addEventListener('pointerover', onPointerOver)
    document.addEventListener('pointerdown', mute, true)
    document.addEventListener('scroll', mute, true)
    document.addEventListener('wheel', mute, { capture: true, passive: true })
    document.addEventListener('keydown', onKeyDown, true)
    document.addEventListener('focusin', onFocusIn)
    document.addEventListener('focusout', onFocusOut)
    /*
     * The three ways the pointer stops being over anything without a
     * `pointerover` ever firing: it leaves the window, the window loses focus,
     * or the window is resized under it. Each of them really is "the pointer is
     * no longer on that control", so each releases.
     */
    document.addEventListener('pointerleave', release)
    window.addEventListener('blur', release)
    window.addEventListener('resize', release)

    return () => {
      document.removeEventListener('pointerover', onPointerOver)
      document.removeEventListener('pointerdown', mute, true)
      document.removeEventListener('scroll', mute, true)
      document.removeEventListener('wheel', mute, true)
      document.removeEventListener('keydown', onKeyDown, true)
      document.removeEventListener('focusin', onFocusIn)
      document.removeEventListener('focusout', onFocusOut)
      document.removeEventListener('pointerleave', release)
      window.removeEventListener('blur', release)
      window.removeEventListener('resize', release)
      // The line that matters. StrictMode tears this effect down and sets it up
      // again on mount, and in production it runs when the window closes;
      // either way an element whose title is held must get it back.
      release()
    }
  }, [mute, release])

  /**
   * Measure, then place, before paint.
   *
   * A plain effect would paint the bubble at its unplaced position for one
   * frame, which on a dark window is a visible flash in the top-left corner —
   * the exact artefact the folder chip's layout effect exists to avoid.
   */
  useLayoutEffect(() => {
    if (bubble === null) return
    const node = bubbleRef.current
    if (node === null) return
    setAt(
      placeTip(
        bubble.anchor,
        { width: node.offsetWidth, height: node.offsetHeight },
        { width: window.innerWidth, height: window.innerHeight },
        blindRegions(),
      ),
    )
  }, [bubble])

  if (bubble === null) return null

  return createPortal(
    <div
      ref={bubbleRef}
      className="tooltip"
      role="tooltip"
      /*
       * Hidden from assistive technology on purpose. The accessible name is
       * already correct — either the control had one of its own, or
       * `tooltip.ts` lent it the identical string as an `aria-label` for
       * exactly as long as the attribute is away — so exposing this bubble as
       * well would have a screen reader say the same words twice.
       */
      aria-hidden="true"
      data-side={at?.side ?? 'below'}
      // Rendered before it is placed, because it has to be laid out to be
      // measured. `data-placed` is what makes it visible, one layout effect
      // later, in the right corner of the window.
      data-placed={at === null ? undefined : 'true'}
      style={{ left: at?.left ?? 0, top: at?.top ?? 0 }}
    >
      <span className="tooltip-label" data-mono={pathLike(bubble.label) || undefined}>
        {bubble.label}
      </span>
      {bubble.chord !== null && <span className="tooltip-chord">{bubble.chord}</span>}
    </div>,
    document.body,
  )
}
