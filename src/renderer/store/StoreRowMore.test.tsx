import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ExtensionRow } from '../browser/ExtensionRow'
import type { StoreExtension } from '../browser/extensions-bridge'
import { McpStoreRow } from '../components/McpStoreRow'
import type { McpStoreRow as Row } from '../components/mcp-store-bridge'
import { StoreDetail } from './StoreDetail'
import { StoreRowMore, StoreRowPlaceIs } from './StoreRowMore'

/**
 * The two sizes a store row has, and the rule that survived giving it a second
 * one.
 *
 * ## What is being pinned, and why it is pinned here
 *
 * The shipped shelf printed licence, project URL, download URL, byte count, a
 * sixty-four character hash and a paragraph of measurement under every row, and
 * fit **two rows on a 1440px screen**. It did that for a reason that was
 * correct: `store/StoreDetail.tsx` draws the *same component* the shelf does, so
 * there was nowhere else for a fact to live, and `browser/StorePanel.test.tsx`
 * pins outright that *a download row shows URL and fingerprint on this screen,
 * not in a detail view*.
 *
 * Folding is the one way to make the shelf readable that does not break that
 * rule, and it only works if the fold is genuinely on the row. So these are the
 * two halves of the same assertion:
 *
 *  - **Nothing left the shelf.** The URL and the digest are in a shelf row's
 *    markup, unconditionally, whether anything has been pressed or not.
 *  - **The shelf is not the page.** On a shelf they are behind a `summary` that
 *    names them; inside `StoreDetail` there is no `summary` at all.
 *
 * A test is the right place for the second one in particular, because the way
 * it breaks is silent: somebody adds a `<div>` between the frame and the row,
 * the context still resolves, and nothing goes wrong until the day somebody
 * renders a row outside the frame and the page quietly folds its own detail
 * away.
 */

function extension(over: Partial<StoreExtension> = {}): StoreExtension {
  return {
    id: 'dark-reader',
    name: 'Dark Reader',
    summary: 'Turns every site dark.',
    homepage: 'https://github.com/darkreader/darkreader',
    licence: 'MIT',
    version: '4.9.129',
    category: 'appearance',
    tags: [],
    needs: [],
    cost: 'free',
    costNote: '',
    works: 'works',
    measured: 'Watched working: a white page came back with background rgb(24, 26, 27).',
    logo: '',
    url: 'https://example.com/darkreader.zip',
    sha256: 'a'.repeat(64),
    bytes: 831_273,
    state: 'available',
    installedVersion: '',
    installedAt: 0,
    enabled: false,
    reach: ['*://*/*'],
    mayAsk: [],
    everywhere: true,
    missing: [],
    provides: [],
    inert: [],
    rulesetsSwitchedOn: 0,
    popup: '',
    optionsPage: '',
    sideloaded: false,
    origin: '',
    crxId: '',
    staticRulesets: false,
    message: '',
    ...over,
  }
}

const noop = (): void => {}

const row = (over: Partial<StoreExtension> = {}) => (
  <ExtensionRow
    extension={extension(over)}
    busy={false}
    said=""
    canOpenPopup={false}
    canOpenOptions={false}
    onAct={noop}
    onEnable={noop}
    onOpenPopup={noop}
    onOpenOptions={noop}
  />
)

const SERVER: Row = {
  id: 'tavily',
  name: 'tavily',
  summary: 'Web search and page extraction.',
  category: 'web',
  tags: [],
  homepage: 'https://github.com/tavily-ai/tavily-mcp',
  registry: 'https://www.npmjs.com/package/tavily-mcp',
  licence: 'MIT',
  version: '0.2.22',
  runtime: 'node',
  runtimeBinary: 'npx',
  origin: 'vendor',
  cost: 'free',
  costNote: '',
  command: 'npx -y tavily-mcp',
  inputs: [],
  state: 'available',
  scope: '',
  custom: false,
  transport: 'stdio',
  envKeys: [],
  runsWords: '',
  runtimeMissing: false,
  taken: '',
  blocked: '',
  caveat: '',
  logo: '',
}

const server = (
  <McpStoreRow
    row={SERVER}
    busy={false}
    values={{}}
    said=""
    arming={false}
    asking={false}
    onValue={noop}
    onAct={noop}
    onArm={noop}
    onAsk={noop}
  />
)

