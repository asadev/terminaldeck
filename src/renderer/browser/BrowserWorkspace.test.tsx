import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it } from 'vitest'
import { BrowserWorkspace, onStartPage, pageVisible } from './BrowserWorkspace'
import { newTab, type WorkspaceTab } from './tabs'
import { composeSend, describeLabelSource, oneLine } from './capture-text'
import { composeShot, shortenPath } from './ScreenshotPopup'
import { elide } from './CapturePopup'
import { formatBytes } from './SessionModal'
import {
  BRIDGE_METHODS,
  humanError,
  missingBridgeMethods,
  resolveBrowserBridge,
  type BrowserBridge,
  type BrowserTabState,
  type RecordingState,
} from './bridge'

/**
 * There is no DOM environment in this project's test setup, so render checks go
 * through static markup: effects do not run, which means these hold the
 * workspace's accessible structure to a contract and leave the live behaviour
 * to the pure modules and the main-process tests.
 */

const IDLE: BrowserTabState = {
  id: 'tab-1',
  url: 'http://localhost:3000/',
  label: 'localhost:3000',
  title: 'Dev',
  loading: false,
  canGoBack: false,
  canGoForward: false,
  inspecting: false,
  error: null,
  failed: false,
}

const NO_RECORDING: RecordingState = {
  recording: false,
  steps: [],
  text: '',
  line: '',
  truncated: false,
}

const noopBridge: BrowserBridge = {
  browserCreate: async () => IDLE,
  browserNavigate: async () => IDLE,
  browserBack: async () => IDLE,
  browserForward: async () => IDLE,
  browserReload: async () => IDLE,
  browserStop: async () => IDLE,
  browserInspect: async () => IDLE,
  browserClose: async () => undefined,
  browserBounds: () => undefined,
  browserVisible: () => undefined,
  onBrowserState: () => () => undefined,
  onBrowserElement: () => () => undefined,
  browserClaim: async () => ({ ok: true }),
  browserRelease: async () => undefined,
  browserZoom: async () => 1,
  browserDevtools: async () => true,
  browserScreenshot: async () => ({ path: '/tmp/x.png', width: 10, height: 10, preview: '' }),
  browserRevealScreenshot: async () => undefined,
  browserUserAgent: async () => 'Chromium',
  browserRecord: async () => NO_RECORDING,
  browserRecordClear: async () => NO_RECORDING,
  onBrowserProgress: () => () => undefined,
  onBrowserRecording: () => () => undefined,
  browserSessionInfo: async () => ({
    partition: 'persist:terminaldeck-browser',
    persistent: true,
    storagePath: '/tmp/Partitions/terminaldeck-browser',
    storageExists: true,
    cookieCount: 0,
    domainCount: 0,
    cacheBytes: 0,
  }),
  browserCookies: async () => [],
  browserClearCookies: async () => ({ removed: 0 }),
  browserClearStorage: async () => ({ origins: [] }),
  browserClearCache: async () => undefined,
}

describe('the bridge contract', () => {
  afterEach(() => {
    delete (globalThis as { window?: unknown }).window
  })

  const withDeck = (deck: unknown): void => {
    ;(globalThis as { window?: unknown }).window = { deck }
  }

  it('lists every method of the bridge interface', () => {
    // `noopBridge` is typed as BrowserBridge, so the compiler forces it to grow
    // when the interface does — and then this fails until the list grows too.
    expect([...BRIDGE_METHODS].sort()).toEqual(Object.keys(noopBridge).sort())
  })

  it('rejects a bridge missing any single method, not a sample of them', () => {
    // Driven off the interface rather than off BRIDGE_METHODS: a test that
    // iterates the list it is checking passes however short that list gets.
    const all = Object.keys(noopBridge)
    for (const absent of all) {
      const partial: Record<string, unknown> = {}
      for (const method of all) {
        if (method !== absent) partial[method] = () => undefined
      }
      withDeck(partial)
      expect(resolveBrowserBridge(), `a bridge without ${absent} was accepted`).toBeNull()
      expect(missingBridgeMethods(partial)).toEqual([absent])
    }
  })

  it('accepts a complete bridge and reports nothing missing', () => {
    withDeck(noopBridge)
    expect(resolveBrowserBridge()).not.toBeNull()
    expect(missingBridgeMethods(noopBridge)).toEqual([])
  })

  it('treats a preload that exposed nothing as everything missing', () => {
    expect(missingBridgeMethods(undefined)).toEqual([...BRIDGE_METHODS])
    expect(missingBridgeMethods(null)).toEqual([...BRIDGE_METHODS])
    withDeck(undefined)
    expect(resolveBrowserBridge()).toBeNull()
  })
})

