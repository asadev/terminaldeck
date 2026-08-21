import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { hostOf, WorkersPanel } from './WorkersPanel'
import { resolveWorkersApi } from './workers-bridge'

/**
 * The panel that holds the one control in this app which copies a login.
 *
 * There is no DOM environment in this project's test setup and `Modal` renders
 * through a portal, so an open panel cannot be rendered here. What can be
 * checked is the part that decides *whether there is a control at all* — which
 * is the half this feature turns on — plus the promises the markup makes, held
 * as source in the way `ProfileMenu.test.tsx` holds its own.
 */
const source = readFileSync(join(__dirname, 'WorkersPanel.tsx'), 'utf8')
/** Comments stripped: what a person sees, not what the file argues. */
const onScreen = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

describe('a build that cannot do this', () => {
  it('draws nothing at all rather than a panel that cannot act', () => {
    /*
     * `workersAvailable` is all-or-nothing, and this is the consequence: an
     * older preload gets no panel instead of an empty one with rows that do
     * nothing. The row that opens this is hidden by the same check in
     * `BrowserWorkspace`, so there is no way to reach a dead screen.
     */
    const markup = renderToStaticMarkup(
      <WorkersPanel
        open
        api={resolveWorkersApi({})}
        viewId="v1"
        pageUrl="https://shop.example.com/"
        onOpenInWorker={() => undefined}
        onClose={() => undefined}
      />,
    )
    expect(markup).toBe('')
  })
})

describe('the site a lift would be about', () => {
  it('is the page’s own host, and nothing at all where there is no page', () => {
    /*
     * The scope is read from the address in front of the person — there is no
     * field to type a host into, here or in the main process. A free-text one
     * would let a lift be aimed at a site nobody was looking at.
     */
    expect(hostOf('https://shop.example.com/account')).toBe('shop.example.com')
    expect(hostOf('about:blank')).toBe('')
    expect(hostOf('file:///etc/passwd')).toBe('')
    expect(hostOf('')).toBe('')
  })
})

describe('what the panel promises', () => {
  it('offers the lift only for a real page, and explains rather than greying out', () => {
    // A greyed button here would be a promise about a page that is not open.
    expect(onScreen).toContain('const canLift = liftAvailable(api) && viewId !== \'\' && host !== \'\'')
    expect(onScreen).toContain('Take the session from {host}')
  })

  it('never says a queued key is signed in, and says so when it cannot queue at all', () => {
    /*
     * The two honest statements this screen exists to make. A build that cannot
     * seed storage copies the cookies and nothing else, and a site that keeps
     * its token in `localStorage` will simply not be signed in there — an hour
     * lost to a worker that looks identical to one that worked.
     */
    expect(onScreen).toContain('canSeedStorage')
    expect(onScreen).toContain('will not be signed in there')
    /*
     * The row's own words come from `workerLine`, which is pinned in
     * `workers-bridge.test.ts` never to say "signed in" for keys that are still
     * waiting. The panel must print that sentence rather than compose a second
     * one of its own, because two spellings of one claim is how one of them
     * comes to be the optimistic version.
     */
    expect(onScreen).toContain('{workerLine(worker)}')
  })

  it('says the pool only grows, on the button that grows it', () => {
    // Whatever a site decided about a worker is bound to that jar and cannot be
    // earned again by making a new one, so nothing on this screen deletes.
    expect(onScreen).toContain('it only ever adds')
    expect(onScreen).toContain('Nothing here removes one')
    expect(onScreen).toContain('Take out of the pool')
    expect(onScreen).not.toContain('Delete')
  })

  it('tells the truth about driving several at once instead of implying it is automatic', () => {
    // One window shows one page at a time, so parallel driving is one worker
    // page per window. Stating it is the difference between a feature and a
    // control that looks like it works.
    expect(onScreen).toContain('one worker page in each browser window')
  })

  it('opens nothing off-screen', () => {
    // Item 11. The browser is a visible window and stays one; the only opening
    // this panel does is a tab in the strip the person is looking at.
    expect(onScreen).not.toContain('window.open')
    expect(onScreen).not.toMatch(/headless|offscreen/i)
    expect(onScreen).not.toContain('visible: false')
  })
})
