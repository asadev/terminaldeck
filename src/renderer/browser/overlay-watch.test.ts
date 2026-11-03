import { describe, expect, it } from 'vitest'
import * as watch from './overlay-watch'
import {
  browserOverlayDom,
  isCovered,
  overlap,
  overlayRects,
  watchOverlays,
  type Overlay,
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
function element(
  rect: Rect | null,
  inside: Record<string, OverlayElement> = {},
  role: string | null = null,
): OverlayElement {
  const box = rect ?? { x: 0, y: 0, width: 0, height: 0 }
  return {
    getBoundingClientRect: () => ({
      left: box.x,
      top: box.y,
      width: box.width,
      height: box.height,
    }),
    querySelector: (selector) => inside[selector] ?? null,
    getAttribute: (name) => (name === 'role' ? role : null),
  }
}

/** The same element, wearing the one attribute that says "hover hint". */
function tooltip(rect: Rect): OverlayElement {
  return element(rect, {}, 'tooltip')
}

const STAGE: Rect = { x: 264, y: 96, width: 900, height: 700 }

describe('overlap', () => {
  it('answers the shared rectangle when the boxes actually overlap', () => {
    expect(overlap(STAGE, { x: 300, y: 200, width: 200, height: 120 })).toEqual({
      x: 300,
      y: 200,
      width: 200,
      height: 120,
    })
  })

  it('clips the shared rectangle into the stage', () => {
    // The half of a menu that is over the sidebar is not over the page, and
    // every judgement downstream is about the part that is.
    expect(overlap(STAGE, { x: 200, y: 60, width: 200, height: 100 })).toEqual({
      x: 264,
      y: 96,
      width: 136,
      height: 64,
    })
  })

  it('is null for a box beside the stage', () => {
    // The ordinary case, and the reason this is geometric at all: a tooltip on a
    // sidebar row must not blank a website.
    expect(overlap(STAGE, { x: 0, y: 200, width: 240, height: 30 })).toBeNull()
  })

  it('does not count a shared edge as an overlap', () => {
    expect(overlap(STAGE, { x: 0, y: 96, width: 264, height: 40 })).toBeNull()
  })

  it('is null for a box with no area, whatever its position', () => {
    expect(overlap(STAGE, { x: 300, y: 200, width: 0, height: 120 })).toBeNull()
    expect(overlap(STAGE, { x: 300, y: 200, width: 200, height: 0 })).toBeNull()
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

/**
 * The rule that used to be "any intersection at all", measured off the screen
 * rather than invented.
 *
 * Every rectangle below was read out of the built app on 2026-08-17 with a page
 * loaded into the browser workspace, and photographed. The first case is the
 * one that shipped as a bug: a 136×24 tooltip clipping the page's top edge by
 * 21px blanked a 587×644 website for as long as the pointer rested on a toolbar
 * button. The rest are the surfaces that must keep parking it, so that softening
 * the rule cannot be taken further by anybody reading only the first test.
 */
describe('isCovered, on the real geometry it got wrong', () => {
  /** The browser workspace's page stage, split beside a terminal. */
  const PAGE: Rect = { x: 845, y: 182, width: 587, height: 644 }

  it('does not park a page for a tooltip that clips its top edge', () => {
    // `Cookies and site data`, hanging off the browser toolbar's last button.
    // The toolbar's buttons end 9px above the page and `placeTip` hangs a bubble
    // 6px below its anchor, so it starts 3px clear and reaches 21px in.
    expect(
      isCovered(PAGE, [{ x: 1296, y: 179, width: 135.90625, height: 24.375, hint: true }]),
    ).toBe(false)
  })

  it('parks it for a dialog, which arrives as a full-window scrim', () => {
    // Measured with the Cookies dialog open: `Modal.tsx` portals a
    // `.modal-overlay` the size of the window, so a dialog is never a near miss.
    expect(isCovered(PAGE, [{ x: 0, y: 0, width: 1440, height: 920 }])).toBe(true)
  })

  it('parks it for a paragraph of tooltip lying on the page', () => {
    // The Shared/Isolated toggle's title is three lines. From the same toolbar
    // row as the Cookies bubble, it reaches 64px in — and a reader who cannot
    // see it has lost something, which is what the 21px bubble had not.
    expect(isCovered(PAGE, [{ x: 1025, y: 179, width: 320, height: 67.5, hint: true }])).toBe(
      true,
    )
  })

  it('parks it for a menu opened over the page', () => {
    // The account menu, at the size it opens: 420×313. Small next to the page
    // and still the whole reason this module exists.
    expect(isCovered(PAGE, [{ x: 900, y: 300, width: 420, height: 313 }])).toBe(true)
  })

  it('parks it for the peeked rail across the page’s left edge', () => {
    // 264 wide and the height of the window. Flush with an edge, like the
    // tooltip, and nothing like a graze.
    expect(isCovered(PAGE, [{ x: 700, y: 0, width: 264, height: 920 }])).toBe(true)
  })

  it('parks it for a shallow band that is not against an edge', () => {
    /*
     * The test that stops this being read as "small overlays are ignored". A
     * banner 24px tall lying across the middle of the page is exactly as shallow
     * as the Cookies tooltip and every pixel of it would be painted over, so it
     * has to park the page. What made the tooltip different was its position,
     * not its size.
     */
    expect(isCovered(PAGE, [{ x: 845, y: 500, width: 587, height: 24, hint: true }])).toBe(true)
  })

  it('treats all four edges the same way', () => {
    const graze = 20
    const land = 60
    for (const [shallow, deep] of [
      // top
      [
        { x: 900, y: PAGE.y - 4, width: 200, height: graze + 4, hint: true },
        { x: 900, y: PAGE.y - 4, width: 200, height: land + 4, hint: true },
      ],
      // bottom
      [
        { x: 900, y: PAGE.y + PAGE.height - graze, width: 200, height: 80, hint: true },
        { x: 900, y: PAGE.y + PAGE.height - land, width: 200, height: 200, hint: true },
      ],
      // left
      [
        { x: PAGE.x - 100, y: 300, width: 100 + graze, height: 200, hint: true },
        { x: PAGE.x - 100, y: 300, width: 100 + land, height: 200, hint: true },
      ],
      // right
      [
        { x: PAGE.x + PAGE.width - graze, y: 300, width: 200, height: 200, hint: true },
        { x: PAGE.x + PAGE.width - land, y: 300, width: 200, height: 200, hint: true },
      ],
    ]) {
      expect(isCovered(PAGE, [shallow])).toBe(false)
      expect(isCovered(PAGE, [deep])).toBe(true)
    }
  })

  it('parks it for one real overlay among several grazes', () => {
    expect(
      isCovered(PAGE, [
        { x: 1296, y: 179, width: 136, height: 24, hint: true },
        { x: 0, y: 400, width: 264, height: 28, hint: true },
        { x: 0, y: 0, width: 1440, height: 920 },
      ]),
    ).toBe(true)
  })

  /**
   * The toolbar's own menus, measured off the recording of 2026-08-21.
   *
   * *"if I now click on three dots, the drop-down is coming in the backside,
   * both of them. They should be the top first layer."* The profile menu opens
   * from a button 25px above the page and is 61px tall, so it reaches 26px in —
   * under the 32 this module calls a graze, which is why the page stayed
   * composited and the menu's second row was painted over. A menu is not a
   * hint, so the depth is not the question.
   */
  describe('the browser toolbar’s menus, which are not hints', () => {
    /** The stage in that frame: full width of the panel, under a drive banner. */
    const FRAME: Rect = { x: 252, y: 114, width: 1348, height: 828 }
    /** `.bw-popup` holding the profile menu, hanging off the `D` button. */
    const PROFILE_MENU: Overlay = { x: 1266, y: 79, width: 326, height: 61 }

    it('parks the page for a short menu clipping its top edge', () => {
      expect(isCovered(FRAME, [PROFILE_MENU])).toBe(true)
    })

    it('would not have, while the rule was written as a depth in pixels', () => {
      // The same rectangle called a hint is the old answer, and it is kept as
      // the statement of what changed: 26px of overlap, flush with the top.
      expect(isCovered(FRAME, [{ ...PROFILE_MENU, hint: true }])).toBe(false)
    })

    it('parks it for the ⋯ menu beside it, which shares the anchor', () => {
      // `BrowserMenu` is narrower — 19rem — and taller, because every row is a
      // verb. Same corner, same top edge.
      expect(isCovered(FRAME, [{ x: 1288, y: 79, width: 304, height: 148 }])).toBe(true)
    })
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
    const tip = tooltip({ x: 20, y: 400, width: 180, height: 32 })
    const rects = overlayRects({ children: [app, menu, tip] }, app)
    expect(rects).toEqual([
      { x: 300, y: 100, width: 260, height: 300, hint: false },
      { x: 20, y: 400, width: 180, height: 32, hint: true },
    ])
  })

  it('marks a surface a hint from its role and from nothing else', () => {
    /*
     * `role="tooltip"` is written by `Tooltips.tsx` and `HoverNote.tsx` because
     * a screen reader needs it, so it is a fact that is already maintained. A
     * rule keyed on a class name would be a second spelling of it, and the next
     * hint somebody writes is the one that forgets the second spelling.
     */
    const app = element({ x: 0, y: 0, width: 1440, height: 900 })
    const dialog = element({ x: 300, y: 100, width: 260, height: 300 }, {}, 'dialog')
    const bubble = tooltip({ x: 20, y: 400, width: 180, height: 32 })
    expect(overlayRects({ children: [app, dialog, bubble] }, app)).toEqual([
      { x: 300, y: 100, width: 260, height: 300, hint: false },
      { x: 20, y: 400, width: 180, height: 32, hint: true },
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
      { x: 0, y: 0, width: 264, height: 900, hint: false },
    ])
  })

  it('finds nothing while the rail is pinned or away', () => {
    const root = element({ x: 0, y: 0, width: 1440, height: 900 })
    expect(overlayRects({ children: [root] }, root)).toEqual([])
  })

  it('survives a body with no app root at all', () => {
    const stray = element({ x: 10, y: 10, width: 40, height: 40 })
    expect(overlayRects({ children: [stray] }, null)).toEqual([
      { x: 10, y: 10, width: 40, height: 40, hint: false },
    ])
  })
})

describe('nothing here outlives the call that measured it', () => {
  /*
   * This module used to export `holdOverlay`, a registry a floating surface
   * could push its rectangle into, with a release function to take it out
   * again. It had no callers, and it could not have been right for the ones it
   * named: it took a *static* rectangle, so a surface that moved or resized —
   * the peeked rail, which is the case it was written for — would have parked
   * the wrong part of the window, and a caller that unmounted without calling
   * release would have parked every page for the rest of the process with
   * nothing on screen to explain it. `overlayRects` skipped it another way, and
   * the newest floating surface in the app, driving mode's focus overlay, went
   * further and mounted itself inside `#root` so this module cannot see it at
   * all.
   *
   * So the export list is the guard. Putting a registry back has to be a
   * deliberate act by somebody who has read this, arriving with the surface
   * that needs it rather than ahead of one.
   */
  it('exports only measurement, and no way to register a rectangle', () => {
    expect(Object.keys(watch).sort()).toEqual([
      // A selector, which is a fact about the DOM rather than a place to keep
      // one. `Tooltips.tsx` reads it and measures for itself.
      'NATIVE_VIEW_SELECTOR',
      'browserOverlayDom',
      'isCovered',
      'overlap',
      'overlayRects',
      'sameRects',
      'watchOverlays',
    ])
  })

  it('answers from the body it was handed and from nothing else', () => {
    const app = element({ x: 0, y: 0, width: 1440, height: 900 })
    expect(overlayRects({ children: [app] }, app)).toEqual([])
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
    const seen: Overlay[][] = []
    const stop = watchOverlays(fake.dom, (rects) => seen.push(rects))
    expect(seen).toEqual([])
    fake.runFrame()
    expect(seen).toEqual([[{ x: 300, y: 100, width: 200, height: 200, hint: false }]])
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
    const seen: Overlay[][] = []
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
    const seen: Overlay[][] = []
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
