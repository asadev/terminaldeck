import { describe, expect, it } from 'vitest'
import { cleanUserAgent, namesTheShell } from './browser-user-agent'

/**
 * The string Electron 41.10.5 actually produced on this machine on 2026-08-18,
 * read out of `app.userAgentFallback` in a real run rather than typed from
 * memory. Every assertion below is against this, because a hand-written sample
 * would drift from the thing the app really sends and the whole point of this
 * module is what a remote server sees.
 */
const MEASURED =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.7680.216 Electron/41.10.5 Safari/537.36'

describe('the embedded browser does not announce its shell', () => {
  it('removes the token Google routes its restricted sign-in flow on', () => {
    // Measured: the same authorisation URL answers `flowName=GeneralOAuthLite`
    // with this token present and `GeneralOAuthFlow` without it. That is the
    // entire reason this function exists, so it is asserted directly rather
    // than through `namesTheShell`.
    expect(cleanUserAgent(MEASURED)).not.toContain('Electron/')
  })

  it('leaves every true fact about the engine in place', () => {
    const cleaned = cleanUserAgent(MEASURED)
    // The platform, the engine and the Chrome version are not disguised. A site
    // serving different code to old Chrome is entitled to know which Chrome
    // this is, and a spoofed version produces rendering bugs nobody can
    // reproduce.
    expect(cleaned).toContain('Macintosh; Intel Mac OS X 10_15_7')
    expect(cleaned).toContain('AppleWebKit/537.36')
    expect(cleaned).toContain('Chrome/146.0.7680.216')
    expect(cleaned).toContain('Safari/537.36')
  })

  it('leaves no double space where the token was', () => {
    // A stray double space is itself a tell: it makes the string differ from
    // Chrome's on a byte comparison, which is the class of signal this is
    // removing in the first place.
    expect(cleanUserAgent(MEASURED)).not.toMatch(/\s{2}/)
  })

  it('is idempotent, so applying it at every session creation is safe', () => {
    const once = cleanUserAgent(MEASURED)
    expect(cleanUserAgent(once)).toBe(once)
  })

  it('also removes the product name, which Chromium adds when it is set', () => {
    const withProduct = MEASURED.replace('Electron/41.10.5', 'terminaldeck/0.3.0 Electron/41.10.5')
    expect(namesTheShell(cleanUserAgent(withProduct))).toBe(false)
  })

  it('never returns nothing, however odd the input', () => {
    // A user agent of the empty string is not "no user agent" — it is a request
    // with no `User-Agent` header at all, which a great many servers answer
    // with 403. Falling back to the original is always better than that.
    expect(cleanUserAgent('Electron/41.10.5')).toBe('Electron/41.10.5')
  })

  it('recognises the shell in a string that still has it', () => {
    expect(namesTheShell(MEASURED)).toBe(true)
    expect(namesTheShell(cleanUserAgent(MEASURED))).toBe(false)
  })
})
