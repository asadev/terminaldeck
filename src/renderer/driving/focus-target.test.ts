import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  anchorId,
  anchorSelector,
  ANCHOR_ATTR,
  createAnchor,
  PAD_ANCHOR,
  PAD_PAGE,
  PAGE_SELECTOR,
  RADIUS_PAGE,
  scrollToFocus,
  type FocusDom,
} from './focus-target'
import { outlineBands, outsideOf, type Rect } from './geometry'
import {
  clearTerminals,
  registerTerminal,
  terminalUnavailable,
  type DriveBuffer,
  type DriveTerminal,
} from './terminal-registry'

/* ------------------------------------------------------------- fake world -- */

const box = (rect: Rect) => ({
  getBoundingClientRect: () => ({
    left: rect.x,
    top: rect.y,
    width: rect.width,
    height: rect.height,
  }),
})

function fakeDom(elements: Record<string, Rect>, viewport: Rect = { x: 0, y: 0, width: 1440, height: 920 }): FocusDom {
  return {
    find: (selector) => (selector in elements ? box(elements[selector]) : null),
    viewport: () => viewport,
  }
}

const NOOP = { dispose: () => undefined }

function fakeTerminal(lines: readonly string[], over: Partial<DriveBuffer> = {}): {
  term: DriveTerminal
  host: HTMLElement
  scrolled: number[]
} {
  const scrolled: number[] = []
  const buffer: DriveBuffer = {
    type: 'normal',
    viewportY: 0,
    baseY: 0,
    length: lines.length,
    getLine: (index) =>
      index >= 0 && index < lines.length ? { translateToString: () => lines[index] } : undefined,
    ...over,
  }
  // A `.xterm` root whose only child is a `.xterm-screen` of known size —
  // exactly what the registry reads and nothing more, so the test says what the
  // registry's contract is.
  const screen = box({ x: 448, y: 186, width: 850, height: 743 })
  const element = {
    querySelector: (selector: string) => (selector === '.xterm-screen' ? screen : null),
  } as unknown as HTMLElement
  return {
    term: {
      cols: 109,
      rows: 33,
      element,
      buffer: { active: buffer },
      onRender: () => NOOP,
      onResize: () => NOOP,
      scrollToLine: (line) => scrolled.push(line),
    },
    host: box({ x: 448, y: 160, width: 868, height: 790 }) as unknown as HTMLElement,
    scrolled,
  }
}

afterEach(() => {
  clearTerminals()
  vi.restoreAllMocks()
})

/* ------------------------------------------------------------- selectors -- */

describe('anchors are a closed set with no selector escape hatch', () => {
  it('names each kind', () => {
    expect(anchorId({ at: 'message', messageId: 'agent:abc' })).toBe('message:agent:abc')
    expect(anchorId({ at: 'session-row', sessionId: 's1' })).toBe('session-row:s1')
    expect(anchorId({ at: 'alert', alertId: 'a1' })).toBe('alert:a1')
    expect(anchorId({ at: 'usage', sessionId: 's1' })).toBe('usage:s1')
    // Keyed on the project folder, not a session: one working tree per folder,
    // however many sessions are open in it. See `DriveAnchor`.
    expect(anchorId({ at: 'git-file', cwd: '/w/proj', path: 'src/a.ts' })).toBe(
      'git-file:/w/proj:src/a.ts',
    )
  })

  it('builds an attribute selector, never a free-form one', () => {
    expect(anchorSelector({ at: 'session-row', sessionId: 's1' })).toBe(
      `[${ANCHOR_ATTR}="session-row:s1"]`,
    )
  })

  /*
   * These values are file paths and ids that arrived over a tool call the
   * copilot composed from *other sessions' transcripts* — untrusted content by
   * `COPILOT-CAPABILITIES.md` §3.2 item 8. A quote or a backslash in a path is
   * the whole attack: end the string early and the rest of the value becomes
   * selector syntax, which decides what the app measures and therefore what the
   * reader is directed to look at.
   */
  it('cannot be escaped out of by a quote or a backslash in a path', () => {
    const selector = anchorSelector({
      at: 'git-file',
      cwd: '/w',
      path: 'a"],[data-drive-anchor],x\\b',
    })
    expect(selector).toBe(`[${ANCHOR_ATTR}="git-file:/w:a\\"],[data-drive-anchor],x\\\\b"]`)
    /*
     * The value is entirely inside one pair of quotes, so nothing in it is
     * selector syntax. Checked by removing the quoted string and seeing that a
     * bare, empty attribute selector is all that is left — if an injected `"`
     * had ended the string early there would be syntax outside it.
     */
    const withoutValue = selector.replace(/"(?:[^"\\]|\\.)*"/, '')
    expect(withoutValue).toBe(`[${ANCHOR_ATTR}=]`)
  })
})

/* ------------------------------------------------------------ page target -- */

