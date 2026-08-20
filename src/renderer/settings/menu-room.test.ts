import { describe, expect, it } from 'vitest'
import { onMenuToggle, placeRowMenu } from './menu-room'

/**
 * The ⋯ menu on an account row, and where it is allowed to open.
 *
 * The defect, rendered on 2026-08-20 in `.harness/coding.html` at 1280×900: the
 * menu on the last account in the list drew at `{y: 757.8, h: 98, bottom: 855.8}`
 * inside a pane whose bottom edge is 786, so **Use by default**, **Rename** and
 * **Remove** were all under the sheet's footer and none could be pressed.
 *
 * There is no DOM in this project, so the elements below are the smallest thing
 * that answers the three questions this module asks — `open`, a rect, and a
 * `getComputedStyle` on the ancestors. That is deliberate rather than lazy: the
 * whole of the decision is arithmetic on four numbers, and a fake that supplies
 * those four exercises every branch, including the ones a screenshot at one
 * window size never reaches.
 */

interface FakeRect {
  top: number
  bottom: number
  height: number
}

/** An element with a rect, a parent chain, and the two attributes this sets. */
function el(rect: FakeRect, parent: unknown = null, overflow = 'visible'): HTMLElement {
  const attributes = new Map<string, string>()
  const node = {
    parentElement: parent,
    style: { setProperty: (k: string, v: string) => attributes.set(k, v) },
    getBoundingClientRect: () => ({ ...rect, left: 0, right: 0, width: 0, x: 0, y: rect.top }),
    setAttribute: (k: string, v: string) => attributes.set(k, v),
    removeAttribute: (k: string) => attributes.delete(k),
    hasAttribute: (k: string) => attributes.has(k),
    getAttribute: (k: string) => attributes.get(k) ?? null,
    querySelector: () => null,
    /** Only for the assertions below. */
    _attrs: attributes,
    _overflow: overflow,
  }
  return node as unknown as HTMLElement
}

/**
 * `getComputedStyle` and `window.innerHeight`, which this module reads and
 * vitest's default environment does not have.
 */
function withWindow<T>(innerHeight: number, run: () => T): T {
  const host = globalThis as unknown as Record<string, unknown>
  const hadWindow = 'window' in host
  const previous = host.window
  host.window = { innerHeight }
  const hadCompute = 'getComputedStyle' in host
  const before = host.getComputedStyle
  host.getComputedStyle = (node: { _overflow?: string }) => ({
    overflowY: node._overflow ?? 'visible',
    overflow: node._overflow ?? 'visible',
  })
  try {
    return run()
  } finally {
    if (hadWindow) host.window = previous
    else delete host.window
    if (hadCompute) host.getComputedStyle = before
    else delete host.getComputedStyle
  }
}

/** A `<details>` at `top`, inside a scrolling pane, with a 98px panel. */
function scene(input: {
  open: boolean
  anchorTop: number
  panelHeight?: number
  clipTop?: number
  clipBottom?: number
}) {
  const clip = el(
    { top: input.clipTop ?? 130, bottom: input.clipBottom ?? 786, height: 656 },
    null,
    'auto',
  )
  const details = el({ top: input.anchorTop, bottom: input.anchorTop + 28, height: 28 }, clip)
  ;(details as unknown as { open: boolean }).open = input.open
  const panel = el({ top: 0, bottom: 0, height: input.panelHeight ?? 98 })
  return { details, panel }
}

const up = (node: HTMLElement): boolean => node.hasAttribute('data-up')

describe('where a row menu opens', () => {
  it('opens downwards when the pane has room under the row', () => {
    const { details, panel } = scene({ open: true, anchorTop: 300 })
    withWindow(900, () => placeRowMenu(details, panel))
    expect(up(details)).toBe(false)
  })

  /**
   * The measured case. A row 28px tall whose top is at 757 leaves 786 − 785 − 8
   * pixels under it and 619 above, so a 98px panel can only be read above.
   */
  it('opens upwards on the last row, where the footer would have cut it', () => {
    const { details, panel } = scene({ open: true, anchorTop: 730 })
    withWindow(900, () => placeRowMenu(details, panel))
    expect(up(details)).toBe(true)
  })

  it('leaves a shut menu with no placement at all', () => {
    // So the next open measures from a known state rather than from wherever
    // the row happened to be the last time it was opened.
    const { details, panel } = scene({ open: false, anchorTop: 730 })
    details.setAttribute('data-up', '')
    withWindow(900, () => placeRowMenu(details, panel))
    expect(up(details)).toBe(false)
  })

  /**
   * Neither side has room — a pane a hundred pixels tall. The answer is not to
   * flip into the ceiling: the panel keeps the side with the most room and the
   * stylesheet spends `--menu-room` on a scroll, which is reachable. A flip that
   * clipped the *top* of the menu would hide the first item instead of the last,
   * which is the same bug with a different victim.
   */
  it('publishes the room it has when neither side can hold the whole menu', () => {
    const { details, panel } = scene({
      open: true,
      anchorTop: 200,
      clipTop: 180,
      clipBottom: 280,
      panelHeight: 98,
    })
    withWindow(900, () => placeRowMenu(details, panel))
    const room = (panel as unknown as { _attrs: Map<string, string> })._attrs.get('--menu-room')
    expect(room).toBeDefined()
    expect(Number.parseInt(room ?? '0', 10)).toBeGreaterThanOrEqual(0)
  })

  it('falls back to the window when nothing above the row scrolls', () => {
    const loose = el({ top: 0, bottom: 0, height: 0 }, null, 'visible')
    const details = el({ top: 700, bottom: 728, height: 28 }, loose)
    ;(details as unknown as { open: boolean }).open = true
    const panel = el({ top: 0, bottom: 0, height: 98 })
    withWindow(760, () => placeRowMenu(details, panel))
    // 760 − 728 − 8 = 24 below, 700 above: the window is the clipper.
    expect(up(details)).toBe(true)
  })

  it('does nothing at all when there is no panel to place', () => {
    const { details } = scene({ open: true, anchorTop: 730 })
    expect(() => withWindow(900, () => placeRowMenu(details, null))).not.toThrow()
    expect(up(details)).toBe(false)
  })

  it('finds the panel itself from the toggle event', () => {
    // `onMenuToggle` is what the component binds, and it looks the panel up by
    // the same class the stylesheet positions — so the two cannot drift.
    const { details } = scene({ open: true, anchorTop: 730 })
    let asked: string | null = null
    ;(details as unknown as { querySelector: (s: string) => null }).querySelector = (
      selector: string,
    ) => {
      asked = selector
      return null
    }
    withWindow(900, () => onMenuToggle({ currentTarget: details }))
    expect(asked).toBe('.settings-rowmenu-items')
  })
})
