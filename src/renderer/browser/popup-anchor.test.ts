import { describe, expect, it } from 'vitest'
import { anchorInWindow, anchorPopup } from './popup-anchor'

/**
 * "Rather than it comes here down, it should open a pop up here."
 *
 * The capture panel used to dock at the bottom of the window, a long way from
 * whatever had just been clicked. It is a popup at the element now, and this is
 * the arithmetic that puts it there and keeps it on screen.
 */

const VIEWPORT = { width: 1440, height: 900 }
const POPUP = { width: 400, height: 260 }

describe('anchorPopup', () => {
  it('sits under the element and lines up with its left edge', () => {
    const at = anchorPopup({ x: 300, y: 200, width: 120, height: 40 }, POPUP, VIEWPORT)
    expect(at).toEqual({ left: 300, top: 248, side: 'below' })
  })

  it('flips above when there is no room below and there is above', () => {
    // An element near the bottom of a long page. Below it there are 40 pixels.
    const at = anchorPopup({ x: 100, y: 820, width: 120, height: 40 }, POPUP, VIEWPORT)
    expect(at.side).toBe('above')
    expect(at.top).toBe(552)
  })

  it('stays below when neither side fits, rather than flipping for its own sake', () => {
    // A short window: 260px of popup fits nowhere. Flipping to the *worse* side
    // is how a popup ends up half off the top of the screen.
    const at = anchorPopup({ x: 10, y: 60, width: 100, height: 30 }, POPUP, { width: 800, height: 200 })
    expect(at.side).toBe('below')
  })

  it('slides left rather than hanging off the right edge', () => {
    const at = anchorPopup({ x: 1380, y: 100, width: 40, height: 20 }, POPUP, VIEWPORT)
    // 1440 - 400 - 8
    expect(at.left).toBe(1032)
  })

  it('never leaves the top-left corner off screen, even when it does not fit', () => {
    const at = anchorPopup({ x: -500, y: -500, width: 20, height: 20 }, POPUP, { width: 300, height: 200 })
    expect(at.left).toBe(8)
    expect(at.top).toBe(8)
  })
})

describe('anchorInWindow', () => {
  const view = { x: 200, y: 100, width: 1000, height: 700 }

  it('adds the page’s own offset, because the guest measures inside the page', () => {
    expect(anchorInWindow({ x: 50, y: 30, width: 120, height: 40 }, view)).toEqual({
      x: 250,
      y: 130,
      width: 120,
      height: 40,
    })
  })

  it('clips a box that runs past the bottom of the view', () => {
    // Otherwise the popup is placed below the workspace, pointing at nothing.
    expect(anchorInWindow({ x: 0, y: 650, width: 100, height: 400 }, view)).toEqual({
      x: 200,
      y: 750,
      width: 100,
      height: 50,
    })
  })

  it('pulls an element scrolled above the page back to the page’s top edge', () => {
    const box = anchorInWindow({ x: 10, y: -300, width: 100, height: 40 }, view)
    expect(box.y).toBe(view.y)
  })

  it('has an answer when the page reported no rectangle at all', () => {
    // Older main processes send none, and a page can be exotic enough to fail
    // the read. The top middle of the view is still on the page.
    expect(anchorInWindow(null, view)).toEqual({ x: 700, y: 100, width: 0, height: 0 })
  })
})
