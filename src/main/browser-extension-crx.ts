import { createHash, createPublicKey, createVerify } from 'node:crypto'

/**
 * Opening a `.crx` — a signed header in front of an ordinary zip.
 *
 * ## Why this exists at all, when the store refuses `.crx` everywhere else
 *
 *   > *"'Add your own': load an unpacked extension from a folder / a .crx the
 *   > person supplies."*
 *
 * The catalogue's rule — no row may point at a `.crx` — is about **fetching**,
 * and it does not move: a row is bytes pulled off somebody else's release page,
 * and the only thing that makes that safe is a fingerprint pinned in this app.
 * A file already on this person's disk is a different question with a different
 * answer. They chose it, in a file dialog, and this app's job there is to open
 * it honestly and say what it does and does not know about it.
 *
 * Electron cannot be handed a `.crx` — `loadExtension` takes a directory, and a
 * `.crx` produces *"Extension directory not found"*. So this module does the one
 * thing that makes the file usable: reads the CRX3 envelope, checks the
 * signature inside it against the payload, and hands back the zip.
 *
 * ## What the signature proves, and what it does not
 *
 * This is the sentence that has to be right, because it is the one a person will
 * lean on.
 *
 * **It proves the file has not changed since whoever packed it signed it.** The
 * proof is over the payload, so a byte flipped anywhere in the zip fails it.
 *
 * **It does not say who that was.** A `.crx` is self-signed: the public key
 * travels inside the file next to the signature it verifies. Anybody can pack
 * and sign anything, and this check would pass every time. There is no authority
 * here to ask, because Chrome's is the Web Store and this app is not talking to
 * it. So {@link openCrx} answers with the **crx id** — which is a fingerprint of
 * the signing key, and is what a person can compare against a Web Store URL if
 * they have one — and never with a word like "trusted".
 *
 * A `.crx` whose signature does **not** verify is refused outright. Not because
 * a valid signature means much, but because an invalid one means exactly one
 * thing: the file is not what its own packer made, and no reason to open it
 * survives that.
 *
 * ## The format, as implemented
 *
 * ```
 *   "Cr24"                    4 bytes
 *   version                   uint32 LE, must be 3
 *   header length             uint32 LE
 *   header                    CrxFileHeader, protobuf
 *   payload                   the zip, to the end of the file
 * ```
 *
 * `CrxFileHeader` carries repeated `sha256_with_rsa` (field 2) and
 * `sha256_with_ecdsa` (field 3) proofs, each an `AsymmetricKeyProof` of
 * `public_key` (field 1) and `signature` (field 2), plus `signed_header_data`
 * (field 10000) which is a `SignedData` holding `crx_id` (field 1).
 *
 * What is signed is not the file: it is
 *
 * ```
 *   "CRX3 SignedData\0"  +  uint32 LE length of signed_header_data
 *                        +  signed_header_data  +  payload
 * ```
 *
 * Getting that prefix wrong produces a module that refuses every real `.crx`
 * while looking correct, which is why it is written out here rather than left
 * implicit in the code.
 *
 * **CRX2 is refused.** Chrome stopped producing it in 2019 and its envelope is a
 * different shape; a file that old is more likely to be a mystery than a
 * convenience, and refusing it with a sentence naming the version is a better
 * answer than half-supporting it.
 */

/** The 16-byte prefix the signature is taken over. `CRX3 SignedData` and a NUL. */
const SIGNED_PREFIX = Buffer.concat([Buffer.from('CRX3 SignedData', 'ascii'), Buffer.from([0])])

/** Chrome's alphabet for an extension id: the hex digits mapped onto `a`–`p`. */
const ID_ALPHABET = 'abcdefghijklmnop'

export interface CrxOpened {
  /** The zip inside, ready for `unzip`. */
  zip: Buffer
  /**
   * The id Chrome would give it: the first 16 bytes of the signing key's sha256,
   * in Chrome's `a`–`p` alphabet. A person can compare it with a Web Store URL.
   */
  crxId: string
  /** Which proof verified: `rsa` or `ecdsa`. */
  algorithm: 'rsa' | 'ecdsa'
  /** True when the id in the signed header matches the key that signed it. */
  idMatchesKey: boolean
}

export type CrxResult = { ok: true; crx: CrxOpened } | { ok: false; why: string }

/* ------------------------------------------------------------- protobuf -- */

interface Field {
  number: number
  bytes: Buffer
}

/**
 * Read the length-delimited fields of a protobuf message, and skip the rest.
 *
 * Deliberately not a protobuf library. Three field numbers are read here and
 * every other wire type is stepped over; a dependency that could parse anything
 * would be a larger surface than the format this file actually meets.
 */
