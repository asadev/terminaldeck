import { renderToStaticMarkup } from 'react-dom/server'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { FocusOverlay } from './FocusOverlay'
import { anchorSelector, PAGE_SELECTOR, type FocusDom } from './focus-target'
import { clearTerminals, registerTerminal, type DriveTerminal } from './terminal-registry'
import { overlayRects } from '../browser/overlay-watch'
import type { Rect } from './geometry'

/**
 * The overlay as it actually renders.
 *
 * No DOM in this project's test run, so this renders to static markup — which
 * is possible at all only because the first measurement is synchronous rather
 * than arriving from an effect. That was a design decision made for the screen
 * (a target that draws one frame late is a flash of undimmed window) and it
 * pays for itself here.
 */

const box = (rect: Rect) => ({
  getBoundingClientRect: () => ({
    left: rect.x,
    top: rect.y,
    width: rect.width,
    height: rect.height,
  }),
})

const dom = (elements: Record<string, Rect>): FocusDom => ({
  find: (selector) => (selector in elements ? box(elements[selector]) : null),
  viewport: () => ({ x: 0, y: 0, width: 1440, height: 920 }),
})

const BUBBLE = anchorSelector({ at: 'message', messageId: 'agent:m1' })
const TARGET = { kind: 'anchor', anchor: { at: 'message', messageId: 'agent:m1' } } as const

afterEach(clearTerminals)

describe('what it draws', () => {
  const world = dom({ [BUBBLE]: { x: 500, y: 300, width: 400, height: 120 } })

  it('draws a scrim and a ring', () => {
    const html = renderToStaticMarkup(<FocusOverlay target={TARGET} dom={world} />)
    expect(html).toContain('fo-scrim')
    expect(html).toContain('fo-ring')
  })

  /*
   * The one lesson `browser-preload.ts` records in full, as an assertion.
   *
   * That file used to paint a 16 % wash over the element it was pointing at,
   * and on camera on 2026-08-16 the element read as "being *replaced* by a pale
   * blue rectangle… You cannot see what you are pointing at, which is the one
   * thing an element picker exists for." The scrim's hole must never carry a
   * background of its own; every pixel of emphasis is outside it.
   */
  it('never fills the thing it is pointing at', () => {
    const html = renderToStaticMarkup(<FocusOverlay target={TARGET} dom={world} />)
    const css = readFileSync(resolve(__dirname, 'FocusOverlay.css'), 'utf8')
    expect(html).not.toMatch(/fo-scrim[^>]*background(?!-)/)
    // And the sheet says so too, for both painted elements.
    expect(css).toMatch(/\.fo-scrim\s*\{[^}]*background:\s*transparent/)
    expect(css).toMatch(/\.fo-ring\s*\{[^}]*background:\s*transparent/)
  })

  it('puts the ring outside the hole, not on it', () => {
    const html = renderToStaticMarkup(<FocusOverlay target={TARGET} dom={world} />)
    // hole: 500-4 = 496 ; ring: one pixel further out again.
    expect(html).toMatch(/fo-scrim[^>]*left:496px/)
    expect(html).toMatch(/fo-ring[^>]*left:495px/)
  })

  it('takes no pointer events, so every control stays live under it', () => {
    const css = readFileSync(resolve(__dirname, 'FocusOverlay.css'), 'utf8')
    // Driving is a highlight, not a modal. A dim you have to dismiss before you
    // can act is a dim that gets resented by the second tour.
    expect(css.match(/pointer-events:\s*none/g)?.length).toBeGreaterThanOrEqual(3)
  })
})

describe('it comes off with nothing left behind', () => {
  /*
   * This app has a recorded history of dismissed overlays leaving translucent
   * rectangles behind, so the guarantee is structural rather than careful: when
   * there is nothing to point at, the component renders *no elements at all*.
   *
   * There is no exit animation and no unmount timer, because both mean keeping
   * a scrim mounted after the state that justified it is gone — waiting on a
   * `transitionend` that does not fire when the element is `display: none`,
   * does not fire when `prefers-reduced-motion` has zeroed the duration in
   * `tokens.css`, and does not fire when the element is removed mid-transition.
   */
  it('renders nothing at all for a null target', () => {
    expect(renderToStaticMarkup(<FocusOverlay target={null} dom={dom({})} />)).toBe('')
  })

  it('renders nothing at all when the anchor is gone', () => {
    expect(renderToStaticMarkup(<FocusOverlay target={TARGET} dom={dom({})} />)).toBe('')
  })

  it('renders nothing at all when a terminal quote cannot be found', () => {
    registerTerminal('s1', {
      term: {
        cols: 80,
        rows: 24,
        element: {
          querySelector: () => box({ x: 0, y: 0, width: 800, height: 600 }),
        } as unknown as HTMLElement,
        buffer: {
          active: {
            type: 'normal',
            viewportY: 0,
            baseY: 0,
            length: 1,
            getLine: () => ({ translateToString: () => 'something else' }),
          },
        },
        onRender: () => ({ dispose: () => undefined }),
        onResize: () => ({ dispose: () => undefined }),
        scrollToLine: () => undefined,
      } satisfies DriveTerminal,
      host: box({ x: 0, y: 0, width: 800, height: 600 }) as unknown as HTMLElement,
    })
    const html = renderToStaticMarkup(
      <FocusOverlay target={{ kind: 'terminal', sessionId: 's1', quote: 'gone' }} dom={dom({})} />,
    )
    expect(html).toBe('')
  })

  /*
   * The CSS half of the same guarantee: nothing in the sheet may hold the
   * overlay on screen after React has taken it off. A `transition` on anything
   * other than opacity, or an animation with a fill mode, would do exactly that.
   */
  it('transitions nothing but opacity', () => {
    const css = readFileSync(resolve(__dirname, 'FocusOverlay.css'), 'utf8')
    for (const rule of css.matchAll(/transition:\s*([^;]+);/g)) {
      expect(rule[1].trim().startsWith('opacity')).toBe(true)
    }
    expect(css).not.toMatch(/animation/)
  })
})

