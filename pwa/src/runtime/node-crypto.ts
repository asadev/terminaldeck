/**
 * `node:crypto`, as far as the shared crypto reaches for it, in a browser.
 *
 * ## What this is, and the thing it is deliberately not
 *
 * `src/shared/sealed.ts` is the sealed channel: Noise IK, the key schedule, the
 * transcript hash, the nonce discipline, the difference between a refusal and a
 * fault. That file has exactly one implementation and this module does not add a
 * second one. The browser client imports *that* file, unchanged, and runs the
 * same bytes the desktop runs — which is the whole point, because a second
 * handshake written for the browser would be a handshake that agrees with itself
 * and drifts from every other client in the product.
 *
 * What a browser cannot do is `import { createHash } from 'node:crypto'`. So
 * this module is the *primitive floor* under that file and nothing above it:
 * SHA-256, HKDF, X25519, a CSPRNG and a constant-time compare. `pwa/vite.config.ts`
 * aliases `node:crypto` here for the browser bundle, and `pwa/tsconfig.json`
 * maps the same specifier so the compiler checks the shared code against these
 * signatures rather than against Node's.
 *
 * ## Why this is not the mistake the ChaCha comment warns about
 *
 * `sealed.ts` says it at length: there is no "use the native one when it is
 * there" fast path, because a fallback means the suite exercises one
 * implementation and users run the other. That is a rule about *one runtime
 * having two choices*. A browser has no `node:crypto` at all — there is nothing
 * to fall back from, the way iOS has CryptoKit and Android has BouncyCastle and
 * neither is a fallback either.
 *
 * The part of that lesson that does apply is the part that bit: an
 * implementation users run and tests do not. So `pwa/tests/node-crypto.test.ts`
 * runs under Node, where both exist, and proves every function below produces
 * the same bytes as the `node:crypto` one it stands in for — key for key, digest
 * for digest, shared secret for shared secret. If these two ever part company
 * the suite fails, rather than a browser quietly failing to reach a Mac.
 *
 * ## Why @noble and not WebCrypto
 *
 * WebCrypto is asynchronous, and `sealed.ts` is a synchronous state machine —
 * making it async would rewrite the one file in this product that must not be
 * rewritten casually, and would do it for four clients to serve one. WebCrypto's
 * X25519 also arrived in Safari long after the 16.4 floor this client builds to,
 * and it has no scrypt at all, which the pairing rendezvous needs.
 *
 * `@noble/ciphers` is already the ChaCha in `sealed.ts` for reasons written out
 * over there. `@noble/hashes` and `@noble/curves` are its siblings by the same
 * author, audited, dependency-free, and pure JavaScript — so unlike the native
 * cipher that vanished under Electron's BoringSSL, there is no runtime in which
 * these are *absent*. They cannot be the shape of that bug.
 */

import { x25519 } from '@noble/curves/ed25519.js'
import { hkdf } from '@noble/hashes/hkdf.js'
import { sha256 } from '@noble/hashes/sha2.js'

/** X25519 keys, digests and HKDF salts are all this long. */
const KEY_BYTES = 32

/**
 * The DER wrappers Node puts around a raw X25519 key.
 *
 * `sealed.ts` builds these two prefixes itself and hands the result here as a
 * `der` blob, because Node speaks `KeyObject` and every other implementation of
 * this handshake speaks 32 raw bytes. Restated rather than imported: they are
 * not exported over there, and the alternative — exporting them so a browser
 * shim can check its own input — would widen that file's surface for this file's
 * convenience.
 *
 * They are *checked* rather than skipped past. A shim that sliced the last 32
 * bytes off whatever it was given would accept a malformed key silently, and
 * silence is how a wrong key becomes a handshake that fails with no reason.
 */
const SPKI_PREFIX = '302a300506032b656e032100'
const PKCS8_PREFIX = '302e020100300506032b656e04220420'

/* -------------------------------------------------------------------------- */
/* Randomness                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * The browser's CSPRNG, and no fallback under it.
 *
 * `crypto.getRandomValues` is the only source here on purpose. It exists in
 * every browser this client supports, and a `Math.random` path for one that
 * lacked it would be a client that generates guessable ephemeral keys and says
 * nothing — the single worst failure this file could contain. A runtime without
 * it gets an exception naming the problem.
 */
