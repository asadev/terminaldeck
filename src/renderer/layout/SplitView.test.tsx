import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SplitView, dividerRatio } from './SplitView'
import {
  MIN_PANE_RATIO,
  createLayout,
  focusPane,
  resizeSplit,
  splitPane,
  type PaneLayout,
} from './pane-tree'

/**
 * There is no DOM environment in this project's test setup, so these render to
 * static markup. Drag behaviour is exercised through pane-tree's own tests —
 * what is worth pinning here is the wiring between the two: that the tree's
 * ratios reach the grid tracks, and that the divider carries the ARIA a
 * keyboard user needs to move it.
 */

function twoPanes(direction: 'horizontal' | 'vertical' = 'horizontal'): PaneLayout {
  return splitPane(createLayout('left', 'left'), 'left', direction, {
    tabId: 'right',
    paneId: 'right',
    splitId: 'split-1',
  })
}

function render(layout: PaneLayout, empty?: string): string {
  return renderToStaticMarkup(
    <SplitView
      layout={layout}
      onLayoutChange={() => {}}
      renderPane={({ tabId }) => <i>{`terminal:${tabId ?? 'none'}`}</i>}
      empty={empty ? <p>{empty}</p> : null}
    />,
  )
}

describe('SplitView', () => {
  it('renders a single pane with no divider', () => {
    const html = render(createLayout('solo', 'solo'))
    expect(html).toContain('terminal:solo')
    expect(html).not.toContain('class="pane-divider"')
    expect(html).not.toContain('class="pane-split"')
  })

  it('renders both panes either side of a divider, in tree order', () => {
    const html = render(twoPanes())
    const divider = html.indexOf('class="pane-divider"')
    expect(html.indexOf('terminal:left')).toBeLessThan(divider)
    expect(divider).toBeLessThan(html.indexOf('terminal:right'))
  })

  it('turns the split ratio into grid tracks on the matching axis', () => {
    const horizontal = render(resizeSplit(twoPanes(), 'split-1', 0.3))
    expect(horizontal).toContain('grid-template-columns:0.3fr var(--pane-divider) 0.7fr')

    const vertical = render(resizeSplit(twoPanes('vertical'), 'split-1', 0.25))
    expect(vertical).toContain('grid-template-rows:0.25fr var(--pane-divider) 0.75fr')
  })

  it('marks the focused pane and only the focused pane', () => {
    const html = render(focusPane(twoPanes(), 'left'))
    expect(html).toContain('data-pane-id="left" data-focused="true"')
    expect(html).toContain('data-pane-id="right" data-focused="false"')
  })

  it('gives the divider the ARIA a keyboard user needs', () => {
    const html = render(resizeSplit(twoPanes(), 'split-1', 0.4))
    expect(html).toContain('role="separator"')
    expect(html).toContain('aria-label="Resize panes"')
    expect(html).toContain('aria-valuenow="40"')
    expect(html).toContain('aria-valuetext="40%"')
    expect(html).toContain('tabindex="0"')
  })

  it('names the separator by its own orientation, not the split’s', () => {
    // Side-by-side panes are parted by a vertical bar; stacked ones by a
    // horizontal bar. Getting this backwards inverts a screen reader's
    // arrow-key hint.
    expect(render(twoPanes('horizontal'))).toContain('aria-orientation="vertical"')
    expect(render(twoPanes('vertical'))).toContain('aria-orientation="horizontal"')
  })

  it('renders a pane that has no session yet', () => {
    const layout = splitPane(createLayout('a', 'a'), 'a', 'horizontal', { paneId: 'b' })
    expect(render(layout)).toContain('terminal:none')
  })

  it('nests splits', () => {
    const layout = splitPane(twoPanes(), 'right', 'vertical', {
      tabId: 'bottom',
      paneId: 'bottom',
      splitId: 'split-2',
    })
    const html = render(layout)
    expect(html.match(/class="pane-split"/g)).toHaveLength(2)
    expect(html.match(/class="pane-divider"/g)).toHaveLength(2)
    expect(html).toContain('terminal:bottom')
  })

  it('shows the empty state once the last pane closes', () => {
    const html = render({ root: null, focusedPaneId: null }, 'Nothing open')
    expect(html).toContain('Nothing open')
    expect(html).toContain('split-view-empty')
    expect(html).not.toContain('pane-leaf')
  })
})

describe('dividerRatio', () => {
  const drag = (offset: number, over: Partial<Parameters<typeof dividerRatio>[0]> = {}) =>
    dividerRatio({ size: 1000, offset, dividerPx: 3, minPanePx: 140, fallback: 0.5, ...over })

  // Regression: the ratio used to be offset/size, which ignores the divider's
  // own track and treats the pointer as the first pane's edge. Grabbing a
  // divider then moved it before the pointer had.
  it('leaves the divider where it was when the drag starts', () => {
    // Wide enough that the pixel floor is not the binding constraint at 0.1.
    const size = 4000
    const free = size - 3
    for (const ratio of [0.1, 0.25, 0.5, 0.75, 0.9]) {
      // Where that ratio actually paints the divider's centre.
      const centre = ratio * free + 1.5
      expect(drag(centre, { size })).toBeCloseTo(ratio, 9)
    }
  })

  it('tracks the pointer across the split', () => {
    expect(drag(250)).toBeCloseTo((250 - 1.5) / 997, 9)
    expect(drag(750)).toBeCloseTo((750 - 1.5) / 997, 9)
  })

  it('keeps a pixel floor under each pane, on top of the ratio floor', () => {
    expect(drag(0)).toBeCloseTo(140 / 997, 9)
    expect(drag(1000)).toBeCloseTo(1 - 140 / 997, 9)
    // A wide window has room for the pixel floor to be the looser of the two.
    expect(drag(0, { size: 4000, minPanePx: 140 })).toBeCloseTo(MIN_PANE_RATIO, 9)
  })

  // Regression: a zero or sub-divider width divided by ~0, and clampRatio reads
  // a non-finite ratio as corrupt and snaps the split to the middle — so a
  // collapsed split silently threw away the user's ratio.
  it('holds the current ratio when the split has no room to measure', () => {
    expect(drag(10, { size: 0, fallback: 0.3 })).toBe(0.3)
    expect(drag(10, { size: 3, fallback: 0.3 })).toBe(0.3)
    expect(drag(10, { size: 2, fallback: 0.3 })).toBe(0.3)
    expect(drag(10, { size: Number.NaN, fallback: 0.3 })).toBe(0.3)
    expect(drag(Number.NaN, { fallback: 0.3 })).toBe(0.3)
  })

  it('survives a divider that reports no thickness', () => {
    expect(drag(500, { dividerPx: 0 })).toBeCloseTo(0.5, 9)
    expect(drag(500, { dividerPx: Number.NaN })).toBeCloseTo(0.5, 9)
  })

  it('never returns a ratio that would collapse a pane', () => {
    for (let offset = -500; offset <= 1500; offset += 7) {
      const ratio = drag(offset)
      expect(ratio).toBeGreaterThanOrEqual(MIN_PANE_RATIO)
      expect(ratio).toBeLessThanOrEqual(1 - MIN_PANE_RATIO)
    }
  })
})
