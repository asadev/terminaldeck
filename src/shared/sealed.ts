/**
 * The sealed channel: end-to-end encryption between a client and this machine.
 *
 * ## Why this exists at all
 *
 * Remote access used to ride a tailnet, where the two endpoints were already on
 * a private network and TLS was terminated by Tailscale. Going through a relay
 * we operate changes the threat model completely: every byte now passes through
 * a box on the public internet, and that box is a machine someone could
 * eventually get into. A relay that can read the stream is a relay that can read
 * a shell — the prompt, the source, whatever the agent pasted, the key you
 * echoed by accident.
 *
 * So the relay is treated as hostile by construction. It sees a routing header
 * and ciphertext. It cannot read a session, cannot inject a keystroke, and
 * cannot replay one. That property does not come from trusting our own server;
 * it comes from the relay never holding a key.
 *
 * ## The handshake is Noise IK, not something invented here
 *
 * Rolling a bespoke handshake is how people end up with a protocol that looks
 * fine and leaks under a paper nobody on this project will read. The pattern
 * below is Noise **IK** — the same shape WireGuard uses — chosen because it
 * matches the situation exactly: the initiator (a paired phone) already knows
 * the responder's static public key, because it received it at pairing time.
 *
 * Three Diffie-Hellmans, each buying one specific thing:
 *
 *   ee = DH(initiator ephemeral, responder ephemeral)  → forward secrecy
 *   es = DH(initiator ephemeral, responder static)     → the responder is this Mac
 *   se = DH(initiator static,    responder ephemeral)  → the initiator is that device
 *
 * Forward secrecy is the one worth spelling out: the ephemeral keys are thrown
 * away when the connection ends, so recording the traffic today and stealing the
 * Mac's disk next year does not decrypt the recording.
 *
 * ## What is on disk, and why that is still safe
 *
 * `device-auth.ts` deliberately stores no key material — devices are scrypt
 * hashes, so a stolen `remote-auth.json` cannot become a device. This module
 * keeps that promise. Only **public** keys are persisted alongside a device.
 * The Mac's own static private key is the single new secret on disk, and it is
 * written 0600 with the same atomic-rename dance as the auth file.
 *
 * A stolen device public key lets an attacker verify a guess, not impersonate.
 *
 * ## Why the transcript is hashed into the keys
 *
 * `h` accumulates every public value in order and ends up mixed into the final
 * key schedule. Two sides that saw even slightly different handshakes — a
 * flipped byte, a reordered field, a relay that swapped one party's ephemeral —
 * derive different keys and simply fail to decrypt. That is what makes the relay
 * unable to sit in the middle: it can drop the connection, which is honest
 * failure, but it cannot man-in-the-middle it without being caught on the first
 * frame.
 *
 * ## Primitives, and why these ones
 *
 * X25519, ChaCha20-Poly1305, HKDF-SHA256, BLAKE2s-free (SHA-256 stands in for
 * the Noise hash, which the spec permits). All of them exist in Apple's
 * CryptoKit and on Android, which matters when the same handshake has to be
 * written four times in four languages and agree byte for byte.
 *
 * ChaCha20-Poly1305 over AES-GCM specifically because two of the four clients
 * are phones: ChaCha is constant-time in software and does not depend on the
 * CPU having AES instructions, and there is no nonce-reuse cliff as steep as
 * GCM's.
 *
 * ## Why the AEAD is not Node's
 *
 * X25519, HKDF and SHA-256 come from `node:crypto`. ChaCha20-Poly1305 does not,
 * and that is deliberate rather than decorative.
 *
 * This code runs in Electron, and Electron does not link OpenSSL — it links
 * **BoringSSL**, which ships 28 ciphers and not one of them is a ChaCha.
 * `createCipheriv('chacha20-poly1305', …)` therefore throws `Unknown cipher` in
 * the product while passing every test under plain Node, which is exactly what
 * happened: every relayed handshake failed, the desktop logged nothing, and the
 * host identity was quarantined and regenerated on each launch because the
 * self-check that validates it is itself a handshake.
 *
 * So the AEAD is `@noble/ciphers` — audited, zero-dependency, and above all the
 * *same code in every runtime*. There is deliberately no "use the native one
 * when it is there" fast path: a fallback means the suite exercises one
 * implementation and users run the other, which is the bug this comment exists
 * because of. One path, one set of bytes, everywhere.
 *
 * The other three primitives stay native because they were each checked to
 * exist under BoringSSL, not assumed — see `src/main/remote/sealed.electron-probe.ts`,
 * which `npm test` runs inside Electron's own Node and which fails the build if
 * any of that stops being true.
 *
 * ## The nonce rule, which is the easiest thing to get fatally wrong
 *
 * Each direction has its own key and its own counter starting at zero. A nonce
 * is never reused under a key, ever, and the counter is refused rather than
 * wrapped — running past the limit closes the connection instead of quietly
 * repeating a nonce, which with ChaCha20-Poly1305 would leak the XOR of two
 * plaintexts and forge the authenticator.
 */

