import { createHash } from 'node:crypto'
import { createReadStream, statSync } from 'node:fs'

/**
 * The fingerprint of a file, and the rule that the file is never changed.
 *
 * ## The loss this exists to stop happening again
 *
 * Asad runs a property-data pipeline that downloads floor plans and photographs.
 * A pass was added to it that resized every image to something sensible before
 * writing it out — and it ran *before* the write, on the buffer, overwriting the
 * original in memory. **58% of the bytes of every image in that run were thrown
 * away and no original survived anywhere.** There was nothing to re-derive from
 * and nothing to compare against; the only way back was to fetch all of it
 * again.
 *
 * The rule that follows from it is one sentence and it is not negotiable:
 *
 * > **A downloaded file is written exactly as the server sent it, and nothing in
 * > this app ever rewrites those bytes. A derivative — a thumbnail, a resized
 * > copy, a re-encode — is made afterwards, from the original, into a different
 * > file, and never instead of it.**
 *
 * `browser-downloads.ts` already obeys it: `will-download` sets a save path and
 * Chromium streams the response onto it, `.part` then rename, with no buffer in
 * between that anything could transform. That is the *current* behaviour, which
 * is not the same thing as a guarantee — the resize that cost him those images
 * was also, the day before it was written, current behaviour.
 *
 * So this module makes it checkable in two independent ways, because either one
 * alone can be walked around:
 *
 *  1. {@link fingerprintFile} and {@link digestOf}, which let a test assert that
 *     the bytes on disk are byte-identical to the bytes a server actually sent.
 *     `browser-download-bytes.test.ts` does exactly that against a real HTTP
 *     server. That test fails the moment a transform is inserted anywhere
 *     between the socket and the disk.
 *  2. {@link findByteTransforms}, which reads the *source* of the download path
 *     and refuses the idioms a transform is written in. It is what catches the
 *     change that is added tomorrow to a code path today's test does not happen
 *     to cover — and it catches it in the diff that introduces it, with the
 *     reason attached, rather than in a run six weeks later that is missing more
 *     than half of every picture.
 *
 * Neither is decoration. (1) proves today's behaviour and cannot see code it did
 * not run; (2) sees all the code and cannot prove behaviour. Together they cover
 * the failure.
 *
 * ## Why sha256 and not something faster
 *
 * The digest is also the ledger's key (`browser-asset-ledger.ts`), which is how
 * a resume tells "already downloaded" from "downloaded, and wrong". A
 * non-cryptographic hash is fine against accidents and useless against a CDN
 * that serves an error page under the right length — and an error page under the
 * right length is exactly what 48,473 skipped assets looked like. The cost is a
 * single sequential read of a file that was, moments ago, written by the same
 * process; on the runs this is for, the network is four orders of magnitude
 * slower.
 */

/** The one algorithm, named once. A digest string always carries its own prefix. */
export const DIGEST_ALGORITHM = 'sha256'

/**
 * The guarantee, in a string, so it can be quoted where it is relied on.
 *
 * A sentence in a header is read by whoever opens the file. This is exported so
 * that a refusal, a log line or a test failure can say the rule out loud at the
 * moment it matters, which is the only time anybody reads it.
 */
export const NO_TRANSFORM_GUARANTEE =
  'A downloaded file is written exactly as the server sent it. Nothing in this app rewrites those ' +
  'bytes. Derivatives are made afterwards, from the original, into a different file — never instead of it.'

/** `sha256:<hex>` for a buffer already in memory. */
export function digestOf(bytes: Buffer | Uint8Array): string {
  return `${DIGEST_ALGORITHM}:${createHash(DIGEST_ALGORITHM).update(bytes).digest('hex')}`
}

/**
 * `sha256:<hex>` for a file, streamed.
 *
 * Streamed rather than `readFileSync` because these are photographs and floor
 * plans in bulk and a 200MB video is a perfectly ordinary thing to find in a
 * downloads folder; reading one whole into a buffer to hash it is a needless
 * copy of the whole file.
 *
 * Answers `''` rather than throwing when the file cannot be read. Every caller
 * here treats an empty digest as *"unknown"*, which is a state the ledger
 * already has to handle — and a download row that lost its digest must not also
 * lose the row.
 */
export async function digestFile(path: string): Promise<string> {
  return new Promise<string>((resolve) => {
    const hash = createHash(DIGEST_ALGORITHM)
    const stream = createReadStream(path)
    stream.on('error', () => resolve(''))
    stream.on('data', (chunk) => hash.update(chunk))
    stream.on('end', () => resolve(`${DIGEST_ALGORITHM}:${hash.digest('hex')}`))
  })
}

/** Size and digest together: what the ledger stores and what a resume compares. */
export interface FileFingerprint {
  bytes: number
  digest: string
}

