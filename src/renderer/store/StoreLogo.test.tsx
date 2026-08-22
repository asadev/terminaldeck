import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { hueOf, monogram, StoreLogo } from './StoreLogo'
import { StoreRowName } from './StoreRowName'

/**
 * The tile every store row wears where its logo goes.
 *
 * Two things are worth pinning and they are the two that make a monogram
 * honest rather than a placeholder: it is **derived from the name**, so it never
 * claims to be somebody's brand, and it is **stable**, because the whole value
 * of a colour is recognising a row you have seen before. A hue that moved
 * between launches would be worse than no hue at all.
 */

describe('the monogram', () => {
  it('takes two letters from a two-word name and one from a single word', () => {
    // `D` beside `Decentraleyes` is a worse mark than `DR`; `se` for
    // `sequential-thinking` reads as a typo.
    expect(monogram('Dark Reader')).toBe('DR')
    expect(monogram('sequential-thinking')).toBe('ST')
    expect(monogram('filesystem')).toBe('F')
  })

  it('skips what is not a letter rather than printing it', () => {
    // `1Password` would otherwise wear a `1`, which is not a monogram of
    // anything.
    expect(monogram('1Password')).toBe('P')
    expect(monogram('@modelcontextprotocol/server-postgres')).toBe('MS')
  })

  it('always has something to draw', () => {
    // A blank tile in a grid of forty reads as a row that failed to load.
    expect(monogram('')).toBe('·')
    expect(monogram('---')).toBe('·')
  })
})

describe('the hue', () => {
  it('is the same every time for the same name', () => {
    expect(hueOf('uBlock Origin')).toBe(hueOf('uBlock Origin'))
  })

  it('is a degree on the wheel, whatever it is given', () => {
    for (const name of ['', 'a', 'Dark Reader', 'github', '@scope/pkg']) {
      const hue = hueOf(name)
      expect(hue).toBeGreaterThanOrEqual(0)
      expect(hue).toBeLessThan(360)
    }
  })

  it('separates neighbours in the same shelf', () => {
    // Not a guarantee the hash can make in general — this is the pair that
    // actually sit next to each other under Blocking ads and trackers.
    expect(hueOf('uBlock Origin')).not.toBe(hueOf('AdGuard'))
  })
})

describe('the name beside it', () => {
  it('is pressable only when there is somewhere to go', () => {
    /*
     * The whole absent-not-disabled rule, at row scale. Both departments render
     * on their own in tests and in the harness, where there is no page to be
     * sent to, and a name that highlighted under the pointer and did nothing is
     * the single defect this window's reviews keep returning to.
     */
    const dead = renderToStaticMarkup(<StoreRowName name="Dark Reader" className="bw-store-name" />)
    expect(dead).not.toContain('<button')

    const live = renderToStaticMarkup(
      <StoreRowName name="Dark Reader" className="bw-store-name" onOpen={() => {}} />,
    )
    expect(live).toContain('<button')
    expect(live).toContain('Open Dark Reader on its own')
  })

  it('keeps the department’s own class on the name', () => {
    // Each department types its own names — one is a mono command, one is a
    // product name — and the shared wrapper must not flatten that.
    const markup = renderToStaticMarkup(<StoreRowName name="github" className="mcp-store-name" />)
    expect(markup).toContain('class="mcp-store-name"')
  })

  it('draws artwork in place of the monogram when a catalogue has some', () => {
    const markup = renderToStaticMarkup(
      <StoreLogo name="Dark Reader" art={<svg data-art="yes" />} />,
    )
    expect(markup).toContain('data-art="yes"')
    expect(markup).not.toContain('store-logo-monogram')
  })
})
