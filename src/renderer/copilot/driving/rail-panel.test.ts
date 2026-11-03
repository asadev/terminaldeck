import { afterEach, describe, expect, it } from 'vitest'
import { resetFrontPageForTests, setFrontPage, type FrontPage } from '../../browser/front-page'
import type { DriveNow } from './browser-trace'
import {
  foldRailPanel,
  openRailPanel,
  railPanelState,
  resetRailPanelForTests,
  setRailDrive,
  subscribeRailPanel,
} from './rail-panel'

/**
 * When the copilot's side panel is drawn, and when it is not.
 *
 * Every assertion here is a sentence Asad said on 2026-08-21 while the panel was
 * on his screen in the wrong place. The panel itself is markup and CSS; this is
 * the part that can be wrong invisibly, and it was — the old rule was "a drive
 * is live", full stop, which drew it over the MCP servers page, over Machines
 * and over a terminal session, and left him stopping the copilot to get his
 * sidebar back.
 */

const drive = (over: Partial<DriveNow> = {}): DriveNow => ({
  state: 'agent',
  tabId: 'view-1',
  step: '',
  url: 'https://example.com/projects',
  ...over,
})

const page = (over: Partial<FrontPage> = {}): FrontPage => ({
  tabId: 'browser-1',
  viewId: 'view-1',
  ...over,
})

afterEach(() => {
  resetRailPanelForTests()
  resetFrontPageForTests()
})

describe('whether the panel has the rail', () => {
  it('draws it while the page being driven is the page in front', () => {
    expect(railPanelState(drive(), page(), false)).toBe('panel')
  })

  it('draws nothing when nothing is driving', () => {
    expect(railPanelState(null, page(), false)).toBe('away')
    expect(railPanelState(drive({ state: 'idle' }), page(), false)).toBe('away')
  })

  it('draws nothing on any page that is not a browser page', () => {
    /*
     * *"As soon as I click on any other thing, it is coming up."* f_0110 is the
     * proof: the app's own MCP servers page, with the panel still occupying the
     * left column. A screen that is not a browser page publishes no front page
     * at all, so this is the whole of that fix — and of *"If I am inside
     * commander, it should not be here"*, since the copilot's window is not a
     * browser page either.
     */
    expect(railPanelState(drive(), null, false)).toBe('away')
  })

  it('draws nothing over a browser page that is not the one being driven', () => {
    /*
     * The join that makes "a drive is live" and "a browser page is in front" add
     * up to "this page is being driven". Without it, opening a second tab while
     * a scrape ran put the panel over a page nothing was happening to.
     */
    expect(railPanelState(drive(), page({ viewId: 'view-2' }), false)).toBe('away')
  })

  it('draws nothing over a window that has no page in it yet', () => {
    // A panel exists before its `WebContentsView` does. An empty view id must
    // not match an empty tab id on a drive that has not claimed one either.
    expect(railPanelState(drive({ tabId: '' }), page({ viewId: '' }), false)).toBe('away')
  })

  it('reports the fold only where the row that undoes it can be seen', () => {
    /*
     * *"If I click on it, and if I am on browser window, if I click on it, it
     * will open up back. But if I am not on the browser window, it will not
     * open, only on the browser window."* So `folded` is a state of the rail
     * only while the driven page is in front; anywhere else the rail is simply
     * the rail and its Commander row means what it has always meant.
     */
    expect(railPanelState(drive(), page(), true)).toBe('folded')
    expect(railPanelState(drive(), null, true)).toBe('away')
  })
})

describe('the fold', () => {
  it('survives the page, the tab and the next errand', () => {
    /*
     * *"Oh, this side panel thing is not going away. As soon as I click on any
     * other thing, it is coming up. So maybe I need to stop this."* The put-away
     * it replaced was remembered per browser tab and the file said outright that
     * *"the panel comes back on the next errand"*. Nothing below un-folds it: not
     * a new page, not a new tab, not the drive ending and another starting.
     */
    setRailDrive(drive())
    setFrontPage('browser-1', page())
    foldRailPanel()
    expect(railPanelState(drive(), page(), true)).toBe('folded')

    // A further errand on a new tab, which is a new drive on a new view.
    setRailDrive(null)
    setRailDrive(drive({ tabId: 'view-9' }))
    setFrontPage('browser-1', null)
    setFrontPage('browser-2', page({ tabId: 'browser-2', viewId: 'view-9' }))
    expect(railPanelState(drive({ tabId: 'view-9' }), page({ viewId: 'view-9' }), true)).toBe(
      'folded',
    )
  })

  it('comes back only when somebody asks for it', () => {
    foldRailPanel()
    openRailPanel()
    expect(railPanelState(drive(), page(), false)).toBe('panel')
  })
})

describe('the drive store', () => {
  it('wakes nobody for a status that says the same thing', () => {
    /*
     * `browser:drive-state` is pushed on every step of a scrape, and most of
     * those pushes change nothing the rail draws. The same measured guard
     * `window-machine.ts` carries, for the same reason: without it every step
     * re-renders the sidebar behind a page nobody is looking at.
     */
    let woken = 0
    const stop = subscribeRailPanel(() => {
      woken += 1
    })
    setRailDrive(drive())
    expect(woken).toBe(1)
    setRailDrive(drive())
    expect(woken).toBe(1)
    setRailDrive(drive({ step: 'clicking “Search”' }))
    expect(woken).toBe(2)
    stop()
  })
})