/**
 * Fingerprint a file, or `null` when there is no file.
 *
 * The two are deliberately one call. A resume that checks the size and then the
 * digest in two separate steps has a window between them, and — far more
 * importantly — a caller that only ever reached for the cheap half is how a
 * ledger comes to believe in a file that is not there.
 */
export async function fingerprintFile(path: string): Promise<FileFingerprint | null> {
  let size: number
  try {
    const info = statSync(path)
    if (!info.isFile()) return null
    size = info.size
  } catch {
    return null
  }
  const digest = await digestFile(path)
  if (digest === '') return null
  return { bytes: size, digest }
}

/* ------------------------------------------------------ the source guard -- */

/** One idiom that would change bytes on their way to disk, and why it is refused. */
export interface ByteTransform {
  /** 1-based, so it can be read against the file in an editor. */
  line: number
  /** The line as written, trimmed. */
  text: string
  /** What this would do to the file. */
  why: string
}

interface TransformPattern {
  pattern: RegExp
  why: string
}

/**
 * The idioms a byte transform is written in.
 *
 * Every entry is something that has to *produce different bytes* to be worth
 * calling — not a general-purpose function that could be misused. The list is
 * short on purpose: a scanner that fires on ordinary code gets a suppression
 * comment added to it within a week and then guards nothing.
 *
 * `nativeImage` is here even though it is Electron's own and perfectly innocent
 * elsewhere in this app — `browser-driver.ts` uses it to mask password fields
 * out of a screenshot, which is a *derivative* and exactly the permitted case.
 * What it must never touch is a file that came down a socket. Which files are
 * scanned is therefore the whole of the policy, and it is stated at the call
 * site in `browser-asset-digest.test.ts` rather than here.
 */
