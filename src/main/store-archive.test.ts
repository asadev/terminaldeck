import { describe, expect, it } from 'vitest'
import { paxRecord as pax, tarGz } from './store-archive.fixture'
import {
  fileAt,
  filesUnder,
  readArchive,
  readTarGz,
  SMALL_ITEM_LIMITS,
  stripSingleRoot,
  type ArchiveFile,
} from './store-archive'

/**
 * The unpacker is the only thing standing between a stranger's archive and this
 * person's home directory, so every refusal it makes is written down here as a
 * test rather than as a comment. The archives come from `store-archive.fixture.ts`,
 * which builds them byte by byte for the reason that file's header gives.
 */

const paths = (files: readonly ArchiveFile[]): string[] => files.map((file) => file.path).sort()

describe('reading an artifact', () => {
  it('reads a plain tar.gz', () => {
    const result = readTarGz(
      tarGz([
        { name: 'item/SKILL.md', body: '# hello' },
        { name: 'item/', type: '5' },
        { name: 'item/notes/two.md', body: 'two' },
      ]),
      SMALL_ITEM_LIMITS,
    )
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(paths(result.files)).toEqual(['item/SKILL.md', 'item/notes/two.md'])
    expect(result.files[0].bytes.toString('utf8')).toBe('# hello')
  })

  it('keeps the mode, because the tier rule reads the executable bit', () => {
    const result = readTarGz(tarGz([{ name: 'a/run', body: '#!/bin/sh\n', mode: 0o755 }]), SMALL_ITEM_LIMITS)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.files[0].mode & 0o111).not.toBe(0)
  })

  it('takes a long name from a pax header rather than truncating it', () => {
    const long = `item/${'d'.repeat(120)}/deep.md`
    const record = pax('path', long)
    const result = readTarGz(
      tarGz([
        { name: 'PaxHeader', type: 'x', body: record },
        { name: long.slice(0, 90), body: 'deep' },
      ]),
      SMALL_ITEM_LIMITS,
    )
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.files[0].path).toBe(long)
  })

  it('ignores the global header a repository host writes at the top', () => {
    const result = readTarGz(
      tarGz([
        { name: 'pax_global_header', type: 'g', body: pax('comment', 'a'.repeat(40)) },
        { name: 'item/SKILL.md', body: 'x' },
      ]),
      SMALL_ITEM_LIMITS,
    )
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(paths(result.files)).toEqual(['item/SKILL.md'])
  })
})

describe('what the unpacker refuses', () => {
  it('refuses an entry that climbs out of the folder', () => {
    const result = readTarGz(tarGz([{ name: '../../.claude/settings.json', body: '{}' }]), SMALL_ITEM_LIMITS)
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('will not write')
  })

  it('refuses an absolute path', () => {
    const result = readTarGz(tarGz([{ name: '/etc/hosts', body: 'x' }]), SMALL_ITEM_LIMITS)
    expect(result.ok).toBe(false)
  })

  it('refuses a symlink outright rather than skipping it', () => {
    const result = readTarGz(
      tarGz([
        { name: 'item/SKILL.md', body: 'ok' },
        { name: 'item/keys', type: '2' },
      ]),
      SMALL_ITEM_LIMITS,
    )
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('link')
  })

  it('refuses a hard link', () => {
    expect(readTarGz(tarGz([{ name: 'item/x', type: '1' }]), SMALL_ITEM_LIMITS).ok).toBe(false)
  })

  it('refuses a device node', () => {
    expect(readTarGz(tarGz([{ name: 'item/null', type: '3' }]), SMALL_ITEM_LIMITS).ok).toBe(false)
  })

  it('refuses a header whose checksum does not add up', () => {
    const result = readTarGz(tarGz([{ name: 'item/a.md', body: 'a' }], { corruptChecksum: true }), SMALL_ITEM_LIMITS)
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('damaged')
  })

  it('refuses a file that claims more bytes than the archive holds', () => {
    const result = readTarGz(tarGz([{ name: 'item/a.md', body: 'a', statedSize: 900_000 }]), SMALL_ITEM_LIMITS)
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('cut short')
  })

  it('refuses more files than the ceiling allows', () => {
    const many = Array.from({ length: 12 }, (_, i) => ({ name: `item/f${i}.md`, body: 'x' }))
    const result = readTarGz(tarGz(many), { ...SMALL_ITEM_LIMITS, maxFiles: 4 })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('more files')
  })

  it('refuses an archive that unpacks past the ceiling', () => {
    const result = readTarGz(tarGz([{ name: 'item/big.md', body: 'x'.repeat(4096) }]), {
      ...SMALL_ITEM_LIMITS,
      maxTotalBytes: 1024,
    })
    expect(result.ok).toBe(false)
  })

  it('refuses an empty archive rather than installing nothing', () => {
    expect(readTarGz(tarGz([]), SMALL_ITEM_LIMITS).ok).toBe(false)
  })
})

describe('choosing a reader by the bytes, never by the name', () => {
  it('reads a gzip', () => {
    expect(readArchive(tarGz([{ name: 'a/b.md', body: 'x' }]), SMALL_ITEM_LIMITS).ok).toBe(true)
  })

  it('refuses something that is neither a zip nor a gzip', () => {
    const result = readArchive(Buffer.from('not an archive at all, just text'), SMALL_ITEM_LIMITS)
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('not an archive')
  })

  it('refuses a download bigger than the ceiling before decompressing anything', () => {
    const result = readArchive(tarGz([{ name: 'a/b.md', body: 'x' }]), { ...SMALL_ITEM_LIMITS, maxArchiveBytes: 4 })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('larger than')
  })
})

describe('finding the item inside the archive', () => {
  const files: ArchiveFile[] = [
    { path: 'repo-abc/terminaldeck.json', bytes: Buffer.from('{}'), mode: 0 },
    { path: 'repo-abc/skill/SKILL.md', bytes: Buffer.from('# s'), mode: 0 },
  ]

  it('drops the one wrapper folder a repository archive adds', () => {
    expect(paths(stripSingleRoot(files))).toEqual(['skill/SKILL.md', 'terminaldeck.json'])
  })

  it('leaves two top-level folders alone, because there is no wrapper to drop', () => {
    const two: ArchiveFile[] = [
      { path: 'one/a.md', bytes: Buffer.alloc(0), mode: 0 },
      { path: 'two/b.md', bytes: Buffer.alloc(0), mode: 0 },
    ]
    expect(paths(stripSingleRoot(two))).toEqual(['one/a.md', 'two/b.md'])
  })

  it('takes the files under one folder, with the folder taken off the front', () => {
    expect(paths(filesUnder(stripSingleRoot(files), 'skill'))).toEqual(['SKILL.md'])
  })

  it('treats a dot as the whole tree', () => {
    expect(filesUnder(stripSingleRoot(files), '.')).toHaveLength(2)
  })

  it('finds one file by its exact path', () => {
    expect(fileAt(stripSingleRoot(files), 'terminaldeck.json')).not.toBeNull()
    expect(fileAt(stripSingleRoot(files), 'nothing.json')).toBeNull()
  })
})
