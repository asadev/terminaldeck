import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import './HoverNote.css'

/**
 * The ⓘ dot, and the paragraph behind it — as a popup over the page, never as
 * the page growing downwards.
 *
 * ## What was asked for, and what was wrong with what was there
 *
 * Asad, 2026-08-17, about Settings → Copilot and the setup flow: *"the ⓘ dot
 * shows its detail **on hover, as a popup** — not by expanding the pane
 * downward."*
 *
 * The control this replaces (`Info` + `MoreBody` in `settings/controls.tsx`) is
 * a disclosure: pressing it inserts the paragraph into the flow, under the row.
 * That is a perfectly good pattern and it is the wrong one here, for a reason
 * that only shows up on a pane with six of them. Every press moves everything
 * below it — so reading the second explanation puts the third somewhere else,
 * and a pane that is already a screen and a half long becomes three. The reader
 * loses their place in order to be told something they wanted in passing.
 *
 * A popup costs nothing below it. Open it, read it, move the pointer, and the
 * page is exactly where it was.
 *
 * ## Hover, and then the three readers hover leaves out
 *
 * Hover alone would be a dead control for a touch screen, a trackpad tap, and a
 * keyboard. So the same string is reachable four ways and there is only ever one
 * copy of it:
 *
 *  - **Pointer** — it opens on enter and closes on leave, with no delay. A
 *    delay is right for a tooltip that might not have been wanted; this one is
 *    on a dot whose entire purpose is to be hovered.
 *  - **Keyboard** — focus opens it, blur closes it, Escape closes it. It is a
 *    real `<button>`, so Tab reaches it.
 *  - **Click / tap** — pins it open until the next click, which is the only
 *    thing that works on a screen with no pointer at all.
 *  - **Screen reader** — the popup carries an id and the button points at it
 *    with `aria-describedby`, so the paragraph is announced as the button's
 *    description whether or not it is on screen.
 *
 * ## Deliberately not a `title`
 *
 * `shell/Tooltips.tsx` turns every `title` in this renderer into the app's own
 * bubble. Putting the paragraph there would have been three lines of code and
 * two defects: that bubble is capped at 320px and one line of `--t-subhead` text
 * — right for "Close (⌘W)", useless for forty words — and it would fight this
 * popup for the same anchor, so a hover would draw both. There is no `title`
 * anywhere in this file, on purpose.
 *
 * ## Placed by measurement, painted once
 *
 * Positioned `fixed` from the button's own rect, flipped above the anchor when
 * there is not room below it, and clamped to the window with a margin, so a dot
 * at the bottom-right of a settings pane still shows a readable box. The
 * measurement happens in a layout effect, before paint — the same reason
 * `Tooltips.tsx` uses one: measuring in a plain effect paints the box in the
 * corner for a frame first, which on a dark window is a visible flash.
 *
 * A portal under `<body>` for the reason every floating surface in this app is
 * one: the settings sheet and the toolbar carry `backdrop-filter`, which makes
 * them backdrop roots, and glass rendered inside one has nothing to frost.
 */

export interface HoverNoteProps {
  /**
   * What the dot is explaining, for the screen reader's benefit: it becomes
   * "More about <label>". Never drawn.
   */
  label: string
  /** The paragraph. A string rather than nodes — see the header on the `title`. */
  children: string
}

/** Where the box ended up, in window coordinates. */
interface Placed {
  left: number
  top: number
  side: 'above' | 'below'
}

/** How far the box is kept off the edge of the window. */
const MARGIN = 8

/**
 * Put the box under the anchor, or above it when it does not fit.
 *
 * Pure, and exported, because it is the half of this component that can be
 * wrong in a way nobody notices until a dot near an edge draws its box
 * half-off-screen — and it is the half a test can reach with no DOM.
 */
