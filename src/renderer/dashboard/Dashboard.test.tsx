import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { Dashboard } from './Dashboard'

/**
 * Overview, rendered.
 *
 * This suite exists because of the failure this repository has been bitten by
 * twice: a page that typechecks, passes its unit tests and then paints nothing,
 * because the defect was a contract mismatch or a throw at mount rather than a
 * type error. Static markup catches exactly that class, and it is the only
 * check available without a DOM environment.
 *
 * `bridge` is supplied so the layout never touches the preload — the point here
 * is the page's shape, not its persistence, which `dashboard-store.test.ts` and
 * `layout.test.ts` already own.
 */

const PROJECT = '/Users/apple/Projects/terminaldeck'

const bridge = {
  loadDashboard: () => Promise.resolve(null),
  saveDashboard: () => Promise.resolve(),
}

function render(): string {
  return renderToStaticMarkup(<Dashboard projectPath={PROJECT} bridge={bridge} />)
}

describe('the Overview page', () => {
  it('renders without a preload, a store or a features provider', () => {
    // All three are absent here and absent in `.harness/`. A page that needs
    // them to paint is a page that is blank the first time anything goes wrong
    // at startup.
    expect(() => render()).not.toThrow()
  })

  it('leads with the session board, not with the widget grid', () => {
    const markup = render()
    // The board's own heading region is present even with nothing running —
    // that empty state is the page's empty state now.
    expect(markup).toContain('Nothing is running')
    expect(markup.indexOf('Nothing is running')).toBeLessThan(markup.indexOf('This project'))
  })

  it('keeps the widget section under a heading that says whose widgets they are', () => {
    // The bar used to float above the whole page. With a session board above
    // it, an unlabelled row of widget controls reads as chrome for the board.
    expect(render()).toContain('This project')
  })
})