export function randomBytes(count: number): Buffer {
  const out = new Uint8Array(count)
  const source = globalThis.crypto
  if (source === undefined || typeof source.getRandomValues !== 'function') {
    throw new Error('this browser has no crypto.getRandomValues, so nothing here can be generated safely')
  }
  source.getRandomValues(out)
  return Buffer.from(out)
}

/* -------------------------------------------------------------------------- */
/* Hashing and key derivation                                                  */
/* -------------------------------------------------------------------------- */

/**
 * Only SHA-256, and anything else is a fault rather than a substitution.
 *
 * `sealed.ts` and `relay-wire.ts` ask for exactly one digest. A shim that
 * quietly answered `sha512` with a SHA-256 would produce a handshake that
 * derives different keys from the same transcript, which fails on the first
 * frame with the uniform refusal — a cryptographic-looking symptom for a
 * plumbing bug, which is precisely the confusion `SealedRefusal` exists to end.
 */
function requireSha256(algorithm: string): void {
  if (algorithm !== 'sha256') {
    throw new Error(`the browser build of this app implements sha256 only, not ${algorithm}`)
  }
}

export interface Hash {
  update(data: Uint8Array | string): Hash
  digest(): Buffer
}

export function createHash(algorithm: string): Hash {
  requireSha256(algorithm)
  const state = sha256.create()
  const wrapper: Hash = {
    update(data) {
      state.update(typeof data === 'string' ? new TextEncoder().encode(data) : data)
      return wrapper
    },
    digest: () => Buffer.from(state.digest()),
  }
  return wrapper
}

/**
 * HKDF, with Node's argument order rather than the RFC's.
 *
 * Node returns an `ArrayBuffer` here and `sealed.ts` wraps it — so this returns
 * one too. Handing back a `Uint8Array` would still work through `Buffer.from`
 * and would be a different function with the same name, which is the kind of
 * near-miss that survives review.
 */
export function hkdfSync(
  digest: string,
  ikm: Uint8Array,
  salt: Uint8Array,
  info: Uint8Array,
  keylen: number,
): ArrayBuffer {
  requireSha256(digest)
  const derived = hkdf(sha256, ikm, salt, info, keylen)
  // A fresh buffer rather than `derived.buffer`: noble may hand back a view into
  // a larger allocation, and returning that would leak neighbouring key material
  // to a caller that measured the ArrayBuffer instead of the view.
  return derived.slice().buffer as ArrayBuffer
}

/* -------------------------------------------------------------------------- */
/* Constant-time comparison                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Node's `timingSafeEqual`, including its refusal to compare unequal lengths.
 *
 * The length check throws rather than returning false, exactly as Node does. It
 * is not a security property — a length is public — but a shim that returned
 * false where Node throws would turn a caller's bug into a quiet "not equal",
 * and the one caller here is comparing a DH result against 32 zero bytes.
 */
export function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    throw new Error('timingSafeEqual needs two buffers of the same length')
  }
  let difference = 0
  for (let at = 0; at < a.length; at += 1) difference |= a[at] ^ b[at]
  return difference === 0
}

/* -------------------------------------------------------------------------- */
/* X25519                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * The half of Node's `KeyObject` the shared code touches, and no more.
 *
 * `sealed.ts` calls exactly one method on one of these — `export` — and converts
 * the DER straight back to 32 raw bytes. Modelling the rest of `KeyObject` would
 * be modelling a surface nothing calls, and the compiler checks this shape
 * against the real usage because `tsconfig.json` points the shared file's
 * `node:crypto` import at this module.
 */
export interface KeyObject {
  readonly type: 'public' | 'private'
  export(options: { type: 'spki' | 'pkcs8'; format: 'der' }): Buffer
}

