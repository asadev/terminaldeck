import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { STORE_LOGO_ASSETS } from './logo-data'
import { StoreLogo, monogram, monogramFill } from './StoreLogo'

/**
 * The marks, and the ways a store full of them could be lying.
 *
 * ## What is actually at risk here
 *
 * 1. **A mark that is secretly a URL.** The whole argument for generating a
 *    module of bytes is that opening the store contacts nobody — not the
 *    vendors, not once, and not differently with the network off. One
 *    `https://…` slipped into `src` and that is quietly untrue. Every asset is
 *    checked for it.
 * 2. **Provenance that cannot be checked.** A recorded source and digest are
 *    what make a mark auditable and refreshable; a blank one is a picture whose
 *    origin nobody can establish afterwards.
 * 3. **A fallback that is worse than nothing.** A row with no mark must draw
 *    something honest rather than a broken-image glyph, and it must still draw
 *    something when the name it was given is empty.
 *
 * The other half of this feature — that every catalogue row names a mark that
 * exists — is checked in `src/main/store-logos.test.ts`, which is the side of
 * the app the catalogues live on.
 */

describe('the marks are bytes, not addresses', () => {
  for (const [key, asset] of Object.entries(STORE_LOGO_ASSETS)) {
    it(`${key} is inline and provable`, () => {
      /* The one that matters. A store that fetched its own furniture would be
         telling a third party every time it opened, and would draw nothing on
         an aeroplane. */
      expect(asset.src.startsWith('data:image/')).toBe(true)
      expect(asset.src).not.toMatch(/https?:\/\//)

      /* Where it came from and what came back, so a refresh is checkable
         rather than a fresh act of faith. */
      expect(asset.source.startsWith('https://')).toBe(true)
      expect(asset.sha256).toMatch(/^[0-9a-f]{64}$/)
      expect(asset.fetched).toMatch(/^\d{4}-\d{2}-\d{2}$/)

      /* The budget, kept as a number somebody can see rather than a hope. This
         is `MAX_BYTES` in `scripts/store-logos.mjs`, and it is here as well
         because the script only runs when somebody runs it. */
      expect(asset.src.length).toBeLessThanOrEqual(24_000)
    })
  }

  it('stays inside a budget a bundle can carry', () => {
    const total = Object.values(STORE_LOGO_ASSETS).reduce((sum, one) => sum + one.src.length, 0)
    expect(total).toBeLessThan(260_000)
  })
})

describe('the row with no mark', () => {
  it('takes the first letter of the name, whatever it is wrapped in', () => {
    expect(monogram('Dark Reader')).toBe('D')
    expect(monogram('uBlock Origin')).toBe('U')
    expect(monogram('@scope/thing')).toBe('S')
    expect(monogram('7-zip')).toBe('7')
  })

  it('says something rather than nothing when there is no name at all', () => {
    expect(monogram('')).toBe('?')
    expect(monogram('   ')).toBe('?')
  })

  it('picks one of the four fills, and the same one every time', () => {
    for (const id of ['a', 'filesystem', 'some-folder-somebody-dropped-in', '']) {
      const fill = monogramFill(id)
      expect(fill).toBeGreaterThanOrEqual(1)
      expect(fill).toBeLessThanOrEqual(4)
      expect(monogramFill(id)).toBe(fill)
    }
  })

  it('does not put a shelf of them all on the same colour', () => {
    const fills = new Set(
      ['one-folder', 'another-folder', 'a-third', 'and-a-fourth'].map(monogramFill),
    )
    expect(fills.size).toBeGreaterThan(1)
  })
})

describe('what it draws', () => {
  it('draws the mark inline, and does not read it out twice', () => {
    const html = renderToStaticMarkup(
      <StoreLogo name="Dark Reader" id="dark-reader" logo="dark-reader" />,
    )
    expect(html).toContain('<img')
    expect(html).toContain('data:image/')
    /* The name is the next thing in the row; a reader that said "Dark Reader
       logo, Dark Reader" would be reading the decoration twice. */
    expect(html).toContain('alt=""')
  })

  it('draws a letter, not a broken picture, for a row with no mark', () => {
    const html = renderToStaticMarkup(<StoreLogo name="My own thing" id="mine" logo="" />)
    expect(html).not.toContain('<img')
    expect(html).toContain('>M<')
    expect(html).toContain('storelogo-monogram')
  })

  it('does the same for a key nothing answers to', () => {
    const html = renderToStaticMarkup(
      <StoreLogo name="Ghost" id="ghost" logo="a-mark-that-was-removed" />,
    )
    expect(html).not.toContain('<img')
    expect(html).toContain('storelogo-monogram')
  })

  it('gives a plate only to the marks that were measured needing one', () => {
    const plated = renderToStaticMarkup(<StoreLogo name="GitHub" id="github" logo="github" />)
    expect(plated).toContain('storelogo-plate')
    const bare = renderToStaticMarkup(<StoreLogo name="Notion" id="notion" logo="notion" />)
    expect(bare).not.toContain('storelogo-plate')
  })
})
