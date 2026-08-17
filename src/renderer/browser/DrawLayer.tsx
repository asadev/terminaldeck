import { useCallback, useEffect, useImperativeHandle, useRef, type PointerEvent, type Ref } from 'react'
import {
  beginMark,
  extendMark,
  isDrawn,
  markColor,
  paintMarks,
  type Mark,
  type MarkKind,
  type Point,
} from './marks'
import type { PageFrame } from './draw-bridge'

/**
 * What the workspace can ask the layer for once the user is finished.
 *
 * One method, and it hands back the very bitmap on screen. That is deliberate:
 * the alternative is composing a second image somewhere else from the same
 * marks, and the whole promise of this feature is that the agent receives the
 * picture he drew, not a reconstruction of it.
 */
export interface DrawSurface {
  /** The frame with the marks on it, as a `data:image/png` URL, or ''. */
  toPng(): string
}

interface Props {
  frame: PageFrame
  marks: Mark[]
  /** Which shape the next drag makes. */
  tool: MarkKind
  /** Where the page's native view is, in window CSS pixels. */
  rect: { x: number; y: number; width: number; height: number }
  /** The stage's own origin, because the layer is positioned inside it. */
  origin: { x: number; y: number }
  onMarks(next: Mark[]): void
  surface: Ref<DrawSurface>
}

/**
 * The canvas you mark a page on.
 *
 * ## Why the page is not underneath this — it is inside it
 *
 * A browser page here is a native `WebContentsView` composited above the entire
 * renderer, so nothing in the DOM can be painted on top of one. `overlay-watch.ts`
 * is the full essay; the consequence for this component is that a transparent
 * canvas "over the page" is impossible, and the only arrangement that works is
 * the workspace parking the native view and this canvas drawing a *photograph*
 * of it. That photograph is `frame.image`, taken by the main process a moment
 * before the view was parked.
 *
 * Which turns out to be exactly what the feature needed anyway, and it answers
 * two of the requirements outright:
 *
 *  - **The overlay must not receive the page's input while drawing.** It cannot.
 *    The page is not composited, so it gets no pointer events at all — there is
 *    no hit-testing race to lose, no `pointer-events` rule to get wrong, and no
 *    way for a drag over a link to navigate.
 *  - **It must come off cleanly.** Leaving draw mode unparks the view. The
 *    WebContents kept running the whole time with its scroll position and its
 *    DOM intact; nothing was injected into it and nothing has to be undone.
 *
 * ## One canvas, at the frame's own resolution
 *
 * The element is *displayed* at the page's rectangle in CSS pixels and its
 * backing store is `frame.width` x `frame.height` device pixels, so the marks
 * are drawn once, crisply, and the PNG that gets saved is `toDataURL()` of this
 * same canvas. There is no second compositing step and therefore no chance of
 * the saved image disagreeing with what was on screen — no scaling factor to get
 * backwards, no stroke width that looks right in one and wrong in the other.
 */