describe('the unwired panel', () => {
  it('names what the preload is missing instead of a blank screen', () => {
    const html = renderToStaticMarkup(<BrowserWorkspace />)
    expect(html).toContain('The browser is not connected')
    expect(html).toContain('browserCreate')
    expect(html).toContain('browserRecord')
  })
})

describe('the wired panel', () => {
  // The panel had a tab strip of its own until the sidebar took over listing
  // browser pages. Nothing here opens or closes a tab any more, so the controls
  // this case names are the toolbar's.
  const html = renderToStaticMarkup(<BrowserWorkspace bridge={noopBridge} />)

  it('gives every control an accessible name', () => {
    for (const label of [
      'Back',
      'Forward',
      'Reload',
      'Home',
      'Inspect an element in the page',
      'Record what you do on this page',
      'Screenshot the page',
      'Show the page at a phone or tablet size',
      'Open Chrome devtools for the page',
      'Cookies and site data',
      'Address and search',
    ]) {
      expect(html, `no control named ${label}`).toContain(`aria-label="${label}"`)
    }
  })

  it('disables what cannot do anything yet', () => {
    // Effects do not run in static markup, so there is no tab: Back, Forward
    // and Reload all have to come up disabled rather than throwing on a click.
    expect(html).toContain('aria-label="Back" disabled=""')
    expect(html).toContain('aria-label="Forward" disabled=""')
  })

  it('prints every action’s name beside its glyph', () => {
    // Six unlabelled icons sat here on 2026-08-16 and he could not name one of
    // them. The accessible name above is the sentence; this is the word on
    // screen, and a tooltip is not a substitute for it.
    for (const word of ['Inspect', 'Record', 'Shot', 'Size', 'Devtools', 'Cookies']) {
      expect(html, `no visible label for ${word}`).toContain(
        `<span class="bw-icon-word">${word}</span>`,
      )
    }
  })

  it('leaves the four navigation glyphs bare', () => {
    // Back, Forward, Reload and Home have looked the same in every browser for
    // thirty years. Captioning those would be noise on the same bar the words
    // were added to.
    expect(html).not.toContain('<span class="bw-icon-word">Back</span>')
    expect(html).not.toContain('<span class="bw-icon-word">Home</span>')
  })

  it('has one bottom panel, and it is the recorder', () => {
    // There were two tabs down here — Element and Flow — and a capture forced
    // the strip onto Element. An element is a popup at the element now, so the
    // strip has one thing in it and nothing to switch with.
    expect(html).toContain('<span class="bw-bottom-title">Flow')
    expect(html).not.toContain('role="tab"')
  })

  it('does not print a second instruction under the first', () => {
    // "Turn on Inspect, then click something in the page to capture its
    // selector" used to sit at the bottom while "Click any element in the page.
    // Escape stops." sat under the toolbar — two instruction strips at once,
    // one of them telling him to do the thing he was already doing.
    expect(html).not.toContain('Turn on Inspect')
  })
})

/**
 * The panel that would not go away.
 *
 * Driving the packaged app found a session tab that rendered the browser
 * forever, and browser chrome ghosting over a *different* tab's terminal. One
 * cause: `visible` only parked the native pages, so the panel's own HTML — the
 * toolbar, the stage, the bottom panels — kept painting on every tab. It is a
 * full-height in-flow block in `.panes`, so it showed through the terminal's
 * padding gutter and pushed that session's chat view a whole pane below the
 * fold.
 *
 * Both halves are checked. The attribute alone hides nothing without the rule,
 * and the rule matches nothing without the attribute.
 */
