import { createHash, createSign, generateKeyPairSync } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import { crxIdFor, openCrx } from './browser-extension-crx'
import { makeExtensionZip, plainManifest } from './browser-extension-zip.fixture'

/**
 * The `.crx` reader, tested by **packing one and opening it**.
 *
 * A test that asserted on a fixture checked in as bytes would be pinning
 * whatever this module happened to do the day the fixture was made. Signing a
 * real RSA key over the real prefix is the only way to find out whether the
 * prefix is right — and the prefix is the whole file: get it wrong and the
 * module refuses every genuine `.crx` in the world while looking perfectly
 * correct against any fixture built by the same mistake.
 *
 * The tampering tests are the ones that matter most. `openCrx` answering *yes*
 * to a modified file would be worse than having no signature check at all,
 * because the sentence beside it in `StorePanel.tsx` tells somebody the file
 * has not changed since it was packed.
 */

/* -------------------------------------------------------------- protobuf -- */

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

/** One length-delimited field: `(number << 3) | 2`, then the length, then bytes. */
function field(number: number, bytes: Buffer): Buffer {
  return Buffer.concat([varint(number * 8 + 2), varint(bytes.length), bytes])
}

const SIGNED_PREFIX = Buffer.concat([Buffer.from('CRX3 SignedData', 'ascii'), Buffer.from([0])])

interface Packed {
  crx: Buffer
  id: string
  zip: Buffer
}

/** Pack a zip into a signed CRX3, the way `crx3` and Chrome itself do. */
function packCrx(zip: Buffer, options: { declaredId?: string | null } = {}): Packed {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 })
  const spki = publicKey.export({ type: 'spki', format: 'der' })
  const id = crxIdFor(Buffer.from(spki))
  const crxIdBytes = createHash('sha256').update(spki).digest().subarray(0, 16)
  const declared =
    options.declaredId === null
      ? Buffer.alloc(0)
      : field(1, options.declaredId === undefined ? crxIdBytes : Buffer.alloc(16, 7))
  const signedHeaderData = declared

  const lengthLE = Buffer.alloc(4)
  lengthLE.writeUInt32LE(signedHeaderData.length, 0)
  const signer = createSign('sha256')
  signer.update(Buffer.concat([SIGNED_PREFIX, lengthLE, signedHeaderData, zip]))
  signer.end()
  const signature = signer.sign(privateKey)

  const proof = Buffer.concat([field(1, Buffer.from(spki)), field(2, signature)])
  const header = Buffer.concat([field(2, proof), field(10000, signedHeaderData)])

  const front = Buffer.alloc(12)
  front.write('Cr24', 0, 'ascii')
  front.writeUInt32LE(3, 4)
  front.writeUInt32LE(header.length, 8)
  return { crx: Buffer.concat([front, header, zip]), id, zip }
}

const ZIP = makeExtensionZip(plainManifest())

/* ----------------------------------------------------------------- tests -- */

describe('a real signed .crx', () => {
  it('opens, and hands back the zip that was inside it', () => {
    const packed = packCrx(ZIP)
    const opened = openCrx(packed.crx)
    expect(opened.ok).toBe(true)
    if (!opened.ok) return
    // Byte-for-byte, because what comes out of here is unpacked and then run.
    expect(opened.crx.zip.equals(ZIP)).toBe(true)
    expect(opened.crx.algorithm).toBe('rsa')
  })

  it('answers with the id Chrome would give it, derived from the signing key', () => {
    /*
     * The one checkable thing about a `.crx`, and the only reason it is worth
     * showing: it is the id in a Chrome Web Store URL, so somebody who has one
     * can compare. Thirty-two characters, all inside Chrome's own a–p alphabet.
     */
    const packed = packCrx(ZIP)
    const opened = openCrx(packed.crx)
    expect(opened.ok).toBe(true)
    if (!opened.ok) return
    expect(opened.crx.crxId).toBe(packed.id)
    expect(opened.crx.crxId).toMatch(/^[a-p]{32}$/)
    expect(opened.crx.idMatchesKey).toBe(true)
  })

  it('notices when the id in the signed header is not the signing key’s', () => {
    // Signed correctly, but claiming to be something else. Not a refusal — the
    // signature is real — and not silence either, because the id is the thing
    // the row invites somebody to compare.
    const packed = packCrx(ZIP, { declaredId: 'mismatched' })
    const opened = openCrx(packed.crx)
    expect(opened.ok).toBe(true)
    if (!opened.ok) return
    expect(opened.crx.idMatchesKey).toBe(false)
  })
})

