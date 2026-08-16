/**
 * The browser's primitives against Node's, byte for byte.
 *
 * ## Why this test is the important one in this directory
 *
 * `src/shared/sealed.ts` is the product's only implementation of the sealed
 * channel and the browser client imports it rather than reimplementing it. What
 * the browser cannot import is `node:crypto`, so `pwa/src/runtime/node-crypto.ts`
 * stands in for the five primitives that file uses, and the bundler and the
 * compiler are both pointed at it.
 *
 * That arrangement has one failure mode and it is the one that cost this project
 * a day: an implementation users run and tests do not. Electron links BoringSSL,
 * BoringSSL ships no ChaCha, and 3,628 tests went on passing under plain Node
 * while every relayed handshake in the product failed silently.
 *
 * So this file runs under Node, where **both** implementations exist, and holds
 * them against each other. Not "does the shim work" — does it produce the same
 * bytes as the thing it replaces, for keys, digests, derivations and shared
 * secrets. If they ever part company the suite says so here, instead of a
 * browser quietly failing to reach a Mac and nobody being able to say why.
 *
 * Lives in `pwa/tests/` rather than `pwa/src/` for a mundane and load-bearing
 * reason: `pwa/tsconfig.json` maps the specifier `node:crypto` onto the shim, so
 * a test under `src/` could not import the real one to compare against. This
 * directory is compiled by `pwa/tsconfig.node.json`, which has `@types/node` and
 * no such mapping.
 */

import {
  createHash as nodeCreateHash,
  createPrivateKey,
  createPublicKey,
  diffieHellman as nodeDiffieHellman,
  generateKeyPairSync as nodeGenerateKeyPairSync,
  hkdfSync as nodeHkdfSync,
  randomBytes as nodeRandomBytes,
  scryptSync,
  timingSafeEqual as nodeTimingSafeEqual,
  type KeyObject,
} from 'node:crypto'
import { describe, expect, it } from 'vitest'
import { scrypt as nobleScrypt, scryptAsync } from '@noble/hashes/scrypt.js'
import {
  createHash,
  createPrivateKey as shimCreatePrivateKey,
  createPublicKey as shimCreatePublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  timingSafeEqual,
} from '../src/runtime/node-crypto'

const KEY_BYTES = 32
const SPKI_PREFIX = Buffer.from('302a300506032b656e032100', 'hex')
const PKCS8_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex')

/** The raw 32 bytes behind a Node key object, the way `sealed.ts` gets them. */
function rawPublic(key: KeyObject): Buffer {
  return key.export({ type: 'spki', format: 'der' }).subarray(-KEY_BYTES)
}

function rawPrivate(key: KeyObject): Buffer {
  return key.export({ type: 'pkcs8', format: 'der' }).subarray(-KEY_BYTES)
}

function nodePublicOf(privateRaw: Buffer): Buffer {
  const key = createPrivateKey({
    key: Buffer.concat([PKCS8_PREFIX, privateRaw]),
    format: 'der',
    type: 'pkcs8',
  })
  return createPublicKey(key).export({ type: 'spki', format: 'der' }).subarray(-KEY_BYTES)
}

function nodeShared(privateRaw: Buffer, publicRaw: Buffer): Buffer {
  return nodeDiffieHellman({
    privateKey: createPrivateKey({
      key: Buffer.concat([PKCS8_PREFIX, privateRaw]),
      format: 'der',
      type: 'pkcs8',
    }),
    publicKey: createPublicKey({
      key: Buffer.concat([SPKI_PREFIX, publicRaw]),
      format: 'der',
      type: 'spki',
    }),
  })
}

describe('sha256', () => {
  it('matches node for every length that crosses a block boundary', () => {
    for (const size of [0, 1, 55, 56, 63, 64, 65, 127, 1000]) {
      const input = nodeRandomBytes(size)
      expect(createHash('sha256').update(input).digest().toString('hex')).toBe(
        nodeCreateHash('sha256').update(input).digest().toString('hex'),
      )
    }
  })

  it('matches node when fed in pieces, which is how `sealed.ts` uses it', () => {
    // Every transcript hash in the handshake is `hash(h, something)` — two
    // updates, never one. A shim that only agreed on a single-shot digest would
    // pass a naive test and derive a different key on the first message.
    const first = nodeRandomBytes(31)
    const second = nodeRandomBytes(97)
    expect(createHash('sha256').update(first).update(second).digest().toString('hex')).toBe(
      nodeCreateHash('sha256').update(first).update(second).digest().toString('hex'),
    )
  })

  it('refuses a digest it does not implement rather than substituting one', () => {
    expect(() => createHash('sha512')).toThrow(/sha256 only/)
  })
})

