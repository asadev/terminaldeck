import { createHash, createSign, generateKeyPairSync } from 'node:crypto'
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

/* --------------------------------------------------------------- a .crx -- */

function varint(value: number): Buffer {
  const out: number[] = []
  let left = value
  while (left > 0x7f) {
    out.push((left & 0x7f) | 0x80)
    left = Math.floor(left / 128)
  }
  out.push(left)
  return Buffer.from(out)
}

/** One length-delimited protobuf field: `(number << 3) | 2`, length, bytes. */
function field(number: number, bytes: Buffer): Buffer {
  return Buffer.concat([varint(number * 8 + 2), varint(bytes.length), bytes])
}

const SIGNED_PREFIX = Buffer.concat([Buffer.from('CRX3 SignedData', 'ascii'), Buffer.from([0])])

export interface PackedCrx {
  crx: Buffer
  /** The id the signing key yields, in Chrome's `a`–`p` alphabet. */
  id: string
  /** The zip that went in, for tests that swap payloads about. */
  zip: Buffer
}

/**
 * Pack a zip into a real, signed CRX3.
 *
 * Signed with a freshly generated key over the real prefix, rather than checked
 * in as bytes, for the reason `browser-extension-crx.test.ts` gives: a fixture
 * built by the same misunderstanding as the reader would agree with it, and the
 * two would be wrong together about every genuine `.crx` in the world.
 */
export function makeSignedCrx(zip: Buffer, options: { wrongId?: boolean } = {}): PackedCrx {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 })
  const spki = Buffer.from(publicKey.export({ type: 'spki', format: 'der' }))
  const digest = createHash('sha256').update(spki).digest().subarray(0, 16)
  const alphabet = 'abcdefghijklmnop'
  let id = ''
  for (const byte of digest) id += alphabet[byte >> 4] + alphabet[byte & 0x0f]

  const signedHeaderData = field(1, options.wrongId === true ? Buffer.alloc(16, 7) : digest)
  const lengthLE = Buffer.alloc(4)
  lengthLE.writeUInt32LE(signedHeaderData.length, 0)
  const signer = createSign('sha256')
  signer.update(Buffer.concat([SIGNED_PREFIX, lengthLE, signedHeaderData, zip]))
  signer.end()
  const signature = signer.sign(privateKey)

  const proof = Buffer.concat([field(1, spki), field(2, signature)])
  const header = Buffer.concat([field(2, proof), field(10000, signedHeaderData)])
  const front = Buffer.alloc(12)
  front.write('Cr24', 0, 'ascii')
  front.writeUInt32LE(3, 4)
  front.writeUInt32LE(header.length, 8)
  return { crx: Buffer.concat([front, header, zip]), id, zip }
}
