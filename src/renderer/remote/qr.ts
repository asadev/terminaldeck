/**
 * A QR encoder — byte mode, error correction level M — and the SVG geometry for
 * one. No dependency, and none wanted.
 *
 * ## Why this is written out rather than installed
 *
 * The only thing this app needs to draw is a pairing URL: one short ASCII
 * string, one error-correction level, one output format. Every QR package on npm
 * carries forty versions, four levels, four encoding modes, canvas and terminal
 * renderers, and a licence header that would have to be tracked in
 * THIRD-PARTY-LICENSES.md forever. The algorithm is published (ISO/IEC 18004)
 * and the part of it we need is about four hundred lines, so it is here.
 *
 * ## What is actually verified, and how
 *
 * The encoder is built from pieces that have published values, and each of those
 * pieces is pinned separately in `qr.test.ts` — a whole-matrix assertion tells
 * you it broke, not where:
 *
 *   - Reed–Solomon, against the worked example in ISO/IEC 18004 Annex I: the
 *     sixteen data codewords for `01234567` at version 1-M produce the ten
 *     error-correction codewords listed there. The same test also checks the
 *     property that makes the vector meaningful — data ‖ ecc evaluates to zero
 *     at α⁰…α^(n−1), which is what a scanner's decoder relies on.
 *   - The format strings, against Table C.1: level M, masks 0–7.
 *   - The version strings for version ≥ 7, against Table D.1.
 *   - Byte-mode capacity per version, against the capacity table.
 *
 * And the whole thing was decoded end-to-end outside this process while it was
 * written: the matrix was written out as a PNG and read back by macOS Vision's
 * barcode detector, which returned the original URL. That is a real scanner
 * disagreeing-or-not with this file, which no unit test in this repo can be.
 *
 * ## Byte mode and level M, and nothing else
 *
 * Byte mode because the payload is a URL with a case-sensitive token in it —
 * alphanumeric mode is upper-case only and would corrupt it silently. Level M
 * because it is the level every published capacity table calls the default: it
 * survives about 15% damage, which is the difference between a code that reads
 * off a slightly glared laptop screen and one that does not. Numeric, kanji and
 * ECI modes are absent because nothing here would ever reach them, and code that
 * cannot be reached cannot be trusted.
 */

export interface QrMatrix {
  /** 1–40. Chosen as the smallest that fits, never larger. */
  version: number
  /** Modules per side: 4 × version + 17. */
  size: number
  /** Row-major, `[y][x]`, `true` is a dark module. */
  modules: boolean[][]
}

/** Four light modules on every side. A code without it fails to read. */
export const QR_QUIET_ZONE = 4

const MIN_VERSION = 1
const MAX_VERSION = 40

/** Mode indicator for byte mode, and the two pad bytes the spec names. */
const MODE_BYTE = 0b0100
const PAD_BYTES = [0xec, 0x11] as const

/**
 * Error-correction codewords per block, and blocks per version, at level M.
 *
 * Index 0 is a hole so the array is indexed by version directly; reading it is
 * a bug, and `-1` makes that bug loud rather than plausible.
 */
const ECC_PER_BLOCK: readonly number[] = [
  -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28,
  28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
]

const BLOCKS: readonly number[] = [
  -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25,
  26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49,
]

/* -------------------------------------------------------------------------- */
/* Capacity                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Bits the character count takes in byte mode. Eight up to version 9, sixteen
 * from version 10 — a version boundary that silently shifts every bit after it,
 * so it is a function rather than a constant anyone could forget to change.
 */
function charCountBits(version: number): number {
  return version < 10 ? 8 : 16
}

/**
 * Data modules in a symbol before error correction is subtracted, i.e. the whole
 * grid minus the finders, timing, alignment, format and version areas.
 *
 * Computed rather than tabulated: the closed form is in the standard, and a
 * forty-row table copied by hand is forty chances to mistype a number that would
 * only show up as an unreadable code at one particular size.
 */
export function rawDataModules(version: number): number {
  let modules = (16 * version + 128) * version + 64
  if (version >= 2) {
    const alignments = Math.floor(version / 7) + 2
    modules -= (25 * alignments - 10) * alignments - 55
    if (version >= 7) modules -= 36
  }
  return modules
}

/** Codewords available to the payload once error correction has taken its share. */
export function dataCodewords(version: number): number {
  return Math.floor(rawDataModules(version) / 8) - ECC_PER_BLOCK[version] * BLOCKS[version]
}

