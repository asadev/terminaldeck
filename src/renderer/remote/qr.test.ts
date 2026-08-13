import { describe, expect, it } from 'vitest'
import {
  alignmentPositions,
  byteCapacity,
  dataCodewords,
  eccCodewords,
  encodeQr,
  formatBits,
  gfMultiply,
  maskAt,
  qrPath,
  qrViewBox,
  QR_QUIET_ZONE,
  rawDataModules,
  versionBits,
  versionFor,
} from './qr'

/**
 * The encoder, checked against published values rather than against itself.
 *
 * A QR encoder is the kind of code that looks right and is wrong: every stage
 * produces plausible bytes, and the only symptom of a mistake anywhere in it is
 * a picture a phone declines to read — with no error, no clue which stage broke,
 * and nothing on screen that looks unusual to a person. So the pieces that have
 * published values are pinned to those values here, one at a time:
 *
 *   - the Reed–Solomon example worked in ISO/IEC 18004 Annex I;
 *   - the format strings of Table C.1 and the version strings of Table D.1;
 *   - the byte-mode capacity table;
 *   - the alignment-pattern centres, including version 32, which is the one
 *     version whose spacing does not follow the formula.
 *
 * Where no published value exists, the test asserts a property instead of a
 * number — the error-correction block must divide by the generator polynomial,
 * which is exactly what a decoder checks, and is a stronger statement than any
 * single vector.
 */

/* ------------------------------------------------------------ arithmetic -- */

describe('GF(256) multiplication', () => {
  it('is ordinary polynomial multiplication when nothing overflows', () => {
    // 3 = x+1, 4 = x², so the product is x³+x² = 12, no reduction involved.
    expect(gfMultiply(3, 4)).toBe(12)
    expect(gfMultiply(1, 0xab)).toBe(0xab)
    expect(gfMultiply(0, 0xab)).toBe(0)
  })

  it('reduces by the field polynomial when it does', () => {
    // 0x80 × 2 = 0x100, which reduces to 0x100 ^ 0x11d = 0x1d.
    expect(gfMultiply(0x80, 2)).toBe(0x1d)
  })

  it('commutes, and stays inside a byte', () => {
    for (let a = 0; a < 256; a += 7) {
      for (let b = 0; b < 256; b += 11) {
        const product = gfMultiply(a, b)
        expect(product).toBe(gfMultiply(b, a))
        expect(product).toBeGreaterThanOrEqual(0)
        expect(product).toBeLessThan(256)
      }
    }
  })
})

describe('Reed–Solomon', () => {
  /**
   * ISO/IEC 18004 Annex I: `01234567` at version 1-M. The data codewords are
   * derivable by hand from the mode header and the numeric groups; the ten
   * error-correction codewords are the standard's own answer, which is what
   * makes this a test of this file rather than a restatement of it.
   */
  const ANNEX_DATA = [
    0x10, 0x20, 0x0c, 0x56, 0x61, 0x80, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11,
  ]
  const ANNEX_ECC = [0xa5, 0x24, 0xd4, 0xc1, 0xed, 0x36, 0xc7, 0x87, 0x2c, 0x55]

  it('reproduces the worked example in the standard', () => {
    expect(eccCodewords(ANNEX_DATA, 10)).toEqual(ANNEX_ECC)
  })

  it('produces a block a decoder accepts: every syndrome is zero', () => {
    // The property behind the vector. data ‖ ecc is a multiple of the generator
    // polynomial, so it evaluates to zero at α⁰…α⁹ — the check a scanner runs
    // before it trusts a single byte.
    const data = [...new TextEncoder().encode('terminaldeck pairing')]
    const block = [...data, ...eccCodewords(data, 18)]
    for (let i = 0; i < 18; i++) {
      const root = powerOfAlpha(i)
      let value = 0
      for (const byte of block) value = gfMultiply(value, root) ^ byte
      expect(value).toBe(0)
    }
  })

  function powerOfAlpha(exponent: number): number {
    let value = 1
    for (let i = 0; i < exponent; i++) value = gfMultiply(value, 2)
    return value
  }
})

