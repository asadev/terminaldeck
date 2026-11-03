import { describe, expect, it } from 'vitest'
import { driveNowOf, shortUrl } from './browser-trace'

/**
 * The drive's status, narrowed, and the address it is on.
 *
 * The action-trace half of this file went with the panel that drew it on
 * 2026-08-21 — the rail's column is the connected session's conversation now,
 * not a log of tool calls — and its tests went with it rather than being kept
 * green against a reader nothing has. What is left is the pair the banner and
 * the rail both still depend on, and the assertions worth having are the ones
 * about **not** claiming something: a status that did not parse is nothing, not
 * an idle drive, and a URL keeps its query string out of a panel somebody may
 * be recording.
 */

describe('the live line', () => {
  it('reads the drive’s own state and its present-tense step', () => {
    const now = driveNowOf({ state: 'agent', tabId: 't1', step: 'clicking “Sign in”', url: 'https://x.test' })
    expect(now).toEqual({ state: 'agent', tabId: 't1', step: 'clicking “Sign in”', url: 'https://x.test' })
  })

  it('carries the tab, because that is which errand this is', () => {
    /*
     * The drive has exactly one tab by design — the tools take no `tabId`
     * anywhere and calling open again navigates the same one — so it is the
     * closest thing to an identity a scrape has, and it is what "put this panel
     * away for the page it is on" is keyed on. A new tab is a new errand and
     * gets the panel back, with nothing having to expire.
     */
    expect(driveNowOf({ state: 'agent' })?.tabId).toBe('')
    expect(driveNowOf({ state: 'agent', tabId: 'tab-9' })?.tabId).toBe('tab-9')
  })

  it('refuses a state this build does not know', () => {
    expect(driveNowOf({ state: 'driving' })).toBeNull()
    expect(driveNowOf(null)).toBeNull()
  })
})

describe('the address, shortened for a narrow column', () => {
  it('drops the scheme and the www, and keeps the path', () => {
    expect(shortUrl('https://www.example.com/a/b')).toBe('example.com/a/b')
    expect(shortUrl('https://example.com/')).toBe('example.com')
  })

  it('drops the query string, because that is where a token ends up', () => {
    // This panel is on screen while somebody may be recording it.
    expect(shortUrl('https://example.com/callback?code=SECRET&state=x')).toBe('example.com/callback')
  })

  it('returns something unparseable untouched rather than blanking it', () => {
    // An unparseable string is still the only thing anybody can be told.
    expect(shortUrl('not a url')).toBe('not a url')
    expect(shortUrl('')).toBe('')
  })
})
