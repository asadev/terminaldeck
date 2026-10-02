import { gunzipSync } from 'node:zlib'
import { safeEntryPath, unzip, type UnzipLimits } from './browser-extension-unzip'

/**
 * Unpacking a community item's artifact, in the two shapes a repository serves.
 *
 * ## Why this file exists beside `browser-extension-unzip.ts`
 *
 * That module already reads a zip byte by byte, with no dependency and no
 * shelling out, and its header states the three rules that matter: no entry may
 * escape the destination, no symlinks, and a ceiling applied to what comes
 * *out* rather than to the archive's own claim about it. None of that is
 * rewritten here — `safeEntryPath` and `unzip` are imported and used exactly as
 * they are.
 *
 * What is new is the other shape. A repository host serves both
 * `/archive/<commit>.zip` and `/archive/<commit>.tar.gz` for the same commit,
 * the store's own catalogue may pin either, and an artifact whose bytes do not
 * match the reader we happen to have is an item that cannot be installed for a
 * reason nobody can act on. So the archive is identified by its first two bytes
 * — `PK` for a zip, `1f 8b` for a gzip — and never by the file name on the end
 * of a URL, which is a server's claim like any other.
 *
 * ## The tar rules, which are the zip rules restated for a different container
 *
 * A tar entry carries its own type byte, so the refusals are more explicit than
 * a zip's and there are more of them: a symlink, a hard link, a device node and
 * a fifo are all *entries a tar may legally contain* and none of them belongs in
 * a published item. Every one is a refusal of the whole archive rather than a
 * skipped entry, because an item that contains one is not the item its publisher
 * believes they published, and installing the rest of it silently is the shape
 * of bug that only shows up much later.
 *
 * Names go through the same `safeEntryPath` a zip entry goes through — an
 * absolute path, a `..` segment, a backslash, a NUL and an over-long name are
 * all refused *by name*, never by normalising, because normalising a hostile
 * path produces a path.
 *
 * ## The ceiling is applied twice, in two different places
 *
 * `gunzipSync` is given `maxOutputLength`, so a few hundred kilobytes that
 * decompress to a disk full of zeroes stops inside zlib rather than after. Then
 * the entries are counted and their sizes summed against the same limits the zip
 * path uses, because the tar *inside* the gzip carries its own claim about how
 * big each file is and that claim is checked against what is actually there.
 */

/** One file out of an artifact, with the mode the archive recorded for it. */
export interface ArchiveFile {
  /** Path inside the archive, `/`-separated, already checked by `safeEntryPath`. */
  path: string
  bytes: Buffer
  /**
   * The permission bits the archive carried, or `0` when it carried none.
   *
   * Zip entries reach this file through `unzip`, which does not surface the
   * external attributes, so every file out of a zip reports `0`. That is honest
   * rather than lossy: the tier rule reads the executable bit *and* the file
   * suffix, and the suffix is the half that decides for every real item — a
   * `.sh` in a zip is still a script here.
   */
  mode: number
}

export interface ArchiveLimits extends UnzipLimits {
  /** Most bytes the archive itself may be, before anything is decompressed. */
  maxArchiveBytes: number
}

export type ArchiveResult = { ok: true; files: ArchiveFile[] } | { ok: false; why: string }

/** A tar header block, and the whole format is multiples of it. */
const BLOCK = 512

/**
 * What the store will unpack for each kind, in bytes and in files.
 *
 * Two rows, not seven. Everything a person installs into an agent — a skill, a
 * set of instructions, a routine — is text and a handful of files, so the
 * ceiling that fits it is small enough that a hostile artifact is refused before
 * it costs anything. A browser extension is a program with a vendored runtime in
 * it and genuinely runs to tens of megabytes, which is why the extension store
 * already carries its own larger numbers.
 */
export const SMALL_ITEM_LIMITS: ArchiveLimits = Object.freeze({
  maxArchiveBytes: 2 * 1024 * 1024,
  maxTotalBytes: 16 * 1024 * 1024,
  maxFiles: 2_000,
})

/** The extension store's own ceilings, restated so both stores read one table. */
export const LARGE_ITEM_LIMITS: ArchiveLimits = Object.freeze({
  maxArchiveBytes: 32 * 1024 * 1024,
  maxTotalBytes: 256 * 1024 * 1024,
  maxFiles: 20_000,
})

/** Is this a gzip stream? Two bytes, and they are the only ones that say so. */
function isGzip(buffer: Buffer): boolean {
  return buffer.length > 2 && buffer[0] === 0x1f && buffer[1] === 0x8b
}