describe('a panel whose tab is not on screen', () => {
  it('marks itself hidden rather than only parking its pages', () => {
    const html = renderToStaticMarkup(<BrowserWorkspace bridge={noopBridge} visible={false} />)
    expect(html).toContain('data-visible="false"')
  })

  it('stays on screen when a dialog only parks the pages', () => {
    // A modal is not a tab switch: the pages have to go under it, the panel
    // behind it must not, or the workspace blanks out behind every dialog.
    const html = renderToStaticMarkup(<BrowserWorkspace bridge={noopBridge} visible parkPage />)
    expect(html).toContain('data-visible="true"')
  })

  it('marks the unwired panel too, which is a whole panel like any other', () => {
    const html = renderToStaticMarkup(<BrowserWorkspace visible={false} />)
    expect(html).toContain('data-visible="false"')
  })

  it('has the stylesheet rule that makes the attribute mean something', () => {
    const css = readFileSync(join(__dirname, 'BrowserWorkspace.css'), 'utf8')
    const rule = /\.bw\[data-visible='false'\]\s*\{([^}]*)\}/.exec(css)
    expect(rule, ".bw[data-visible='false'] has no rule, so the flag hides nothing").not.toBeNull()
    expect(rule?.[1]).toMatch(/display:\s*none/)
  })
})

describe('oneLine', () => {
  it('flattens a multi-line paste, which would otherwise submit early', () => {
    expect(oneLine('make this\ngreen')).toBe('make this green')
  })

  it('strips terminal escapes out of what the user pasted', () => {
    // A raw ESC reaches a PTY and repaints the user's screen.
    const escape = String.fromCharCode(27)
    expect(oneLine(`rename${escape}[31m it`)).toBe('rename [31m it')
  })

  it('collapses runs of whitespace', () => {
    expect(oneLine('  a   b  ')).toBe('a b')
  })
})

describe('composeSend', () => {
  const context = '[browser: on http://localhost:3000/, element `#cta`, <button>]'

  it('puts the instruction before the context', () => {
    expect(composeSend(context, 'Make it green')).toBe(`Make it green ${context}`)
  })

  it('sends the context alone when there is no instruction', () => {
    expect(composeSend(context, '   ')).toBe(context)
  })
})

describe('describeLabelSource', () => {
  it('says nothing when there was no label to name', () => {
    expect(describeLabelSource('none')).toBe('')
    expect(describeLabelSource('text')).toBe('text')
    expect(describeLabelSource('aria-label')).toBe('aria-label')
  })
})

describe('formatBytes', () => {
  it('reads the way a person would say it', () => {
    expect(formatBytes(0)).toBe('0 B')
    expect(formatBytes(512)).toBe('512 B')
    expect(formatBytes(2048)).toBe('2.0 kB')
    expect(formatBytes(20 * 1024)).toBe('20 kB')
    expect(formatBytes(5 * 1024 * 1024)).toBe('5.0 MB')
  })

  it('does not go strange on a missing or negative size', () => {
    expect(formatBytes(-1)).toBe('0 B')
    expect(formatBytes(Number.NaN)).toBe('0 B')
  })
})

/**
 * The two faults from the screen recording of 2026-08-16 that this panel
 * decides, both of which live in an effect — which is exactly where this
 * project cannot test them, because its test run has no DOM and effects never
 * fire. So the rule itself is a pure function and this is where it is pinned.
 */