/* -------------------------------------------------------------- capacity -- */

describe('capacity at level M', () => {
  it('matches the published byte-mode table', () => {
    const published: Record<number, number> = {
      1: 14,
      2: 26,
      3: 42,
      4: 62,
      5: 84,
      6: 106,
      7: 122,
      10: 213,
      13: 331,
      40: 2331,
    }
    for (const [version, bytes] of Object.entries(published)) {
      expect(byteCapacity(Number(version)), `version ${version}`).toBe(bytes)
    }
  })

  it('agrees with the total-codeword counts the standard lists', () => {
    // Version 1 is 26 codewords, version 7 is 196, version 40 is 3706. Those are
    // the totals; the split into data and error correction is this file's table.
    expect(rawDataModules(1) / 8).toBe(26)
    expect(rawDataModules(7) / 8).toBe(196)
    expect(rawDataModules(40) / 8).toBe(3706)
    expect(dataCodewords(1)).toBe(16)
    expect(dataCodewords(7)).toBe(124)
  })

  it('picks the smallest version that fits, and says so when nothing does', () => {
    expect(versionFor(14)).toBe(1)
    // 15 bytes is one past version 1, and the count field is still 8 bits, so
    // this is the boundary where a mistake would be a silently truncated URL.
    expect(versionFor(15)).toBe(2)
    expect(versionFor(2331)).toBe(40)
    expect(() => versionFor(2332)).toThrow(/will not fit/)
  })
})

/* ------------------------------------------------------------- structure -- */

describe('format and version information', () => {
  it('matches Table C.1 for level M', () => {
    const published = [
      '101010000010010',
      '101000100100101',
      '101111001111100',
      '101101101001011',
      '100010111111001',
      '100000011001110',
      '100111110010111',
      '100101010100000',
    ]
    for (let mask = 0; mask < 8; mask++) {
      expect(formatBits(mask).toString(2).padStart(15, '0'), `mask ${mask}`).toBe(published[mask])
    }
  })

  it('matches Table D.1 where the version is written into the symbol', () => {
    expect(versionBits(7)).toBe(0x07c94)
    expect(versionBits(10)).toBe(0x0a4d3)
    expect(versionBits(40)).toBe(0x28c69)
  })
})

describe('alignment pattern centres', () => {
  it('matches the table, including the version that breaks the formula', () => {
    expect(alignmentPositions(1)).toEqual([])
    expect(alignmentPositions(2)).toEqual([6, 18])
    expect(alignmentPositions(7)).toEqual([6, 22, 38])
    expect(alignmentPositions(32)).toEqual([6, 34, 60, 86, 112, 138])
  })
})

describe('the masks', () => {
  it('are the eight published formulas, and there is no ninth', () => {
    expect(maskAt(0, 0, 0)).toBe(true)
    expect(maskAt(0, 1, 0)).toBe(false)
    expect(maskAt(1, 0, 2)).toBe(true)
    expect(maskAt(2, 3, 5)).toBe(true)
    expect(maskAt(4, 2, 1)).toBe(true)
    expect(maskAt(4, 3, 1)).toBe(false)
    expect(() => maskAt(8, 0, 0)).toThrow(/eight masks/)
  })
})

/* -------------------------------------------------------------- symbols -- */

const PAIRING_URL = 'https://asads-macbook-pro-1.taile59277.ts.net/#8fb1c2d4e5a6b7c8d9e0f1a2b3c4d5e6'

function isDark(matrix: { modules: boolean[][] }, x: number, y: number): boolean {
  return matrix.modules[y][x]
}