/** How many bytes of payload a version holds at level M. */
export function byteCapacity(version: number): number {
  return Math.floor((dataCodewords(version) * 8 - 4 - charCountBits(version)) / 8)
}

/* -------------------------------------------------------------------------- */
/* GF(256) and Reed–Solomon                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Multiply in GF(256) modulo x⁸+x⁴+x³+x²+1 (0x11d), the field QR uses.
 *
 * Reduction happens *before* each shift, on the bit that is about to overflow,
 * which is why nothing here ever exceeds a byte. Exported because it is the
 * bottom of everything above it and a wrong product is invisible until a
 * scanner refuses the code.
 */
export function gfMultiply(a: number, b: number): number {
  let product = 0
  for (let bit = 7; bit >= 0; bit--) {
    product = (product << 1) ^ ((product >>> 7) * 0x11d)
    product ^= ((b >>> bit) & 1) * a
  }
  return product & 0xff
}

/** The generator polynomial of the given degree, highest power first. */
function generatorPoly(degree: number): number[] {
  const coefficients = new Array<number>(degree).fill(0)
  coefficients[degree - 1] = 1
  // Multiply out (x − α⁰)(x − α¹)…(x − α^(degree−1)), one root at a time.
  let root = 1
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < degree; j++) {
      coefficients[j] = gfMultiply(coefficients[j], root)
      if (j + 1 < degree) coefficients[j] ^= coefficients[j + 1]
    }
    root = gfMultiply(root, 2)
  }
  return coefficients
}

/** The error-correction codewords for one block. */
export function eccCodewords(data: readonly number[], degree: number): number[] {
  const generator = generatorPoly(degree)
  const remainder = new Array<number>(degree).fill(0)
  for (const byte of data) {
    const factor = byte ^ (remainder.shift() ?? 0)
    remainder.push(0)
    for (let i = 0; i < degree; i++) remainder[i] ^= gfMultiply(generator[i], factor)
  }
  return remainder
}

/* -------------------------------------------------------------------------- */
/* Payload → codewords                                                         */
/* -------------------------------------------------------------------------- */

/** The smallest version that holds this many bytes at level M. */
export function versionFor(byteLength: number): number {
  for (let version = MIN_VERSION; version <= MAX_VERSION; version++) {
    if (byteLength <= byteCapacity(version)) return version
  }
  throw new RangeError(
    `${byteLength} bytes will not fit in a QR code — the largest holds ${byteCapacity(MAX_VERSION)} at this error-correction level.`,
  )
}

/** The payload as data codewords: header, bytes, terminator, padding. */
function dataCodewordsFor(bytes: Uint8Array, version: number): number[] {
  const capacityBits = dataCodewords(version) * 8
  const bits: number[] = []
  const push = (value: number, width: number): void => {
    for (let i = width - 1; i >= 0; i--) bits.push((value >>> i) & 1)
  }

  push(MODE_BYTE, 4)
  push(bytes.length, charCountBits(version))
  for (const byte of bytes) push(byte, 8)

  // Terminator, then to a byte boundary. Both are bounded by what is left,
  // because a payload that exactly fills the version has room for neither.
  push(0, Math.min(4, capacityBits - bits.length))
  push(0, (8 - (bits.length % 8)) % 8)

  const codewords: number[] = []
  for (let i = 0; i < bits.length; i += 8) {
    let byte = 0
    for (let j = 0; j < 8; j++) byte = (byte << 1) | bits[i + j]
    codewords.push(byte)
  }
  for (let i = 0; codewords.length < capacityBits / 8; i++) {
    codewords.push(PAD_BYTES[i % PAD_BYTES.length])
  }
  return codewords
}

/**
 * Split into blocks, add error correction, and interleave the result.
 *
 * The interleaving is the point: a scanner reading a code with a coffee ring on
 * it loses a contiguous run of codewords, and spreading each block across the
 * symbol turns that into a few recoverable errors per block instead of one
 * destroyed block. Short blocks are one codeword shorter than long ones and are
 * skipped on the last data column, which is why the loop tests the length.
 */