describe('it does not park the browser pages it is drawn over', () => {
  /*
   * The trap this exists for is specific and severe.
   *
   * `overlay-watch.ts` treats every child of `<body>` that has a box as a
   * floating surface, and parks — `setVisible(false)` — any browser page it
   * intersects. So an overlay portalled into `<body>`, which is what every
   * other floating surface in this app does, would blank every web page in the
   * app for as long as a highlight was up. Worse, it would do it *because* the
   * highlight was over the page, which is the one moment the page has to stay
   * visible: the tour is pointing at it.
   *
   * The overlay is therefore rendered in place, inside the app root, and this
   * is the assertion that keeps it there. The React root is skipped by
   * `overlayRects`, so an overlay inside it contributes nothing.
   */
  it('contributes no overlay rectangle when it lives inside the app root', () => {
    const appRoot = {
      getBoundingClientRect: () => ({ left: 0, top: 0, width: 1440, height: 920 }),
      querySelector: () => null,
    }
    const body = { children: [appRoot] }
    expect(overlayRects(body, appRoot)).toEqual([])
  })

  it('would park every page if it were portalled into the body', () => {
    // The counter-case, so the test above is a claim rather than a tautology.
    const appRoot = {
      getBoundingClientRect: () => ({ left: 0, top: 0, width: 1440, height: 920 }),
      querySelector: () => null,
    }
    const portalled = {
      getBoundingClientRect: () => ({ left: 500, top: 300, width: 400, height: 120 }),
      querySelector: () => null,
    }
    const body = { children: [appRoot, portalled] }
    expect(overlayRects(body, appRoot)).toHaveLength(1)
  })

  it('draws a live page bright, with the hole exactly on it', () => {
    const page = { x: 400, y: 120, width: 800, height: 600 }
    const html = renderToStaticMarkup(
      <FocusOverlay target={{ kind: 'page' }} dom={dom({ [PAGE_SELECTOR]: page })} />,
    )
    expect(html).toMatch(/fo-scrim[^>]*left:400px/)
    expect(html).toMatch(/fo-scrim[^>]*border-radius:0/)
    // One pixel out on every side, so no ring pixel lands on the native view.
    expect(html).toMatch(/fo-ring[^>]*left:399px/)
    expect(html).toMatch(/fo-ring[^>]*width:802px/)
  })
})

describe('a clipped region does not claim edges it does not have', () => {
  it('marks the top border as a cut when the anchor is scrolled off', () => {
    const html = renderToStaticMarkup(
      <FocusOverlay
        target={TARGET}
        dom={dom({ [BUBBLE]: { x: 500, y: -40, width: 400, height: 120 } })}
      />,
    )
    expect(html).toContain('data-cut-top')
    expect(html).not.toContain('data-cut-bottom')
  })

  it('claims all four when the region is wholly inside', () => {
    const html = renderToStaticMarkup(
      <FocusOverlay
        target={TARGET}
        dom={dom({ [BUBBLE]: { x: 500, y: 300, width: 400, height: 120 } })}
      />,
    )
    expect(html).not.toContain('data-cut-')
  })
})

describe('travel', () => {
  it('is unlit while the screen is moving and lit at rest', () => {
    const world = dom({ [BUBBLE]: { x: 500, y: 300, width: 400, height: 120 } })
    expect(renderToStaticMarkup(<FocusOverlay target={TARGET} dom={world} lit />)).toContain(
      'data-lit',
    )
    expect(
      renderToStaticMarkup(<FocusOverlay target={TARGET} dom={world} lit={false} />),
    ).not.toContain('data-lit')
  })

  it('is hidden from assistive technology, being decoration over real content', () => {
    const world = dom({ [BUBBLE]: { x: 500, y: 300, width: 400, height: 120 } })
    expect(renderToStaticMarkup(<FocusOverlay target={TARGET} dom={world} />)).toContain(
      'aria-hidden="true"',
    )
  })
})
