import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { PageScope } from './PageScope'
import { thisMachine } from '../platform'

/**
 * The line that answers *"maybe I'm not the actual one or something."*
 *
 * Rendered to static markup — there is no DOM in this project's test setup —
 * which is all this needs: the whole component is what it says and what it
 * leaves out.
 */
describe('PageScope', () => {
  it('names the folder the page read', () => {
    const html = renderToStaticMarkup(<PageScope path="/Users/apple/Templates" />)
    expect(html).toContain('/Users/apple/Templates')
    // And in the tooltip too, because the line truncates on a narrow window and
    // the head of a path is the half it drops.
    expect(html).toContain('title="/Users/apple/Templates"')
  })

  it('names the machine, and by default that is this one', () => {
    const html = renderToStaticMarkup(<PageScope path="/p" />)
    // The noun itself comes from `platform.ts` and is whatever the machine
    // running this test is — "this Mac" here, "this PC" on the Windows runner.
    // Asserting one of them would be a test that fails on the other platform,
    // which is the exact class of defect the Windows job exists to catch.
    expect(html).toContain(`on ${thisMachine()}`)
    expect(html).toContain('on this ')
  })

  it('names another machine when the page is reporting on one', () => {
    const html = renderToStaticMarkup(<PageScope path="/home/imza/AAAA" machine="DESKTOP-DDGMNCV" />)
    expect(html).toContain('on DESKTOP-DDGMNCV')
    expect(html).not.toContain('on this ')
  })

  it('carries the one extra fact a page has, when it has one', () => {
    const html = renderToStaticMarkup(<PageScope path="/p" machine="Office PC" detail="through Session 1" />)
    expect(html).toContain('through Session 1')
  })

  /**
   * A page with no folder still says which machine it is about — that is the
   * Integrations case, where the subject is a machine rather than a project.
   */
  it('stands on the machine alone when there is no folder', () => {
    const html = renderToStaticMarkup(<PageScope path={null} machine="DESKTOP-DDGMNCV" />)
    expect(html).toContain('on DESKTOP-DDGMNCV')
    expect(html).not.toContain('page-scope-path')
  })

  /**
   * And draws nothing at all when it has been given nothing. A caption with no
   * subject is furniture, and it would break the rule that centres a page whose
   * whole content is an empty state.
   */
  it('draws nothing when there is no subject to name', () => {
    expect(renderToStaticMarkup(<PageScope path={null} />)).toBe('')
  })
})
