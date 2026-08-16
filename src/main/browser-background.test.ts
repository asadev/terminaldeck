import { describe, expect, it } from 'vitest'
import { backgroundFor, PAGE_BACKGROUND, safeBackground } from './browser-background'

describe('safeBackground', () => {
  it('takes the forms tokens.css actually writes', () => {
    expect(safeBackground('#191919')).toBe('#191919')
    expect(safeBackground('  #FAFAFA  ')).toBe('#fafafa')
    expect(safeBackground('#abc')).toBe('#aabbcc')
  })

  it('drops the alpha rather than passing it to a native view', () => {
    // A translucent view lets the app's own UI show through the page, which
    // reads as a rendering fault rather than as transparency.
    expect(safeBackground('#19191980')).toBe('#191919')
  })

  it('refuses anything Electron would throw on, instead of guessing', () => {
    for (const bad of [
      '',
      '   ',
      'white',
      'rgb(25,25,25)',
      'var(--bg-primary)',
      '#12',
      '#1234567',
      '#gggggg',
      null,
      undefined,
      0x191919,
      { hex: '#191919' },
    ]) {
      expect(safeBackground(bad), `${String(bad)} was accepted`).toBeNull()
    }
  })
})

describe('backgroundFor', () => {
  const APP = '#191919'

  it('paints a real page white, whatever the app theme is', () => {
    // Load-bearing, and the thing somebody will try to "simplify" away: bare
    // HTML declares no background, so a dark base colour renders an unstyled
    // dev-server page as black text on dark grey.
    expect(backgroundFor('http://localhost:3000/', APP)).toBe(PAGE_BACKGROUND)
    expect(backgroundFor('https://example.com/', APP)).toBe(PAGE_BACKGROUND)
    expect(backgroundFor('HTTP://LOCALHOST:3000/', APP)).toBe(PAGE_BACKGROUND)
  })

  it('paints an empty view in the app colour, which is the whole fix', () => {
    expect(backgroundFor('', APP)).toBe(APP)
    expect(backgroundFor('about:blank', APP)).toBe(APP)
  })

  it('falls back to white when the renderer sent no colour', () => {
    // An older preload, or a build where the token was renamed. A backdrop that
    // is conventional-but-wrong beats a black rectangle nobody chose.
    expect(backgroundFor('about:blank', null)).toBe(PAGE_BACKGROUND)
    expect(backgroundFor('http://localhost:3000/', null)).toBe(PAGE_BACKGROUND)
  })
})