import {
  createHash,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  timingSafeEqual,
  type KeyObject,
} from 'node:crypto'
import { chacha20poly1305 } from '@noble/ciphers/chacha.js'

/* -------------------------------------------------------------------------- */
/* Constants                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * Noise protocol name, mixed into the initial hash.
 *
 * Written exactly as the Noise spec would name this construction. It is a
 * domain separator: change any primitive and this string changes, so a client
 * built against a different suite fails at the first decrypt rather than
 * negotiating its way down to it. There is no downgrade path because there is
 * nothing to negotiate.
 */
export const NOISE_NAME = 'Noise_IK_25519_ChaChaPoly_SHA256'

/** Bumped with any change to the framing or key schedule below. */
export const SEALED_VERSION = 1

const KEY_BYTES = 32
const NONCE_BYTES = 12
const TAG_BYTES = 16
const HASH_BYTES = 32

/**
 * Highest message counter allowed under one key.
 *
 * Far below the 2^64 the nonce field could hold: a session that sent a message
 * every millisecond for a century would not reach 2^48. The cap exists so the
 * counter is checked at all, and so the failure is a closed connection rather
 * than a wrapped nonce.
 */
const MAX_COUNTER = 2 ** 48

/* -------------------------------------------------------------------------- */
/* Refusals versus faults                                                      */
/* -------------------------------------------------------------------------- */

/**
 * A refusal: this module worked correctly and said no.
 *
 * Everything that throws below is one of two completely different events, and
 * for a day they were indistinguishable to every caller — which is the reason
 * this class exists.
 *
 *  - **A refusal.** An unpaired device, a forged tag, a replayed frame, a
 *    handshake aimed at another Mac. Routine, expected, and deliberately
 *    uniform: the message is the same for all of them so that no caller can
 *    turn the difference into an oracle. This class.
 *  - **A fault.** The runtime could not perform the operation at all —
 *    `Unknown cipher` under Electron's BoringSSL being the specific one that
 *    cost a day. Nothing to do with the peer, and never routine. A plain
 *    `Error`, which reaches the caller unwrapped.
 *
 * A caller that lumps the two together reports a broken build as an unpaired
 * phone and logs nothing, which is exactly what happened. So the distinction is
 * carried in the type rather than in a message anyone has to parse:
 * `err instanceof SealedRefusal` is "no", and anything else is "this is broken".
 *
 * Note that the uniformity is preserved — every refusal still carries one of a
 * tiny set of messages and none of them says which check failed.
 */
export class SealedRefusal extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SealedRefusal'
  }
}

/* -------------------------------------------------------------------------- */
/* Keys                                                                        */
/* -------------------------------------------------------------------------- */

/** A static identity. The private half never leaves the machine that made it. */
export interface StaticKeyPair {
  publicKey: Buffer
  privateKey: Buffer
}

/** Raw 32-byte X25519 keys, the only shape that crosses the wire or the disk. */
export function generateStatic(): StaticKeyPair {
  const { publicKey, privateKey } = generateKeyPairSync('x25519')
  return { publicKey: rawPublic(publicKey), privateKey: rawPrivate(privateKey) }
}

/**
 * X25519 keys travel as 32 raw bytes, not as DER or PEM.
 *
 * Node speaks `KeyObject`; CryptoKit and Android speak 32 bytes. Converting at
 * this boundary rather than at every call site is what lets the four
 * implementations agree, and it keeps DER parsing out of the phone clients.
 */
