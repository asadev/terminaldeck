import { useMemo } from 'react'
import { createPortal } from 'react-dom'
import type { AnnotatedElement, AnnotationRound } from '../../shared/annotate'
import type { NormRect } from '../../shared/device-tree'
import { AnnotateSurface, type Pick } from '../annotate/AnnotateSurface'
import type { BrowserCapture, CaptureRect } from './bridge'
import { readMarkedShot, type DrawApi } from './draw-bridge'
import type { Rect } from './devices'
import type { AgentTarget } from './useAgentTarget'

/**
 * Annotate in the browser: the shared surface, laid over the page.
 *
 * ## Where it starts
 *
 * Annotate (the toolbar button that was Inspect) is on, and the person clicks
 * an element of the live page. The main process answers with that element and
 * a photograph of the page at the instant of the click — exactly the capture
 * Inspect always produced. That capture is the first marker, and the photograph
 * is the frozen frame for the rest of the round.
 *
 * ## Over the page, not beside it
 *
 * A phone screen is narrow and sits beside the notes. A web page is the width
 * of the pane, and shrinking it to make room would put every marker somewhere
 * other than where the element was on screen a moment ago. So here the frozen
 * page fills the page's own rectangle at its own size and the notes float over
 * its right-hand edge, as the same glass card.
 *
 * Portalled into `<body>` and fixed over the page rectangle, like every popup
 * in this panel: the page is a native view composited above the renderer, and
 * `overlay-watch.ts` parks it only for something it can find there. The
 * workspace also parks it explicitly while a round is open, so not even one
 * frame of the live site sits over the picture.
 *
 * ## Units
 *
 * A capture's rectangle is in the page's CSS pixels. The photograph is in the
 * view's own pixels, which differ by the zoom this app may have applied to fit
 * the page (`browser-fit.ts`). Both picks — the first click and every later
 * point — are converted by the same function below, so they agree.
 */

interface Props {
  capture: BrowserCapture
  /** The page's rectangle in the window, which the photograph covers exactly. */
  rect: Rect
  zoom: number
  tabId: string
  title: string
  agent: AgentTarget
  pickAt?(tabId: string, x: number, y: number): Promise<BrowserCapture | null>
  save?(png: string, round: AnnotationRound): Promise<{ path: string; width: number; height: number }>
  sent?(roundId: string, sentTo: { sessionId: string; label: string }): Promise<void>
  /** Draw mode's save, used when this build's preload has no Annotate channel of its own. */
  drawApi: DrawApi
  onClose(): void
}

/** A capture's CSS-pixel rectangle as a fraction of the page's own rectangle. */
export function normalise(box: CaptureRect | null, rect: Rect, zoom: number): NormRect | null {
  if (!box || rect.width <= 0 || rect.height <= 0) return null
  const z = zoom > 0 ? zoom : 1
  const clamp = (v: number): number => Math.min(Math.max(v, 0), 1)
  const x = clamp((box.x * z) / rect.width)
  const y = clamp((box.y * z) / rect.height)
  return {
    x,
    y,
    width: Math.min(Math.max((box.width * z) / rect.width, 0), 1 - x),
    height: Math.min(Math.max((box.height * z) / rect.height, 0), 1 - y),
  }
}

/** What the agent is told about a page element: its tag, what it says, and the selector that finds it. */
export function elementFromCapture(capture: BrowserCapture): AnnotatedElement {
  const id = capture.attributes['id'] ?? ''
  return {
    ...(capture.tag ? { role: `<${capture.tag}>` } : {}),
    ...(capture.label ? { name: capture.label } : {}),
    ...(id ? { identifier: id } : {}),
    ...(capture.selector ? { selector: capture.selector } : {}),
  }
}

function pickFrom(capture: BrowserCapture, rect: Rect, zoom: number): Pick | null {
  const box = normalise(capture.rect, rect, zoom)
  return box ? { rect: box, element: elementFromCapture(capture) } : null
}

export function BrowserAnnotate({
  capture,
  rect,
  zoom,
  tabId,
  title,
  agent,
  pickAt,
  save,
  sent,
  drawApi,
  onClose,
}: Props) {
  // The first marker is the click that opened the round. Read once: a later
  // capture of the same tab is a new round, keyed by the parent.
  const initial = useMemo(() => pickFrom(capture, rect, zoom) ?? undefined, [capture])

  if (!capture.pageImage || typeof document === 'undefined') return null

  return createPortal(
    <AnnotateSurface
      frame={{ image: capture.pageImage, width: Math.round(rect.width), height: Math.round(rect.height) }}
      where={{ kind: 'browser', place: 'browser page', name: title, url: capture.url }}
      initial={initial}
      noun="page"
      layout="over"
      agent={agent}
      pick={async (x, y) => {
        if (!pickAt) return null
        const found = await pickAt(tabId, x * rect.width, y * rect.height).catch(() => null)
        return found ? pickFrom(found, rect, zoom) : null
      }}
      save={async (png, round) => {
        if (save) return await save(png, round).catch(() => null)
        // An older preload: Draw mode's own save writes the same folder with
        // the same rules. The round is just not remembered for the tools.
        if (typeof drawApi.browserScreenshotMarked !== 'function') return null
        const shot = readMarkedShot(await drawApi.browserScreenshotMarked(tabId, png).catch(() => null))
        return shot ? { path: shot.path, width: shot.width, height: shot.height } : null
      }}
      onSent={(roundId, to) => void sent?.(roundId, to).catch(() => undefined)}
      onClose={onClose}
      style={{ position: 'fixed', zIndex: 60, left: rect.x, top: rect.y, width: rect.width, height: rect.height }}
    />,
    document.body,
  )
}
