import { beforeEach, describe, expect, it } from 'vitest'
import {
  baseZoom,
  fitFactor,
  fitPageToPane,
  forgetFit,
  noteManualZoom,
  resetFit,
  worthApplying,
  ZOOM_FLOOR,
  type FittablePage,
} from './browser-fit'

/**
 * Fitting a page to the pane it was given.
 *
 * The numbers in these tests are the ones that were measured in a real window
 * on 2026-08-23, not invented ones: a 1440×900 window with the sidebar open
 * gives the browser pane 1176 device-independent pixels, and
 * `chromewebstore.google.com` lays out at 1280 with `body { min-width: 1280px }`.
 * That is the case the whole file exists for, so it is the case it is tested on.
 */

/** A page whose measurements and zoom are whatever the test says they are. */
function page(options: {
  client: number
  content: number
  zoom?: number
  dead?: boolean
  throws?: boolean
}): FittablePage & { zoom: number; calls: number } {
  const self = {
    zoom: options.zoom ?? 1,
    calls: 0,
    isDestroyed: () => options.dead === true,
    getZoomFactor: () => self.zoom,
    setZoomFactor: (factor: number) => {
      self.zoom = factor
    },
    executeJavaScript: async (): Promise<unknown> => {
      self.calls += 1
      if (options.throws) throw new Error('no page')
      // What Chromium answers: `clientWidth` shrinks as the zoom does, and a
      // page pinned by `min-width` keeps the same content width regardless.
      const client = Math.round(options.client / self.zoom)
      return { client, content: Math.max(options.content, client) }
    },
  }
  return self
}

let seq = 0
const nextId = (): string => `tab-${(seq += 1)}`

beforeEach(() => {
  seq += 1000
})

describe('the zoom that makes a layout fit', () => {
  it('shrinks the store into the pane it is actually given', () => {
    // 1176 / 1280 = 0.91875, floored to two places.
    expect(fitFactor({ paneWidth: 1176, contentWidth: 1280, base: 1 })).toBe(0.91)
  })

  it('rounds down, so the viewport is never a sliver short of the layout', () => {
    /*
     * Measured, and the reason this rounds the way it does: 0.92 is the nearest
     * percent to 1176/1280 and gives a 1278px viewport, which leaves 2px of a
     * 1280px page clipped. Every fit has to end with the whole layout inside
     * the pane, or it has not fitted anything.
     */
    for (const [pane, content] of [
      [1176, 1280],
      [1176, 1249],
      [1000, 1100],
      [900, 1024],
    ]) {
      const factor = fitFactor({ paneWidth: pane, contentWidth: content, base: 1 })
      expect(pane / factor).toBeGreaterThanOrEqual(content)
    }
  })

  it('leaves a page that already fits exactly alone', () => {
    // Every ordinary heavy site measured reflowed to the pane with no overflow.
    expect(fitFactor({ paneWidth: 1176, contentWidth: 1176, base: 1 })).toBe(1)
  })

  it('never zooms in, whatever the arithmetic says', () => {
    /*
     * A narrow page in a wide pane divides out above 1, and enlarging it would
     * be this file deciding how big somebody's text is — which is not what it
     * is for and not something they asked for.
     */
    expect(fitFactor({ paneWidth: 1600, contentWidth: 800, base: 1 })).toBe(1)
  })

  it('never goes above a zoom the person chose', () => {
    // They are reading at 110%. Fitting may take that down, never past it.
    expect(fitFactor({ paneWidth: 1600, contentWidth: 800, base: 1.1 })).toBe(1.1)
    expect(fitFactor({ paneWidth: 1176, contentWidth: 1280, base: 1.1 })).toBe(0.91)
  })

  it('stands down rather than shrink a page past reading size', () => {
    /*
     * The store in one pane of a split: 568 wide against a layout that wants
     * 1249 needs 45%, which is a picture of a page rather than a page. The
     * honest answer at that size is the scrollbar the page already has.
     */
    const factor = fitFactor({ paneWidth: 568, contentWidth: 1249, base: 1 })
    expect(factor).toBe(1)
    expect(568 / 1249).toBeLessThan(ZOOM_FLOOR)
  })

  it('answers the base for a pane or a page with no width', () => {
    expect(fitFactor({ paneWidth: 0, contentWidth: 1280, base: 1 })).toBe(1)
    expect(fitFactor({ paneWidth: 1176, contentWidth: 0, base: 1 })).toBe(1)
    expect(fitFactor({ paneWidth: Number.NaN, contentWidth: 1280, base: 1 })).toBe(1)
  })

  it('does not count a difference too small to see as a change', () => {
    expect(worthApplying(0.92, 0.92)).toBe(false)
    expect(worthApplying(1, 0.92)).toBe(true)
  })
})

