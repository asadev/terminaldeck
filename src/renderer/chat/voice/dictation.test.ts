import { describe, expect, it } from 'vitest'
import { appendSpoken, isMac, speechSupport } from './dictation'

const MAC = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Electron/41.10.5'
const WINDOWS = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Electron/41.10.5'

describe('what the runtime actually offers', () => {
  /*
   * Still measured, still true, and now the reason this app does its own
   * recording and sends the audio somewhere rather than asking Chromium to
   * listen: `start()` fires and then emits nothing at all — no audio, no
   * result, and no error — for ten seconds. The name is the warning, and the
   * check stays so that a future Electron making this work is noticed rather
   * than assumed.
   */
  it('reports the constructor as present-but-silent, never as available', () => {
    expect(speechSupport({ SpeechRecognition: () => undefined })).toBe('present-but-silent')
    expect(speechSupport({ webkitSpeechRecognition: () => undefined })).toBe('present-but-silent')
  })

  it('reports missing when there is no constructor', () => {
    expect(speechSupport({})).toBe('missing')
    expect(speechSupport(undefined)).toBe('missing')
  })
})

describe('guidance', () => {
  it('knows a Mac from a PC', () => {
    expect(isMac(MAC)).toBe(true)
    expect(isMac(WINDOWS)).toBe(false)
  })
})

describe('appending to what is already typed', () => {
  it('separates from existing text with one space', () => {
    expect(appendSpoken('fix the parser', 'and then run the tests')).toBe(
      'fix the parser and then run the tests',
    )
  })

  it('does not double a space the user already left', () => {
    expect(appendSpoken('fix the parser ', 'and run')).toBe('fix the parser and run')
  })

  it('leaves the box alone when nothing was said', () => {
    expect(appendSpoken('keep me', '   ')).toBe('keep me')
  })

  it('starts an empty box without a leading space', () => {
    expect(appendSpoken('', ' hello ')).toBe('hello')
  })
})