function readFields(buffer: Buffer): Field[] | null {
  const out: Field[] = []
  let at = 0
  while (at < buffer.length) {
    let key = 0
    let shift = 0
    for (;;) {
      if (at >= buffer.length || shift > 35) return null
      const byte = buffer[at++] as number
      key |= (byte & 0x7f) * 2 ** shift
      shift += 7
      if ((byte & 0x80) === 0) break
    }
    const number = Math.floor(key / 8)
    const wire = key % 8
    if (wire === 2) {
      let length = 0
      let lengthShift = 0
      for (;;) {
        if (at >= buffer.length || lengthShift > 35) return null
        const byte = buffer[at++] as number
        length += (byte & 0x7f) * 2 ** lengthShift
        lengthShift += 7
        if ((byte & 0x80) === 0) break
      }
      if (length < 0 || at + length > buffer.length) return null
      out.push({ number, bytes: buffer.subarray(at, at + length) })
      at += length
    } else if (wire === 0) {
      for (;;) {
        if (at >= buffer.length) return null
        if (((buffer[at++] as number) & 0x80) === 0) break
      }
    } else if (wire === 5) {
      at += 4
    } else if (wire === 1) {
      at += 8
    } else {
      // Groups (3 and 4) and anything unknown. A CRX header has none, and
      // guessing at a length here would be how a malformed file walks off the
      // end of the buffer.
      return null
    }
    if (at > buffer.length) return null
  }
  return out
}

/** The id Chrome derives from a signing key: sha256, first 16 bytes, into `a`–`p`. */
export function crxIdFor(publicKey: Buffer): string {
  const digest = createHash('sha256').update(publicKey).digest().subarray(0, 16)
  let out = ''
  for (const byte of digest) {
    out += ID_ALPHABET[byte >> 4]
    out += ID_ALPHABET[byte & 0x0f]
  }
  return out
}

/* ----------------------------------------------------------------- open -- */

/**
 * Open a `.crx`, or say exactly which check refused it.
 *
 * Every refusal names the thing that gave way — the magic, the version, the
 * header, the proofs, the signature — because *"it could not be opened"* is the
 * sentence this whole store was written to replace.
 */
export function openCrx(bytes: Buffer): CrxResult {
  if (bytes.length < 16) return { ok: false, why: 'the file is too short to be a .crx' }
  if (bytes.subarray(0, 4).toString('ascii') !== 'Cr24') {
    return { ok: false, why: 'the file does not begin with Cr24, so it is not a .crx at all' }
  }
  const version = bytes.readUInt32LE(4)
  if (version === 2) {
    return {
      ok: false,
      why:
        'it is a CRX2 file. Chrome stopped making those in 2019 and this app does not open them — ' +
        'unzip it yourself and add the folder instead',
    }
  }
  if (version !== 3) {
    return { ok: false, why: `it says it is CRX version ${version}, and this app opens version 3` }
  }
  const headerLength = bytes.readUInt32LE(8)
  if (headerLength <= 0 || 12 + headerLength > bytes.length) {
    return { ok: false, why: 'its header length points past the end of the file' }
  }
  const header = bytes.subarray(12, 12 + headerLength)
  const payload = bytes.subarray(12 + headerLength)
  if (payload.length === 0) return { ok: false, why: 'there is nothing after its header' }

  const fields = readFields(header)
  if (fields === null) return { ok: false, why: 'its header is not a CRX3 header' }

  const signedHeaderData = fields.find((field) => field.number === 10000)?.bytes
  if (signedHeaderData === undefined) {
    return { ok: false, why: 'its header carries no signed data, so there is nothing to check' }
  }

  /*
   * The exact bytes the signature was taken over. Built once and reused for
   * every proof: two proofs disagreeing about what was signed would be a bug
   * that only shows up on multiply-signed files, which are the rare ones.
   */
  const lengthLE = Buffer.alloc(4)
  lengthLE.writeUInt32LE(signedHeaderData.length, 0)
  const signed = Buffer.concat([SIGNED_PREFIX, lengthLE, signedHeaderData, payload])

  const declaredId = (() => {
    const inner = readFields(signedHeaderData)
    const raw = inner?.find((field) => field.number === 1)?.bytes
    if (raw === undefined || raw.length !== 16) return ''
    let out = ''
    for (const byte of raw) {
      out += ID_ALPHABET[byte >> 4]
      out += ID_ALPHABET[byte & 0x0f]
    }
    return out
  })()

  let sawAProof = false
  for (const [number, algorithm] of [
    [2, 'rsa'],
    [3, 'ecdsa'],
  ] as const) {
    for (const proof of fields.filter((field) => field.number === number)) {
      const parts = readFields(proof.bytes)
      if (parts === null) continue
      const publicKey = parts.find((part) => part.number === 1)?.bytes
      const signature = parts.find((part) => part.number === 2)?.bytes
      if (publicKey === undefined || signature === undefined) continue
      sawAProof = true
      let ok = false
      try {
        const key = createPublicKey({ key: publicKey, format: 'der', type: 'spki' })
        const verifier = createVerify('sha256')
        verifier.update(signed)
        verifier.end()
        ok = verifier.verify(key, signature)
      } catch {
        // A key this build of Node cannot read is a proof that did not verify.
        // Trying the next one is right; treating it as a pass never is.
        ok = false
      }
      if (!ok) continue
      const keyId = crxIdFor(publicKey)
      return {
        ok: true,
        crx: {
          zip: Buffer.from(payload),
          crxId: keyId,
          algorithm,
          idMatchesKey: declaredId === '' || declaredId === keyId,
        },
      }
    }
  }

  return {
    ok: false,
    why: sawAProof
      ? 'its signature does not match its contents — the file is not what whoever packed it signed'
      : 'it carries no signature this app can read',
  }
}