function interleave(data: readonly number[], version: number): number[] {
  const eccLength = ECC_PER_BLOCK[version]
  const blockCount = BLOCKS[version]
  const totalCodewords = Math.floor(rawDataModules(version) / 8)
  const shortBlocks = blockCount - (totalCodewords % blockCount)
  const shortLength = Math.floor(totalCodewords / blockCount)

  const dataBlocks: number[][] = []
  const eccBlocks: number[][] = []
  let taken = 0
  for (let i = 0; i < blockCount; i++) {
    const length = shortLength - eccLength + (i < shortBlocks ? 0 : 1)
    const block = data.slice(taken, taken + length)
    taken += length
    dataBlocks.push(block)
    eccBlocks.push(eccCodewords(block, eccLength))
  }

  const result: number[] = []
  for (let i = 0; i < shortLength - eccLength + 1; i++) {
    for (const block of dataBlocks) if (i < block.length) result.push(block[i])
  }
  for (let i = 0; i < eccLength; i++) {
    for (const block of eccBlocks) result.push(block[i])
  }
  return result
}

/* -------------------------------------------------------------------------- */
/* Drawing                                                                     */
/* -------------------------------------------------------------------------- */

interface Canvas {
  size: number
  modules: boolean[][]
  /** True where a function pattern lives: never data, never masked. */
  fixed: boolean[][]
}

function blankCanvas(size: number): Canvas {
  const grid = (): boolean[][] =>
    Array.from({ length: size }, () => new Array<boolean>(size).fill(false))
  return { size, modules: grid(), fixed: grid() }
}

function setFunction(canvas: Canvas, x: number, y: number, dark: boolean): void {
  if (x < 0 || y < 0 || x >= canvas.size || y >= canvas.size) return
  canvas.modules[y][x] = dark
  canvas.fixed[y][x] = true
}

/**
 * Where the alignment patterns sit, in both axes.
 *
 * The closed form again, for the same reason as `rawDataModules` — and version
 * 32 really is the one exception in the standard, not a typo here.
 */
export function alignmentPositions(version: number): number[] {
  if (version === 1) return []
  const count = Math.floor(version / 7) + 2
  const size = 4 * version + 17
  const step = version === 32 ? 26 : Math.ceil((version * 4 + 4) / (count * 2 - 2)) * 2
  const positions = [6]
  for (let pos = size - 7; positions.length < count; pos -= step) positions.splice(1, 0, pos)
  return positions
}

/** A finder and its separator: 3×3 dark core, light ring, dark ring, light edge. */
function drawFinder(canvas: Canvas, cx: number, cy: number): void {
  for (let dy = -4; dy <= 4; dy++) {
    for (let dx = -4; dx <= 4; dx++) {
      const ring = Math.max(Math.abs(dx), Math.abs(dy))
      setFunction(canvas, cx + dx, cy + dy, ring !== 2 && ring !== 4)
    }
  }
}

function drawAlignment(canvas: Canvas, cx: number, cy: number): void {
  for (let dy = -2; dy <= 2; dy++) {
    for (let dx = -2; dx <= 2; dx++) {
      setFunction(canvas, cx + dx, cy + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1)
    }
  }
}

/** The fifteen format bits: level M (00), the mask, BCH(15,5), XOR 0x5412. */
export function formatBits(mask: number): number {
  const data = mask // level M is 0b00, so the level field contributes nothing.
  let remainder = data
  for (let i = 0; i < 10; i++) remainder = (remainder << 1) ^ ((remainder >>> 9) * 0x537)
  return ((data << 10) | remainder) ^ 0x5412
}

/** The eighteen version bits, for version 7 and up: BCH(18,6), no XOR. */
export function versionBits(version: number): number {
  let remainder = version
  for (let i = 0; i < 12; i++) remainder = (remainder << 1) ^ ((remainder >>> 11) * 0x1f25)
  return (version << 12) | remainder
}

function drawFormat(canvas: Canvas, mask: number): void {
  const bits = formatBits(mask)
  const bit = (i: number): boolean => ((bits >>> i) & 1) !== 0
  const size = canvas.size

  // Two copies, so a symbol with one corner damaged still says which mask it
  // used. The split positions are the standard's, not a pattern.
  for (let i = 0; i <= 5; i++) setFunction(canvas, 8, i, bit(i))
  setFunction(canvas, 8, 7, bit(6))
  setFunction(canvas, 8, 8, bit(7))
  setFunction(canvas, 7, 8, bit(8))
  for (let i = 9; i < 15; i++) setFunction(canvas, 14 - i, 8, bit(i))

  for (let i = 0; i < 8; i++) setFunction(canvas, size - 1 - i, 8, bit(i))
  for (let i = 8; i < 15; i++) setFunction(canvas, 8, size - 15 + i, bit(i))

  // The one module that is always dark, whatever else happens.
  setFunction(canvas, 8, size - 8, true)
}

