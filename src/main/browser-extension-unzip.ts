import { inflateRawSync } from 'node:zlib'

/**
 * Reading a zip, byte by byte, with no dependency and no shelling out.
 *
 * ## Why this is written here rather than installed
 *
 * Because the only thing between a downloaded archive and this app's user data
 * directory is whatever unpacks it, and that is not a component to take on
 * somebody else's word. Three specific things have to be true and none of them
 * is the default in a general-purpose unzip:
 *
 *  1. **No entry may escape the destination.** A zip entry name is arbitrary
 *     text, and `../../.claude/settings.json` is a perfectly legal one. This is
 *     the oldest bug in archive handling and it is still the reason a store that
 *     unpacks downloads has to own its own unpacker. {@link safeEntryPath}
 *     refuses absolute paths, drive letters, backslashes, any `..` segment and
 *     any name with a NUL in it — and it refuses by name rather than by
 *     normalising, because normalising a hostile path produces a path.
 *  2. **No symlinks.** A zip records unix mode bits in its external attributes,
 *     and a symlink entry pointing at `~/.ssh` turns a later write into a write
 *     somewhere else entirely. Nothing here ever calls `symlink`, and an entry
 *     that says it is one is refused rather than written as a regular file
 *     containing a path.
 *  3. **A ceiling, on the decompressed size and on the count.** A few hundred
 *     kilobytes of zip can decompress to a disk-filling amount, and the ceiling
 *     has to be applied to what comes *out*, never to the archive's own claim
 *     about it — the same rule `httpsFetchBytes` states for `content-length`:
 *     *"a header is the server's claim and the cap has to hold against a server
 *     that lies."*
 *
 * `tar -xf` was the other option and it is worse on all three counts: it is a
 * different binary on macOS and Windows with different behaviour, it is happy to
 * write symlinks, and its refusals arrive as exit codes and locale-dependent
 * text rather than as a sentence this app can put on a row.
 *
 * ## Why the central directory and not the local headers
 *
 * A local file header is allowed to carry zeroes for the compressed and
 * uncompressed sizes and put the real values in a data descriptor *after* the
 * data — which is what a zip written by a streaming producer does, and both
 * uBlock Origin's and Violentmonkey's releases contain entries like that. A
 * reader that trusted local headers would read zero bytes for those files and
 * produce an extension that is missing exactly the parts that were streamed.
 * The central directory at the end of the file always carries the true sizes,
 * so it is the only thing read for them.
 */

/** One file, decompressed. Directories are not entries — they are made as needed. */
export interface ZipFile {
  path: string
  bytes: Buffer
}

export interface UnzipLimits {
  /** Most bytes the whole archive may decompress to. */
  maxTotalBytes: number
  /** Most files it may contain. */
  maxFiles: number
}

export type UnzipResult = { ok: true; files: ZipFile[] } | { ok: false; why: string }

const SIG_END = 0x06054b50
const SIG_END64_LOCATOR = 0x07064b50
const SIG_END64 = 0x06064b50
const SIG_CENTRAL = 0x02014b50
const SIG_LOCAL = 0x04034b50

const METHOD_STORE = 0
const METHOD_DEFLATE = 8

/**
 * Is this a path we are willing to write under a directory we own?
 *
 * Returns the cleaned relative path, or `null` to refuse. Refusing is always
 * correct here: an extension is a published artifact and none of these shapes
 * appears in a legitimate one, so there is nothing to lose by declining and a
 * user-data directory to lose by being clever.
 */
export function safeEntryPath(raw: string): string | null {
  if (raw === '' || raw.length > 512) return null
  if (raw.includes('\0')) return null
  // A backslash is a separator on Windows and a legal filename character on
  // POSIX, so a name containing one means two different trees depending on
  // where it is unpacked. Refused rather than translated.
  if (raw.includes('\\')) return null
  if (raw.startsWith('/')) return null
  if (/^[A-Za-z]:/.test(raw)) return null
  const parts = raw.split('/')
  for (const part of parts) {
    if (part === '..') return null
    // A `.` or an empty segment means the name is not in its simplest form, and
    // the simplest form is the only one this compares against.
    if (part === '.' || part === '') {
      // A single trailing empty segment is how a directory entry is written.
      if (part === '' && parts.indexOf(part) === parts.length - 1) continue
      return null
    }
  }
  return raw
}

