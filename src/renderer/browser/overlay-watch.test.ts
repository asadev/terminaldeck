import { describe, expect, it } from 'vitest'
import {
  browserOverlayDom,
  holdOverlay,
  intersects,
  isCovered,
  overlayRects,
  watchOverlays,
  type OverlayDom,
  type OverlayElement,
  type Rect,
} from './overlay-watch'

/**
 * The fault these pin is not "a tooltip is invisible" — it is that the obvious
 * fix does not work. A browser page is a native view composited above the whole
 * renderer, so no CSS can put HTML on top of it and the only lever is the view's
 * own visibility. That makes the decision *geometric*, and geometry is the part
 * worth testing.
 */

/** A stand-in for a DOM element, with the box a test wants it to have. */
function element(rect: Rect | null, inside: Record<string, OverlayElement> = {}): OverlayElement {
  const box = rect ?? { x: 0, y: 0, width: 0, height: 0 }
  return {
    getBoundingClientRect: () => ({
      left: box.x,
      top: box.y,
      width: box.width,
      height: box.height,
    }),
    querySelector: (selector) => inside[selector] ?? null,
  }
}

const STAGE: Rect = { x: 264, y: 96, width: 900, height: 700 }

describe('intersects', () => {
  it('is true when the boxes actually overlap', () => {
    expect(intersects(STAGE, { x: 300, y: 200, width: 200, height: 120 })).toBe(true)
  })

  it('is false for a box beside the stage', () => {
    // The ordinary case, and the reason this is geometric at all: a tooltip on a
    // sidebar row must not blank a website.
    expect(intersects(STAGE, { x: 0, y: 200, width: 240, height: 30 })).toBe(false)
  })

  it('does not count a shared edge as an overlap', () => {
    expect(intersects(STAGE, { x: 0, y: 96, width: 264, height: 40 })).toBe(false)
  })

  it('is false for a box with no area, whatever its position', () => {
    expect(intersects(STAGE, { x: 300, y: 200, width: 0, height: 120 })).toBe(false)
    expect(intersects(STAGE, { x: 300, y: 200, width: 200, height: 0 })).toBe(false)
  })
})

describe('isCovered', () => {
  it('reports the one overlay that lands on the page, out of several that do not', () => {
    expect(
      isCovered(STAGE, [
        { x: 0, y: 120, width: 264, height: 28 },
        { x: 400, y: 300, width: 320, height: 180 },
        { x: 0, y: 0, width: 264, height: 44 },
      ]),
    ).toBe(true)
  })

  it('leaves the page alone when nothing reaches it', () => {
    expect(isCovered(STAGE, [{ x: 0, y: 120, width: 264, height: 28 }])).toBe(false)
    expect(isCovered(STAGE, [])).toBe(false)
  })

  it('never parks a page whose stage has not been measured', () => {
    // A panel on a hidden tab has no box. Reporting it as covered would hide a
    // page for a reason that has nothing to do with overlays, and it would
    // never come back, because a hidden panel is never measured again.
    const unmeasured = { x: 0, y: 0, width: 0, height: 0 }
    expect(isCovered(unmeasured, [{ x: 0, y: 0, width: 400, height: 400 }])).toBe(false)
  })
})

describe('overlayRects', () => {
  it('ignores the app itself, which is a child of body like any other', () => {
    /*
     * The one that would have shipped. `.app` is a *grandchild* of `<body>` —
     * `index.html` mounts React into `#root` — so an exclusion written against
     * `.app` matches nothing in `body.children`, `#root` is counted as an
     * overlay covering the whole window, and every browser page is parked
     * forever with nothing on screen to explain it. Typechecks perfectly.
     */
    const app = element({ x: 0, y: 0, width: 1440, height: 900 })
    expect(overlayRects({ children: [app] }, app)).toEqual([])
  })

  it('collects the portals that a menu, a tooltip and a dialog become', () => {
    const app = element({ x: 0, y: 0, width: 1440, height: 900 })
    const menu = element({ x: 300, y: 100, width: 260, height: 300 })
    const tip = element({ x: 20, y: 400, width: 180, height: 32 })
    const rects = overlayRects({ children: [app, menu, tip] }, app)
    expect(rects).toEqual([
      { x: 300, y: 100, width: 260, height: 300 },
      { x: 20, y: 400, width: 180, height: 32 },
    ])
  })

  it('skips an empty portal container, which React leaves mounted between openings', () => {
    // Counting one would park every page permanently, which is worse than the
    // bug this module is fixing.
    const app = element({ x: 0, y: 0, width: 1440, height: 900 })
    const emptyContainer = element(null)
    expect(overlayRects({ children: [app, emptyContainer] }, app)).toEqual([])
  })

  it('counts the peeked sidebar, which is the flyout he named', () => {
    /*
     * The peeked rail is the one floating surface that is not a portal: it is
     * `position: absolute` inside the app. `Sidebar.tsx` sets `data-peek` only
     * while it is floating, so the attribute's presence IS the state and there
     * is nothing to gate on.
     */
    const rail = element({ x: 0, y: 0, width: 264, height: 900 })
    const root = element({ x: 0, y: 0, width: 1440, height: 900 }, { '[data-peek]': rail })
    expect(overlayRects({ children: [root] }, root)).toEqual([
      { x: 0, y: 0, width: 264, height: 900 },
    ])
  })

  it('finds nothing while the rail is pinned or away', () => {
    const root = element({ x: 0, y: 0, width: 1440, height: 900 })
    expect(overlayRects({ children: [root] }, root)).toEqual([])
  })

  it('survives a body with no app root at all', () => {
    const stray = element({ x: 10, y: 10, width: 40, height: 40 })
    expect(overlayRects({ children: [stray] }, null)).toEqual([
      { x: 10, y: 10, width: 40, height: 40 },
    ])
  })
})