function keyObject(type: 'public' | 'private', raw: Buffer): KeyObject {
  if (raw.length !== KEY_BYTES) throw new Error(`an x25519 key is ${KEY_BYTES} bytes, not ${raw.length}`)
  return {
    type,
    export(options) {
      const wanted = type === 'public' ? 'spki' : 'pkcs8'
      if (options.format !== 'der' || options.type !== wanted) {
        throw new Error(`this build can only export an x25519 ${type} key as ${wanted}/der`)
      }
      const prefix = type === 'public' ? SPKI_PREFIX : PKCS8_PREFIX
      return Buffer.concat([Buffer.from(prefix, 'hex'), raw])
    },
  }
}

/** Strip a DER wrapper, refusing anything that is not the one wrapper we emit. */
function rawFromDer(der: Uint8Array, prefix: string): Buffer {
  const head = Buffer.from(prefix, 'hex')
  if (der.length !== head.length + KEY_BYTES) throw new Error('that is not a raw x25519 key in DER')
  for (let at = 0; at < head.length; at += 1) {
    if (der[at] !== head[at]) throw new Error('that is not a raw x25519 key in DER')
  }
  return Buffer.from(der.subarray(head.length))
}

export interface KeyPair {
  publicKey: KeyObject
  privateKey: KeyObject
}

/**
 * A fresh X25519 pair.
 *
 * The private half is the **unclamped** 32-byte seed, which is what Node's
 * PKCS#8 export carries and what `staticFromSeed` depends on: a client that
 * exported the clamped scalar would round-trip a key into a different key, and
 * two machines deriving an identity from the same pairing code would stop
 * agreeing. `pwa/tests/node-crypto.test.ts` pins that against Node directly.
 */
export function generateKeyPairSync(type: string): KeyPair {
  if (type !== 'x25519') throw new Error(`the browser build generates x25519 keys only, not ${type}`)
  const secret = randomBytes(KEY_BYTES)
  return {
    privateKey: keyObject('private', secret),
    publicKey: keyObject('public', Buffer.from(x25519.getPublicKey(secret))),
  }
}

type KeyInput = KeyObject | { key: Uint8Array; format: 'der'; type: 'spki' | 'pkcs8' }

function isKeyObject(value: KeyInput): value is KeyObject {
  return 'type' in value && (value.type === 'public' || value.type === 'private') && !('key' in value)
}

/**
 * A public key, from DER — or from a private key, which is a derivation.
 *
 * The second shape is the one `staticFromSeed` uses, and it is the reason this
 * cannot simply parse bytes: turning a seed into a pair means running the curve,
 * and Node hides that behind the same function name.
 */
export function createPublicKey(input: KeyInput): KeyObject {
  if (isKeyObject(input)) {
    if (input.type === 'public') return input
    const secret = rawFromDer(input.export({ type: 'pkcs8', format: 'der' }), PKCS8_PREFIX)
    return keyObject('public', Buffer.from(x25519.getPublicKey(secret)))
  }
  if (input.type !== 'spki') throw new Error('a public key arrives as spki/der')
  return keyObject('public', rawFromDer(input.key, SPKI_PREFIX))
}

export function createPrivateKey(input: KeyInput): KeyObject {
  if (isKeyObject(input)) {
    if (input.type !== 'private') throw new Error('that is a public key')
    return input
  }
  if (input.type !== 'pkcs8') throw new Error('a private key arrives as pkcs8/der')
  return keyObject('private', rawFromDer(input.key, PKCS8_PREFIX))
}

/**
 * X25519, with the all-zero shared secret rejected — by the library, here.
 *
 * `sealed.ts` explains why this must throw rather than return 32 zero bytes: a
 * peer can send a low-order point and force the shared secret to a value it also
 * knows. OpenSSL refuses it and so does `@noble/curves`, which is what keeps the
 * two implementations of `dh()` behaving identically rather than only looking
 * alike — and `sealed.ts` checks the result again afterwards regardless, because
 * not every implementation of this handshake runs on either library.
 */
export function diffieHellman(input: { privateKey: KeyObject; publicKey: KeyObject }): Buffer {
  const secret = rawFromDer(input.privateKey.export({ type: 'pkcs8', format: 'der' }), PKCS8_PREFIX)
  const peer = rawFromDer(input.publicKey.export({ type: 'spki', format: 'der' }), SPKI_PREFIX)
  return Buffer.from(x25519.getSharedSecret(secret, peer))
}