describe('hkdf', () => {
  it('matches node at the length and argument order the key schedule uses', () => {
    const ikm = nodeRandomBytes(KEY_BYTES)
    const salt = nodeRandomBytes(KEY_BYTES)
    const mine = Buffer.from(hkdfSync('sha256', ikm, salt, Buffer.alloc(0), KEY_BYTES * 2))
    const theirs = Buffer.from(nodeHkdfSync('sha256', ikm, salt, Buffer.alloc(0), KEY_BYTES * 2))
    expect(mine.toString('hex')).toBe(theirs.toString('hex'))
  })

  it('returns exactly the requested bytes and not a view into more', () => {
    // `sealed.ts` wraps the result in `Buffer.from(...)`, which for an
    // `ArrayBuffer` shares rather than copies. A shim handing back the backing
    // store of a larger allocation would hand a caller neighbouring key
    // material along with the key.
    const out = hkdfSync('sha256', nodeRandomBytes(32), nodeRandomBytes(32), Buffer.alloc(0), 64)
    expect(out.byteLength).toBe(64)
  })
})

describe('x25519', () => {
  it('derives the same public key node does, from the same private bytes', () => {
    for (let round = 0; round < 8; round += 1) {
      const pair = generateKeyPairSync('x25519')
      const priv = pair.privateKey.export({ type: 'pkcs8', format: 'der' }).subarray(-KEY_BYTES)
      const pub = pair.publicKey.export({ type: 'spki', format: 'der' }).subarray(-KEY_BYTES)
      expect(pub.toString('hex')).toBe(nodePublicOf(priv).toString('hex'))
    }
  })

  it('exports the unclamped seed as the private key, as node does', () => {
    // `staticFromSeed` depends on this exactly: two machines feeding identical
    // seeds must get identical pairs. A shim that exported the *clamped* scalar
    // would round-trip a key into a different key, and a pairing code would stop
    // naming the same rendezvous on both ends.
    const seed = nodeRandomBytes(KEY_BYTES)
    const shimmed = shimCreatePrivateKey({
      key: Buffer.concat([PKCS8_PREFIX, seed]),
      format: 'der',
      type: 'pkcs8',
    })
    expect(shimmed.export({ type: 'pkcs8', format: 'der' }).subarray(-KEY_BYTES).toString('hex')).toBe(
      seed.toString('hex'),
    )
    expect(
      shimCreatePublicKey(shimmed).export({ type: 'spki', format: 'der' }).subarray(-KEY_BYTES).toString('hex'),
    ).toBe(nodePublicOf(seed).toString('hex'))
  })

  it('agrees with node on a shared secret, in both directions', () => {
    const theirs = nodeGenerateKeyPairSync('x25519')
    const theirPrivate = rawPrivate(theirs.privateKey)
    const theirPublic = rawPublic(theirs.publicKey)

    const mine = generateKeyPairSync('x25519')
    const myPrivate = mine.privateKey.export({ type: 'pkcs8', format: 'der' }).subarray(-KEY_BYTES)
    const myPublic = mine.publicKey.export({ type: 'spki', format: 'der' }).subarray(-KEY_BYTES)

    const shimSide = diffieHellman({
      privateKey: mine.privateKey,
      publicKey: shimCreatePublicKey({
        key: Buffer.concat([SPKI_PREFIX, theirPublic]),
        format: 'der',
        type: 'spki',
      }),
    })
    const nodeSide = nodeShared(theirPrivate, myPublic)
    expect(shimSide.toString('hex')).toBe(nodeSide.toString('hex'))
    // And the shim's own view of the same secret from the other seat.
    expect(shimSide.toString('hex')).toBe(nodeShared(myPrivate, theirPublic).toString('hex'))
  })

  it('refuses a low-order point rather than returning a shared zero', () => {
    // RFC 7748 §6.1. A peer that sends this forces the secret to a value it also
    // knows; OpenSSL refuses it and so must this, or the two `dh()` paths only
    // look alike.
    const mine = generateKeyPairSync('x25519')
    expect(() =>
      diffieHellman({
        privateKey: mine.privateKey,
        publicKey: shimCreatePublicKey({
          key: Buffer.concat([SPKI_PREFIX, Buffer.alloc(KEY_BYTES)]),
          format: 'der',
          type: 'spki',
        }),
      }),
    ).toThrow()
  })

  it('refuses DER that is not a bare x25519 key', () => {
    expect(() =>
      shimCreatePublicKey({ key: Buffer.alloc(SPKI_PREFIX.length + KEY_BYTES), format: 'der', type: 'spki' }),
    ).toThrow(/not a raw x25519 key/)
  })
})