export function DrawLayer({ frame, marks, tool, rect, origin, onMarks, surface }: Props) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null)
  /** The frame's bitmap, decoded once and kept — repainting happens per move. */
  const imageRef = useRef<HTMLImageElement | null>(null)
  /** The mark under the pointer right now, which is not in `marks` until it ends. */
  const liveRef = useRef<Mark | null>(null)
  const marksRef = useRef<Mark[]>(marks)
  marksRef.current = marks

  const repaint = useCallback((): void => {
    const canvas = canvasRef.current
    const ctx = canvas?.getContext('2d')
    if (!canvas || !ctx) return

    ctx.clearRect(0, 0, canvas.width, canvas.height)
    const image = imageRef.current
    // Only once it has decoded. An undrawn frame is a transparent canvas over
    // the app's own canvas, which is honest — nothing is invented to fill it.
    if (image) ctx.drawImage(image, 0, 0, canvas.width, canvas.height)

    const live = liveRef.current
    paintMarks(
      ctx,
      live ? [...marksRef.current, live] : marksRef.current,
      canvas.width,
      canvas.height,
      markColor(canvas),
    )
  }, [])

  /* -- decode the frame once per capture, then paint. */
  useEffect(() => {
    if (typeof Image === 'undefined') return
    const image = new Image()
    let live = true
    image.onload = () => {
      if (!live) return
      imageRef.current = image
      repaint()
    }
    image.src = frame.image
    return () => {
      live = false
      imageRef.current = null
    }
  }, [frame.image, repaint])

  /* -- and whenever the mark list changes under us: undo, clear, a new tool. */
  useEffect(repaint, [marks, repaint])

  /*
   * Take focus, so Escape reaches the workspace.
   *
   * The panel binds Escape on its own wrapper rather than on the window —
   * deliberately, so a browser page open in a background tab cannot swallow a
   * key the rest of the app wants. The consequence is that Escape only works
   * while something inside the panel has focus, and a `<canvas>` is not
   * focusable on its own: clicking it to draw would leave focus wherever it
   * happened to be, and the one documented way out of draw mode would work or
   * not depending on what the user last clicked.
   *
   * `-1` rather than `0`: this is not a tab stop. It is the element the pointer
   * is already on, and it should not join the keyboard order of a toolbar it is
   * not part of.
   */
  useEffect(() => {
    canvasRef.current?.focus({ preventScroll: true })
  }, [])

  useImperativeHandle(
    surface,
    () => ({
      toPng: (): string => {
        const canvas = canvasRef.current
        if (!canvas) return ''
        try {
          return canvas.toDataURL('image/png')
        } catch {
          // A tainted canvas cannot be read back. It should be impossible here —
          // the frame is a `data:` URL this app produced — but returning '' lets
          // the workspace say so instead of writing `undefined` to a file.
          return ''
        }
      },
    }),
    [],
  )

  /** Where a pointer is, as a fraction of the frame. */
  const pointAt = (event: PointerEvent<HTMLCanvasElement>): Point => {
    const box = event.currentTarget.getBoundingClientRect()
    return {
      x: box.width > 0 ? (event.clientX - box.left) / box.width : 0,
      y: box.height > 0 ? (event.clientY - box.top) / box.height : 0,
    }
  }

  const onDown = (event: PointerEvent<HTMLCanvasElement>): void => {
    if (event.button !== 0) return
    // Capture, so a drag that leaves the canvas — off the top of the page, over
    // the toolbar — keeps drawing and keeps its pointerup. Without it a stroke
    // that goes past the edge never ends and the next click continues it.
    event.currentTarget.setPointerCapture(event.pointerId)
    liveRef.current = beginMark(tool, pointAt(event))
    repaint()
  }

  const onMove = (event: PointerEvent<HTMLCanvasElement>): void => {
    if (!liveRef.current) return
    liveRef.current = extendMark(liveRef.current, pointAt(event))
    repaint()
  }

  const onUp = (event: PointerEvent<HTMLCanvasElement>): void => {
    const live = liveRef.current
    liveRef.current = null
    if (!live) return
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
    // A click that the trackpad turned into a one-pixel drag is not a mark. See
    // `isDrawn`: keeping those leaves invisible specks that Undo has to be
    // pressed for, once each, with nothing disappearing from the screen.
    if (isDrawn(live)) onMarks([...marksRef.current, live])
    else repaint()
  }

  return (
    <canvas
      ref={canvasRef}
      className="bw-draw"
      width={frame.width}
      height={frame.height}
      // The page's own rectangle, so the photograph lands exactly where the view
      // was and the marks land exactly where the user thinks they are pointing.
      style={{
        left: rect.x - origin.x,
        top: rect.y - origin.y,
        width: rect.width,
        height: rect.height,
      }}
      role="application"
      aria-label="Draw on the page"
      tabIndex={-1}
      onPointerDown={onDown}
      onPointerMove={onMove}
      onPointerUp={onUp}
      onPointerCancel={onUp}
    />
  )
}
