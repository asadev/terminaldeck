import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SavedLoginBar, type SavedLoginOffer } from './SavedLoginBar'
import { sameOrigin, type AccountsApi } from './accounts-bridge'

/**
 * The bar that offers a saved login on the page it belongs to.
 *
 * Rendered rather than reasoned about, for the reason `SavedLoginRow`'s tests
 * give: the rule that matters here is a rule about *markup* — that nothing on
 * this bar is or could become a password — and a rule about markup has to be
 * checked by producing markup.
 */

const offer = (over: Partial<SavedLoginOffer> = {}): SavedLoginOffer => ({
  id: 'view-1',
  origin: 'https://example.com',
  usernames: ['ada'],
  filled: false,
  note: '',
  ...over,
})

const api: AccountsApi = { browserPasswordFill: () => Promise.resolve(true) }

function markup(props: SavedLoginOffer, host: AccountsApi = api): string {
  return renderToStaticMarkup(
    <SavedLoginBar offer={props} api={host} onDone={() => undefined} onDismiss={() => undefined} />,
  )
}

describe('what is on the bar', () => {
  it('names the site and the account, and never a password', () => {
    const html = markup(offer({ usernames: ['ada', 'grace'] }))
    expect(html).toContain('example.com')
    expect(html).toContain('ada')
    expect(html).toContain('grace')
    // There is no field on `SavedLoginOffer` that could carry one, which is the
    // point — this asserts the consequence rather than the shape.
    expect(html).not.toMatch(/hunter2|password"\s*value/i)
  })

  it('gives every saved account its own button rather than burying the second one', () => {
    /*
     * Two accounts on one site is the case this bar exists for on pages no
     * agent has ever touched. Before it, using the second one meant Settings →
     * Browser → Saved passwords → Copy → click the field → paste. A chevron
     * would put it back one press out of sight.
     */
    const html = markup(offer({ usernames: ['ada', 'grace'] }))
    expect(html.match(/<button/g) ?? []).toHaveLength(3) // two accounts, plus "Not now"
  })

  it('says what happened when the fill was withheld, in the main process’s own words', () => {
    const note = 'An agent opened this page, so the saved login was not filled in automatically.'
    const html = markup(offer({ note }))
    expect(html).toContain('Saved login for this site')
    expect(html).toContain(note)
  })

  it('reads as a report rather than an offer once the login went in', () => {
    // Still drawn, because this is the only place a *wrong* guess is visible
    // and switchable — the store fills the most recently saved account.
    const html = markup(offer({ filled: true, usernames: ['ada', 'grace'] }))
    expect(html).toContain('Signed in with a saved login')
  })
})

describe('an older preload that cannot fill', () => {
  it('shows the accounts disabled rather than offering a press that does nothing', () => {
    // A control that appears to work and does not is worse than no control at
    // all, and it is the defect this whole round is about.
    const html = markup(offer(), {})
    expect(html).toContain('disabled')
  })
})

describe('an offer only stands while the page it is about is on screen', () => {
  it('matches an address to the origin it was offered for, exactly', () => {
    // The same exact-origin rule the store itself runs on: `app.example.com`
    // is a different site from `example.com`, and a login saved for one is
    // never offered on the other. `browser-passwords.ts` argues the trade.
    expect(sameOrigin('https://example.com', 'https://example.com/sign-in')).toBe(true)
    expect(sameOrigin('https://example.com', 'https://app.example.com/sign-in')).toBe(false)
    expect(sameOrigin('https://example.com', 'http://example.com/sign-in')).toBe(false)
    expect(sameOrigin('http://localhost:3000', 'http://localhost:3000/login')).toBe(true)
    expect(sameOrigin('http://localhost:3000', 'http://localhost:3001/login')).toBe(false)
  })

  it('matches nothing when there is no address, or it will not parse', () => {
    expect(sameOrigin('https://example.com', '')).toBe(false)
    expect(sameOrigin('https://example.com', 'not a url')).toBe(false)
    expect(sameOrigin('', 'https://example.com/')).toBe(false)
  })
})
