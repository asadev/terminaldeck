import { randomBytes } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import {
  CODE_ALPHABET,
  CODE_DRAWS,
  CODE_DRAW_LIMIT,
  CODE_ENTROPY_BYTES,
  CODE_LENGTH,
  CODE_SPACE,
  CODE_WORD_BYTES,
  codeFromBytes,
  formatCode,
  isCode,
  normaliseCode,
} from './short-code'

/** One draw, as `codeFromBytes` reads it: four bytes, big-endian. */
function word(draw: number): Uint8Array {
  return Uint8Array.from([(draw >>> 24) & 0xff, (draw >>> 16) & 0xff, (draw >>> 8) & 0xff, draw & 0xff])
}

function words(...draws: number[]): Uint8Array {
  const out = new Uint8Array(draws.length * CODE_WORD_BYTES)
  draws.forEach((draw, index) => out.set(word(draw), index * CODE_WORD_BYTES))
  return out
}

describe('the format', () => {
  it('is six decimal digits with nothing between them', () => {
    const code = codeFromBytes(randomBytes(CODE_ENTROPY_BYTES))
    expect(code).toMatch(/^[0-9]{6}$/)
    expect(code).toHaveLength(CODE_LENGTH)
  })

  it('has no grouping character anywhere in it', () => {
    // The eight-character format put a hyphen in the middle. Nothing does now,
    // and `formatCode` is the one place that could reintroduce one — so it is
    // asserted here rather than left to be noticed on a phone keypad that
    // cannot type a hyphen.
    expect(formatCode('123456')).toBe('123456')
    for (let i = 0; i < 200; i++) {
      expect(codeFromBytes(randomBytes(CODE_ENTROPY_BYTES))).not.toMatch(/[^0-9]/)
    }
  })

  it('is digits only — the alphabet is ten symbols, not thirty-two', () => {
    expect(CODE_ALPHABET).toBe('0123456789')
    expect(CODE_SPACE).toBe(10 ** CODE_LENGTH)
  })
})

describe('minting uniformly, which is the whole of the security argument', () => {
  /*
   * These three facts *are* the uniformity proof, and they are asserted rather
   * than sampled because sampling can only ever fail to notice a bias.
   *
   * `% CODE_SPACE` over a contiguous range of draws is uniform exactly when the
   * range is a whole number of cycles long. So: the accepted region starts at
   * zero, its length is a multiple of 10^6, and it is the *largest* such
   * multiple inside 2^32 (throwing away more than it has to would be safe but
   * wasteful, and would mean somebody had changed this without understanding
   * it). Every accepted draw therefore lands on one of the million residues,
   * and each residue is reachable from exactly CODE_DRAW_LIMIT / 10^6 draws.
   */
  it('accepts exactly a whole number of cycles of 10^6', () => {
    expect(CODE_DRAW_LIMIT % CODE_SPACE).toBe(0)
    expect(CODE_DRAW_LIMIT).toBeLessThanOrEqual(2 ** 32)
    expect(2 ** 32 - CODE_DRAW_LIMIT).toBeLessThan(CODE_SPACE)
    // Written out, so a change to the word size fails here with the number in
    // front of the reader rather than as an arithmetic identity that still holds.
    expect(CODE_DRAW_LIMIT).toBe(4_294_000_000)
    expect(CODE_DRAW_LIMIT / CODE_SPACE).toBe(4294)
  })

  it('throws away the draws a naive modulo would have skewed', () => {
    // 2^32 is 4,294 millions plus 967,296. Under `draw % 1_000_000` every one of
    // those 967,296 leftover draws would add a second chance to a code in
    // 000000…967295, making the low end of the space 0.023% likelier than the
    // high end. This is the assertion that the leftovers are refused: the first
    // word here is in the rejection region, so the answer comes from the second.
    expect(codeFromBytes(words(CODE_DRAW_LIMIT + 7, 123_456, 0, 0))).toBe('123456')
    // The same input under `% 1_000_000` would have answered this instead.
    expect(String((CODE_DRAW_LIMIT + 7) % CODE_SPACE).padStart(6, '0')).toBe('000007')
  })

  it('accepts the last draw below the limit and rejects the first at it', () => {
    expect(codeFromBytes(words(CODE_DRAW_LIMIT - 1, 0, 0, 0))).toBe('999999')
    expect(codeFromBytes(words(CODE_DRAW_LIMIT, 424_242, 0, 0))).toBe('424242')
  })

  it('pads a small draw out to six digits rather than emitting a short code', () => {
    expect(codeFromBytes(words(0, 0, 0, 0))).toBe('000000')
    expect(codeFromBytes(words(7, 0, 0, 0))).toBe('000007')
    expect(codeFromBytes(words(CODE_SPACE - 1, 0, 0, 0))).toBe('999999')
  })

  it('spreads evenly across the space, from a stream nobody chose', () => {
    /*
     * A deterministic stream rather than `randomBytes`, so this test either
     * always passes or always fails. A flaky uniformity test is worse than none:
     * it gets retried until it is green and then it is not evidence of anything.
     *
     * xorshift32 is not a cryptographic generator and does not need to be — what
     * is under test is the reduction from a 32-bit draw to a digit, not the
     * quality of the draws. 400,000 codes into 100 buckets of 10,000 values
     * expects 4,000 per bucket with σ ≈ 63, so the band below is about ±4.7σ. A
     * modulo bias of the size this file refuses would put the first 97 buckets
     * measurably above the last 3.
     */
    let state = 0x1337_beef
    const next = (): number => {
      state ^= state << 13
      state ^= state >>> 17
      state ^= state << 5
      return state >>> 0
    }

    const buckets = new Array<number>(100).fill(0)
    const supply = new Uint8Array(CODE_ENTROPY_BYTES)
    for (let i = 0; i < 400_000; i++) {
      for (let at = 0; at < CODE_DRAWS; at++) supply.set(word(next()), at * CODE_WORD_BYTES)
      const code = codeFromBytes(supply)
      buckets[Math.floor(Number(code) / 10_000)] += 1
    }

    const low = Math.min(...buckets)
    const high = Math.max(...buckets)
    expect(low, `a bucket only got ${low} of an expected 4000`).toBeGreaterThan(3700)
    expect(high, `a bucket got ${high} of an expected 4000`).toBeLessThan(4300)
    expect(buckets.reduce((sum, count) => sum + count, 0)).toBe(400_000)
  })

  it('refuses to mint from less randomness than it needs', () => {
    expect(() => codeFromBytes(new Uint8Array(CODE_ENTROPY_BYTES - 1))).toThrow(/randomness/)
  })

  it('throws rather than falling back to a biased draw when every draw is rejected', () => {
    // Only reachable by handing it bytes chosen to be rejected — the odds of
    // meeting it on real randomness are about 2.6e-15 per mint. It throws so
    // that if it ever does happen it is a crash somebody reads, not a code that
    // is quietly drawn from the skewed tail.
    const doomed = words(...new Array<number>(CODE_DRAWS).fill(CODE_DRAW_LIMIT))
    expect(() => codeFromBytes(doomed)).toThrow(/rejection region/)
  })

  it('carries enough draws that exhaustion is not a thing that happens', () => {
    // (967296 / 2^32)^4 ≈ 2.6e-15. The assertion is on the shape rather than
    // the probability: four draws of four bytes, and a change to either is a
    // change to that number.
    expect(CODE_DRAWS).toBeGreaterThanOrEqual(4)
    expect(CODE_ENTROPY_BYTES).toBe(CODE_WORD_BYTES * CODE_DRAWS)
  })
})

