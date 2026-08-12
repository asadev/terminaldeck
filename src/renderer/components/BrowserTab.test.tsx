import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it } from 'vitest'
import {
  BRIDGE_METHODS,
  BrowserTab,
  composeSend,
  describeLabelSource,
  oneLine,
  resolveBridge,
  type BrowserBridge,
  type BrowserTabState,
} from './BrowserTab'

/**
 * There is no DOM environment in this project's test setup, so the render
 * checks go through static markup. Effects do not run there, which means these
 * hold the chrome's accessible structure to a contract and leave the live
 * behaviour to the main-process tests.
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

const noopBridge: BrowserBridge = {
  createBrowserTab: async () => IDLE,
  navigateBrowserTab: async () => IDLE,
  reloadBrowserTab: async () => IDLE,
  stopBrowserTab: async () => IDLE,
  browserTabBack: async () => IDLE,
  browserTabForward: async () => IDLE,
  setBrowserInspect: async () => IDLE,
  closeBrowserTab: async () => undefined,
  setBrowserTabBounds: () => undefined,
  setBrowserTabVisible: () => undefined,
  onBrowserTabState: () => () => undefined,
  onBrowserElement: () => () => undefined,
}

describe('resolveBridge', () => {
  afterEach(() => {
    delete (globalThis as { window?: unknown }).window
  })

  const withPawl = (pawl: unknown) => {
    ;(globalThis as { window?: unknown }).window = { pawl }
  }

  it('checks every method the panel calls, not a sample of them', () => {
    // The panel only renders its "not connected" explanation when this returns
    // null. A partial check meant a bridge missing `browserTabBack` mounted
    // fine and then threw a TypeError under the Back button.
    // Driven off the interface, not off BRIDGE_METHODS: a test that iterates
    // the list it is checking passes however short the list gets.
    const all = Object.keys(noopBridge)
    for (const missing of all) {
      const partial: Record<string, unknown> = {}
      for (const method of all) {
        if (method !== missing) partial[method] = () => undefined
      }
      withPawl(partial)
      expect(resolveBridge(), `bridge without ${missing} was accepted`).toBeNull()
    }
  })

  it('lists every method of the bridge interface', () => {
    // `noopBridge` is typed as BrowserBridge, so the compiler forces it to grow
    // when the interface does — and then this fails until the list grows too.
    expect([...BRIDGE_METHODS].sort()).toEqual(Object.keys(noopBridge).sort())
  })

  it('accepts a complete bridge', () => {
    withPawl(noopBridge)
    expect(resolveBridge()).not.toBeNull()
  })

  it('returns null when the preload exposed nothing at all', () => {
    withPawl(undefined)
    expect(resolveBridge()).toBeNull()
  })
})

describe('oneLine', () => {
  it('flattens a multi-line paste, which would otherwise submit early', () => {
    expect(oneLine('make this\ngreen')).toBe('make this green')
  })

  it('strips terminal escapes out of what the user pasted', () => {
    expect(oneLine('rename\u001b[31m it')).toBe('rename [31m it')
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

  it('never produces more than one line', () => {
    expect(composeSend(context, 'first\nsecond')).not.toMatch(/\n/)
  })
})

describe('describeLabelSource', () => {
  it('names the attribute a label came from, and nothing for plain text', () => {
    expect(describeLabelSource('aria-label')).toBe('aria-label')
    expect(describeLabelSource('text')).toBe('text')
    expect(describeLabelSource('none')).toBe('')
  })
})

describe('BrowserTab chrome', () => {
  const html = renderToStaticMarkup(<BrowserTab bridge={noopBridge} initialUrl="localhost:3000" />)

  it('labels every control, since they are all icons', () => {
    expect(html).toContain('aria-label="Back"')
    expect(html).toContain('aria-label="Forward"')
    expect(html).toContain('aria-label="Reload"')
    expect(html).toContain('aria-label="Address"')
  })

  it('exposes Inspect as a toggle rather than a plain button', () => {
    expect(html).toContain('aria-pressed="false"')
  })

  it('starts back and forward disabled', () => {
    expect(html.match(/disabled/g) ?? []).toHaveLength(2)
  })

  it('renders the viewport rectangle the native view is painted over', () => {
    expect(html).toContain('browser-viewport')
  })

  it('shows no capture panel until an element is clicked', () => {
    expect(html).not.toContain('browser-capture')
    expect(html).not.toContain('Send to agent')
  })
})
