import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  describeByteTransforms,
  digestFile,
  digestOf,
  findByteTransforms,
  findByteWriters,
  fingerprintFile,
  listSourceFiles,
  NO_TRANSFORM_GUARANTEE,
  stripCommentsAndStrings,
  writesBytesToDisk,
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
   * Who is scanned, and why it is nobody's list.
   *
   * It used to be five file names typed into this file. `browser-capture-store.ts`
   * writes response bodies to disk and was not one of them, so the guarantee had
   * a hole in it for as long as that file existed — and no test could notice,
   * because the list was the only statement of what the list should hold. That is
   * the same failure as a hand-written count of tools sitting next to a
   * hand-written list of them.
   *
   * So the set is read off the files: **every module under `src/main` that puts
   * bytes on a disk is scanned**, found by {@link findByteWriters}. A writer
   * added tomorrow is inside the guarantee tomorrow, under any name, in any
   * folder, with nobody having remembered anything.
   *
   * `src/main` and not `src/`: writing a file is a main-process act. A renderer
   * and a preload have no `node:fs`, and the headless host in `src/headless`
   * writes its own state and never a downloaded file — if that changes, the root
   * here is the one line that moves.
   *
   * ## And a second rule, because a writer is not the first thing to arrive
   *
   * The asset modules are scanned whether or not they write anything today.
   * *"We already have the file open, we may as well make a thumbnail here"* is
   * how the transform gets added, and the transform is written before the write
   * is: `browser-asset-rendition.ts` and `browser-asset-probe.ts` handle asset
   * bytes and touch no disk at all, and dropping them the moment the rule became
   * "writers" would have narrowed the guarantee while widening it.
   *
   * So: **everything that writes bytes, plus everything on the asset path.**
   * Both halves are patterns rather than lists — a `browser-asset-fetch.ts`
   * added next week is inside this guarantee under either one, having asked
   * nobody.
   */
  const ASSET_PATH = /(?:^|\/)browser-asset-[^/]+\.ts$/
  const WRITERS = findByteWriters(__dirname)
  const SCANNED = [
    ...new Set([...WRITERS, ...listSourceFiles(__dirname).filter((file) => ASSET_PATH.test(file))]),
  ].sort()

  /**
   * Writers that are not download paths, each with the reason it is out.
   *
   * Default-in is the whole point: this list can only ever *shrink* the scan, it
   * is read out loud in the failure when a new writer needs judging, and every
   * entry below is checked to still be a writer, so it cannot rot into a
   * silent hole the way the old list did.
   *
   * The first three are the same case — an image this app *made*, written into
   * its own file, from something that was never a download. That is the
   * permitted half of the rule, stated in {@link NO_TRANSFORM_GUARANTEE} itself:
   * *"derivatives are made afterwards, from the original, into a different
   * file."* The fourth is not about images at all.
   */
  const NOT_DOWNLOADS: Record<string, string> = {
    'browser-driver.ts':
      'decodes a screenshot to mask password fields out of it. A screenshot is not a download, and the ' +
      'masked copy is its own file.',
    'browser-view.ts':
      'writes screenshots and scales a preview for the panel. Both are pictures this app took; neither ' +
      'is a file a server sent.',
    'attach-outside.ts':
      'writes an image off the clipboard so it can be handed to a session. The clipboard is not a socket.',
    'servers/servers.electron-probe.ts':
      'resizes a terminal — cols and rows, not pixels. Left in the patterns rather than carved out of ' +
      'them: the scan is narrowed by naming a file, never by teaching the patterns to miss a spelling, ' +
      'because a pattern with a hole in it is invisible and a named file is not.',
    'remote/server.ts':
      'resizes a terminal, exactly as the probe above does — `SessionAccess.resize(id, cols, rows)`, ' +
      'forwarded from the wire\'s own `resize` frame. It entered the scan when it grew a write of ' +
      'its own: `browserProfilesFor` keeps the machine\'s browser-profile list in a JSON file, which ' +
      'makes this a byte-writer by the deriver\'s rule and therefore a file the patterns run over. ' +
      'The bytes it writes are a list it composed itself, never a file a server sent, and the only ' +
      'download it touches it hands on untouched. Named here rather than pattern-matched away, for ' +
      'the reason written one entry up.',
  }

  it('finds the writers by reading them, and is not quietly finding nothing', () => {
    /*
     * The test that makes every test below it mean something.
     *
     * A deriver that returned `[]` — a wrong root, a walk that threw, a stripper
     * that blanked everything — would turn the whole guard into a loop over
     * nothing that passes for ever. That is precisely the empty success this
     * round of work exists to end, and a guard is not exempt from it.
     */
    expect(WRITERS.length).toBeGreaterThan(10)
    for (const file of [
      // The download path, split by wave-2 so the server can carry it without
      // Electron: the ledger, the desktop `will-download` transport (its
      // `setSavePath` is the write), and the CDP transport (its move of the
      // completed file). `browser-downloads.ts` is now only a re-export and
      // writes nothing, so the scan follows the bytes to where they moved.
      'browser-downloads-store.ts',
      'browser-downloads-electron.ts',
      'browser-downloads-cdp.ts',
      // The hole this rewrite exists to close: it has written response bodies
      // to disk since the day it was added and was outside the old list.
      'browser-capture-store.ts',
      'browser-asset-ledger.ts',
      'browser-asset-coverage.ts',
      'browser-block-watch.ts',
      // Not a browser file at all, and it downloads the application: the widened
      // rule found it without anybody thinking of it, which is the point.
      'updates/fetch-update.ts',
    ]) {
      expect(WRITERS).toContain(file)
    }
    // The asset path, in or out of the writer set. These two write nothing.
    for (const file of ['browser-asset-rendition.ts', 'browser-asset-probe.ts']) {
      expect(WRITERS).not.toContain(file)
      expect(SCANNED).toContain(file)
    }
  })

  it('reads the code and not the prose', () => {
    // `browser-scrape-paths.ts` describes `mkdirSync(..., { recursive: true })`
    // in its header and writes nothing at all. A membership rule that could not
    // tell a document from a writer would sweep in every file in this folder.
    expect(WRITERS).not.toContain('browser-scrape-paths.ts')
    expect(writesBytesToDisk('// writeFileSync(path, bytes) is what a writer does')).toBe(false)
    expect(writesBytesToDisk("const how = 'call writeFileSync(path, bytes)'")).toBe(false)
    expect(writesBytesToDisk('writeFileSync(path, bytes)')).toBe(true)
    expect(writesBytesToDisk('await writeFile(path, bytes)')).toBe(true)
    expect(writesBytesToDisk('createWriteStream(path)')).toBe(true)
    expect(writesBytesToDisk('item.setSavePath(path)')).toBe(true)
    // A socket, a pty and a response all have a `write`. None of them is a file.
    expect(writesBytesToDisk('socket.write(chunk)')).toBe(false)
  })

  it('has no exclusion that has stopped being a writer', () => {
    /*
     * An exclusion for a file that was renamed, deleted or no longer writes is a
     * line that reads like a considered decision and defends nothing. Worse, it
     * would go on looking like the reason a *new* file of that name is out.
     */
    for (const file of Object.keys(NOT_DOWNLOADS)) {
      expect(WRITERS, `${file} is excluded but no longer writes bytes — delete the exclusion`).toContain(
        file,
      )
    }
  })

  for (const file of SCANNED) {
    const why = NOT_DOWNLOADS[file]
    if (why !== undefined) continue
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