function rawPublic(key: KeyObject): Buffer {
  return key.export({ type: 'spki', format: 'der' }).subarray(-KEY_BYTES)
}

function rawPrivate(key: KeyObject): Buffer {
  return key.export({ type: 'pkcs8', format: 'der' }).subarray(-KEY_BYTES)
}

const SPKI_PREFIX = Buffer.from('302a300506032b656e032100', 'hex')
const PKCS8_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex')

function publicKeyObject(raw: Buffer): KeyObject {
  if (raw.length !== KEY_BYTES) throw new SealedRefusal('x25519 public key must be 32 bytes')
  return createPublicKey({
    key: Buffer.concat([SPKI_PREFIX, raw]),
    format: 'der',
    type: 'spki',
  })
}

function privateKeyObject(raw: Buffer): KeyObject {
  if (raw.length !== KEY_BYTES) throw new SealedRefusal('x25519 private key must be 32 bytes')
  return createPrivateKey({
    key: Buffer.concat([PKCS8_PREFIX, raw]),
    format: 'der',
    type: 'pkcs8',
  })
}

/**
 * X25519 with the all-zero output rejected.
 *
 * A peer can send a low-order point and force the shared secret to zero on the
 * other side, which would hand an attacker a key they also know. RFC 7748 §6.1
 * says to check; Node does not check for us. The comparison is constant-time
 * out of habit rather than necessity — the value is not secret once it is zero.
 */
function dh(privateRaw: Buffer, publicRaw: Buffer): Buffer {
  let secret: Buffer
  try {
    secret = diffieHellman({
      privateKey: privateKeyObject(privateRaw),
      publicKey: publicKeyObject(publicRaw),
    })
  } catch {
    // OpenSSL rejects the all-zero result itself, with
    // `error:1C8000A4:Provider routines::failed during derivation`. Letting
    // that reach a caller would make a malformed key distinguishable from a
    // bad tag, which is precisely the oracle this module refuses to give — so
    // every way a DH can fail produces the one message.
    //
    // This is the one catch in the file that cannot tell a refusal from a
    // fault, and it is left that way on purpose: narrowing it would mean
    // branching on an OpenSSL error string, and being wrong about that string
    // is an oracle. The cost is that a runtime with no X25519 at all would be
    // reported here as an authentication failure — the exact laundering that
    // hid the ChaCha bug — so X25519 is exercised directly, under Electron, by
    // `sealed.electron-probe.ts`. The check lives there because it cannot
    // safely live here.
    throw new SealedRefusal('handshake failed authentication')
  }
  // Kept even though OpenSSL got there first: this is the check RFC 7748 §6.1
  // actually asks for, and the three other implementations of this handshake
  // do not all run on OpenSSL. CryptoKit throws, Android's XDH does not.
  if (timingSafeEqual(secret, Buffer.alloc(KEY_BYTES))) {
    throw new SealedRefusal('handshake failed authentication')
  }
  return secret
}

/* -------------------------------------------------------------------------- */
/* Symmetric state                                                             */
/* -------------------------------------------------------------------------- */

function hash(...parts: Buffer[]): Buffer {
  const h = createHash('sha256')
  for (const part of parts) h.update(part)
  return h.digest()
}

/**
 * Noise's `MixKey`: fold a fresh DH result into the chaining key.
 *
 * Two outputs from one HKDF — the next chaining key and a key usable now. Each
 * DH therefore both advances the chain and produces material, so a handshake
 * message can be encrypted under the keys derived from the DHs that preceded
 * it. Compromising one stage does not hand over the ones before it.
 */
function mixKey(chainingKey: Buffer, input: Buffer): { chainingKey: Buffer; temp: Buffer } {
  const out = Buffer.from(hkdfSync('sha256', input, chainingKey, Buffer.alloc(0), KEY_BYTES * 2))
  return { chainingKey: out.subarray(0, KEY_BYTES), temp: out.subarray(KEY_BYTES) }
}

function nonceBuffer(counter: number): Buffer {
  const nonce = Buffer.alloc(NONCE_BYTES)
  // Noise puts the counter in the last 8 bytes, little-endian, leaving the
  // first 4 zero. Writing it any other way is a silent interop break.
  nonce.writeBigUInt64LE(BigInt(counter), 4)
  return nonce
}