describe('holdOverlay', () => {
  it('adds a surface that is neither a portal nor the rail, and takes it away again', () => {
    const app = element({ x: 0, y: 0, width: 1440, height: 900 })
    const release = holdOverlay({ x: 500, y: 500, width: 100, height: 100 })
    expect(overlayRects({ children: [app] }, app)).toEqual([
      { x: 500, y: 500, width: 100, height: 100 },
    ])
    release()
    expect(overlayRects({ children: [app] }, app)).toEqual([])
  })

  it('is safe to release twice', () => {
    const app = element({ x: 0, y: 0, width: 1440, height: 900 })
    const release = holdOverlay({ x: 1, y: 1, width: 2, height: 2 })
    release()
    release()
    expect(overlayRects({ children: [app] }, app)).toEqual([])
  })
})

describe('watchOverlays', () => {
  /** A fake DOM that records what was observed and lets a test fire it. */
  function fakeDom(): {
    dom: OverlayDom
    fire(): void
    runFrame(): void
    pending(): boolean
    observed: string[]
    disconnected: number
    subtreeChildList: boolean
  } {
    const triggers: Array<() => void> = []
    let pendingFrame: (() => void) | null = null
    const observed: string[] = []
    let disconnected = 0
    let subtreeChildList = false
    const app = element({ x: 0, y: 0, width: 1440, height: 900 })
    const portal = element({ x: 300, y: 100, width: 200, height: 200 })

    const dom: OverlayDom = {
      body: { children: [app, portal] },
      appRoot: app,
      observe: (_target, options, run) => {
        if (options.childList && options.subtree) subtreeChildList = true
        observed.push(options.childList ? 'childList' : (options.attributeFilter ?? []).join(','))
        triggers.push(run)
        return () => {
          disconnected += 1
        }
      },
      addEventListener: (type, run) => {
        observed.push(type)
        triggers.push(run)
        return () => {
          disconnected += 1
        }
      },
      frame: (run) => {
        pendingFrame = run
        return () => {
          pendingFrame = null
        }
      },
    }

    return {
      dom,
      fire: () => triggers.forEach((run) => run()),
      runFrame: () => {
        const run = pendingFrame
        pendingFrame = null
        run?.()
      },
      pending: () => pendingFrame !== null,
      observed,
      get disconnected() {
        return disconnected
      },
      get subtreeChildList() {
        return subtreeChildList
      },
    }
  }

  it('never watches the document’s child list in a subtree', () => {
    // That observer would fire on every character a terminal prints. Attribute
    // observation with a filter is a string compare and can afford `subtree`;
    // childList observation cannot, and this is the guard on that distinction.
    const fake = fakeDom()
    const stop = watchOverlays(fake.dom, () => undefined)
    expect(fake.observed).toEqual([
      'childList',
      'data-sidebar-peek,data-peek',
      'scroll',
      'resize',
    ])
    expect(fake.subtreeChildList).toBe(false)
    stop()
  })

  it('measures a frame later, because a portal is positioned after it mounts', () => {
    /*
     * The failure this prevents: a menu is mounted at 0,0 and moved into place
     * by a layout effect. Measuring inside the mutation callback measures it
     * over the sidebar, so the page it is actually covering is never parked.
     */
    const fake = fakeDom()
    const seen: Rect[][] = []
    const stop = watchOverlays(fake.dom, (rects) => seen.push(rects))
    expect(seen).toEqual([])
    fake.runFrame()
    expect(seen).toEqual([[{ x: 300, y: 100, width: 200, height: 200 }]])
    stop()
  })

  it('coalesces a burst of mutations into one frame', () => {
    const fake = fakeDom()
    const stop = watchOverlays(fake.dom, () => undefined)
    fake.runFrame()
    fake.fire()
    fake.fire()
    fake.fire()
    // Three mutations, one pending frame: running it once drains all of them.
    expect(fake.pending()).toBe(true)
    fake.runFrame()
    expect(fake.pending()).toBe(false)
    stop()
  })

  it('says nothing when a recompute finds the same rectangles', () => {
    /*
     * `scroll` fires continuously while any panel in the window is scrolled,
     * and the consumer is React state. Without this, scrolling a long file tree
     * would re-render the browser workspace every frame to arrive at the same
     * list each time.
     */
    const fake = fakeDom()
    const seen: Rect[][] = []
    const stop = watchOverlays(fake.dom, (rects) => seen.push(rects))
    fake.runFrame()
    expect(seen.length).toBe(1)
    fake.fire()
    fake.runFrame()
    fake.fire()
    fake.runFrame()
    expect(seen.length).toBe(1)
    stop()
  })

  it('detaches everything it attached, and reports nothing afterwards', () => {
    const fake = fakeDom()
    const seen: Rect[][] = []
    const stop = watchOverlays(fake.dom, (rects) => seen.push(rects))
    stop()
    fake.runFrame()
    fake.fire()
    expect(seen).toEqual([])
    expect(fake.disconnected).toBe(4)
  })
})

describe('browserOverlayDom', () => {
  it('says there is nothing to watch rather than throwing in a Node test run', () => {
    // This project's tests have no DOM. A module that assumed one would take
    // every static-markup render of the workspace down with it.
    expect(typeof document).toBe('undefined')
    expect(browserOverlayDom()).toBeNull()
  })
})
