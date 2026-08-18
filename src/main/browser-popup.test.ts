import { describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({ BrowserWindow: class {} }))

const { popupSize, popupTitle, wantsPopupWindow } = await import('./browser-popup')

/**
 * The routing rule, held against what Chromium actually reports.
 *
 * Every case below is a line from a real measurement on Electron 41.10.5 on
 * 2026-08-18: a page called each of these and the `setWindowOpenHandler`
 * details were printed. They are pinned here because the rule is only correct
 * if those values are what they were, and a future Electron changing one of
 * them should fail loudly rather than silently start opening every link in a
 * window — or, far worse, silently stop opening sign-ins in one.
 */
const ask = (over: Partial<Parameters<typeof wantsPopupWindow>[0]>) => ({
  url: 'https://example.com/x',
  frameName: '',
  disposition: 'foreground-tab',
  features: '',
  ...over,
})

describe('a sign-in pop-up is told apart from a link', () => {
  it('window.open with a size is a pop-up', () => {
    // window.open(url, 'oauth', 'width=500,height=600')
    expect(
      wantsPopupWindow(ask({ frameName: 'oauth', disposition: 'new-window', features: 'width=500,height=600' })),
    ).toBe(true)
  })

  it('a named target is a pop-up even without a size', () => {
    // window.open(url, 'oauth2') — the page kept a name so it can find the
    // window again, which is only useful if it also kept the handle.
    expect(wantsPopupWindow(ask({ frameName: 'oauth2' }))).toBe(true)
  })

  it('a plain window.open is a link', () => {
    expect(wantsPopupWindow(ask({}))).toBe(false)
  })

  it('target="_blank" is a link, because Chromium normalises the name away', () => {
    // Measured: both `window.open(url, '_blank')` and a clicked
    // `<a target="_blank">` arrive with an EMPTY frame name. That is what keeps
    // the named-target rule above from catching every ordinary link on the web.
    expect(wantsPopupWindow(ask({ frameName: '' }))).toBe(false)
  })

  it('refuses anything that is not http(s), whatever its disposition', () => {
    // The guard `browser-tab.ts` has always had. A pop-up is a window with
    // fewer checks than a tab, so this is the one place it must not be relaxed.
    expect(wantsPopupWindow(ask({ url: 'file:///etc/passwd', disposition: 'new-window' }))).toBe(false)
    expect(wantsPopupWindow(ask({ url: 'javascript:alert(1)', frameName: 'x' }))).toBe(false)
  })

  it('allows about:blank, which is how a pop-up is opened before it is aimed', () => {
    // Half the OAuth libraries on the web open about:blank first and set
    // `popup.location` afterwards, so refusing it would refuse them.
    expect(wantsPopupWindow(ask({ url: 'about:blank', disposition: 'new-window' }))).toBe(true)
  })
})

describe('the size a pop-up gets', () => {
  it('is the one the page asked for, when that is usable', () => {
    expect(popupSize('width=500,height=600')).toEqual({ width: 500, height: 600 })
  })

  it('clamps a transport-sized pop-up up to something visible', () => {
    // `width=1` is a real value on real sites, used when a pop-up is a message
    // channel rather than a screen. Obeying it produces a window a person
    // cannot see or close.
    expect(popupSize('width=1,height=1').width).toBeGreaterThanOrEqual(320)
    expect(popupSize('width=1,height=1').height).toBeGreaterThanOrEqual(360)
  })

  it('falls back when the page said nothing', () => {
    expect(popupSize('')).toEqual({ width: 520, height: 680 })
  })

  it('is not fooled by a number that is part of another word', () => {
    // `noopener` contains no digits, but `menubar=0,width=400` and
    // `screenwidth=9999` both do — and the second must not become the size.
    expect(popupSize('screenwidth=9999,width=400,height=500')).toEqual({ width: 400, height: 500 })
  })
})

describe('the title of a window somebody types a password into', () => {
  it('leads with the host, because the page chooses its own title', () => {
    expect(popupTitle('https://accounts.google.com/signin', 'Sign in')).toBe(
      'accounts.google.com — Sign in',
    )
  })

  it('is the host alone when the document has not said anything', () => {
    expect(popupTitle('https://accounts.google.com/signin', '')).toBe('accounts.google.com')
  })

  it('does not print the host twice when the page named itself after it', () => {
    expect(popupTitle('https://example.com/', 'example.com')).toBe('example.com')
  })
})
