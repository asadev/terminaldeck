import { describe, expect, it } from 'vitest'
import { cleanUserAgent, machineBrowserUserAgent, namesTheShell } from './browser-user-agent'

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

/**
 * The machine's *headless* Chromium is a separate browser from the desktop's
 * Electron views, and it announced itself `HeadlessChrome` — the loudest tell
 * there is for Google's *"this browser or app may not be secure"* refusal, and
 * one nothing in `cleanUserAgent` above ever reached. This is what it presents
 * instead: the same engine's true user agent, minus the one word that names how
 * it was started rather than what it is.
 *
 * The exact strings are pinned because the whole point is what a remote server
 * sees, and because modern Chrome's user agent is frozen — the OS token and the
 * `.0.0.0` version are fixed values a real Chrome on each platform reports, so a
 * drift here would be a drift from Chrome itself, not a harmless reformat.
 */
describe('the machine’s headless browser presents as an ordinary Chromium', () => {
  it('drops the Headless word and reports the true engine for this Mac', () => {
    const ua = machineBrowserUserAgent('darwin', '146.0.7680.165')
    expect(ua).not.toContain('Headless')
    expect(namesTheShell(ua)).toBe(false)
    // Byte for byte what a real Chrome 146 on this Mac sends.
    expect(ua).toBe(
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36',
    )
  })

  it('uses each platform’s own frozen OS token', () => {
    expect(machineBrowserUserAgent('win32', '146.0.7680.165')).toContain('Windows NT 10.0; Win64; x64')
    expect(machineBrowserUserAgent('linux', '146.0.7680.165')).toContain('X11; Linux x86_64')
  })

  it('carries only the major version, because the reduced user agent carries only the major', () => {
    expect(machineBrowserUserAgent('darwin', '147.0.1.2')).toContain('Chrome/147.0.0.0')
  })

  it('returns nothing for a version it cannot read, so a side-loaded binary keeps its own', () => {
    // `installChromium` reports `'sideloaded'` for a `TERMINALDECK_CHROMIUM_PATH`
    // override; guessing a major for it would be the disguise this file refuses,
    // and the launch adds no `--user-agent` when this is empty.
    expect(machineBrowserUserAgent('darwin', 'sideloaded')).toBe('')
    expect(machineBrowserUserAgent('darwin', '')).toBe('')
  })
})