const TRANSFORMS: readonly TransformPattern[] = [
  { pattern: /\bresize\s*\(/i, why: 'resizing rewrites the file and the original cannot be got back' },
  { pattern: /\bcrop\s*\(/i, why: 'cropping discards part of the file' },
  { pattern: /\bthumbnail\s*\(/i, why: 'a thumbnail is a derivative and belongs in its own file' },
  { pattern: /\bcompress\s*\(/i, why: 're-compressing rewrites the file' },
  {
    pattern: /\bto(?:JPEG|PNG|Bitmap|DataURL)\s*\(/,
    why: 're-encoding an image produces different bytes from the ones the server sent',
  },
  {
    pattern: /\bnativeImage\b/,
    why: 'decoding a download into an image is the first half of re-encoding it',
  },
  { pattern: /\b(?:sharp|jimp|imagemin|gm)\s*\(/i, why: 'an image library rewrites what it is given' },
  { pattern: /\bzlib\./, why: 'recompressing a payload changes the bytes on disk' },
]

/**
 * Does a `/` here begin a regular expression rather than a division?
 *
 * The standard heuristic: after a value — an identifier, a number, a closing
 * bracket — a slash divides; after an operator, a comma, an opening bracket or
 * nothing at all, it opens a literal. Wrong only for `a / b / c` written with
 * no other punctuation, which nothing scanned here contains.
 */
function startsRegex(lastSignificant: string): boolean {
  if (lastSignificant === '') return true
  return !/[A-Za-z0-9_$)\]]/.test(lastSignificant)
}

/**
 * Blank a regular-expression literal and its flags, answering the index after it.
 *
 * Character classes are tracked, because `/[/]/` is a perfectly ordinary regex
 * whose middle slash does not close it — and a stripper that stopped there would
 * leave the rest of the literal being read as code.
 */
function blankRegex(source: string, start: number, blank: (character: string) => void): number {
  let index = start
  blank(source[index])
  index += 1
  let inClass = false
  while (index < source.length) {
    const character = source[index]
    if (character === '\n') {
      // An unterminated literal: it was a division after all. Stop rather than
      // blanking the rest of the file.
      return index
    }
    blank(character)
    index += 1
    if (character === '\\') {
      if (index < source.length) {
        blank(source[index])
        index += 1
      }
      continue
    }
    if (character === '[') inClass = true
    else if (character === ']') inClass = false
    else if (character === '/' && !inClass) break
  }
  while (index < source.length && /[a-z]/.test(source[index])) {
    blank(source[index])
    index += 1
  }
  return index
}

/**
 * Blank out comments and string literals, keeping every line number.
 *
 * Necessary rather than fussy: this very file, and the header of
 * `browser-downloads.ts`, both have to use the word *resize* in prose to explain
 * why resizing is forbidden. A scanner that could not tell prose from code would
 * fire on the documentation of its own rule, and the first person to hit that
 * would delete the scanner.
 *
 * Removed spans become spaces of the same length so offsets and line numbers
 * survive. Template *expressions* — the part between `${` and `}` — stay as
 * code, because that is code and a call hidden in one would otherwise be
 * invisible.
 *
 * Regular-expression literals are blanked too, and that is not fussiness
 * either: `browser-downloads.ts` contains `/[:*?"<>|]/g`, whose double quote
 * would otherwise open a string that swallowed the next several hundred lines of
 * real code. A scanner that quietly stops looking is worse than no scanner. The
 * regex-versus-division question is settled by the last significant character,
 * which is the ordinary heuristic and is wrong only for arithmetic written
 * between two divisions — a shape none of the scanned files contain.
 */
export function stripCommentsAndStrings(source: string): string {
  const out: string[] = []
  // Which template literals we are inside, so a `}` knows whether it closes an
  // expression or is just a brace. Depth counting per template, innermost last.
  const templates: number[] = []
  let mode: 'code' | 'line' | 'block' | 'single' | 'double' | 'template' = 'code'
  let index = 0
  /** The last non-whitespace character emitted as code, for the regex question. */
  let lastSignificant = ''

  const keep = (character: string): void => {
    out.push(character === '\n' ? '\n' : character)
  }
  const blank = (character: string): void => {
    out.push(character === '\n' ? '\n' : ' ')
  }

  while (index < source.length) {
    const character = source[index]
    const next = source[index + 1] ?? ''

    if (mode === 'code') {
      if (character === '/' && next === '/') {
        mode = 'line'
        blank(character)
        blank(next)
        index += 2
        continue
      }
      if (character === '/' && next === '*') {
        mode = 'block'
        blank(character)
        blank(next)
        index += 2
        continue
      }
      if (character === "'") {
        mode = 'single'
        blank(character)
        index += 1
        continue
      }
      if (character === '"') {
        mode = 'double'
        blank(character)
        index += 1
        continue
      }
      if (character === '`') {
        mode = 'template'
        templates.push(0)
        blank(character)
        index += 1
        continue
      }
      if (character === '}' && templates.length > 0) {
        // Closing a `${…}` and going back into the template it belongs to.
        mode = 'template'
        blank(character)
        index += 1
        continue
      }
      if (character === '/' && startsRegex(lastSignificant)) {
        index = blankRegex(source, index, blank)
        lastSignificant = '/'
        continue
      }
      keep(character)
      if (character.trim() !== '') lastSignificant = character
      index += 1
      continue
    }

    if (mode === 'line') {
      if (character === '\n') mode = 'code'
      blank(character)
      index += 1
      continue
    }

    if (mode === 'block') {
      if (character === '*' && next === '/') {
        mode = 'code'
        blank(character)
        blank(next)
        index += 2
        continue
      }
      blank(character)
      index += 1
      continue
    }

    if (mode === 'single' || mode === 'double') {
      if (character === '\\') {
        blank(character)
        if (index + 1 < source.length) blank(next)
        index += 2
        continue
      }
      if ((mode === 'single' && character === "'") || (mode === 'double' && character === '"')) {
        mode = 'code'
      }
      blank(character)
      index += 1
      continue
    }

    // Inside a template literal.
    if (character === '\\') {
      blank(character)
      if (index + 1 < source.length) blank(next)
      index += 2
      continue
    }
    if (character === '$' && next === '{') {
      mode = 'code'
      blank(character)
      blank(next)
      index += 2
      continue
    }
    if (character === '`') {
      mode = 'code'
      templates.pop()
      blank(character)
      index += 1
      continue
    }
    blank(character)
    index += 1
  }

  return out.join('')
}

/**
 * Every byte-transforming idiom in a file's *code*, with the line it is on.
 *
 * Empty means the file does not rewrite what it was handed. A test asserts that
 * over the download path; see this module's header for why that test and the
 * end-to-end one are both needed.
 */
export function findByteTransforms(source: string): ByteTransform[] {
  const code = stripCommentsAndStrings(source).split('\n')
  const raw = source.split('\n')
  const found: ByteTransform[] = []
  for (let n = 0; n < code.length; n += 1) {
    for (const { pattern, why } of TRANSFORMS) {
      if (pattern.test(code[n])) {
        found.push({ line: n + 1, text: (raw[n] ?? '').trim(), why })
        break
      }
    }
  }
  return found
}

/**
 * The sentence a failing guard should print.
 *
 * Composed here rather than in the test so that the reason travels with the
 * rule: whoever reads the failure gets the rule, the line, and what that line
 * would have done, without opening this file.
 */
export function describeByteTransforms(file: string, found: readonly ByteTransform[]): string {
  if (found.length === 0) return ''
  const lines = found.map((entry) => `  ${file}:${entry.line}  ${entry.text}\n    → ${entry.why}`)
  return `${NO_TRANSFORM_GUARANTEE}\n\n${lines.join('\n')}`
}