/** Unix mode bits live in the top 16 of a zip's external attributes. */
function isSymlink(externalAttributes: number): boolean {
  const mode = (externalAttributes >>> 16) & 0xffff
  return (mode & 0xf000) === 0xa000
}

function findEndOfCentralDirectory(buffer: Buffer): number {
  // The end record is 22 bytes plus a comment of up to 65535, so it lives in
  // the last 64 KiB and is found by searching backwards for its signature.
  const from = Math.max(0, buffer.length - 22 - 0xffff)
  for (let at = buffer.length - 22; at >= from; at--) {
    if (buffer.readUInt32LE(at) === SIG_END) return at
  }
  return -1
}

/**
 * Where the central directory starts and how many entries it has.
 *
 * Zip64 is read because an extension release can carry more than 65535 files —
 * uBlock Origin Lite's is close — and the 16-bit count in the classic end record
 * wraps silently rather than failing. A wrapped count would unpack a fraction of
 * an extension and report success, which is the shape of quiet loss this
 * codebase keeps finding.
 */
function locateCentralDirectory(buffer: Buffer): { offset: number; count: number } | null {
  const end = findEndOfCentralDirectory(buffer)
  if (end < 0) return null
  let count = buffer.readUInt16LE(end + 10)
  let offset = buffer.readUInt32LE(end + 16)

  if (count === 0xffff || offset === 0xffffffff) {
    const locator = end - 20
    if (locator < 0 || buffer.readUInt32LE(locator) !== SIG_END64_LOCATOR) return null
    const end64 = Number(buffer.readBigUInt64LE(locator + 8))
    if (!Number.isSafeInteger(end64) || end64 < 0 || end64 + 56 > buffer.length) return null
    if (buffer.readUInt32LE(end64) !== SIG_END64) return null
    count = Number(buffer.readBigUInt64LE(end64 + 32))
    offset = Number(buffer.readBigUInt64LE(end64 + 48))
  }
  if (!Number.isSafeInteger(count) || !Number.isSafeInteger(offset)) return null
  if (offset < 0 || offset >= buffer.length) return null
  return { offset, count }
}

/**
 * Unpack an archive in memory.
 *
 * In memory because every caller already holds the whole archive: the digest has
 * to be computed over all of it before a single byte may be written, so there is
 * no streaming arrangement in which the bytes are not all present anyway.
 */