describe('fitting a real page', () => {
  it('zooms the store out until its whole layout is on screen', async () => {
    const id = nextId()
    const store = page({ client: 1176, content: 1280 })
    expect(await fitPageToPane(id, store)).toBe(0.91)
    expect(store.zoom).toBe(0.91)
    // 1176 / 0.91 = 1292 CSS pixels of viewport for a 1280px layout. The whole
    // of the page is inside the pane, which is the only result that counts.
    expect(1176 / store.zoom).toBeGreaterThanOrEqual(1280)
    forgetFit(id)
  })

  it('leaves a page that fits at exactly the zoom it was at', async () => {
    const id = nextId()
    const ordinary = page({ client: 1176, content: 1176 })
    expect(await fitPageToPane(id, ordinary)).toBe(1)
    expect(ordinary.zoom).toBe(1)
    forgetFit(id)
  })

  it('puts the zoom back when the pane grows past what the page wanted', async () => {
    const id = nextId()
    const store = page({ client: 1176, content: 1280 })
    await fitPageToPane(id, store)
    expect(store.zoom).toBe(0.91)

    /*
     * The sidebar is hidden, so the pane is the whole 1440. This is the case a
     * re-measure alone could never get right: at 92% the page no longer
     * overflows, so `scrollWidth` answers `clientWidth` and the page looks like
     * one that fits — which is why the width it asked for is remembered.
     */
    const wider = page({ client: 1440, content: 1280, zoom: store.zoom })
    expect(await fitPageToPane(id, wider)).toBe(1)
    expect(wider.zoom).toBe(1)
    forgetFit(id)
  })

  it('does not walk itself down to the floor on repeated measures', async () => {
    /*
     * The ratchet this is guarding: if the base were re-read from the live zoom
     * each time, 92% would become the ceiling, the next fit would shrink that,
     * and a window nobody touched would keep getting smaller.
     */
    const id = nextId()
    const store = page({ client: 1176, content: 1280 })
    await fitPageToPane(id, store)
    await fitPageToPane(id, store)
    await fitPageToPane(id, store)
    expect(store.zoom).toBe(0.91)
    expect(baseZoom(id)).toBe(1)
    forgetFit(id)
  })

  it('stops touching a page whose zoom the person set themselves', async () => {
    const id = nextId()
    const store = page({ client: 1176, content: 1280 })
    await fitPageToPane(id, store)
    expect(store.zoom).toBe(0.91)

    // They pressed the chip to get back to 100%. That has to stay pressed.
    store.setZoomFactor(1)
    noteManualZoom(id, 1)
    const callsBefore = store.calls
    expect(await fitPageToPane(id, store)).toBeNull()
    expect(store.zoom).toBe(1)
    // Not even measured: a script in somebody's page for a decision already made.
    expect(store.calls).toBe(callsBefore)
    forgetFit(id)
  })

  it('fits again once the tab navigates, and takes their zoom as the new ceiling', async () => {
    const id = nextId()
    const store = page({ client: 1176, content: 1280 })
    await fitPageToPane(id, store)
    store.setZoomFactor(1.1)
    noteManualZoom(id, 1.1)
    expect(await fitPageToPane(id, store)).toBeNull()

    // A new document. The caller restores `baseZoom` first — see `unfit` in
    // `browser-tab.ts` — and fitting is live again from their number.
    store.setZoomFactor(1.1)
    resetFit(id)
    expect(await fitPageToPane(id, store)).toBe(0.91)
    expect(baseZoom(id)).toBe(1.1)
    forgetFit(id)
  })

  it('says nothing at all for a page that has gone, and touches nothing', async () => {
    const id = nextId()
    const gone = page({ client: 1176, content: 1280, dead: true })
    expect(await fitPageToPane(id, gone)).toBeNull()
    expect(gone.calls).toBe(0)
    forgetFit(id)
  })

  it('swallows a measurement that throws rather than failing the load', async () => {
    const id = nextId()
    const hostile = page({ client: 1176, content: 1280, throws: true })
    expect(await fitPageToPane(id, hostile)).toBeNull()
    expect(hostile.zoom).toBe(1)
    forgetFit(id)
  })
})