describe('when a native page is composited', () => {
  const showing: WorkspaceTab = {
    ...newTab('tab-1'),
    id: 'main-1',
    url: 'http://localhost:5173/',
  }
  const everythingOpen = {
    isActive: true,
    visible: true,
    parkPage: false,
    sessionOpen: false,
    covered: false,
    drawing: false,
    shotOpen: false,
  }

  it('shows a real page on the active tab of the visible panel', () => {
    expect(pageVisible(showing, everythingOpen)).toBe(true)
  })

  it('hides the page while any HTML surface is over it', () => {
    /*
     * The fault: "whatever the message popup is coming, it's hiding behind. I
     * cannot even see what it shows." A browser page is a native view
     * composited above the whole renderer, so no z-index can put a tooltip or a
     * menu on top of it. Hiding the view is the only lever Electron offers —
     * see `overlay-watch.ts`, which decides `covered` by geometry so an overlay
     * beside the page does not blank it.
     */
    expect(pageVisible(showing, { ...everythingOpen, covered: true })).toBe(false)
  })

  it('hides the page for a dialog, which is the same fault with a flag', () => {
    expect(pageVisible(showing, { ...everythingOpen, parkPage: true })).toBe(false)
    expect(pageVisible(showing, { ...everythingOpen, sessionOpen: true })).toBe(false)
  })

  it('hides the page while it is being drawn on, from the state and not the geometry', () => {
    /*
     * `covered` would eventually catch the canvas too, and "eventually" is a
     * frame too late. It is discovered by an observer *after* the surface
     * appears, and in that one frame the live website is on top and receives the
     * pointerdown that was meant for the drawing. Parking it from the state that
     * opened the canvas is what "the overlay must not receive the page's input
     * while drawing" actually requires.
     */
    expect(pageVisible(showing, { ...everythingOpen, drawing: true })).toBe(false)
  })

  it('hides the page while a screenshot popup is over it', () => {
    // Same reason, and it is what stops the website flashing back for a frame
    // between draw mode ending and the popup for the saved image opening.
    expect(pageVisible(showing, { ...everythingOpen, shotOpen: true })).toBe(false)
  })

  it('hides the page on a tab that is not the one on screen', () => {
    expect(pageVisible(showing, { ...everythingOpen, isActive: false })).toBe(false)
    expect(pageVisible(showing, { ...everythingOpen, visible: false })).toBe(false)
  })

  it('never composites a view whose load failed', () => {
    // The Windows fault, and the reason `failed` exists as its own field: the
    // document in the view is Chromium's red error page, and the whole change
    // is that nobody should ever see it.
    const failed: WorkspaceTab = { ...showing, failed: true, error: 'Nothing is listening.' }
    expect(pageVisible(failed, everythingOpen)).toBe(false)
    expect(onStartPage(failed)).toBe(true)
  })

  it('never composites a view that has not been anywhere', () => {
    expect(onStartPage(newTab('tab-2'))).toBe(true)
    expect(onStartPage({ ...showing, url: 'about:blank' })).toBe(true)
    expect(pageVisible(newTab('tab-2'), everythingOpen)).toBe(false)
  })

  it('keeps showing a page whose *error* is only a refusal', () => {
    // A blocked pop-up sets `error` over a page that is still perfectly
    // readable. Reading `error !== null` as "hide the page" would blank a
    // working site because something on it tried to open a window.
    const refused: WorkspaceTab = { ...showing, error: 'Blocked a pop-up to ads.example.' }
    expect(onStartPage(refused)).toBe(false)
    expect(pageVisible(refused, everythingOpen)).toBe(true)
  })
})

/**
 * A page leaves the screen before it is closed, not as a consequence of being
 * closed.
 *
 * `browserVisible` is a `send`: it is in the main process's queue the instant it
 * is called. `browserClose` and `browserRelease` are `invoke`s that resolve
 * whenever their round trip does, and in `closeTab` they are queued behind
 * whatever else the panel has in flight — a create waiting on an isolation key,
 * for instance. So "close it and it stops being on screen" leaves the page
 * composited over its replacement for as long as that takes, which is the
 * permanent bug of 2026-08-17 in miniature: a website over somebody's terminal,
 * only briefly.
 *
 * This is a source-text test because both call sites are inside effects and
 * callbacks, and this project's test run has no DOM — the same reason the rule
 * above is a pure function. It reads only for the *order* of the two calls,
 * which is the whole of the contract; `browser-view.channels.test.ts` is the
 * precedent for reading a file this way, and the last case here is the one that
 * fails rather than passing vacuously if the shape ever changes.
 *
 * None of this is the fix for the reported bug, and it must not be read as one.
 * A reload, a crash or a window closing never reaches any line in this file —
 * `shouldComposite` in `browser-tab.ts` is what covers those, and it is tested
 * there.
 */
