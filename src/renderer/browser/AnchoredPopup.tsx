import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { anchorPopup, type Box } from './popup-anchor'

interface Props {
  /** Where the popup should point, in window CSS pixels. */
  anchor: Box
  /** Names the popup for screen readers. */
  label: string
  onClose(): void
  children: ReactNode
}

/**
 * A small floating panel placed against a rectangle, portalled into `<body>`.
 *
 * ## The portal is load-bearing, not a habit
 *
 * A browser page here is a native `WebContentsView` composited above the whole
 * renderer, so no `z-index` can put HTML over it — `overlay-watch.ts` is a full
 * essay on that. The one mechanism that works is the workspace hiding the native
 * view while something is over its rectangle, and the way the workspace *finds*
 * those somethings is by watching `<body>`'s child list. Rendering this popup
 * inside the workspace's own tree instead would leave it painted underneath the
 * web page, which is precisely the fault he reported of another popup:
 * *"whatever the message popup is coming, it's hiding behind. I cannot even see
 * what it shows."*
 *
 * So: portal to body, and the page parks for as long as the popup is open. That
 * is a real trade — the website is not on screen while you type — and it is the
 * only arrangement in which the popup can be seen at all.
 *
 * ## Measured, then placed
 *
 * Two passes. The first render is invisible and unpositioned so the box can be
 * measured; a layout effect then computes the placement from the real size and
 * the real window. Guessing a height instead is how a popup ends up hanging off
 * the bottom of the screen for exactly the elements near the bottom of the page.
 */
export function AnchoredPopup({ anchor, label, onClose, children }: Props) {
  const ref = useRef<HTMLDivElement | null>(null)
  const [placed, setPlaced] = useState<{ left: number; top: number } | null>(null)

  useLayoutEffect(() => {
    const node = ref.current
    if (!node || typeof window === 'undefined') return
    const box = node.getBoundingClientRect()
    const next = anchorPopup(
      anchor,
      { width: box.width, height: box.height },
      { width: window.innerWidth, height: window.innerHeight },
    )
    setPlaced({ left: next.left, top: next.top })
  }, [anchor, children])

  useEffect(() => {
    if (typeof window === 'undefined') return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        // Stopped here rather than left to bubble: the workspace also binds
        // Escape, to turn inspection off. Closing the popup should not also end
        // the mode that produced it — you are usually about to click something
        // else.
        event.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [onClose])

  if (typeof document === 'undefined') return null

  return createPortal(
    <div
      ref={ref}
      className="bw-popup"
      role="dialog"
      aria-label={label}
      style={
        placed
          ? { left: placed.left, top: placed.top }
          : // First pass: laid out where it will roughly land, but not painted,
            // so measuring it cannot flash an unplaced box on screen.
            { left: 0, top: 0, visibility: 'hidden' }
      }
    >
      <button type="button" className="bw-popup-close" aria-label="Close" onClick={onClose}>
        <svg
          width="12"
          height="12"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          aria-hidden="true"
        >
          <path d="M6 6l12 12M18 6L6 18" />
        </svg>
      </button>
      {children}
    </div>,
    document.body,
  )
}