describe('a browser page is worked around, never painted over', () => {
  const page: Rect = { x: 400, y: 120, width: 800, height: 600 }

  it('makes the hole exactly the page, with no padding and square corners', () => {
    const dom = fakeDom({ [PAGE_SELECTOR]: page })
    const result = createAnchor({ kind: 'page' }).measure(dom)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.focus.rect).toEqual(page)
    expect(PAD_PAGE).toBe(0)
    expect(result.focus.radius).toBe(RADIUS_PAGE)
  })

  /*
   * The rule this enforces is physics. A page is a `WebContentsView` composited
   * above the entire renderer, so an overlay pixel inside its rectangle is not
   * composited at all — it silently disappears. The ring is a 1px border on a
   * box grown by 1px, which lands entirely outside; a rounded hole would also
   * be a lie, because the scrim's corners would be drawn inside the page and
   * never appear.
   */
  it('leaves every pixel of the page to the page', () => {
    const dom = fakeDom({ [PAGE_SELECTOR]: page })
    const result = createAnchor({ kind: 'page' }).measure(dom)
    if (!result.ok) throw new Error('expected a resolution')
    expect(outsideOf(outlineBands(result.focus.rect, 1), page)).toBe(true)
  })

  it('says so when there is no page on screen', () => {
    const result = createAnchor({ kind: 'page' }).measure(fakeDom({}))
    expect(result).toMatchObject({ ok: false, why: 'no-page' })
  })

  /*
   * The honest half. When the focus is somewhere else and a live page is inside
   * the dimmed area, no HTML in this process can dim it — and the overlay does
   * not reach for the two things that would hide that. It does not park the
   * page, which would make a dull region vanish outright (censorship, not
   * emphasis), and it does not freeze a photograph over it. It reports.
   */
  it('reports a page it cannot dim when the focus is elsewhere', () => {
    const dom = fakeDom({
      [PAGE_SELECTOR]: page,
      [anchorSelector({ at: 'alert', alertId: 'a1' })]: { x: 10, y: 10, width: 100, height: 40 },
    })
    const result = createAnchor({ kind: 'anchor', anchor: { at: 'alert', alertId: 'a1' } }).measure(
      dom,
    )
    if (!result.ok) throw new Error('expected a resolution')
    expect(result.focus.undimmable).toEqual(['browser-page'])
  })

  it('reports nothing undimmable when the page is the focus', () => {
    const dom = fakeDom({ [PAGE_SELECTOR]: page })
    const result = createAnchor({ kind: 'page' }).measure(dom)
    if (!result.ok) throw new Error('expected a resolution')
    expect(result.focus.undimmable).toEqual([])
  })
})

/* ---------------------------------------------------------- anchor target -- */

describe('a chrome anchor', () => {
  const selector = anchorSelector({ at: 'message', messageId: 'agent:m1' })

  it('grows the bubble so the ring is not on its text', () => {
    const dom = fakeDom({ [selector]: { x: 500, y: 300, width: 400, height: 120 } })
    const result = createAnchor({
      kind: 'anchor',
      anchor: { at: 'message', messageId: 'agent:m1' },
    }).measure(dom)
    if (!result.ok) throw new Error('expected a resolution')
    expect(result.focus.rect).toEqual({
      x: 500 - PAD_ANCHOR,
      y: 300 - PAD_ANCHOR,
      width: 400 + PAD_ANCHOR * 2,
      height: 120 + PAD_ANCHOR * 2,
    })
  })

  it('clips a bubble scrolled half out of the window and drops the cut edge', () => {
    const dom = fakeDom({ [selector]: { x: 500, y: -40, width: 400, height: 120 } })
    const result = createAnchor({
      kind: 'anchor',
      anchor: { at: 'message', messageId: 'agent:m1' },
    }).measure(dom)
    if (!result.ok) throw new Error('expected a resolution')
    expect(result.focus.edges.top).toBe(false)
    expect(result.focus.rect.y).toBe(0)
  })

  it('says the anchor is missing rather than guessing', () => {
    const result = createAnchor({
      kind: 'anchor',
      anchor: { at: 'message', messageId: 'gone' },
    }).measure(fakeDom({}))
    expect(result).toMatchObject({ ok: false, why: 'anchor-missing' })
  })

  it('says off-screen for an anchor scrolled entirely away', () => {
    const dom = fakeDom({ [selector]: { x: 500, y: -900, width: 400, height: 120 } })
    const result = createAnchor({
      kind: 'anchor',
      anchor: { at: 'message', messageId: 'agent:m1' },
    }).measure(dom)
    expect(result).toMatchObject({ ok: false, why: 'off-screen' })
  })
})

/* -------------------------------------------------------- terminal target -- */

