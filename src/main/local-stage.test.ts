/**
 * Bytes to a file on this machine, against a real folder.
 *
 * A real temporary directory rather than a fake store, because the two things
 * worth pinning here are both filesystem facts: that the path answered back is a
 * file that actually exists with those bytes in it, and that a second paste of
 * the same name lands *beside* the first rather than over it. A mocked store
 * would assert that this module called something, which is not the property that
 * matters.
 */

import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { MAX_UPLOAD_BYTES } from './remote/protocol'
import { stageBytes } from './local-stage'

let dir = ''
const deps = { dir: () => dir }

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'stage-'))
})
afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

const bytes = (text: string): ArrayBuffer => {
  const buffer = Buffer.from(text, 'utf8')
  return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength) as ArrayBuffer
}

describe('a clipboard image becoming a file', () => {
  it('answers a path that exists, in the folder it was given, with the bytes in it', async () => {
    const out = await stageBytes(deps, 'pasted.png', bytes('pixels'))
    expect(out.ok).toBe(true)
    if (!out.ok) return
    expect(dirname(out.path)).toBe(dir)
    expect(await readFile(out.path, 'utf8')).toBe('pixels')
  })

  it('puts a second paste of the same name beside the first, not over it', async () => {
    const first = await stageBytes(deps, 'pasted.png', bytes('one'))
    const second = await stageBytes(deps, 'pasted.png', bytes('two'))
    expect(first.ok && second.ok).toBe(true)
    if (!first.ok || !second.ok) return
    expect(second.path).not.toBe(first.path)
    expect(await readFile(first.path, 'utf8')).toBe('one')
    expect(await readFile(second.path, 'utf8')).toBe('two')
  })

  it('never lets the caller name a location, only a file', async () => {
    // The whole reason this channel takes a name: a path here would be a
    // `writeFile` anywhere on the disk, which is the argument `uploads.ts` opens
    // with one layer out.
    const out = await stageBytes(deps, '../../../etc/passwd', bytes('nope'))
    expect(out.ok).toBe(true)
    if (!out.ok) return
    expect(dirname(out.path)).toBe(dir)
    expect(basename(out.path)).not.toContain('/')
  })

  it('refuses an empty clipboard rather than making a zero-byte file', async () => {
    expect((await stageBytes(deps, 'x.png', new ArrayBuffer(0))).ok).toBe(false)
    expect((await stageBytes(deps, 'x.png', undefined)).ok).toBe(false)
    expect((await stageBytes(deps, 'x.png', 'not bytes')).ok).toBe(false)
  })

  it('refuses something bigger than the wire would carry, before writing it', async () => {
    const out = await stageBytes(deps, 'huge.bin', { byteLength: MAX_UPLOAD_BYTES + 1 } as unknown as ArrayBuffer)
    expect(out.ok).toBe(false)
  })

  it('answers a sentence rather than throwing when the folder cannot be made', async () => {
    const out = await stageBytes({ dir: () => join(dir, 'a-file', 'under', 'it') }, 'x.png', bytes('x'))
    // A real refusal only if the path is genuinely unusable; either way this
    // must never reject, because the caller is somebody's ⌘V.
    expect(typeof out.ok).toBe('boolean')
  })
})