/** Is this a zip? The local file header signature, which every zip starts with. */
function isZip(buffer: Buffer): boolean {
  return buffer.length > 4 && buffer[0] === 0x50 && buffer[1] === 0x4b
}

/** An octal field, NUL- or space-terminated, as tar has written numbers since 1979. */
function octal(block: Buffer, at: number, length: number): number | null {
  let text = ''
  for (let i = at; i < at + length; i++) {
    const byte = block[i]
    if (byte === 0 || byte === 0x20) break
    text += String.fromCharCode(byte)
  }
  const trimmed = text.trim()
  if (trimmed === '') return 0
  if (!/^[0-7]+$/.test(trimmed)) return null
  const value = Number.parseInt(trimmed, 8)
  return Number.isSafeInteger(value) ? value : null
}

/** A NUL-terminated string field. */
function field(block: Buffer, at: number, length: number): string {
  const end = block.indexOf(0, at)
  const stop = end === -1 || end > at + length ? at + length : end
  return block.toString('utf8', at, stop)
}

/**
 * The header checksum, which is what tells a truncated download from a header.
 *
 * The eight checksum bytes are treated as spaces while the sum is taken, which
 * is the rule the format defines. Both the signed and unsigned sums are
 * accepted because historic writers disagreed about it and a reader that picks
 * one refuses perfectly good archives written by the other.
 */
function checksumOk(block: Buffer): boolean {
  const stated = octal(block, 148, 8)
  if (stated === null) return false
  let unsigned = 0
  let signed = 0
  for (let i = 0; i < BLOCK; i++) {
    const byte = i >= 148 && i < 156 ? 0x20 : block[i]
    unsigned += byte
    signed += byte > 127 ? byte - 256 : byte
  }
  return stated === unsigned || stated === signed
}

/**
 * The `path=` value out of a pax extended header, or null when it names none.
 *
 * A repository host writes one of these for every entry whose name is longer
 * than a hundred characters, and one global header at the top of the archive
 * carrying the commit. The format is a run of `<length> <key>=<value>\n`
 * records, where the length counts itself, so it is parsed rather than searched:
 * a `path=` appearing inside somebody's *value* is not a path.
 */
function paxPath(data: Buffer): string | null {
  let at = 0
  let found: string | null = null
  while (at < data.length) {
    const space = data.indexOf(0x20, at)
    if (space === -1) return found
    const length = Number.parseInt(data.toString('ascii', at, space), 10)
    if (!Number.isSafeInteger(length) || length <= 0 || at + length > data.length) return found
    const record = data.toString('utf8', space + 1, at + length).replace(/\n$/, '')
    const equals = record.indexOf('=')
    if (equals > 0 && record.slice(0, equals) === 'path') found = record.slice(equals + 1)
    at += length
  }
  return found
}

/**
 * Read a gzipped tar, refusing everything that is not a plain file or a folder.
 *
 * Never throws. Every refusal is a sentence a row can print, because the person
 * pressing Install is the one who has to decide what to do about it, and "read
 * of undefined" is not a decision anybody can make.
 */