function drawFunctionPatterns(canvas: Canvas, version: number): void {
  const size = canvas.size

  for (let i = 0; i < size; i++) {
    setFunction(canvas, 6, i, i % 2 === 0)
    setFunction(canvas, i, 6, i % 2 === 0)
  }

  drawFinder(canvas, 3, 3)
  drawFinder(canvas, size - 4, 3)
  drawFinder(canvas, 3, size - 4)

  const positions = alignmentPositions(version)
  for (let i = 0; i < positions.length; i++) {
    for (let j = 0; j < positions.length; j++) {
      // The three that would sit on a finder are simply absent.
      const corner =
        (i === 0 && j === 0) ||
        (i === 0 && j === positions.length - 1) ||
        (i === positions.length - 1 && j === 0)
      if (!corner) drawAlignment(canvas, positions[i], positions[j])
    }
  }

  if (version >= 7) {
    const bits = versionBits(version)
    for (let i = 0; i < 18; i++) {
      const dark = ((bits >>> i) & 1) !== 0
      const far = size - 11 + (i % 3)
      const near = Math.floor(i / 3)
      setFunction(canvas, far, near, dark)
      setFunction(canvas, near, far, dark)
    }
  }

  // Drawn with mask 0 only to reserve the modules; the real bits go on last,
  // once the mask has been chosen by measuring the finished symbol.
  drawFormat(canvas, 0)
}

/** Lay the codewords in the two-module-wide zigzag, bottom-right upward. */
function drawCodewords(canvas: Canvas, codewords: readonly number[]): void {
  const size = canvas.size
  let bitIndex = 0
  for (let right = size - 1; right >= 1; right -= 2) {
    // Column 6 is the vertical timing pattern; the zigzag steps over it.
    if (right === 6) right = 5
    for (let step = 0; step < size; step++) {
      for (let column = 0; column < 2; column++) {
        const x = right - column
        const upward = ((right + 1) & 2) === 0
        const y = upward ? size - 1 - step : step
        if (canvas.fixed[y][x] || bitIndex >= codewords.length * 8) continue
        canvas.modules[y][x] = ((codewords[bitIndex >>> 3] >>> (7 - (bitIndex & 7))) & 1) !== 0
        bitIndex++
      }
    }
  }
}