/**
 * RFC 8439 ChaCha20-Poly1305, output as `ciphertext || tag`.
 *
 * That layout is what Node's `getAuthTag()` had to be concatenated into by hand
 * above, and it is what noble returns directly — the same bytes either way, and
 * the same bytes CryptoKit's `SealedBox.combined` (minus its nonce prefix) and
 * BouncyCastle's `doFinal` produce. Nothing here is free to change: the fixtures
 * under `ios/Tests/Fixtures` and `android/app/src/test/resources` are generated
 * from this function and compared byte for byte by the phone test suites.
 */
function seal(key: Buffer, counter: number, plaintext: Buffer, aad: Buffer): Buffer {
  if (key.length !== KEY_BYTES) throw new Error(`sealing key was ${key.length} bytes, not ${KEY_BYTES}`)
  return Buffer.from(chacha20poly1305(key, nonceBuffer(counter), aad).encrypt(plaintext))
}

/**
 * The inverse, with a bad tag reported as a refusal and nothing else.
 *
 * A wrong key length is a *fault* — this module derived it, no peer can
 * influence it, and a caller that turned it into "authentication failed" would
 * be hiding a bug in exactly the way the ChaCha bug was hidden. Checking it
 * here leaves the tag as the only thing left for the decrypt to object to, so
 * the conversion below is a statement about the peer rather than a shrug.
 */
function open(key: Buffer, counter: number, sealed: Buffer, aad: Buffer): Buffer {
  if (key.length !== KEY_BYTES) throw new Error(`opening key was ${key.length} bytes, not ${KEY_BYTES}`)
  if (sealed.length < TAG_BYTES) throw new SealedRefusal('ciphertext shorter than its tag')
  try {
    return Buffer.from(chacha20poly1305(key, nonceBuffer(counter), aad).decrypt(sealed))
  } catch {
    throw new SealedRefusal('sealed frame failed authentication')
  }
}

/* -------------------------------------------------------------------------- */
/* Transport                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * A live sealed channel, after the handshake.
 *
 * Send and receive counters are independent and never shared. `receive` refuses
 * to advance on a failed decrypt, so a forged frame costs an attacker the
 * connection rather than desynchronising the counter — and every failure is the
 * same failure, because distinguishing "bad tag" from "bad counter" out loud is
 * an oracle.
 */
export class SealedTransport {
  private sendCounter = 0
  private receiveCounter = 0

  constructor(
    private readonly sendKey: Buffer,
    private readonly receiveKey: Buffer,
    /** The final handshake hash. Both sides have it; useful as a channel binding. */
    readonly channelBinding: Buffer,
  ) {}

  send(plaintext: Buffer): Buffer {
    if (this.sendCounter >= MAX_COUNTER) throw new SealedRefusal('sealed channel exhausted')
    const frame = seal(this.sendKey, this.sendCounter, plaintext, Buffer.alloc(0))
    this.sendCounter += 1
    return frame
  }

  receive(sealed: Buffer): Buffer {
    if (this.receiveCounter >= MAX_COUNTER) throw new SealedRefusal('sealed channel exhausted')
    let plaintext: Buffer
    try {
      plaintext = open(this.receiveKey, this.receiveCounter, sealed, Buffer.alloc(0))
    } catch (err) {
      // One message for every *refusal*. Which check failed is not the caller's
      // business and definitely not the network's. A fault is not a refusal and
      // is rethrown untouched — relabelling it as an authentication failure is
      // how a dead cipher looked like an unpaired phone for a day.
      if (!(err instanceof SealedRefusal)) throw err
      throw new SealedRefusal('sealed frame failed authentication')
    }
    this.receiveCounter += 1
    return plaintext
  }

  sendText(value: string): Buffer {
    return this.send(Buffer.from(value, 'utf8'))
  }

  receiveText(sealed: Buffer): string {
    return this.receive(sealed).toString('utf8')
  }
}

/* -------------------------------------------------------------------------- */
/* Handshake — initiator (phone) side                                          */
/* -------------------------------------------------------------------------- */

export interface InitiatorStart {
  /** Goes on the wire: ephemeral public key, then the encrypted static key. */
  message: Buffer
  /** Held until the responder answers. */
  pending: PendingInitiator
}