export function readTarGz(buffer: Buffer, limits: ArchiveLimits): ArchiveResult {
  let tar: Buffer
  try {
    tar = gunzipSync(buffer, { maxOutputLength: limits.maxTotalBytes })
  } catch {
    return { ok: false, why: 'this archive could not be unpacked, or it unpacks to more than this app will read' }
  }

  const files: ArchiveFile[] = []
  let total = 0
  let at = 0
  /** A `L` or `x` header sets the next entry's name and is not an entry itself. */
  let pendingName: string | null = null

  while (at + BLOCK <= tar.length) {
    const header = tar.subarray(at, at + BLOCK)
    at += BLOCK

    // Two consecutive zero blocks end the archive; one on its own is padding.
    if (header.every((byte) => byte === 0)) continue

    if (!checksumOk(header)) {
      return { ok: false, why: 'this archive is damaged: one of its file headers does not add up' }
    }

    const size = octal(header, 124, 12)
    const mode = octal(header, 100, 8)
    if (size === null || mode === null) {
      return { ok: false, why: 'this archive is damaged: a file in it has no readable size' }
    }
    const dataAt = at
    at += Math.ceil(size / BLOCK) * BLOCK
    if (dataAt + size > tar.length) {
      return { ok: false, why: 'this archive is cut short: a file in it claims more bytes than are there' }
    }

    const type = String.fromCharCode(header[156] === 0 ? 0x30 : header[156])

    if (type === 'x' || type === 'g') {
      // An extended header describes the entry after it (`x`) or the whole
      // archive (`g`). Only a longer name is taken from it; every other pax
      // record is metadata this app has no use for.
      const named = paxPath(tar.subarray(dataAt, dataAt + size))
      if (type === 'x' && named !== null) pendingName = named
      continue
    }
    if (type === 'L') {
      pendingName = tar.toString('utf8', dataAt, dataAt + size).replace(/\0+$/, '')
      continue
    }
    if (type === '2' || type === '1') {
      return {
        ok: false,
        why: 'this archive contains a link, and a link points somewhere this app did not check. Nothing was unpacked.',
      }
    }
    if (type === '3' || type === '4' || type === '6' || type === '7') {
      return { ok: false, why: 'this archive contains something that is not a file or a folder. Nothing was unpacked.' }
    }

    const prefix = field(header, 345, 155)
    const raw = pendingName ?? (prefix === '' ? field(header, 0, 100) : `${prefix}/${field(header, 0, 100)}`)
    pendingName = null

    if (type === '5') continue // A folder. Folders are made as they are needed.
    if (type !== '0') {
      return { ok: false, why: 'this archive contains something that is not a file or a folder. Nothing was unpacked.' }
    }

    const safe = safeEntryPath(raw)
    if (safe === null || safe.endsWith('/')) {
      return { ok: false, why: `this archive contains a name this app will not write: ${raw.slice(0, 80)}` }
    }

    total += size
    if (total > limits.maxTotalBytes) {
      return { ok: false, why: 'this archive unpacks to more than this app will read' }
    }
    if (files.length >= limits.maxFiles) {
      return { ok: false, why: 'this archive contains more files than this app will read' }
    }
    files.push({ path: safe, bytes: Buffer.from(tar.subarray(dataAt, dataAt + size)), mode: mode & 0o7777 })
  }

  if (files.length === 0) return { ok: false, why: 'this archive has nothing in it' }
  return { ok: true, files }
}

/**
 * Unpack an artifact, whichever of the two shapes it arrived in.
 *
 * The archive's own size is checked here rather than by the caller because it is
 * the cheapest refusal there is and it has to happen before anything is
 * decompressed. The digest check has already happened by the time this runs —
 * see `store-install.ts` — so these bytes are the bytes the catalogue named;
 * this is what stops a *correctly fingerprinted* archive from being a bomb.
 */
export function readArchive(buffer: Buffer, limits: ArchiveLimits): ArchiveResult {
  if (buffer.byteLength > limits.maxArchiveBytes) {
    return { ok: false, why: 'this download is larger than this app will unpack' }
  }
  if (isGzip(buffer)) return readTarGz(buffer, limits)
  if (isZip(buffer)) {
    const unpacked = unzip(buffer, { maxTotalBytes: limits.maxTotalBytes, maxFiles: limits.maxFiles })
    if (!unpacked.ok) return unpacked
    return { ok: true, files: unpacked.files.map((file) => ({ path: file.path, bytes: file.bytes, mode: 0 })) }
  }
  return { ok: false, why: 'this download is not an archive this app can open' }
}

/**
 * Drop the single wrapper folder a repository archive puts everything inside.
 *
 * Every host does it and every host names it differently —
 * `<repo>-<commit>/`, `<repo>-<tag>/` — so the folder is found rather than
 * predicted: if every path in the archive starts with the same first segment,
 * that segment is the wrapper. When they do not agree, nothing is stripped,
 * because an archive with two top-level folders has no wrapper to remove and
 * guessing at one would silently install half an item.
 */
export function stripSingleRoot(files: readonly ArchiveFile[]): ArchiveFile[] {
  if (files.length === 0) return []
  const first = files[0].path.split('/')[0]
  if (first === '' || !files.every((file) => file.path.startsWith(`${first}/`))) return [...files]
  return files.map((file) => ({ ...file, path: file.path.slice(first.length + 1) }))
}

/**
 * The files under one folder of the item, with that folder taken off the front.
 *
 * `.` means the whole tree, which is what the manifest grammar already spells it
 * as. A path that matches nothing comes back empty and the caller says so by
 * name — an item whose manifest points at a folder its own archive does not
 * contain is a publishing mistake, and the person installing it can only act on
 * it if the message names the folder.
 */
export function filesUnder(files: readonly ArchiveFile[], dir: string): ArchiveFile[] {
  if (dir === '.' || dir === '') return [...files]
  const prefix = `${dir.replace(/\/+$/, '')}/`
  return files
    .filter((file) => file.path.startsWith(prefix))
    .map((file) => ({ ...file, path: file.path.slice(prefix.length) }))
}

/** One file by its exact path inside the item, or null. */
export function fileAt(files: readonly ArchiveFile[], path: string): ArchiveFile | null {
  return files.find((file) => file.path === path) ?? null
}