export function unzip(buffer: Buffer, limits: UnzipLimits): UnzipResult {
  const located = locateCentralDirectory(buffer)
  if (located === null) return { ok: false, why: 'it is not a zip archive' }
  if (located.count > limits.maxFiles) {
    return { ok: false, why: `it contains ${located.count} files, more than this app will unpack` }
  }

  const files: ZipFile[] = []
  let total = 0
  let at = located.offset

  for (let index = 0; index < located.count; index++) {
    if (at + 46 > buffer.length) return { ok: false, why: 'its index is truncated' }
    if (buffer.readUInt32LE(at) !== SIG_CENTRAL) return { ok: false, why: 'its index is damaged' }

    const method = buffer.readUInt16LE(at + 10)
    const flags = buffer.readUInt16LE(at + 8)
    let compressedSize = buffer.readUInt32LE(at + 20)
    let uncompressedSize = buffer.readUInt32LE(at + 24)
    const nameLength = buffer.readUInt16LE(at + 28)
    const extraLength = buffer.readUInt16LE(at + 30)
    const commentLength = buffer.readUInt16LE(at + 32)
    const externalAttributes = buffer.readUInt32LE(at + 38)
    let localOffset = buffer.readUInt32LE(at + 42)

    const nameAt = at + 46
    if (nameAt + nameLength > buffer.length) return { ok: false, why: 'its index is truncated' }
    const name = buffer.toString('utf8', nameAt, nameAt + nameLength)

    // Zip64 puts the real sizes in an extra field keyed 0x0001, in the order
    // uncompressed, compressed, offset — but *only* the ones whose 32-bit slot
    // was saturated, so the order is positional and the reads are conditional.
    if (uncompressedSize === 0xffffffff || compressedSize === 0xffffffff || localOffset === 0xffffffff) {
      let extraAt = nameAt + nameLength
      const extraEnd = extraAt + extraLength
      while (extraAt + 4 <= extraEnd && extraAt + 4 <= buffer.length) {
        const tag = buffer.readUInt16LE(extraAt)
        const size = buffer.readUInt16LE(extraAt + 2)
        let field = extraAt + 4
        if (tag === 0x0001) {
          if (uncompressedSize === 0xffffffff && field + 8 <= buffer.length) {
            uncompressedSize = Number(buffer.readBigUInt64LE(field))
            field += 8
          }
          if (compressedSize === 0xffffffff && field + 8 <= buffer.length) {
            compressedSize = Number(buffer.readBigUInt64LE(field))
            field += 8
          }
          if (localOffset === 0xffffffff && field + 8 <= buffer.length) {
            localOffset = Number(buffer.readBigUInt64LE(field))
          }
          break
        }
        extraAt += 4 + size
      }
    }

    at = nameAt + nameLength + extraLength + commentLength

    // A directory entry carries no data. Directories are created from the file
    // paths at write time, so nothing here needs them.
    if (name.endsWith('/')) continue

    const path = safeEntryPath(name)
    if (path === null) {
      return { ok: false, why: `it contains a file this app will not write: ${name.slice(0, 80)}` }
    }
    if (isSymlink(externalAttributes)) {
      return { ok: false, why: `it contains a symbolic link (${path}), which is not unpacked here` }
    }
    if (method !== METHOD_STORE && method !== METHOD_DEFLATE) {
      return { ok: false, why: `${path} uses a compression method this app cannot read` }
    }
    // Bit 0 of the flags is "encrypted". An encrypted entry decompresses to
    // rubbish rather than failing, so it is caught here rather than surfacing
    // later as a corrupt manifest.
    if ((flags & 0x1) !== 0) return { ok: false, why: 'it is encrypted' }

    if (!Number.isSafeInteger(uncompressedSize) || uncompressedSize < 0) {
      return { ok: false, why: `${path} declares an impossible size` }
    }
    total += uncompressedSize
    if (total > limits.maxTotalBytes) {
      return {
        ok: false,
        why: `it unpacks to more than ${limits.maxTotalBytes} bytes, which this app will not write`,
      }
    }

    if (localOffset + 30 > buffer.length) return { ok: false, why: `${path} points outside the file` }
    if (buffer.readUInt32LE(localOffset) !== SIG_LOCAL) {
      return { ok: false, why: `${path} has a damaged header` }
    }
    const localNameLength = buffer.readUInt16LE(localOffset + 26)
    const localExtraLength = buffer.readUInt16LE(localOffset + 28)
    const dataAt = localOffset + 30 + localNameLength + localExtraLength
    if (dataAt + compressedSize > buffer.length) {
      return { ok: false, why: `${path} runs past the end of the file` }
    }
    const raw = buffer.subarray(dataAt, dataAt + compressedSize)

    let bytes: Buffer
    if (method === METHOD_STORE) {
      bytes = Buffer.from(raw)
    } else {
      try {
        bytes = inflateRawSync(raw, { maxOutputLength: limits.maxTotalBytes })
      } catch {
        return { ok: false, why: `${path} could not be decompressed` }
      }
    }
    // The declared size is checked against what actually came out. They disagree
    // only when the archive is damaged or lying, and both are reasons not to
    // write it into an extension that is then going to run.
    if (bytes.byteLength !== uncompressedSize) {
      return { ok: false, why: `${path} is not the size the archive says it is` }
    }
    files.push({ path, bytes })
  }

  if (files.length === 0) return { ok: false, why: 'it contains no files' }
  return { ok: true, files }
}

/**
 * Where the manifest is, and what to strip off every path to get there.
 *
 * Release archives are written both ways and this is not a detail that can be
 * assumed: ClearURLs and Dark Reader put `manifest.json` at the root, and uBlock
 * Origin's release wraps everything in a single `uBlock0.chromium/` folder. An
 * unpacker that guessed wrong would hand `loadExtension` a directory with no
 * manifest in it, and the error would be about the directory rather than about
 * the archive.
 *
 * Only a **single** top-level directory is unwrapped. An archive with two of
 * them and a manifest inside one is not an extension with a wrapper — it is an
 * archive containing an extension among other things, and picking one is a guess
 * this refuses to make.
 */
export function manifestPrefix(files: readonly ZipFile[]): string | null {
  if (files.some((file) => file.path === 'manifest.json')) return ''
  const tops = new Set<string>()
  for (const file of files) {
    const slash = file.path.indexOf('/')
    if (slash < 0) return null
    tops.add(file.path.slice(0, slash))
  }
  if (tops.size !== 1) return null
  const [top] = [...tops]
  return files.some((file) => file.path === `${top}/manifest.json`) ? `${top}/` : null
}