export interface PendingInitiator {
  ephemeralPrivate: Buffer
  chainingKey: Buffer
  h: Buffer
  staticPrivate: Buffer
}

function initialState(responderStatic: Buffer): { chainingKey: Buffer; h: Buffer } {
  // Noise: h = HASH(protocol_name) when the name is exactly 32 bytes, else
  // HASH of it. Ours is longer than 32, so it is hashed.
  const h0 = hash(Buffer.from(NOISE_NAME, 'utf8'))
  // Then the responder's static public key is mixed in as the pre-message,
  // which is what makes this IK rather than XX.
  return { chainingKey: h0, h: hash(h0, responderStatic) }
}

/**
 * First handshake message, from a device that already knows this Mac's key.
 *
 * The device's own static public key is sent *encrypted*, under a key derived
 * from `es`. That is the point of IK: a passive observer — including the
 * relay — cannot tell which device is connecting, only that some device is.
 */
export function startHandshake(
  deviceStatic: StaticKeyPair,
  responderStaticPublic: Buffer,
): InitiatorStart {
  let { chainingKey, h } = initialState(responderStaticPublic)
  const ephemeral = generateStatic()

  h = hash(h, ephemeral.publicKey)
  const es = mixKey(chainingKey, dh(ephemeral.privateKey, responderStaticPublic))
  chainingKey = es.chainingKey

  const encryptedStatic = seal(es.temp, 0, deviceStatic.publicKey, h)
  h = hash(h, encryptedStatic)

  const ss = mixKey(chainingKey, dh(deviceStatic.privateKey, responderStaticPublic))
  chainingKey = ss.chainingKey

  return {
    message: Buffer.concat([ephemeral.publicKey, encryptedStatic]),
    pending: {
      ephemeralPrivate: ephemeral.privateKey,
      chainingKey,
      h,
      staticPrivate: deviceStatic.privateKey,
    },
  }
}

/** Completes the initiator's side once the responder's reply arrives. */
export function finishHandshake(pending: PendingInitiator, reply: Buffer): SealedTransport {
  if (reply.length !== KEY_BYTES + TAG_BYTES) {
    throw new SealedRefusal('handshake reply was the wrong length')
  }
  const responderEphemeral = reply.subarray(0, KEY_BYTES)
  const confirmation = reply.subarray(KEY_BYTES)

  let { chainingKey, h } = pending
  h = hash(h, responderEphemeral)

  const ee = mixKey(chainingKey, dh(pending.ephemeralPrivate, responderEphemeral))
  chainingKey = ee.chainingKey
  const se = mixKey(chainingKey, dh(pending.staticPrivate, responderEphemeral))
  chainingKey = se.chainingKey

  // An empty payload whose only job is to prove the responder derived the same
  // keys. If this opens, the far end holds the Mac's static private key.
  try {
    open(se.temp, 0, confirmation, h)
  } catch (err) {
    // A fault reaches the caller as a fault; only a refusal is made uniform.
    if (!(err instanceof SealedRefusal)) throw err
    throw new SealedRefusal('handshake reply failed authentication')
  }
  h = hash(h, confirmation)

  const { k1, k2, binding } = split(chainingKey, h)
  // The initiator sends under k1 and receives under k2; the responder mirrors.
  return new SealedTransport(k1, k2, binding)
}

/* -------------------------------------------------------------------------- */
/* Handshake — responder (this Mac) side                                       */
/* -------------------------------------------------------------------------- */

export interface ResponderResult {
  /** Goes back on the wire. */
  reply: Buffer
  transport: SealedTransport
  /** Which device this was, by its static public key. Now authenticated. */
  devicePublicKey: Buffer
}

/**
 * Answers a handshake, and tells the caller *which* device it was.
 *
 * `isKnownDevice` is asked before any reply is produced. An unrecognised static
 * key is refused here rather than after a transport exists, so an unpaired
 * device never gets a channel it could send anything down — and refusing costs
 * the same work as accepting, since the DHs have already run either way.
 */
