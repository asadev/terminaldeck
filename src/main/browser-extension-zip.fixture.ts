import { deflateRawSync } from 'node:zlib'

/**
 * A zip writer, for tests only.
 *
 * Nothing in the app imports this and nothing should: the app **reads** zips and
 * never writes one. It exists because `browser-extension-unzip.ts` is the only
 * thing standing between a downloaded archive and `<userData>`, and testing it
 * against archives checked into the repository would test six fixed files rather
 * than the reader — the interesting cases are the ones no real extension ships,
 * like an entry called `../../escape` or one whose mode bits say symlink.
 *
 * It is a separate module rather than a helper inside a `.test.ts` because
 * importing one test file from another registers its `describe` blocks twice.
 *
 * Deliberately minimal and deliberately *able to write malformed archives*: a
 * fixture that could only produce valid zips could not test a single refusal.
 */

export interface ZipEntry {
  path: string
  bytes: Buffer
  /** Store instead of deflate, to cover the other method the reader accepts. */
  store?: boolean
  /** Unix mode bits for the external attributes — `0o120777` makes a symlink. */
  mode?: number
  /**
   * Claim a different uncompressed size in the index than the data really is.
   *
   * The reader compares the two and refuses when they disagree, which is the
   * check that catches a damaged or lying archive before its bytes are written
   * into something that is then going to run.
   */
  lieAboutSize?: number
}

function crc32(buffer: Buffer): number {
  let crc = 0xffffffff
  for (const byte of buffer) {
    crc ^= byte
    for (let bit = 0; bit < 8; bit++) {
      crc = crc & 1 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1
    }
  }
  return (crc ^ 0xffffffff) >>> 0
}

/** Build a zip archive in memory. */
export function makeZip(entries: readonly ZipEntry[]): Buffer {
  const locals: Buffer[] = []
  const central: Buffer[] = []
  let offset = 0

  for (const entry of entries) {
    const name = Buffer.from(entry.path, 'utf8')
    const store = entry.store === true
    const data = store ? entry.bytes : deflateRawSync(entry.bytes)
    const declared = entry.lieAboutSize ?? entry.bytes.byteLength

    const local = Buffer.alloc(30)
    local.writeUInt32LE(0x04034b50, 0)
    local.writeUInt16LE(20, 4)
    local.writeUInt16LE(0, 6)
    local.writeUInt16LE(store ? 0 : 8, 8)
    local.writeUInt16LE(0, 10)
    local.writeUInt16LE(0, 12)
    local.writeUInt32LE(crc32(entry.bytes), 14)
    local.writeUInt32LE(data.byteLength, 18)
    local.writeUInt32LE(declared, 22)
    local.writeUInt16LE(name.byteLength, 26)
    local.writeUInt16LE(0, 28)
    locals.push(local, name, data)

    const head = Buffer.alloc(46)
    head.writeUInt32LE(0x02014b50, 0)
    head.writeUInt16LE(20, 4)
    head.writeUInt16LE(20, 6)
    head.writeUInt16LE(0, 8)
    head.writeUInt16LE(store ? 0 : 8, 10)
    head.writeUInt16LE(0, 12)
    head.writeUInt16LE(0, 14)
    head.writeUInt32LE(crc32(entry.bytes), 16)
    head.writeUInt32LE(data.byteLength, 20)
    head.writeUInt32LE(declared, 24)
    head.writeUInt16LE(name.byteLength, 28)
    head.writeUInt16LE(0, 30)
    head.writeUInt16LE(0, 32)
    head.writeUInt16LE(0, 34)
    head.writeUInt16LE(0, 36)
    head.writeUInt32LE(((entry.mode ?? 0o100644) << 16) >>> 0, 38)
    head.writeUInt32LE(offset, 42)
    central.push(head, name)

    offset += local.byteLength + name.byteLength + data.byteLength
  }

  const body = Buffer.concat(locals)
  const index = Buffer.concat(central)
  const end = Buffer.alloc(22)
  end.writeUInt32LE(0x06054b50, 0)
  end.writeUInt16LE(0, 4)
  end.writeUInt16LE(0, 6)
  end.writeUInt16LE(entries.length, 8)
  end.writeUInt16LE(entries.length, 10)
  end.writeUInt32LE(index.byteLength, 12)
  end.writeUInt32LE(body.byteLength, 16)
  end.writeUInt16LE(0, 20)
  return Buffer.concat([body, index, end])
}

/** A minimal working extension, as an archive. */
export function makeExtensionZip(
  manifest: Record<string, unknown>,
  extra: readonly ZipEntry[] = [],
  prefix = '',
): Buffer {
  return makeZip([
    { path: `${prefix}manifest.json`, bytes: Buffer.from(JSON.stringify(manifest), 'utf8') },
    ...extra.map((entry) => ({ ...entry, path: `${prefix}${entry.path}` })),
  ])
}

/** The manifest most tests want: MV3, loads, asks for nothing missing. */
export function plainManifest(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    manifest_version: 3,
    name: 'Test Extension',
    version: '1.0.0',
    permissions: ['storage'],
    host_permissions: ['https://example.com/*'],
    ...over,
  }
}
