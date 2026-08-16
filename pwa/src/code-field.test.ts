import { describe, expect, it } from 'vitest'
import { CODE_LENGTH, normaliseCode } from '../../src/shared/short-code'
import { asCodeField, type CodeFieldLike } from './code-field'

function blank(): CodeFieldLike {
  return {
    type: '',
    inputMode: '',
    autocomplete: '',
    pattern: '',
    maxLength: -1,
    placeholder: '',
    autocapitalize: '',
    spellcheck: true,
  }
}

describe('the six-digit field', () => {
  it('raises a numeric keypad', () => {
    // Half the argument for digits is what a phone puts under them. Without
    // this the field is a full alphanumeric keyboard and the format has bought
    // nothing on the device it was chosen for.
    expect(asCodeField(blank()).inputMode).toBe('numeric')
  })

  it('is a text input, so a leading zero survives', () => {
    /*
     * `type="number"` is the obvious choice and it is wrong. It strips leading
     * zeros, offers a spinner, and on several browsers refuses a paste that is
     * not a valid number — and `000042` is a code the desktop mints one time in
     * ten thousand. The number type would turn it into `42`, which normalises to
     * null and reads on screen as a code that was typed correctly and refused.
     */
    expect(asCodeField(blank()).type).toBe('text')
    expect(normaliseCode('000042')).toBe('000042')
    expect(normaliseCode(String(Number('000042')))).toBeNull()
  })

  it('is not a telephone keypad', () => {
    // `tel` raises a keypad too, and carries `+`, `*`, `#` and a pause key on
    // iOS. None of them can appear in a pairing code, so all of them are ways to
    // enter something the field will refuse.
    expect(asCodeField(blank()).inputMode).not.toBe('tel')
    expect(asCodeField(blank()).inputMode).not.toBe('decimal')
  })

  it('asks for the one-time-code autofill, which is exactly what it is', () => {
    expect(asCodeField(blank()).autocomplete).toBe('one-time-code')
  })

  it('stops at six characters', () => {
    // Not validation — `normaliseCode` is validation. This is what keeps a slow
    // seventh tap out of a field that has already auto-submitted, so the person
    // does not have to clear it before trying again.
    expect(asCodeField(blank()).maxLength).toBe(CODE_LENGTH)
    expect(asCodeField(blank()).maxLength).toBe(6)
  })

  it('shows a shape rather than an example somebody will type in', () => {
    const field = asCodeField(blank())
    expect(field.placeholder).toBe('000000')
    // The old field's placeholder was a literal example code, `H4K9-2FQT`, and
    // people typed it. A placeholder of zeroes cannot be mistaken for a value.
    expect(normaliseCode(field.placeholder)).toBe('000000')
  })

  it('turns off the corrections that would rewrite a code', () => {
    const field = asCodeField(blank())
    expect(field.autocapitalize).toBe('off')
    expect(field.spellcheck).toBe(false)
  })
})