describe('reading one back', () => {
  it('accepts the string exactly as it is printed', () => {
    expect(normaliseCode('123456')).toBe('123456')
  })

  it('drops every separator a screen, a person or a chat app puts in', () => {
    expect(normaliseCode(' 123 456 ')).toBe('123456')
    expect(normaliseCode('123-456')).toBe('123456')
    // The curly dash a messaging app substitutes for a hyphen, and a
    // non-breaking space, both of which arrive from a real paste.
    expect(normaliseCode('123–456')).toBe('123456')
    expect(normaliseCode('123 456')).toBe('123456')
    expect(normaliseCode('1 2\t3\n4.5,6')).toBe('123456')
  })

  it('refuses a letter rather than folding it onto a digit', () => {
    /*
     * The eight-character format folded `O` onto `0` and `I`/`L` onto `1`,
     * because the screen was showing letters and three of them are unprintable
     * in the wrong face. The screen shows digits now, so a letter is a typo —
     * and folding a typo produces a *different valid code*, six characters that
     * normalise cleanly and belong to somebody else's pairing.
     */
    expect(normaliseCode('O23456')).toBeNull()
    expect(normaliseCode('12345I')).toBeNull()
    expect(normaliseCode('abcdef')).toBeNull()
  })

  it('refuses anything that is not six digits', () => {
    expect(normaliseCode('12345')).toBeNull()
    expect(normaliseCode('1234567')).toBeNull()
    expect(normaliseCode('')).toBeNull()
    expect(normaliseCode('------')).toBeNull()
  })

  it('walks a hostile paste without walking all of it', () => {
    // Bounded before the scan, and bailing the moment there are too many
    // digits. Neither is a security boundary; both are what keeps a pasted
    // megabyte from being a megabyte of string concatenation on the UI thread.
    expect(normaliseCode('1'.repeat(1_000_000))).toBeNull()
    expect(normaliseCode(`123456${' '.repeat(1_000)}`)).toBe('123456')
  })

  it('round-trips everything it mints', () => {
    for (let i = 0; i < 500; i++) {
      const code = codeFromBytes(randomBytes(CODE_ENTROPY_BYTES))
      expect(normaliseCode(code)).toBe(code)
      expect(isCode(code)).toBe(true)
    }
  })

  it('undoes whatever formatCode did, whatever that becomes', () => {
    // The contract that lets `formatCode` be changed later without breaking the
    // machine on the other end: anything it emits, `normaliseCode` reads back.
    for (const digits of ['000000', '123456', '999999', '000007']) {
      expect(normaliseCode(formatCode(digits))).toBe(formatCode(digits))
    }
  })

  it('does not call a credential a code', () => {
    // `authenticatorFor` tells the two apart by the dot, and this is the other
    // half of that: nothing shaped like `<deviceId>.<secret>` may normalise.
    expect(isCode('AbCdEfGhIjKl.0123456789abcdef')).toBe(false)
    expect(normaliseCode('AbCdEfGhIjKl.0123456789abcdef')).toBeNull()
    // A credential of digits and dots only — no letters to refuse it on — is
    // still not six digits once the dot is dropped.
    expect(normaliseCode('123456.789012')).toBeNull()
  })
})
