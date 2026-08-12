import { describe, expect, it } from 'vitest'
import { appendSpoken, dictationGuidance, isMac, speechSupport } from './dictation'

const MAC = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Electron/41.10.5'
const WINDOWS = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Electron/41.10.5'

describe('what the runtime actually offers', () => {
  it('reports the constructor as present-but-silent, never as available', () => {
    // Measured in this Electron: start() fires and then emits nothing at all —
    // no audio, no result, no error — for ten seconds. The name is the warning.
    expect(speechSupport({ SpeechRecognition: () => undefined })).toBe('present-but-silent')
    expect(speechSupport({ webkitSpeechRecognition: () => undefined })).toBe('present-but-silent')
  })

  it('reports missing when there is no constructor', () => {
    expect(speechSupport({})).toBe('missing')
    expect(speechSupport(undefined)).toBe('missing')
  })
})

describe('guidance', () => {
  it('names the macOS route, which is the one that exists', () => {
    const guidance = dictationGuidance(MAC)
    expect(guidance.steps.join(' ')).toContain('Edit ▸ Start Dictation')
    expect(guidance.steps.join(' ')).toContain('System Settings')
  })

  it('does not claim a keyboard shortcut it cannot know', () => {
    // The Dictation hotkey is unbound on the machine this was built on, so
    // "press Fn twice" would have been confidently wrong.
    expect(dictationGuidance(MAC).steps.join(' ')).not.toMatch(/Fn|twice/)
  })

  it('gives a different route off macOS instead of nonsense', () => {
    expect(dictationGuidance(WINDOWS).steps.join(' ')).toContain('Win + H')
    expect(dictationGuidance(WINDOWS).steps.join(' ')).not.toContain('Edit ▸ Start Dictation')
  })

  it('always carries the reason, so the popover never has to say "unsupported"', () => {
    expect(dictationGuidance(MAC).reason).toContain('Electron does not ship')
  })

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