describe('a row on a shelf', () => {
  it('still carries its download and its fingerprint, folded', () => {
    /*
     * The whole reason the shelf was allowed to fold anything. `StorePanel`'s
     * own suite says the URL and the digest are on *this* screen and not behind
     * a navigation; a `details` keeps that literally true — both are in the
     * markup of a shelf row that nobody has touched — while costing the row the
     * six lines they used to occupy.
     */
    const html = renderToStaticMarkup(row())
    expect(html).toContain('https://example.com/darkreader.zip')
    expect(html).toContain('a'.repeat(64))
    expect(html).toContain('831,273 bytes, exactly')
    expect(html).toContain('Watched working')
  })

  it('names what is behind the fold rather than saying More', () => {
    // Somebody auditing a download has to know from the shelf that the
    // fingerprint is one press behind this line. A summary that will not say
    // what it holds makes them open twenty of them to find out.
    const html = renderToStaticMarkup(row())
    expect(html).toContain('<summary class="store-more-summary">')
    expect(html).toContain('checksum')
  })

  it('keeps what somebody is agreeing to out of the fold', () => {
    /*
     * Three things never fold, and each for its own reason. **Reaches** is the
     * whole of the permission decision. The **price sentence** is the one thing
     * that is useless once Install has been pressed. Anything **red** is this
     * app saying something on this machine is not what the row above it looks
     * like.
     */
    const html = renderToStaticMarkup(
      row({ cost: 'paid', costNote: 'No free plan at all.', state: 'damaged', message: 'The file on disk is not the one that was installed.' }),
    )
    const fold = html.indexOf('store-more-summary')
    expect(html.indexOf('Reaches')).toBeLessThan(fold)
    expect(html.indexOf('No free plan at all.')).toBeLessThan(fold)
    expect(html.indexOf('The file on disk is not the one that was installed.')).toBeGreaterThan(fold)
    expect(html).toContain('bw-error')
  })

  it('folds the MCP row the same way, and keeps its fields out of the fold', () => {
    /*
     * The servers half had the same shape — Source, Package, How it runs, Needs
     * and Command, five definition rows deep, before the summary had finished.
     * What may not move is the field somebody types a token into: hiding a
     * required key one click away is how a store ends up with an Install that
     * fails.
     */
    const html = renderToStaticMarkup(server)
    expect(html).toContain('store-more-summary')
    const fold = html.indexOf('store-more-summary')
    expect(html.indexOf('Runs with')).toBeLessThan(fold)
    expect(html.indexOf('npx -y tavily-mcp')).toBeGreaterThan(fold)
    expect(html.indexOf('https://www.npmjs.com/package/tavily-mcp')).toBeGreaterThan(fold)
  })
})

describe('the same row, read on its own', () => {
  it('has no fold in it at all', () => {
    /*
     * A disclosure on the surface that exists to disclose is a control whose
     * only use is to hide the thing you navigated to. `StoreDetail` is what says
     * so, and it says it to whatever it was handed rather than to a particular
     * department — which is why this asserts through the real frame.
     */
    const html = renderToStaticMarkup(
      <StoreDetail backTo="How pages look" onBack={noop}>
        <ul className="bw-store-list">{row()}</ul>
      </StoreDetail>,
    )
    expect(html).not.toContain('store-more-summary')
    expect(html).not.toContain('<details')
    expect(html).toContain('a'.repeat(64))
    expect(html).toContain('Watched working')
  })

  it('unfolds a server the same way, through the same frame', () => {
    const html = renderToStaticMarkup(
      <StoreDetail backTo="Searching and reading the web" onBack={noop}>
        <ul className="mcp-store-list">{server}</ul>
      </StoreDetail>,
    )
    expect(html).not.toContain('store-more-summary')
    expect(html).toContain('npx -y tavily-mcp')
  })
})

describe('the place a row is drawn in', () => {
  it('is a shelf wherever nobody has said otherwise', () => {
    /*
     * The safe default, and it is safe in one direction only: a folded row has
     * a way out of the fold, and a row that unfolded on a shelf because nothing
     * told it where it was would be the shipped defect back again, silently.
     */
    const html = renderToStaticMarkup(
      <StoreRowMore label="Licence and checksum">
        <p>the facts</p>
      </StoreRowMore>,
    )
    expect(html).toContain('<details')
    expect(html).toContain('the facts')
  })

  it('does not leak out of the frame that set it', () => {
    /*
     * Two of them in one pass, one inside the frame and one after it. Rendering
     * both together is what proves the place is scoped rather than a module-level
     * flag — the shape this would most plausibly have been written as, and one
     * whose failure is a shelf that unfolds after somebody has looked at a
     * detail page.
     */
    const html = renderToStaticMarkup(
      <>
        <StoreRowPlaceIs place="page">
          <StoreRowMore label="Inside">
            <p>on the page</p>
          </StoreRowMore>
        </StoreRowPlaceIs>
        <StoreRowMore label="Outside">
          <p>on the shelf</p>
        </StoreRowMore>
      </>,
    )
    // One `details`, and it is the second one. The first drew its facts with no
    // summary at all, so its label never reached the markup.
    expect(html.split('<details').length - 1).toBe(1)
    expect(html).not.toContain('Inside')
    expect(html).toContain('>Outside</summary>')
    expect(html).toContain('on the page')
    expect(html).toContain('on the shelf')
  })
})