describe('a whole symbol', () => {
  const matrix = encodeQr(PAIRING_URL)

  it('is the size its version says it is', () => {
    expect(matrix.size).toBe(4 * matrix.version + 17)
    expect(matrix.modules).toHaveLength(matrix.size)
    for (const row of matrix.modules) expect(row).toHaveLength(matrix.size)
  })

  it('is only as large as the payload needs', () => {
    expect(matrix.version).toBe(versionFor(new TextEncoder().encode(PAIRING_URL).length))
  })

  it('has a finder in three corners and not in the fourth', () => {
    const finder = (ox: number, oy: number): boolean => {
      for (let y = 0; y < 7; y++) {
        for (let x = 0; x < 7; x++) {
          const ring = Math.max(Math.abs(x - 3), Math.abs(y - 3))
          if (isDark(matrix, ox + x, oy + y) !== (ring !== 2)) return false
        }
      }
      return true
    }
    expect(finder(0, 0)).toBe(true)
    expect(finder(matrix.size - 7, 0)).toBe(true)
    expect(finder(0, matrix.size - 7)).toBe(true)
    expect(finder(matrix.size - 7, matrix.size - 7)).toBe(false)
  })

  it('has timing patterns that alternate all the way across', () => {
    for (let i = 8; i < matrix.size - 8; i++) {
      expect(isDark(matrix, i, 6), `column ${i} of the horizontal timing pattern`).toBe(i % 2 === 0)
      expect(isDark(matrix, 6, i), `row ${i} of the vertical timing pattern`).toBe(i % 2 === 0)
    }
  })

  it('keeps the module that is dark in every QR code ever made', () => {
    expect(isDark(matrix, 8, matrix.size - 8)).toBe(true)
  })

  it('is not wildly lopsided, which is what choosing a mask is for', () => {
    let dark = 0
    for (const row of matrix.modules) for (const module of row) if (module) dark++
    const share = dark / (matrix.size * matrix.size)
    expect(share).toBeGreaterThan(0.35)
    expect(share).toBeLessThan(0.65)
  })

  it('refuses a payload no version can carry', () => {
    expect(() => encodeQr('x'.repeat(2332))).toThrow(RangeError)
  })

  it('encodes non-ASCII as UTF-8 bytes rather than characters', () => {
    // The token is ASCII today, but a host name need not be — and a count field
    // holding characters instead of bytes is a corrupt symbol, not a short one.
    const text = 'https://ärger.example/#ok'
    expect(encodeQr(text).version).toBe(versionFor(new TextEncoder().encode(text).length))
  })
})

describe('the SVG geometry', () => {
  const matrix = encodeQr('https://example.ts.net/#token')

  it('offsets everything by the quiet zone', () => {
    const path = qrPath(matrix)
    const first = /^M(\d+) (\d+)/.exec(path)
    expect(first).not.toBeNull()
    expect(Number(first?.[1])).toBeGreaterThanOrEqual(QR_QUIET_ZONE)
    expect(Number(first?.[2])).toBeGreaterThanOrEqual(QR_QUIET_ZONE)
    expect(qrViewBox(matrix)).toBe(
      `0 0 ${matrix.size + QR_QUIET_ZONE * 2} ${matrix.size + QR_QUIET_ZONE * 2}`,
    )
  })

  it('draws every dark module exactly once, as merged horizontal runs', () => {
    let dark = 0
    for (const row of matrix.modules) for (const module of row) if (module) dark++
    const drawn = [...qrPath(matrix).matchAll(/h(\d+)v1/g)].reduce(
      (total, run) => total + Number(run[1]),
      0,
    )
    expect(drawn).toBe(dark)
    // Merged, not one rect per module: the seams between adjacent rects are what
    // a camera reads as light modules.
    expect(qrPath(matrix)).toMatch(/h[2-9]\d*v1/)
  })

  it('stays inside the view box', () => {
    const limit = matrix.size + QR_QUIET_ZONE
    for (const move of qrPath(matrix).matchAll(/M(\d+) (\d+)h(\d+)/g)) {
      expect(Number(move[1]) + Number(move[3])).toBeLessThanOrEqual(limit)
      expect(Number(move[2])).toBeLessThan(limit)
    }
  })
})