export function placeNote(
  anchor: { left: number; top: number; width: number; height: number },
  box: { width: number; height: number },
  view: { width: number; height: number },
  gap = 8,
): Placed {
  const below = anchor.top + anchor.height + gap
  const above = anchor.top - box.height - gap
  // Below unless it would run off the bottom *and* there is room above. A box
  // that fits in neither stays below and is clamped, because scrolling down to
  // the rest of it is better than having it start off the top of the window.
  const side: Placed['side'] = below + box.height <= view.height - MARGIN || above < MARGIN ? 'below' : 'above'
  const top = side === 'below' ? below : above
  // Centred on the dot, then pulled back inside the window. `Math.max` last so
  // that on a window narrower than the box the left edge wins, which keeps the
  // first word of every line readable.
  const centred = anchor.left + anchor.width / 2 - box.width / 2
  const left = Math.max(MARGIN, Math.min(centred, view.width - box.width - MARGIN))
  return { left, top: Math.max(MARGIN, Math.min(top, view.height - box.height - MARGIN)), side }
}

export function HoverNote({ label, children }: HoverNoteProps) {
  const [open, setOpen] = useState(false)
  /** A click pins it: it survives the pointer leaving, until the next click. */
  const [pinned, setPinned] = useState(false)
  const [at, setAt] = useState<Placed | null>(null)
  const dot = useRef<HTMLButtonElement>(null)
  const box = useRef<HTMLDivElement>(null)
  const id = useId()

  const shut = useCallback(() => {
    setOpen(false)
    setPinned(false)
    setAt(null)
  }, [])

  useLayoutEffect(() => {
    if (!open) return
    const anchor = dot.current?.getBoundingClientRect()
    const node = box.current
    if (!anchor || !node) return
    setAt(
      placeNote(
        { left: anchor.left, top: anchor.top, width: anchor.width, height: anchor.height },
        { width: node.offsetWidth, height: node.offsetHeight },
        { width: window.innerWidth, height: window.innerHeight },
      ),
    )
  }, [open, children])

  /*
   * Everything that means "you are looking at something else now".
   *
   * A scroll is the one that matters on this pane: the box is placed once and
   * does not chase its anchor, so a popup left open through a scroll would be a
   * paragraph floating over an unrelated row. Captured, because a scroll inside
   * the settings panel does not bubble to the document.
   */
  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') shut()
    }
    const onScroll = (): void => shut()
    document.addEventListener('keydown', onKey, true)
    document.addEventListener('scroll', onScroll, true)
    window.addEventListener('resize', onScroll)
    window.addEventListener('blur', onScroll)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      document.removeEventListener('scroll', onScroll, true)
      window.removeEventListener('resize', onScroll)
      window.removeEventListener('blur', onScroll)
    }
  }, [open, shut])

  return (
    <>
      <button
        ref={dot}
        type="button"
        className="hovernote-dot"
        aria-label={`More about ${label}`}
        aria-expanded={open}
        aria-describedby={id}
        onPointerEnter={() => setOpen(true)}
        onPointerLeave={() => {
          if (!pinned) shut()
        }}
        onFocus={() => setOpen(true)}
        onBlur={() => {
          if (!pinned) shut()
        }}
        onClick={() => {
          // A click on an already-pinned dot puts it away, which is the only
          // way to dismiss it on a screen with no pointer to move away.
          if (pinned) shut()
          else {
            setPinned(true)
            setOpen(true)
          }
        }}
      >
        <span aria-hidden="true">ⓘ</span>
      </button>
      {open &&
        createPortal(
          <div
            ref={box}
            id={id}
            className="hovernote"
            role="tooltip"
            data-side={at?.side ?? 'below'}
            // Rendered before it is placed, because it has to be laid out to be
            // measured. `data-placed` is what makes it visible, one layout
            // effect later, in the right place.
            data-placed={at === null ? undefined : 'true'}
            style={{ left: at?.left ?? 0, top: at?.top ?? 0 }}
          >
            {children}
          </div>,
          document.body,
        )}
    </>
  )
}
