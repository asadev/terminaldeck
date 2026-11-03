import { describe, expect, it } from 'vitest'
import { makeExtensionZip, makeZip, plainManifest } from './browser-extension-zip.fixture'
import { manifestPrefix, safeEntryPath, unzip } from './browser-extension-unzip'

const LIMITS = { maxTotalBytes: 1_000_000, maxFiles: 100 }

function why(result: ReturnType<typeof unzip>): string {
  return result.ok ? '' : result.why
}

describe('what a zip entry is allowed to be called', () => {
  /*
   * The whole reason this app owns its unpacker. Every one of these is a legal
   * zip entry name and every one of them writes outside the directory the store
   * chose, which for this app means somewhere under the user's home directory —
   * `~/.claude/settings.json` being the one that would matter most.
   */
  it.each([
    ['../escape', 'a parent segment'],
    ['a/../../escape', 'a parent segment in the middle'],
    ['/etc/passwd', 'an absolute path'],
    ['C:/Windows/System32/x', 'a drive letter'],
    ['a\\b', 'a backslash, which is a separator on one platform and a filename on the other'],
    ['a//b', 'an empty segment'],
    ['./a', 'a dot segment'],
  ])('refuses %s — %s', (path) => {
    expect(safeEntryPath(path)).toBeNull()
  })

  it('refuses a name with a NUL in it', () => {
    expect(safeEntryPath('a\0b')).toBeNull()
  })

  it('takes an ordinary nested path', () => {
    expect(safeEntryPath('js/background/index.js')).toBe('js/background/index.js')
  })

  it('refuses the archive rather than sanitising the name', () => {
    /*
     * Sanitising produces a path, and a path is something that then gets
     * written. The refusal is the point: nothing legitimate ships an entry like
     * this, so there is nothing to lose by declining and a user data directory
     * to lose by being clever about it.
     */
    const zip = makeZip([{ path: '../escape.js', bytes: Buffer.from('x') }])
    expect(why(unzip(zip, LIMITS))).toContain('will not write')
  })
})

describe('what it will not unpack', () => {
  it('refuses a symbolic link', () => {
    // A symlink entry pointing at ~/.ssh turns a later write into a write
    // somewhere else entirely, so it is caught by its mode bits, not its name.
    const zip = makeZip([{ path: 'link', bytes: Buffer.from('/etc/passwd'), mode: 0o120777 }])
    expect(why(unzip(zip, LIMITS))).toContain('symbolic link')
  })

  it('refuses an archive that unpacks to more than the ceiling', () => {
    const zip = makeZip([{ path: 'big.js', bytes: Buffer.alloc(50_000, 0x61) }])
    expect(why(unzip(zip, { maxTotalBytes: 1_000, maxFiles: 100 }))).toContain('unpacks to more than')
  })

  it('refuses an archive with more files than the ceiling', () => {
    const zip = makeZip(
      Array.from({ length: 10 }, (_, index) => ({
        path: `f${index}.js`,
        bytes: Buffer.from('x'),
      })),
    )
    expect(why(unzip(zip, { maxTotalBytes: 1_000_000, maxFiles: 3 }))).toContain('more than this app will unpack')
  })

  it('refuses an entry that is not the size the index says it is', () => {
    /*
     * The check that catches a damaged transfer that still had the right total
     * length, and a deliberately mismatched index. Without it those bytes reach
     * the disk and then run.
     */
    const zip = makeZip([{ path: 'a.js', bytes: Buffer.from('hello'), lieAboutSize: 99 }])
    expect(why(unzip(zip, LIMITS))).toContain('not the size the archive says')
  })

  it('refuses something that is not a zip at all', () => {
    expect(why(unzip(Buffer.from('not a zip, just some text'), LIMITS))).toBe('it is not a zip archive')
  })

  it('refuses an empty archive', () => {
    expect(why(unzip(makeZip([]), LIMITS))).toBe('it contains no files')
  })
})

describe('what it does unpack', () => {
  it('round-trips deflated bytes exactly', () => {
    const body = Buffer.from('a'.repeat(5000) + 'tail')
    const result = unzip(makeZip([{ path: 'x.js', bytes: body }]), LIMITS)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.files[0].bytes.equals(body)).toBe(true)
  })

  it('round-trips stored bytes exactly', () => {
    // Both methods a real release uses. A reader that handled only deflate would
    // silently mangle the small files most zip writers store rather than compress.
    const body = Buffer.from([0, 1, 2, 253, 254, 255])
    const result = unzip(makeZip([{ path: 'x.bin', bytes: body, store: true }]), LIMITS)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.files[0].bytes.equals(body)).toBe(true)
  })

  it('skips directory entries rather than treating them as files', () => {
    const zip = makeZip([
      { path: 'dir/', bytes: Buffer.alloc(0), store: true },
      { path: 'dir/a.js', bytes: Buffer.from('x') },
    ])
    const result = unzip(zip, LIMITS)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.files.map((file) => file.path)).toEqual(['dir/a.js'])
  })
})

describe('finding the manifest', () => {
  it('takes a manifest at the root', () => {
    const result = unzip(makeExtensionZip(plainManifest()), LIMITS)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(manifestPrefix(result.files)).toBe('')
  })

  it('unwraps a single top-level folder', () => {
    /*
     * uBlock Origin's release is shaped exactly like this — everything under
     * `uBlock0.chromium/`. An unpacker that assumed a root manifest would hand
     * `loadExtension` a directory with no manifest in it, and the error would be
     * about the directory rather than about the archive.
     */
    const result = unzip(makeExtensionZip(plainManifest(), [], 'uBlock0.chromium/'), LIMITS)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(manifestPrefix(result.files)).toBe('uBlock0.chromium/')
  })

  it('refuses to choose between two top-level folders', () => {
    // Not an extension with a wrapper — an archive containing an extension among
    // other things. Picking one is a guess, and a guess here decides what runs.
    const zip = makeZip([
      { path: 'one/manifest.json', bytes: Buffer.from('{}') },
      { path: 'two/manifest.json', bytes: Buffer.from('{}') },
    ])
    const result = unzip(zip, LIMITS)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(manifestPrefix(result.files)).toBeNull()
  })

  it('answers null when there is no manifest anywhere', () => {
    const result = unzip(makeZip([{ path: 'readme.txt', bytes: Buffer.from('hi') }]), LIMITS)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(manifestPrefix(result.files)).toBeNull()
  })
})