export function respondToHandshake(
  responderStatic: StaticKeyPair,
  message: Buffer,
  isKnownDevice: (devicePublicKey: Buffer) => boolean,
): ResponderResult {
  if (message.length !== KEY_BYTES + KEY_BYTES + TAG_BYTES) {
    throw new SealedRefusal('handshake message was the wrong length')
  }
  const initiatorEphemeral = message.subarray(0, KEY_BYTES)
  const encryptedStatic = message.subarray(KEY_BYTES)

  let { chainingKey, h } = initialState(responderStatic.publicKey)
  h = hash(h, initiatorEphemeral)

  const es = mixKey(chainingKey, dh(responderStatic.privateKey, initiatorEphemeral))
  chainingKey = es.chainingKey

  let devicePublicKey: Buffer
  try {
    devicePublicKey = open(es.temp, 0, encryptedStatic, h)
  } catch (err) {
    // A fault reaches the caller as a fault; only a refusal is made uniform.
    if (!(err instanceof SealedRefusal)) throw err
    throw new SealedRefusal('handshake failed authentication')
  }
  h = hash(h, encryptedStatic)

  const ss = mixKey(chainingKey, dh(responderStatic.privateKey, devicePublicKey))
  chainingKey = ss.chainingKey

  if (!isKnownDevice(devicePublicKey)) {
    throw new SealedRefusal('handshake failed authentication')
  }

  const ephemeral = generateStatic()
  h = hash(h, ephemeral.publicKey)

  const ee = mixKey(chainingKey, dh(ephemeral.privateKey, initiatorEphemeral))
  chainingKey = ee.chainingKey
  const se = mixKey(chainingKey, dh(ephemeral.privateKey, devicePublicKey))
  chainingKey = se.chainingKey

  const confirmation = seal(se.temp, 0, Buffer.alloc(0), h)
  h = hash(h, confirmation)

  const { k1, k2, binding } = split(chainingKey, h)
  // Mirrored against the initiator: it sends under k1, so we receive under k1.
  return {
    reply: Buffer.concat([ephemeral.publicKey, confirmation]),
    transport: new SealedTransport(k2, k1, binding),
    devicePublicKey,
  }
}

/**
 * Noise's `Split`: two directional keys plus a channel binding.
 *
 * The binding is the final transcript hash. It is not secret and it is not used
 * to encrypt anything — it exists so a higher layer can prove two parties are
 * on the same channel without a second handshake.
 */
function split(chainingKey: Buffer, h: Buffer): { k1: Buffer; k2: Buffer; binding: Buffer } {
  const out = Buffer.from(
    hkdfSync('sha256', Buffer.alloc(0), chainingKey, Buffer.alloc(0), KEY_BYTES * 2),
  )
  return {
    k1: out.subarray(0, KEY_BYTES),
    k2: out.subarray(KEY_BYTES),
    binding: Buffer.from(h.subarray(0, HASH_BYTES)),
  }
}

/* -------------------------------------------------------------------------- */
/* Fingerprints                                                                */
/* -------------------------------------------------------------------------- */

/**
 * A short, human-comparable form of a public key.
 *
 * Shown on the Mac and on the phone during pairing so a person can see the same
 * six groups in both places. Not a security boundary on its own — the pairing
 * token and the approval step are — but it is what turns "trust this device"
 * from a dialog you dismiss into one you can actually check.
 *
 * Base32 without padding, uppercase, in groups of four: no `0`/`O` or `1`/`I`
 * confusion when someone reads it down a phone line.
 */
/**
 * Exactly 32 symbols: A–Z without `I` or `O`, then 2–9.
 *
 * Dropping both letters *and* both digits they are confused with is what makes
 * the count come out at 32 — an alphabet with `I` still in it is 33 long, which
 * silently makes the last symbol unreachable and the encoding non-standard.
 */
const BASE32 = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

export function fingerprint(publicKey: Buffer): string {
  const digest = hash(Buffer.from('terminaldeck-fingerprint', 'utf8'), publicKey)
  let bits = 0
  let value = 0
  let out = ''
  for (const byte of digest.subarray(0, 15)) {
    value = (value << 8) | byte
    bits += 8
    while (bits >= 5) {
      bits -= 5
      out += BASE32[(value >> bits) & 31]
    }
  }
  return (out.match(/.{1,4}/g) ?? []).join('-')
}

/** Fresh 32 bytes, for callers that need a secret and should not reach for Math.random. */
export function secretBytes(count = KEY_BYTES): Buffer {
  return randomBytes(count)
}
