import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { BrowserWorkspace } from './BrowserWorkspace'
import { BRIDGE_METHODS, type BrowserBridge } from './bridge'
import { measureSlots, slotStyle, SLOT_ATTR, type SlotElement, type SlotHost } from '../layout/pane-slots'

/**
 * A terminal beside a live page, and the page still being the page afterwards.
 *
 * ## Why this file exists
 *
 * *"Entering a split reloads the page that pane holds."* It was every page once
 * and had been fixed down to this one: the split renderer mounted the panel
 * *inside* whichever pane was holding the page, moving a component between two
 * subtrees is a remount, and an unmounting `BrowserWorkspace` closes its
 * `WebContentsView` for real — so pressing Split reloaded the site under
 * somebody who had asked for a layout. The pane draws an empty hole now and the
 * panel stays where it was mounted, given the hole's rectangle.
 *
 * That change was correct by construction and by the pattern `.remote-pane`
 * already uses, and **unmeasured**: no screenshot exists of a terminal beside a
 * live page in a split, or of the page surviving the press. There is no DOM
 * here and no window to open, so what is measured instead is the whole of what
 * the press does to this panel — which is arithmetic and one prop.
 *
 *  - `layout/pane-slots.ts` turns a real split's rectangles into the pane's own
 *    coordinates. Its own tests hold the arithmetic; this one joins it to the
 *    panel that has to stand in the hole.
 *  - The panel takes the box and **nothing else changes**. That is the claim the
 *    remount broke: a remount changes everything, starting with which
 *    `WebContentsView` is on screen. Here the two renders are compared whole.
 *
 * The other half — that a rectangle and a visibility can never lose a page — is
 * measured against the real main process in `main/browser-tab.test.ts`, where
 * the view that used to be destroyed actually lives.
 */

/**
 * A bridge that answers nothing, built from the list the panel is checked
 * against.
 *
 * Nothing calls a method: effects do not run under `renderToStaticMarkup`, which
 * is the whole reason this file is about markup and not behaviour. It is built
 * off `BRIDGE_METHODS` rather than written out so it cannot go stale — a method
 * added to the bridge appears here the same day, and `BrowserWorkspace.test.tsx`
 * is what pins that list against the interface.
 */
const bridge = Object.fromEntries(
  BRIDGE_METHODS.map((name) => [name, () => undefined]),
) as unknown as BrowserBridge

function slot(id: string, box: { top: number; left: number; width: number; height: number }): SlotElement {
  return {
    getAttribute: (name) => (name === SLOT_ATTR ? id : null),
    getBoundingClientRect: () => box,
  }
}

function host(slots: readonly SlotElement[]): SlotHost {
  return {
    // The pane area: below the tab strip, right of the sidebar. Viewport
    // coordinates, because that is what a browser hands back and the offset is
    // exactly what `measureSlots` exists to remove.
    getBoundingClientRect: () => ({ top: 96, left: 264, width: 1200, height: 704 }),
    querySelectorAll: () => slots,
  }
}

/**
 * The window Asad describes: a terminal in the left pane, a page in the right.
 *
 * Only the page draws a hole. A local terminal is redrawn from the main
 * process's scrollback, so the split view mounts it inside its pane and no slot
 * is needed for it — see `pane-slots.ts` for which three kinds of pane cannot
 * take that and why a page is one of them.
 */
const SPLIT = host([slot('page-1', { top: 96, left: 872, width: 592, height: 704 })])

/** The opening tag of the panel's root, and everything after it. */
function split(markup: string): { root: string; body: string } {
  const end = markup.indexOf('>')
  return { root: markup.slice(0, end + 1), body: markup.slice(end + 1) }
}

const panel = (box?: Record<string, string>): string =>
  renderToStaticMarkup(<BrowserWorkspace bridge={bridge} tabId="page-1" visible box={box} />)

describe('a page in one pane of a split', () => {
  it('is given the hole the pane left, in the pane area’s own coordinates', () => {
    const boxes = measureSlots(SPLIT)
    // 872 - 264 across, 96 - 96 down: hard against the top of the pane area and
    // starting where the divider is. Handed viewport numbers instead, the page
    // would be drawn one sidebar-width too far right, over nothing.
    expect(boxes['page-1']).toEqual({ top: 0, left: 608, width: 592, height: 704 })

    const style = slotStyle(boxes['page-1'])
    expect(style).toEqual({
      // The four sides are released before they are set: the stylesheet fills
      // the pane area with `inset: 0`, and a `top` alone would leave the panel
      // pinned to the far edges and stretched rather than moved.
      inset: 'auto',
      top: '0px',
      left: '608px',
      width: '592px',
      height: '704px',
    })
  })

  it('draws itself over that hole rather than in the flow of the window', () => {
    const markup = panel(slotStyle(measureSlots(SPLIT)['page-1']))
    expect(markup).toContain('data-boxed="true"')
    expect(markup).toContain('left:608px')
    expect(markup).toContain('width:592px')
    // `.bw[data-boxed='true']` is what takes it out of the flow; without the
    // attribute the inline geometry describes a block that is still in it.
    expect(split(markup).root).toContain('inset:auto')
  })

  it('is the same panel before and after the press, and only its box moves', () => {
    /*
     * The claim the remount broke, stated in the only units available without a
     * window: entering a split changes where this panel is drawn and nothing
     * else about it. Not its toolbar, not its address, not which page it is.
     *
     * A remount cannot pass this even in principle — it is a different
     * component instance with a different `WebContentsView` behind it, and the
     * address it comes back at is the start page rather than the one somebody
     * was reading. What that costs is measured against the real main process in
     * `main/browser-tab.test.ts`; what is pinned here is that the layout path
     * touches one attribute and one style.
     */
    const unsplit = split(panel())
    const boxed = split(panel(slotStyle(measureSlots(SPLIT)['page-1'])))

    expect(boxed.body).toBe(unsplit.body)
    expect(boxed.root).not.toBe(unsplit.root)
  })

  it('goes back to filling the window when the split is left', () => {
    // `undefined` and not an empty object: it is what leaves the stylesheet's
    // in-flow panel alone, and the absence of `data-boxed="true"` is what lets
    // `inset: 0` come back.
    const markup = panel(undefined)
    expect(markup).toContain('data-boxed="false"')
    expect(split(markup).root).not.toContain('left:')
  })

  it('boxes the unwired panel too, which is a whole panel like any other', () => {
    /*
     * A build whose preload is missing bridge methods draws a message instead of
     * a browser, and that message is the same in-flow block: unboxed, it fills
     * the pane area and covers the terminal in the other pane. The panel being
     * broken is not a reason for it to be somewhere it was not put.
     */
    const markup = renderToStaticMarkup(
      <BrowserWorkspace visible box={slotStyle(measureSlots(SPLIT)['page-1'])} />,
    )
    expect(markup).toContain('The browser is not connected')
    expect(markup).toContain('data-boxed="true"')
    expect(markup).toContain('left:608px')
  })
})