describe('randomness and comparison', () => {
  it('fills the requested length from the platform CSPRNG', () => {
    const bytes = randomBytes(48)
    expect(bytes.length).toBe(48)
    expect(bytes.equals(Buffer.alloc(48))).toBe(false)
    expect(randomBytes(48).equals(bytes)).toBe(false)
  })

  it('answers timingSafeEqual the way node does, including the throw', () => {
    const a = nodeRandomBytes(KEY_BYTES)
    const b = Buffer.from(a)
    b[7] ^= 1
    expect(timingSafeEqual(a, Buffer.from(a))).toBe(nodeTimingSafeEqual(a, Buffer.from(a)))
    expect(timingSafeEqual(a, b)).toBe(nodeTimingSafeEqual(a, b))
    expect(() => timingSafeEqual(a, a.subarray(1))).toThrow()
  })
})

describe('scrypt, which the pairing rendezvous derives its identity with', () => {
  /**
   * The desktop's parameters, restated from `machines/rendezvous.ts` because
   * that module cannot be imported here — it pulls in the desktop's relay client
   * and, through it, `node:net`. This is the cross-check that catches the drift:
   * change them there and not in `pwa/src/rendezvous.ts` and the vector below
   * stops matching, instead of a typed pairing code finding nothing at the relay.
   */
  const SCRYPT = { N: 16384, r: 8, p: 1 } as const
  const CODE = '482913'
  /**
   * The literal, not the constant, and deliberately so.
   *
   * `pwa/src/rendezvous.ts` cannot be imported here — it reaches `relay-socket.ts`
   * and through it `WebSocket`, which this Node-typed project has no business
   * knowing about. So the salt is pinned to its text in two places instead:
   * here, against Node's scrypt, and in `pwa/src/rendezvous.test.ts`, against the
   * browser module's exported constant. Change it on one side and one of the two
   * fails; change it on the desktop and neither does, which is why the live
   * proof pairs by typed code against a real host rather than trusting this.
   */
  const RENDEZVOUS_SALT = 'terminaldeck-machine-pairing-v1'

  it('matches node for the code, salt and parameters both ends use', () => {
    const theirs = scryptSync(CODE, RENDEZVOUS_SALT, 64, { ...SCRYPT, maxmem: 256 * SCRYPT.N * SCRYPT.r })
    const mine = Buffer.from(nobleScrypt(CODE, RENDEZVOUS_SALT, { ...SCRYPT, dkLen: 64 }))
    expect(mine.toString('hex')).toBe(theirs.toString('hex'))
  })

  it('gives the async form the same bytes as the sync one', async () => {
    // The browser uses `scryptAsync` so the page does not freeze for a third of
    // a second on the one screen somebody is watching. Same algorithm, and this
    // is where "same" stops being an assumption.
    const sync = Buffer.from(nobleScrypt(CODE, RENDEZVOUS_SALT, { ...SCRYPT, dkLen: 64 }))
    const async = Buffer.from(await scryptAsync(CODE, RENDEZVOUS_SALT, { ...SCRYPT, dkLen: 64 }))
    expect(async.toString('hex')).toBe(sync.toString('hex'))
  })
})