describe('a .crx that is not what it was when it was packed', () => {
  it('is refused when a byte of the payload changed', () => {
    const packed = packCrx(ZIP)
    const tampered = Buffer.from(packed.crx)
    tampered[tampered.length - 20] ^= 0xff
    const opened = openCrx(tampered)
    expect(opened.ok).toBe(false)
    if (opened.ok) return
    expect(opened.why).toContain('signature does not match')
  })

  it('is refused when the payload is replaced wholesale', () => {
    /*
     * The attack the check exists for: keep the header, swap the extension.
     * Anything that verified this would be worse than no check at all, because
     * the row beside it says the file has not changed since it was packed.
     */
    const packed = packCrx(ZIP)
    const other = makeExtensionZip(plainManifest({ name: 'Something Else' }))
    const header = packed.crx.subarray(0, packed.crx.length - packed.zip.length)
    const opened = openCrx(Buffer.concat([header, other]))
    expect(opened.ok).toBe(false)
  })

  it('is refused when one file’s header is put in front of another’s payload', () => {
    /*
     * Two real files, and the pair is not real. Worth being exact about what
     * this proves and what it cannot: if both payloads were **identical** the
     * swap would verify, and correctly so — that second signature genuinely is
     * over those bytes by that key. What the signature says is *this payload was
     * signed by this key*, never *this payload belongs with this header*, and
     * the row's wording is written to that.
     */
    const other = makeExtensionZip(plainManifest({ name: 'Something Else' }))
    const first = packCrx(ZIP)
    const second = packCrx(other)
    expect(first.id).not.toBe(second.id)
    const secondHeader = second.crx.subarray(0, second.crx.length - second.zip.length)
    expect(openCrx(Buffer.concat([secondHeader, ZIP])).ok).toBe(false)
  })
})

describe('a file that is not a CRX3 at all', () => {
  it('says so when it does not begin with Cr24', () => {
    const opened = openCrx(Buffer.concat([Buffer.from('PK'), ZIP]))
    expect(opened.ok).toBe(false)
    if (opened.ok) return
    expect(opened.why).toContain('not a .crx')
  })

  it('names the version when it is the old CRX2 shape', () => {
    /*
     * Chrome stopped making these in 2019. Refused with the version in the
     * sentence and a way forward — unzip it and add the folder — rather than
     * with "it could not be opened", which is the sentence this whole store was
     * written to replace.
     */
    const front = Buffer.alloc(16)
    front.write('Cr24', 0, 'ascii')
    front.writeUInt32LE(2, 4)
    const opened = openCrx(Buffer.concat([front, ZIP]))
    expect(opened.ok).toBe(false)
    if (opened.ok) return
    expect(opened.why).toContain('CRX2')
    expect(opened.why).toContain('add the folder')
  })

  it('refuses a header length that points past the end', () => {
    const front = Buffer.alloc(12)
    front.write('Cr24', 0, 'ascii')
    front.writeUInt32LE(3, 4)
    front.writeUInt32LE(0xffffff, 8)
    const opened = openCrx(Buffer.concat([front, Buffer.alloc(64)]))
    expect(opened.ok).toBe(false)
    if (opened.ok) return
    expect(opened.why).toContain('past the end')
  })

  it('refuses a header with no signature in it', () => {
    const header = field(10000, Buffer.alloc(0))
    const front = Buffer.alloc(12)
    front.write('Cr24', 0, 'ascii')
    front.writeUInt32LE(3, 4)
    front.writeUInt32LE(header.length, 8)
    const opened = openCrx(Buffer.concat([front, header, ZIP]))
    expect(opened.ok).toBe(false)
    if (opened.ok) return
    expect(opened.why).toContain('no signature')
  })

  it('refuses a truncated file rather than reading off the end of it', () => {
    const packed = packCrx(ZIP)
    for (const length of [0, 4, 11, 15, 32]) {
      expect(openCrx(packed.crx.subarray(0, length)).ok, `${length} bytes`).toBe(false)
    }
  })

  it('refuses random bytes wearing the right magic', () => {
    // The fuzz case: a header length that parses, and a header that is not a
    // protobuf. `readFields` must answer null rather than walk off the buffer.
    const body = Buffer.alloc(200)
    for (let index = 0; index < body.length; index++) body[index] = (index * 37 + 11) % 256
    const front = Buffer.alloc(12)
    front.write('Cr24', 0, 'ascii')
    front.writeUInt32LE(3, 4)
    front.writeUInt32LE(100, 8)
    expect(openCrx(Buffer.concat([front, body])).ok).toBe(false)
  })
})
