import { describe, expect, it } from 'vitest'
import { describeUpdateError } from './update-error'

/**
 * The message a real user's Windows install put on screen on 2026-08-20, kept
 * verbatim because every fault in it is a separate thing this module has to
 * strip: the wrapper sentences, the Chromium code, four `node_modules` stack
 * frames carrying a stranger's home directory, and the whole Atom feed with the
 * release notes escaped into it twice.
 */
const REAL_WINDOWS_FAILURE = [
  'Cannot parse releases feed: Error: Unable to find latest version on GitHub',
  '(https://github.com/asadev/terminaldeck/releases/latest), please ensure a production',
  'release exists: Error: net::ERR_NETWORK_CHANGED at SimpleURLLoaderWrapper.<anonymous>',
  '(node:electron/js2c/browser_init:2:135010) at SimpleURLLoaderWrapper.emit',
  '(node:events:509:28) at newError (C:\\Users\\Asus\\AppData\\Local\\Programs\\Terminal',
  'Deck\\resources\\app.asar\\node_modules\\builder-util-runtime\\out\\error.js:5:19)',
  'at GitHubProvider.getLatestTagName (C:\\Users\\Asus\\AppData\\Local\\Programs\\Terminal',
  'Deck\\resources\\app.asar\\node_modules\\electron-updater\\out\\providers\\GitHubProvider.js:173:55)',
  'XML: <?xml version="1.0" encoding="UTF-8"?> <feed xmlns="http://www.w3.org/2005/Atom">',
  '<title>Release notes from terminaldeck</title> <entry> <content type="html">',
  '&lt;h3&gt;Install&lt;/h3&gt; &lt;p&gt;macOS 12 or later, Apple silicon: open',
].join(' ')

describe('describeUpdateError', () => {
  it('reduces the real Windows failure to one sentence', () => {
    const failure = describeUpdateError(new Error(REAL_WINDOWS_FAILURE))

    expect(failure.text).toBe('No connection to the update server.')
    expect(failure.transient).toBe(true)
  })

  it('never lets a feed, a stack frame or a file path reach the panel', () => {
    const { text } = describeUpdateError(new Error(REAL_WINDOWS_FAILURE))

    expect(text).not.toContain('<')
    expect(text).not.toContain('node_modules')
    expect(text).not.toContain('C:\\')
    expect(text).not.toMatch(/\.js:\d+/)
    expect(text.length).toBeLessThanOrEqual(120)
  })

  it('treats the codes a moving network produces as worth retrying', () => {
    for (const code of [
      'net::ERR_NETWORK_CHANGED',
      'net::ERR_INTERNET_DISCONNECTED',
      'net::ERR_NAME_NOT_RESOLVED',
      'net::ERR_CONNECTION_RESET',
      'getaddrinfo ENOTFOUND github.com',
      'connect ETIMEDOUT 140.82.121.4:443',
    ]) {
      expect(describeUpdateError(new Error(code)), code).toEqual({
        text: 'No connection to the update server.',
        transient: true,
      })
    }
  })

  it('does not call a refused connection or a bad certificate transient', () => {
    // Retrying either of these just fails again more slowly.
    expect(describeUpdateError(new Error('net::ERR_CONNECTION_REFUSED')).transient).toBe(false)
    expect(describeUpdateError(new Error('net::ERR_CERT_DATE_INVALID')).transient).toBe(false)
  })

  it('names the causes a person can actually act on', () => {
    expect(describeUpdateError(new Error('HTTP 429: API rate limit exceeded')).text).toContain('rate-limiting')
    expect(describeUpdateError(new Error('ENOSPC: no space left on device')).text).toContain('disk space')
    expect(describeUpdateError(new Error('EACCES: permission denied')).text).toContain('could not write')
  })

  it('keeps a short message that is already a sentence', () => {
    expect(describeUpdateError(new Error('The release has no macOS asset.'))).toEqual({
      text: 'The release has no macOS asset.',
      transient: false,
    })
  })

  it('truncates a long message rather than passing it through', () => {
    const { text } = describeUpdateError(new Error('x'.repeat(400)))

    expect(text.length).toBeLessThanOrEqual(120)
    expect(text.endsWith('…')).toBe(true)
  })

  it('always has something to say', () => {
    for (const thrown of [null, undefined, '', {}, new Error(''), 0]) {
      const { text } = describeUpdateError(thrown)
      expect(text.trim(), JSON.stringify(thrown)).not.toBe('')
    }
  })

  it('reads a message off a thrown object that is not an Error', () => {
    expect(describeUpdateError({ message: 'net::ERR_NETWORK_CHANGED' }).transient).toBe(true)
  })
})
