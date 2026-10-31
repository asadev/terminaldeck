import { createRef } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { FindBar } from './FindBar'

/**
 * The bar's accessible structure, by static markup — the same contract the
 * workspace's own render tests hold, with the live behaviour left to the pure
 * modules (`find-bridge.test.ts`) and the main-process tests
 * (`browser-view.find.test.ts`), because this suite runs with no DOM.
 */

const noop = () => undefined

function render(query: string, count: { ordinal: number; matches: number } | null): string {
  return renderToStaticMarkup(
    <FindBar
      query={query}
      count={count}
      inputRef={createRef<HTMLInputElement>()}
      onQuery={noop}
      onStep={noop}
      onClose={noop}
    />,
  )
}

describe('the find bar', () => {
  it('is the terminal bar, control for control', () => {
    const html = render('', null)
    expect(html).toContain('role="search"')
    expect(html).toContain('Find in page')
    expect(html).toContain('aria-label="Previous match"')
    expect(html).toContain('aria-label="Next match"')
    expect(html).toContain('aria-label="Close find"')
  })

  it('prints Chromium&#x27;s count and never its own arithmetic', () => {
    expect(render('needle', { ordinal: 2, matches: 17 })).toContain('2/17')
  })

  it('says No matches rather than 0/0', () => {
    const html = render('needle', { ordinal: 0, matches: 0 })
    expect(html).toContain('No matches')
    expect(html).not.toContain('0/0')
  })

  it('says nothing at all before there is a query to count', () => {
    expect(render('', { ordinal: 2, matches: 17 })).not.toContain('bw-find-count')
  })
})
