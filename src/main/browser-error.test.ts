import { describe, expect, it } from 'vitest'
import { ERR_ABORTED, isAbortCode, isLocal, loadFailureSentence } from './browser-error'

/**
 * These pin the thing the recording actually caught: a person looking at
 * `ERR_CONNECTION_REFUSED` where a sentence belonged. So the assertions are
 * mostly about what must NOT be on screen — a Chromium constant, a bare number
 * with no words around it — rather than about exact wording, which is allowed
 * to be edited without breaking a test.
 */

describe('loadFailureSentence', () => {
  it('says what to do about a dev server that is not running', () => {
    const sentence = loadFailureSentence(-102, 'ERR_CONNECTION_REFUSED', 'http://localhost:3000/')
    expect(sentence).toContain('localhost:3000')
    expect(sentence).toMatch(/start the server/i)
    // The whole point: none of Chromium's own vocabulary survives.
    expect(sentence).not.toContain('ERR_')
    expect(sentence).not.toContain('-102')
  })

  it('does not tell someone to start a server they do not own', () => {
    const sentence = loadFailureSentence(-102, 'ERR_CONNECTION_REFUSED', 'https://example.com/')
    expect(sentence).toContain('example.com')
    expect(sentence).not.toMatch(/start the server/i)
  })

  it('never leaves a hole where the host should be', () => {
    // A failure with no URL at all still has to read as a sentence.
    for (const url of ['', 'about:blank', 'not a url']) {
      expect(loadFailureSentence(-102, 'ERR_CONNECTION_REFUSED', url)).not.toContain('New tab')
      expect(loadFailureSentence(-102, 'ERR_CONNECTION_REFUSED', url)).toMatch(/\S/)
    }
  })

  it('writes every code it claims to know without any machine text', () => {
    const known = [-105, -137, -106, -109, -7, -118, -101, -100, -104, -324, -310, -21, -200, -201, -202, -501, -20, -27, -6]
    for (const code of known) {
      const sentence = loadFailureSentence(code, 'ERR_SOMETHING', 'http://localhost:5173/')
      expect(sentence, `code ${code} leaked a constant`).not.toContain('ERR_')
      expect(sentence, `code ${code} leaked its number`).not.toContain(String(code))
      expect(sentence.endsWith('.'), `code ${code} is not a sentence`).toBe(true)
    }
  })

  it('keeps the evidence for a code nobody anticipated', () => {
    // The rule is "never only machine output", not "never machine output": for
    // an unrecognised failure the constant and the number are the only things
    // that will let anyone diagnose it.
    const sentence = loadFailureSentence(-9999, 'ERR_INVENTED_TOMORROW', 'http://localhost:4321/')
    expect(sentence).toContain('localhost:4321')
    expect(sentence).toContain('ERR_INVENTED_TOMORROW')
    expect(sentence).toContain('-9999')
    expect(sentence).toMatch(/did not load/)
  })

  it('still reads as a sentence when Chromium supplies no description', () => {
    expect(loadFailureSentence(-9999, '   ', 'http://localhost:4321/')).toBe(
      'localhost:4321 did not load (-9999).',
    )
  })
})

describe('isAbortCode', () => {
  it('knows the one code that is not a failure', () => {
    // Typing a new address mid-load reports this. Showing an error for it is
    // how a browser ends up flashing a warning during ordinary use.
    expect(isAbortCode(ERR_ABORTED)).toBe(true)
    expect(ERR_ABORTED).toBe(-3)
    expect(isAbortCode(-102)).toBe(false)
    expect(isAbortCode(0)).toBe(false)
  })
})

describe('isLocal', () => {
  it('recognises every spelling of this machine', () => {
    expect(isLocal('http://localhost:3000/')).toBe(true)
    expect(isLocal('http://LOCALHOST:3000/')).toBe(true)
    expect(isLocal('http://127.0.0.1:8080/')).toBe(true)
    // The IPv6 loopback is the case that actually bit on Windows, where a node
    // dev server binds `::1` and nothing else — see `platform/ports.ts`.
    expect(isLocal('http://[::1]:5199/')).toBe(true)
  })

  it('does not mistake a hostname that merely contains one for it', () => {
    expect(isLocal('http://localhost.evil.example/')).toBe(false)
    expect(isLocal('https://example.com/')).toBe(false)
    expect(isLocal('')).toBe(false)
  })
})