describe('a page is hidden before it is closed', () => {
  const source = readFileSync(join(__dirname, 'BrowserWorkspace.tsx'), 'utf8')

  /** Every bridge call in `source`, in the order they appear. */
  const calls = [...source.matchAll(/\bapi\.(browser[A-Za-z]+)\(/g)].map((match) => ({
    name: match[1],
    at: match.index ?? 0,
  }))

  function hideBefore(closeIndex: number): boolean {
    const hides = calls.filter((call) => call.name === 'browserVisible' && call.at < closeIndex)
    // Within the same block: the nearest preceding call has to be the hide, or
    // "somewhere earlier in the file" would satisfy this forever.
    const nearest = calls.filter((call) => call.at < closeIndex).at(-1)
    return hides.length > 0 && nearest?.name === 'browserVisible'
  }

  it('hides the page in the unmount teardown before releasing and closing it', () => {
    const teardown = source.indexOf('void api.browserRelease(tab.id)')
    expect(teardown, 'the unmount teardown moved').toBeGreaterThan(0)
    expect(hideBefore(teardown)).toBe(true)
  })

  it('hides the page when a tab is closed, before the queued close', () => {
    const queued = source.indexOf('await api.browserRelease(id)')
    expect(queued, 'closeTab moved').toBeGreaterThan(0)
    expect(hideBefore(queued)).toBe(true)
  })

  it('reads a file that really does call the bridge', () => {
    // If the regex stops matching — the calls move behind a helper, the bridge
    // is renamed — every case above would pass by finding nothing at all.
    expect(calls.length).toBeGreaterThan(5)
    expect(calls.map((call) => call.name)).toContain('browserCreate')
  })
})

/**
 * The screenshot popup replaced a one-line banner — *"Saved 3072 x 1496 to
 * …png"* with Reveal and Dismiss beside it, and no picture. His instruction was
 * to show the shot with a box to type into, so the two strings the popup builds
 * are held here.
 */
describe('the screenshot popup', () => {
  it('cuts the path at the front, where the useless half is', () => {
    // `/Users/apple/Pictures/Terminal Deck/` is identical on every row; the
    // filename carries the site and the timestamp.
    expect(shortenPath('/Users/apple/Pictures/Terminal Deck/localhost-8791-20260817-012405.png'))
      .toBe('…/Terminal Deck/localhost-8791-20260817-012405.png')
  })

  it('leaves a short path alone', () => {
    expect(shortenPath('/tmp/a.png')).toBe('/tmp/a.png')
  })

  it('never reorders the path, which is what the CSS version did', () => {
    // `direction: rtl` moved the leading slash to the visual end and printed
    // `…Terminal Deck/localhost-8791.png/` — a path that reads as a directory.
    expect(shortenPath('/Users/apple/Pictures/Terminal Deck/x.png')).not.toMatch(/\/$/)
  })

  it('hands the agent the path and the size, on one line', () => {
    const line = composeShot(
      { path: '/tmp/page.png', width: 3072, height: 1496, preview: 'data:image/png;base64,AA' },
      'why is the header cut off?',
    )
    expect(line).toBe('why is the header cut off? [browser screenshot: /tmp/page.png (3072 x 1496)]')
    expect(line).not.toContain('\n')
    // The preview is for the popup. An agent cannot do anything with a data URL
    // typed into a terminal, and it would be a megabyte of it.
    expect(line).not.toContain('base64')
  })
})

/**
 * What the notice band says when an invoke rejects.
 *
 * Seen on screen on 2026-08-17, pressing Draw on a tab that had not been
 * anywhere: *"Error invoking remote method 'browser-view:frame': Error: The page
 * has to be on screen to capture it."* The main process phrases that as a
 * sentence precisely so a person can read it, and Electron's wrapper undoes the
 * work on the way across.
 */
describe('an error that came back over the bridge', () => {
  it('is the sentence the main process wrote, without Electron’s wrapper', () => {
    const wrapped = new Error(
      "Error invoking remote method 'browser-view:frame': Error: The page has to be on screen to capture it.",
    )
    expect(humanError(wrapped)).toBe('The page has to be on screen to capture it.')
  })

  it('keeps a message that was never wrapped, even one starting with Error:', () => {
    expect(humanError(new Error('Error: something local'))).toBe('Error: something local')
    expect(humanError(new Error('plain'))).toBe('plain')
  })

  it('never returns nothing, whatever it is handed', () => {
    // A blank notice band is the same as no notice at all, and the case it is
    // reporting is one where a control appeared to do nothing.
    const empty = new Error("Error invoking remote method 'x': Error: ")
    expect(humanError(empty)).toBe("Error invoking remote method 'x': Error: ")
    expect(humanError('a string')).toBe('a string')
    expect(humanError(null)).toBe('null')
  })
})

describe('the capture popup’s text line', () => {
  it('shows a short label whole', () => {
    expect(elide('Place order')).toBe('Place order')
  })

  it('cuts a long one on a word boundary', () => {
    const long =
      'Country United Arab Emirates Pakistan Portugal Afghanistan Albania Algeria Andorra Angola Argentina'
    const shown = elide(long)
    expect(shown.endsWith('…')).toBe(true)
    expect(shown.length).toBeLessThanOrEqual(91)
    // Cut between words, not through one: what is shown is a prefix of the
    // original that ends where a word does.
    const visible = shown.slice(0, -1)
    expect(long.startsWith(visible)).toBe(true)
    expect(long[visible.length]).toBe(' ')
  })
})