/** The eight mask patterns, by their published formulas. */
export function maskAt(mask: number, x: number, y: number): boolean {
  switch (mask) {
    case 0:
      return (x + y) % 2 === 0
    case 1:
      return y % 2 === 0
    case 2:
      return x % 3 === 0
    case 3:
      return (x + y) % 3 === 0
    case 4:
      return (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0
    case 5:
      return ((x * y) % 2) + ((x * y) % 3) === 0
    case 6:
      return (((x * y) % 2) + ((x * y) % 3)) % 2 === 0
    case 7:
      return (((x + y) % 2) + ((x * y) % 3)) % 2 === 0
    default:
      throw new RangeError(`There are eight masks, 0–7; ${mask} is not one of them.`)
  }
}

function applyMask(canvas: Canvas, mask: number): void {
  for (let y = 0; y < canvas.size; y++) {
    for (let x = 0; x < canvas.size; x++) {
      if (!canvas.fixed[y][x] && maskAt(mask, x, y)) canvas.modules[y][x] = !canvas.modules[y][x]
    }
  }
}

const RUN_PENALTY = 3
const BLOCK_PENALTY = 3
const FINDER_LIKE_PENALTY = 40
const BALANCE_PENALTY = 10

/** Same-colour runs of five or more, scored per line. */
function runPenalty(line: readonly boolean[]): number {
  let score = 0
  let run = 1
  for (let i = 1; i < line.length; i++) {
    if (line[i] === line[i - 1]) {
      run++
      if (run === 5) score += RUN_PENALTY
      else if (run > 5) score += 1
    } else {
      run = 1
    }
  }
  return score
}

/** The 1:1:3:1:1 finder proportion with four light modules beside it. */
function finderLikePenalty(line: readonly boolean[]): number {
  const pattern = [true, false, true, true, true, false, true]
  const light = [false, false, false, false]
  const matches = (at: number, wanted: readonly boolean[]): boolean =>
    wanted.every((value, i) => line[at + i] === value)

  let score = 0
  for (let i = 0; i + 7 <= line.length; i++) {
    if (!matches(i, pattern)) continue
    const before = i >= 4 && matches(i - 4, light)
    const after = i + 11 <= line.length && matches(i + 7, light)
    if (before || after) score += FINDER_LIKE_PENALTY
  }
  return score
}

/**
 * How bad a masked symbol looks to a scanner, by the standard's four rules.
 *
 * None of this affects what the code says — every mask decodes. It affects
 * whether a decoder locks on at all, which is why the encoder measures all eight
 * rather than picking a favourite.
 */
export function penalty(canvas: Canvas): number {
  const size = canvas.size
  let score = 0

  // Rows and columns are the same length, so one pass does both lines at index i.
  for (let i = 0; i < size; i++) {
    const row = canvas.modules[i]
    const column = canvas.modules.map((line) => line[i])
    score += runPenalty(row) + runPenalty(column)
    score += finderLikePenalty(row) + finderLikePenalty(column)
  }

  for (let y = 0; y + 1 < size; y++) {
    for (let x = 0; x + 1 < size; x++) {
      const corner = canvas.modules[y][x]
      if (
        corner === canvas.modules[y][x + 1] &&
        corner === canvas.modules[y + 1][x] &&
        corner === canvas.modules[y + 1][x + 1]
      ) {
        score += BLOCK_PENALTY
      }
    }
  }

  let dark = 0
  for (const row of canvas.modules) for (const module of row) if (module) dark++
  const total = size * size
  // Every five percent away from an even split costs, so a code that is nearly
  // all one colour never wins the comparison.
  const drift = Math.floor((Math.abs(dark * 20 - total * 10) + total - 1) / total)
  return score + drift * BALANCE_PENALTY
}

/* -------------------------------------------------------------------------- */
/* The encoder                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * Encode a string. Throws `RangeError` when it is too long for any version —
 * the caller shows the URL instead, because a truncated QR code is a URL that
 * silently goes somewhere else.
 */
export function encodeQr(text: string): QrMatrix {
  const bytes = new TextEncoder().encode(text)
  const version = versionFor(bytes.length)
  const codewords = interleave(dataCodewordsFor(bytes, version), version)
  const size = 4 * version + 17

  let best: Canvas | null = null
  let bestScore = Number.POSITIVE_INFINITY
  for (let mask = 0; mask < 8; mask++) {
    const canvas = blankCanvas(size)
    drawFunctionPatterns(canvas, version)
    drawCodewords(canvas, codewords)
    applyMask(canvas, mask)
    drawFormat(canvas, mask)
    const score = penalty(canvas)
    if (score < bestScore) {
      bestScore = score
      best = canvas
    }
  }

  // `best` is assigned on the first iteration; the check is for the compiler.
  if (!best) throw new Error('No mask was evaluated, which cannot happen.')
  return { version, size, modules: best.modules }
}

/* -------------------------------------------------------------------------- */
/* SVG geometry                                                                */
/* -------------------------------------------------------------------------- */

/**
 * One path covering every dark module, with horizontal runs merged.
 *
 * A rect per module is the obvious version and it puts thousands of elements in
 * the document for a code this size; merging runs cuts it by roughly two thirds
 * and, more importantly, removes the hairline seams that appear between adjacent
 * rects when a browser rounds their edges to different device pixels — seams a
 * camera reads as light modules.
 */
export function qrPath(matrix: QrMatrix, quiet = QR_QUIET_ZONE): string {
  const parts: string[] = []
  for (let y = 0; y < matrix.size; y++) {
    let x = 0
    while (x < matrix.size) {
      if (!matrix.modules[y][x]) {
        x++
        continue
      }
      let run = 1
      while (x + run < matrix.size && matrix.modules[y][x + run]) run++
      parts.push(`M${x + quiet} ${y + quiet}h${run}v1h-${run}z`)
      x += run
    }
  }
  return parts.join('')
}

/** The view box the path is drawn in: the symbol plus its quiet zone. */
export function qrViewBox(matrix: QrMatrix, quiet = QR_QUIET_ZONE): string {
  const side = matrix.size + quiet * 2
  return `0 0 ${side} ${side}`
}
