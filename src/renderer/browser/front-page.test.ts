import { afterEach, describe, expect, it } from 'vitest'
import { forgetFrontPage, frontPage, resetFrontPageForTests, setFrontPage } from './front-page'

/**
 * Which browser page is in front, published by every mounted browser panel.
 *
 * The awkward part is that *every* panel publishes, on every navigation, and all
 * but one of them is hidden. So the rules below are about a hidden window not
 * being able to answer for a visible one — which is the whole reason this is a
 * store with a guard rather than a bare setter.
 */

afterEach(() => resetFrontPageForTests())

describe('the page in front', () => {
  it('is whichever window says it is visible', () => {
    setFrontPage('b1', { tabId: 'b1', viewId: 'view-1' })
    expect(frontPage()).toEqual({ tabId: 'b1', viewId: 'view-1' })
  })

  it('is not cleared by a different window saying it is hidden', () => {
    /*
     * A tab switch renders both panels: the one arriving publishes itself and
     * the one leaving publishes null, in whichever order React happens to run
     * their effects. Without this guard the visible window's answer is wiped by
     * a window nobody is looking at, and the rail's panel flickers away on every
     * switch between two pages.
     */
    setFrontPage('b1', { tabId: 'b1', viewId: 'view-1' })
    setFrontPage('b2', null)
    expect(frontPage()).toEqual({ tabId: 'b1', viewId: 'view-1' })
  })

  it('is cleared by the window that is holding it', () => {
    setFrontPage('b1', { tabId: 'b1', viewId: 'view-1' })
    setFrontPage('b1', null)
    expect(frontPage()).toBeNull()
    setFrontPage('b1', { tabId: 'b1', viewId: 'view-1' })
    forgetFrontPage('b1')
    expect(frontPage()).toBeNull()
  })

  it('follows the view id when the page underneath is replaced', () => {
    // The isolation switch closes the view and opens a new one under a window
    // that has not moved. A store holding the old view id would tell the rail
    // that the page in front is not the page being driven, and the panel would
    // vanish mid-scrape.
    setFrontPage('b1', { tabId: 'b1', viewId: 'view-1' })
    setFrontPage('b1', { tabId: 'b1', viewId: 'view-2' })
    expect(frontPage()?.viewId).toBe('view-2')
  })
})
