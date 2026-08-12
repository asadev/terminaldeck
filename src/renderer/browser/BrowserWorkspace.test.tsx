import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it } from 'vitest'
import { BrowserWorkspace } from './BrowserWorkspace'
import { composeSend, describeLabelSource, oneLine } from './CapturePanel'
import { formatBytes } from './SessionModal'
import {
  BRIDGE_METHODS,
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
  browserScreenshot: async () => ({ path: '/tmp/x.png', width: 10, height: 10 }),
  browserRevealScreenshot: async () => undefined,
  browserUserAgent: async () => 'Chromium',
  browserRecord: async () => NO_RECORDING,
  browserRecordClear: async () => NO_RECORDING,
  onBrowserProgress: () => () => undefined,
  onBrowserRecording: () => () => undefined,
  browserSessionInfo: async () => ({
    partition: 'persist:pawl-browser',
    persistent: true,
    storagePath: '/tmp/Partitions/pawl-browser',
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

  const withPawl = (pawl: unknown): void => {
    ;(globalThis as { window?: unknown }).window = { pawl }
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
      withPawl(partial)
      expect(resolveBrowserBridge(), `a bridge without ${absent} was accepted`).toBeNull()
      expect(missingBridgeMethods(partial)).toEqual([absent])
    }
  })

  it('accepts a complete bridge and reports nothing missing', () => {
    withPawl(noopBridge)
    expect(resolveBrowserBridge()).not.toBeNull()
    expect(missingBridgeMethods(noopBridge)).toEqual([])
  })

  it('treats a preload that exposed nothing as everything missing', () => {
    expect(missingBridgeMethods(undefined)).toEqual([...BRIDGE_METHODS])
    expect(missingBridgeMethods(null)).toEqual([...BRIDGE_METHODS])
    withPawl(undefined)
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
  // showTabs on: the window header owns tabs in the app, so the panel's own
  // strip is off by default. This case is about the strip's controls.
  const html = renderToStaticMarkup(<BrowserWorkspace bridge={noopBridge} showTabs />)

  it('gives every control an accessible name', () => {
    for (const label of [
      'Back',
      'Forward',
      'Reload',
      'Home',
      'Inspect an element',
      'Record a flow',
      'Screenshot the page',
      'Responsive sizes',
      'Open devtools for the page',
      'Cookies and site data',
      'New browser tab',
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

  it('starts on the element panel with an instruction rather than emptiness', () => {
    expect(html).toContain('Turn on Inspect')
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
