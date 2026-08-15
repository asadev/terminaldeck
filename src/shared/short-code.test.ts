import { randomBytes } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import {
  CODE_ALPHABET,
  CODE_ENTROPY_BYTES,
  CODE_LENGTH,
  codeFromBytes,
  formatCode,
  isCode,
  normaliseCode,
} from './short-code'

describe('the alphabet', () => {
  it('is exactly 32 symbols, which is what makes five bits come out even', () => {
    expect(CODE_ALPHABET).toHaveLength(32)
    expect(new Set(CODE_ALPHABET).size).toBe(32)
  })

  it('contains none of I, L, O or U', () => {
    for (const letter of ['I', 'L', 'O', 'U']) {
      expect(CODE_ALPHABET, `${letter} is misread or unprintable in a code`).not.toContain(letter)
    }
  })
})

describe('minting', () => {
  it('is eight symbols in two groups of four', () => {
    const code = codeFromBytes(randomBytes(CODE_ENTROPY_BYTES))
    expect(code).toMatch(/^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/)
    expect(code.replace('-', '')).toHaveLength(CODE_LENGTH)
  })

  it('reads the bits from the top down, the way the string is read', () => {
    // 0xff picks the last symbol of the alphabet, 0x00 the first. Written out
    // rather than computed so a change to the bit order fails here loudly.
    expect(codeFromBytes(Uint8Array.from([0, 0, 0, 0, 0]))).toBe('0000-0000')
    expect(codeFromBytes(Uint8Array.from([0xff, 0xff, 0xff, 0xff, 0xff]))).toBe('ZZZZ-ZZZZ')
    expect(codeFromBytes(Uint8Array.from([0b11111000, 0, 0, 0, 0]))).toBe('Z000-0000')
  })

  it('refuses to pad a short buffer out into something that looks like forty bits', () => {
    expect(() => codeFromBytes(Uint8Array.from([1, 2, 3, 4]))).toThrow(/randomness/)
  })

  it('mints every symbol eventually, so no part of the alphabet is unreachable', () => {
    const seen = new Set<string>()
    for (let i = 0; i < 4000; i++) {
      for (const symbol of codeFromBytes(randomBytes(CODE_ENTROPY_BYTES)).replace('-', '')) {
        seen.add(symbol)
      }
    }
    expect([...seen].sort().join('')).toBe([...CODE_ALPHABET].sort().join(''))
  })
})

describe('reading one back', () => {
  it('accepts the string exactly as it is printed', () => {
    expect(normaliseCode('H4K9-2FQT')).toBe('H4K9-2FQT')
  })

  it('accepts it without the hyphen, in any case, with stray spacing', () => {
    expect(normaliseCode('h4k92fqt')).toBe('H4K9-2FQT')
    expect(normaliseCode('  H4K9 2FQT ')).toBe('H4K9-2FQT')
    expect(normaliseCode('H4K9–2FQT')).toBe('H4K9-2FQT')
  })

  it('folds the three characters the alphabet left out for being misread', () => {
    // O is a zero, I and L are ones. Somebody copying off a screen types what
    // they see, and what they see in most faces is a letter.
    expect(normaliseCode('OI1L-0000')).toBe('0111-0000')
  })

  it('refuses U, which was dropped for a different reason', () => {
    // U is not ambiguous, so folding it would be inventing a character the
    // minting side can never have produced.
    expect(normaliseCode('UUUU-UUUU')).toBeNull()
  })

  it('refuses anything that is not eight symbols', () => {
    expect(normaliseCode('H4K9-2FQ')).toBeNull()
    expect(normaliseCode('H4K9-2FQTT')).toBeNull()
    expect(normaliseCode('')).toBeNull()
    expect(normaliseCode('----')).toBeNull()
  })

  it('round-trips everything it mints', () => {
    for (let i = 0; i < 500; i++) {
      const code = codeFromBytes(randomBytes(CODE_ENTROPY_BYTES))
      expect(normaliseCode(code)).toBe(code)
      expect(isCode(code)).toBe(true)
    }
  })

  it('does not call a credential a code', () => {
    // `authenticatorFor` tells the two apart by the dot, and this is the other
    // half of that: nothing shaped like `<deviceId>.<secret>` may normalise.
    expect(isCode('AbCdEfGhIjKl.0123456789abcdef')).toBe(false)
    expect(normaliseCode('AbCdEfGhIjKl.0123456789abcdef')).toBeNull()
  })
})

describe('formatting', () => {
  it('groups in fours and leaves a short remainder alone', () => {
    expect(formatCode('ABCDEFGH')).toBe('ABCD-EFGH')
    expect(formatCode('ABC')).toBe('ABC')
  })
})