describe('a terminal region', () => {
  const LINES = ['boot', 'npm test', 'FAIL  src/a.test.ts', '  expected 1 got 2', 'done']

  it('boxes the quoted lines where they actually are', () => {
    const fake = fakeTerminal(LINES)
    registerTerminal('s1', fake)
    const result = createAnchor({
      kind: 'terminal',
      sessionId: 's1',
      quote: 'FAIL  src/a.test.ts\n  expected 1 got 2',
    }).measure(fakeDom({}))
    if (!result.ok) throw new Error('expected a resolution')
    // Two lines starting at buffer line 2, with the terminal at the top.
    expect(result.focus.rect.y).toBeCloseTo(186 + (743 / 33) * 2 - 3, 2)
    expect(result.focus.rect.height).toBeCloseTo((743 / 33) * 2 + 6, 2)
  })

  it('says the quote is gone rather than boxing something else', () => {
    registerTerminal('s1', fakeTerminal(LINES))
    const result = createAnchor({
      kind: 'terminal',
      sessionId: 's1',
      quote: 'a line that was never printed',
    }).measure(fakeDom({}))
    expect(result).toMatchObject({ ok: false, why: 'quote-not-found' })
  })

  /*
   * A full-screen TUI has no scrollback and repaints wholesale, so there is
   * nothing to anchor to. This is a state to name, not a bug to route around —
   * "a tour that quietly stops boxing is worse than one that says 'this one is
   * in vim; here is the text.'"
   */
  it('names the alternate screen buffer instead of drawing a wrong box', () => {
    registerTerminal('s1', fakeTerminal(LINES, { type: 'alternate' }))
    expect(terminalUnavailable('s1')).toBe('alternate-buffer')
    const result = createAnchor({ kind: 'terminal', sessionId: 's1', quote: 'boot' }).measure(
      fakeDom({}),
    )
    expect(result).toMatchObject({ ok: false, why: 'alternate-buffer' })
  })

  it('names a session with no terminal mounted', () => {
    const result = createAnchor({ kind: 'terminal', sessionId: 'nope', quote: 'x' }).measure(
      fakeDom({}),
    )
    expect(result).toMatchObject({ ok: false, why: 'not-registered' })
  })

  /*
   * The cache is one integer and it is revalidated in O(1) before use, because
   * the alternative — a full backwards scan — runs on every frame a streaming
   * session renders on. Here the buffer is rewritten under the cached line, and
   * the anchor must relocate rather than keep pointing at the old index.
   */
  it('relocates when the cached line is overwritten', () => {
    const lines = ['x', 'the important line', 'y']
    const buffer = { current: lines }
    const fake = fakeTerminal(lines)
    const live: DriveTerminal = {
      ...fake.term,
      buffer: {
        active: {
          ...fake.term.buffer.active,
          get length() {
            return buffer.current.length
          },
          getLine: (index: number) =>
            index >= 0 && index < buffer.current.length
              ? { translateToString: () => buffer.current[index] }
              : undefined,
        },
      },
    }
    registerTerminal('s1', { term: live, host: fake.host })

    const anchor = createAnchor({
      kind: 'terminal',
      sessionId: 's1',
      quote: 'the important line',
    })
    const first = anchor.measure(fakeDom({}))
    if (!first.ok) throw new Error('expected a resolution')
    const firstY = first.focus.rect.y

    // A repaint moves it down two lines and leaves something else behind.
    buffer.current = ['x', 'a spinner frame', 'y', 'the important line', 'z']
    const second = anchor.measure(fakeDom({}))
    if (!second.ok) throw new Error('expected a resolution after the repaint')
    expect(second.focus.rect.y).toBeCloseTo(firstY + (743 / 33) * 2, 2)
  })

  it('reports off-screen once the region has scrolled past the top', () => {
    const fake = fakeTerminal(LINES, { viewportY: 40 })
    registerTerminal('s1', fake)
    const result = createAnchor({ kind: 'terminal', sessionId: 's1', quote: 'boot' }).measure(
      fakeDom({}),
    )
    expect(result).toMatchObject({ ok: false, why: 'off-screen' })
  })

  /*
   * Travel is an action, so it only fires when the region genuinely is not
   * visible. Scrolling a terminal that is already showing the passage moves the
   * reader's page for no reason, which during a tour reads as the app twitching.
   */
  it('scrolls to a region that is off screen and leaves a visible one alone', () => {
    const off = fakeTerminal(LINES, { viewportY: 40 })
    registerTerminal('s1', off)
    const hidden = createAnchor({ kind: 'terminal', sessionId: 's1', quote: 'FAIL' })
    expect(scrollToFocus(hidden)).toBe(true)
    expect(off.scrolled).toEqual([0])

    clearTerminals()
    const visible = fakeTerminal(LINES)
    registerTerminal('s2', visible)
    const shown = createAnchor({ kind: 'terminal', sessionId: 's2', quote: 'FAIL' })
    expect(scrollToFocus(shown)).toBe(false)
    expect(visible.scrolled).toEqual([])
  })
})
