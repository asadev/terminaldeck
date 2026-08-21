import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  describeByteTransforms,
  digestFile,
  digestOf,
  findByteTransforms,
  fingerprintFile,
  NO_TRANSFORM_GUARANTEE,
  stripCommentsAndStrings,
} from './browser-asset-digest'

/**
 * The guarantee that a downloaded file is never rewritten, made into a gate.
 *
 * The behavioural half of this lives in `browser-download-bytes.test.ts`, which
 * runs a real HTTP server and asserts the bytes on disk are byte-identical to
 * the bytes served. This file is the other half: it reads the *source* of the
 * download path and fails if the idioms of a byte transform appear in it.
 *
 * Both are needed and the reason is in `browser-asset-digest.ts`'s header. The
 * short form: the end-to-end test proves today's behaviour and can only see the
 * code it happens to run; the scanner sees every line and cannot prove anything
 * about behaviour. The resize that cost Asad 58% of every image in a run was
 * inserted into code that had a passing test suite around it.
 */

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'asset-digest-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('digests', () => {
  it('carries its own algorithm, so a stored digest can never be read with the wrong one', () => {
    expect(digestOf(Buffer.from('hello'))).toBe(
      'sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    )
  })

  it('hashes a file the same as the buffer it was written from', async () => {
    const bytes = Buffer.from('floor plan, 1920px, allegedly')
    const path = join(dir, 'plan.jpg')
    writeFileSync(path, bytes)
    expect(await digestFile(path)).toBe(digestOf(bytes))
  })

  it('answers an empty digest rather than throwing when there is no file', async () => {
    expect(await digestFile(join(dir, 'nothing-here.jpg'))).toBe('')
  })

  it('fingerprints size and digest together, and answers null for a directory', async () => {
    const path = join(dir, 'photo.jpg')
    writeFileSync(path, Buffer.alloc(1024, 7))
    expect(await fingerprintFile(path)).toEqual({ bytes: 1024, digest: digestOf(Buffer.alloc(1024, 7)) })
    // A directory is not a file, and a resume that fingerprinted one would think
    // it had the asset.
    expect(await fingerprintFile(dir)).toBeNull()
  })
})

describe('the stripper', () => {
  it('keeps line numbers, so a finding can be read against the file', () => {
    const stripped = stripCommentsAndStrings('const a = 1\n// resize(2)\nconst b = 3\n')
    expect(stripped.split('\n')).toHaveLength(4)
    expect(stripped.split('\n')[1].trim()).toBe('')
  })

  it('does not see a transform that is only being written about', () => {
    // The header of the module under test has to use the word to explain the
    // rule. A scanner that fired on its own documentation would be deleted.
    expect(findByteTransforms('/* never call resize() on a download */')).toEqual([])
    expect(findByteTransforms("const why = 'we do not resize(x) here'")).toEqual([])
    expect(findByteTransforms('/** resize() is forbidden\n * crop() too\n */')).toEqual([])
  })

  it('still sees a transform hidden inside a template expression', () => {
    // `${…}` is code, and a call in one would be invisible to a stripper that
    // treated the whole template as a string.
    expect(findByteTransforms('const path = `${image.resize(800)}`')).toHaveLength(1)
  })

  it('does not let a quote inside a regular expression swallow the rest of the file', () => {
    // `browser-downloads.ts` really does contain /[:*?"<>|]/g. A stripper that
    // read that double quote as the start of a string would blank every line
    // after it and report a clean file for ever.
    const source = ['const bad = /[:*?"<>|]/g', 'image.resize({ width: 800 })'].join('\n')
    const found = findByteTransforms(source)
    expect(found).toHaveLength(1)
    expect(found[0].line).toBe(2)
  })

  it('does not mistake division for a regular expression', () => {
    const source = ['const ratio = width / height', 'buffer.crop(1, 2)'].join('\n')
    expect(findByteTransforms(source).map((entry) => entry.line)).toEqual([2])
  })
})

describe('the guard over the download path', () => {
  /**
   * The files scanned, and why exactly these.
   *
   * `browser-downloads.ts` is the only place in this app where bytes arrive from
   * a socket and land on a disk. The asset modules are what a later pass would
   * most plausibly be added to — "we already have the file open, we may as well
   * make a thumbnail here".
   *
   * `browser-driver.ts` is deliberately **not** scanned, and the omission is the
   * policy rather than a gap: it decodes an image and repaints it to mask
   * password fields out of a screenshot. That is a derivative, made into its own
   * file, from something that was never a download. The rule is about downloads.
   *
   * `browser-asset-digest.ts` is not scanned either, for a duller reason: it
   * contains the patterns themselves as regular-expression literals, and those
   * are code.
   */
  const GUARDED = [
    'browser-downloads.ts',
    'browser-asset-ledger.ts',
    'browser-asset-rendition.ts',
    'browser-asset-probe.ts',
    'browser-asset-coverage.ts',
  ]

  for (const file of GUARDED) {
    it(`${file} does not rewrite the bytes it was handed`, () => {
      const source = readFileSync(join(__dirname, file), 'utf8')
      const found = findByteTransforms(source)
      // The message carries the rule and the offending line, so whoever hits
      // this reads why rather than going looking for it.
      expect(describeByteTransforms(file, found)).toBe('')
    })
  }

  it('would fail if somebody added the resize that cost him 58% of every image', () => {
    /*
     * The exact shape of the change that did it: a sensible-looking transform
     * applied to the buffer *before* the write, overwriting the original.
     *
     * This is the assertion that makes the five above mean something. Without it
     * a scanner that had quietly stopped matching anything would keep reporting
     * a clean download path for ever.
     */
    const damage = [
      "import { nativeImage } from 'electron'",
      'function save(bytes: Buffer, path: string): void {',
      '  const image = nativeImage.createFromBuffer(bytes)',
      '  const small = image.resize({ width: 1024 })',
      '  writeFileSync(path, small.toPNG())',
      '}',
    ].join('\n')
    const found = findByteTransforms(damage)
    expect(found.length).toBeGreaterThanOrEqual(3)
    expect(found.map((entry) => entry.line)).toContain(4)
    expect(describeByteTransforms('browser-downloads.ts', found)).toContain(NO_TRANSFORM_GUARANTEE)
    expect(describeByteTransforms('browser-downloads.ts', found)).toContain(
      'the original cannot be got back',
    )
  })
})
