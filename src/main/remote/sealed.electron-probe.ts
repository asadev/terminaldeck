/**
 * The sealed channel, exercised under **Electron's** Node rather than yours.
 *
 * ## Why this file exists
 *
 * `sealed.test.ts` has 28 tests and every one of them passed while the feature
 * was completely dead in the product. Vitest runs under whatever `node` is on
 * the path, and that Node links OpenSSL. Electron links **BoringSSL**, which
 * ships 28 ciphers and not one of them is a ChaCha. So
 * `createCipheriv('chacha20-poly1305', …)` threw `Unknown cipher` on every
 * relayed handshake, the throw was swallowed, and the only outward symptom was
 * a channel that closed and a host identity regenerated on every launch.
 *
 * A test suite that cannot see the runtime it ships on is a test suite that can
 * be entirely green while nothing works. This file closes that gap: it is run
 * by `scripts/check-electron-crypto.mjs`, which bundles it and executes it
 * inside `ELECTRON_RUN_AS_NODE=1 electron`, and `npm test` runs that after
 * vitest. CI therefore cannot go green while the desktop is broken.
 *
 * ## What it checks, and why each one is here
 *
 * 1. **Every primitive, exercised rather than listed.** `getCiphers()` says what
 *    exists; only calling it says whether it works. Each primitive `sealed.ts`
 *    takes from `node:crypto` is run for real, so "BoringSSL has X25519" is a
 *    measurement and not an assumption.
 * 2. **A live handshake and a sealed round trip**, which is the one line that
 *    would have caught the original bug on day one.
 * 3. **Known-answer vectors** from `ios/Tests/Fixtures/sealed-vectors.json`,
 *    committed *before* the AEAD was replaced. A self-consistent implementation
 *    agrees with itself no matter how wrong it is; these bytes were recorded by
 *    the old code, so reproducing them proves the wire format did not move.
 * 4. **The host identity, loaded twice.** The regression that orphaned every
 *    paired phone was not in the cipher — it was `pairIsSound()` running a real
 *    handshake, throwing, and being read as "this key is corrupt". Loading twice
 *    and demanding the same `hostId` with nothing quarantined is the direct
 *    guard on that.
 * 5. **Every algorithm name in the product sources**, checked against this
 *    runtime's `getCiphers()`/`getHashes()`. The driver does the reading — it
 *    has esbuild, so it can tell a `createCipheriv` call from a sentence about
 *    one — and hands the names over. The first four checks guard the bug that
 *    happened; this one guards the next one, anywhere in `src/main`,
 *    `src/shared`, `src/preload` or `relay/src`, including files nobody has
 *    written yet.
 * 6. **scrypt, run and compared against known answers.** Check 5 cannot see
 *    this one: scrypt is not named by a string anywhere, so a scan for
 *    `createCipheriv('…')`-shaped calls will never mention it however carefully
 *    it is written. It is on the relay path — `machines/rendezvous.ts` derives
 *    the whole machine-to-machine pairing from it, and `device-auth.ts` hashes
 *    every device credential with it — and it arrived after this file did,
 *    which is exactly how the ChaCha hole opened: a primitive assumed rather
 *    than measured. If BoringSSL's scrypt differed by a byte, two machines
 *    would derive different rendezvous slots and pairing would fail with a
 *    fault instead of a refusal, in the one code path nobody can test from a
 *    unit test because both ends are the same runtime.
 *
 * Nothing here imports vitest. It reports through an exit code so it can run
 * inside a runtime that has no test framework installed.
 */

import {
  createHash,
  diffieHellman,
  generateKeyPairSync,
  getCiphers,
  getHashes,
  hkdfSync,
  randomBytes,
  scrypt as scryptCallback,
  scryptSync,
  timingSafeEqual,
} from 'node:crypto'
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  fingerprint,
  finishHandshake,
  generateStatic,
  respondToHandshake,
  startHandshake,
  type PendingInitiator,
  type StaticKeyPair,
} from '../../shared/sealed'
import { HOST_IDENTITY_FILE, loadHostIdentity } from './host-identity'
import { RENDEZVOUS_SALT, rendezvousIdentity } from './machines/rendezvous'

/* -------------------------------------------------------------------------- */
/* Reporting                                                                   */
/* -------------------------------------------------------------------------- */

let failures = 0
let checks = 0

function check(what: string, run: () => void): void {
  checks += 1
  try {
    run()
    process.stdout.write(`  ok   ${what}\n`)
  } catch (err) {
    failures += 1
    process.stdout.write(`  FAIL ${what}\n         ${(err as Error).message}\n`)
  }
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

function equalBytes(actual: Buffer, expected: Buffer, what: string): void {
  assert(
    actual.length === expected.length && actual.equals(expected),
    `${what}: expected ${expected.toString('hex').slice(0, 64)}… got ${actual.toString('hex').slice(0, 64)}…`,
  )
}

/** The repository root, handed in by the driver — this file runs from a bundle. */
const REPO = process.env.TD_REPO_ROOT
if (!REPO) {
  process.stderr.write('TD_REPO_ROOT is not set — run this through scripts/check-electron-crypto.mjs\n')
  process.exit(2)
}

/* -------------------------------------------------------------------------- */
/* 0. The runtime                                                              */
/* -------------------------------------------------------------------------- */

const ciphers = getCiphers()
process.stdout.write(
  `\nruntime: electron ${process.versions.electron ?? '(none)'} · node ${process.versions.node} · ` +
    `openssl ${process.versions.openssl ?? '(none)'} · ${ciphers.length} ciphers\n`,
)
assert(
  process.versions.electron,
  'this probe must run under Electron — plain Node is the runtime that hid the bug',
)
process.stdout.write(
  `chacha ciphers offered by this runtime: ${JSON.stringify(ciphers.filter((c) => c.includes('chacha')))}\n\n`,
)

/* -------------------------------------------------------------------------- */
/* 1. Primitives, exercised                                                    */
/* -------------------------------------------------------------------------- */

process.stdout.write('primitives, run rather than listed\n')

check('x25519 keygen and diffieHellman', () => {
  const a = generateKeyPairSync('x25519')
  const b = generateKeyPairSync('x25519')
  const ab = diffieHellman({ privateKey: a.privateKey, publicKey: b.publicKey })
  const ba = diffieHellman({ privateKey: b.privateKey, publicKey: a.publicKey })
  assert(ab.length === 32, `shared secret was ${ab.length} bytes`)
  equalBytes(ab, ba, 'the two sides derived different secrets')
})

check('sha256', () => {
  const digest = createHash('sha256').update('terminaldeck').digest()
  assert(digest.length === 32, `digest was ${digest.length} bytes`)
})

check('hkdf-sha256, 64 bytes out', () => {
  const out = Buffer.from(hkdfSync('sha256', Buffer.alloc(32, 1), Buffer.alloc(32, 2), Buffer.alloc(0), 64))
  assert(out.length === 64, `hkdf produced ${out.length} bytes`)
})

check('randomBytes and timingSafeEqual', () => {
  const value = randomBytes(32)
  assert(timingSafeEqual(value, Buffer.from(value)), 'timingSafeEqual disagreed with itself')
  assert(!timingSafeEqual(value, randomBytes(32)), 'timingSafeEqual matched two random buffers')
})

check('chacha20-poly1305 through sealed.ts, whatever it is built on', () => {
  // Deliberately not `createCipheriv`: the point is that the module's AEAD
  // works here, not that any particular library provides it.
  const mac = generateStatic()
  const device = generateStatic()
  const started = startHandshake(device, mac.publicKey)
  respondToHandshake(mac, started.message, () => true)
})

/* -------------------------------------------------------------------------- */
/* 2. A live handshake and a sealed round trip                                 */
/* -------------------------------------------------------------------------- */

process.stdout.write('\na real handshake, in this runtime\n')

check('handshake completes and both directions carry traffic', () => {
  const mac = generateStatic()
  const device = generateStatic()
  const started = startHandshake(device, mac.publicKey)
  const answered = respondToHandshake(mac, started.message, (key) => key.equals(device.publicKey))
  const client = finishHandshake(started.pending, answered.reply)
  const server = answered.transport

  assert(answered.devicePublicKey.equals(device.publicKey), 'the responder named the wrong device')
  assert(client.channelBinding.equals(server.channelBinding), 'the two ends bound different channels')
  assert(server.receiveText(client.sendText('ls -la')) === 'ls -la', 'phone to Mac failed')
  assert(client.receiveText(server.sendText('total 0\r\n')) === 'total 0\r\n', 'Mac to phone failed')

  const big = randomBytes(64 * 1024)
  assert(server.receive(client.send(big)).equals(big), 'a 64 KiB frame did not survive')
  assert(server.receive(client.send(Buffer.alloc(0))).length === 0, 'an empty frame did not survive')
})

check('a forged frame is still refused here', () => {
  const mac = generateStatic()
  const device = generateStatic()
  const started = startHandshake(device, mac.publicKey)
  const answered = respondToHandshake(mac, started.message, () => true)
  finishHandshake(started.pending, answered.reply)

  const frame = answered.transport.send(Buffer.from('x'))
  frame[frame.length - 1] ^= 0x01
  let threw = false
  try {
    answered.transport.receive(frame)
  } catch {
    threw = true
  }
  assert(threw, 'a frame with a flipped tag byte was accepted')
})

/* -------------------------------------------------------------------------- */
/* 3. Known-answer vectors recorded before the AEAD changed                    */
/* -------------------------------------------------------------------------- */

process.stdout.write('\nknown-answer vectors (ios/Tests/Fixtures/sealed-vectors.json)\n')

interface VectorFrame {
  plaintext: string
  frame: string
}

interface VectorSession {
  label: string
  mac: { publicKey: string; privateKey: string }
  device: { publicKey: string; privateKey: string }
  ephemeralPrivate: string
  handshakeMessage: string
  pendingChainingKey: string
  pendingH: string
  reply: string
  channelBinding: string
  devicePublicKey: string
  initiatorToResponder: VectorFrame[]
  responderToInitiator: VectorFrame[]
}

interface Vectors {
  noiseName: string
  sealedVersion: number
  sessions: VectorSession[]
  fingerprints: { publicKey: string; fingerprint: string }[]
}

const vectorFile = join(REPO, 'ios/Tests/Fixtures/sealed-vectors.json')
const hex = (value: string): Buffer => Buffer.from(value, 'hex')

let vectors: Vectors | null = null
check('the committed vectors are readable', () => {
  vectors = JSON.parse(readFileSync(vectorFile, 'utf8')) as Vectors
  assert(vectors.sessions.length > 0, 'the fixture holds no sessions')
})

for (const session of vectors === null ? [] : (vectors as Vectors).sessions) {
  const mac: StaticKeyPair = {
    publicKey: hex(session.mac.publicKey),
    privateKey: hex(session.mac.privateKey),
  }

  check(`[${session.label}] the responder opens a handshake recorded by the old code`, () => {
    const answered = respondToHandshake(mac, hex(session.handshakeMessage), () => true)
    equalBytes(answered.devicePublicKey, hex(session.devicePublicKey), 'the device key recovered')
  })

  check(`[${session.label}] the initiator reproduces the recorded frames byte for byte`, () => {
    // Reconstructed rather than re-run: the recorded handshake used an ephemeral
    // that `startHandshake` will never choose again, and the fixture kept every
    // field of the pending state so this side can be replayed exactly.
    const pending: PendingInitiator = {
      ephemeralPrivate: hex(session.ephemeralPrivate),
      chainingKey: hex(session.pendingChainingKey),
      h: hex(session.pendingH),
      staticPrivate: hex(session.device.privateKey),
    }
    const client = finishHandshake(pending, hex(session.reply))
    equalBytes(client.channelBinding, hex(session.channelBinding), 'channel binding')

    // Sealing: every byte this side produces must equal what was recorded.
    for (const [index, expected] of session.initiatorToResponder.entries()) {
      equalBytes(client.send(hex(expected.plaintext)), hex(expected.frame), `sealed frame ${index}`)
    }
    // Opening: every frame the far end recorded must still open, to the byte.
    for (const [index, expected] of session.responderToInitiator.entries()) {
      equalBytes(client.receive(hex(expected.frame)), hex(expected.plaintext), `opened frame ${index}`)
    }
  })
}

check('fingerprints are unchanged', () => {
  for (const entry of (vectors as Vectors).fingerprints) {
    const actual = fingerprint(hex(entry.publicKey))
    assert(actual === entry.fingerprint, `expected ${entry.fingerprint}, got ${actual}`)
  }
})

/* -------------------------------------------------------------------------- */
/* 4. The host identity survives a restart                                     */
/* -------------------------------------------------------------------------- */

process.stdout.write('\nthe host identity, loaded twice in this runtime\n')

check('a stored identity is reused rather than quarantined and regenerated', () => {
  const dir = mkdtempSync(join(tmpdir(), 'td-identity-'))
  try {
    const first = loadHostIdentity(dir)
    const second = loadHostIdentity(dir)

    assert(second.hostId === first.hostId, `hostId changed across a reload: ${first.hostId} → ${second.hostId}`)
    assert(second.fingerprint === first.fingerprint, 'the fingerprint changed across a reload')
    equalBytes(second.keys.publicKey, first.keys.publicKey, 'the static public key changed')
    equalBytes(second.hostSecret, first.hostSecret, 'the host secret changed')

    const quarantined = readdirSync(dir).filter((name) => name.startsWith(`${HOST_IDENTITY_FILE}.corrupt-`))
    assert(
      quarantined.length === 0,
      `a good identity was quarantined: ${quarantined.join(', ')} — every paired phone would have been orphaned`,
    )
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

/* -------------------------------------------------------------------------- */
/* 5. Every algorithm name in the sources exists in this runtime               */
/* -------------------------------------------------------------------------- */

process.stdout.write('\nalgorithm names used anywhere in the product sources\n')

/**
 * Scanned by the driver, which has esbuild and can tell code from comments;
 * checked here, which is the only place `getCiphers()` means anything.
 */
interface AlgorithmUse {
  kind: 'cipher' | 'hash'
  name: string
  where: string[]
}

const available = { cipher: new Set(getCiphers()), hash: new Set(getHashes()) }
const algorithms = JSON.parse(process.env.TD_ALGORITHMS ?? '[]') as AlgorithmUse[]

assert(algorithms.length > 0, 'the driver passed no algorithm names — the scan has gone stale')

for (const use of algorithms) {
  check(`${use.kind} '${use.name}' exists here (${use.where.join(', ')})`, () => {
    assert(
      available[use.kind].has(use.name),
      `this runtime does not offer the ${use.kind} '${use.name}'. BoringSSL is not OpenSSL — ` +
        'either use a primitive it has, or bring an implementation with you the way sealed.ts does for ChaCha.',
    )
  })
}

/* -------------------------------------------------------------------------- */
/* 6. scrypt, which the relay path added after this file was written           */
/* -------------------------------------------------------------------------- */

process.stdout.write('\nscrypt, against answers recorded under plain Node\n')

/**
 * The parameters the product actually uses, in both places it uses them.
 *
 * `device-auth.ts` hashes every device credential at these, and
 * `machines/rendezvous.ts` derives a pairing rendezvous at the same ones on
 * purpose — the comment there says so, and the salt is versioned so that
 * changing them is a visible break rather than two builds quietly failing to
 * find each other. Written out again here rather than imported because a probe
 * that imported the constant would pass just as happily if somebody halved N:
 * the point is to pin the numbers a recorded answer was taken at.
 */
const SCRYPT = { N: 16384, r: 8, p: 1 } as const
/** Derived exactly as both call sites derive it: 32MB is not enough for 16384×8. */
const SCRYPT_MAXMEM = 256 * SCRYPT.N * SCRYPT.r

/**
 * Recorded under plain Node (OpenSSL 3.6.3) with these inputs and these
 * parameters. Not self-consistent — recorded on the *other* implementation,
 * which is the only kind of answer that can catch BoringSSL disagreeing.
 *
 *   scryptSync(Buffer.alloc(32, 0x2a), Buffer.alloc(16, 0x5b), 32, params)
 */
const CREDENTIAL_KAT = '4bf290a5a496b447a9166888fb58f41b13c8a9aa68a518737e3262a0d6d46b87'

/**
 * The same, for the rendezvous: the canonical form of one code, the versioned
 * salt, and the 64 bytes `rendezvousIdentity` splits into a relay slot secret
 * and a responder key pair.
 */
const RENDEZVOUS_KAT =
  '646639452580485e5bedb2a94a33340c6c00e6408ad91636c9144a00552f202b' +
  '8a9cbc26a0a81dbe81811217934593f968d4378c98b57bdd8589b8b0bec8cd89'

/**
 * A code somebody could be reading off the other machine's screen.
 *
 * Six digits, because that is what a code is now. These constants and
 * `RENDEZVOUS_KAT` were recorded against the old eight-character Crockford
 * code (`h4k9 2fqt`), and re-recording them was not a formality: the derivation
 * is keyed by the code, so every byte downstream of it moves. They were
 * regenerated under plain Node — the same way the originals were — and this
 * check then confirmed Electron reaches the identical bytes, which is the only
 * thing it exists to say.
 */
const CODE = '482913'
const CODE_HOST_ID = 'PNN7FEFPVPEPG8J6JD5LTK22CW'
const CODE_FINGERPRINT = '4JZJ-V39S-DBQ2-CQ5X-GGBS-9JSR'
const CODE_PUBLIC_KEY = 'PluJUUCYOIi9dWOnMK0Sq8NrO635DqyD0yTLIyeLlAU='

const credentialSecret = Buffer.alloc(32, 0x2a)
const credentialSalt = Buffer.alloc(16, 0x5b)

check('scryptSync exists here and answers what OpenSSL answered', () => {
  const key = scryptSync(credentialSecret, credentialSalt, 32, { ...SCRYPT, maxmem: SCRYPT_MAXMEM })
  equalBytes(key, Buffer.from(CREDENTIAL_KAT, 'hex'), 'scrypt at the credential parameters')
})

check('the rendezvous seed is the same 64 bytes it is everywhere else', () => {
  const seed = scryptSync('482913', RENDEZVOUS_SALT, 64, { ...SCRYPT, maxmem: SCRYPT_MAXMEM })
  equalBytes(seed, Buffer.from(RENDEZVOUS_KAT, 'hex'), 'the rendezvous seed')
})

check('two machines typing one code land on the same slot and the same key', () => {
  // The end of the derivation rather than the middle of it: a slot name and a
  // responder identity, which is what the two machines actually have to agree
  // on. A byte of difference here is a pairing that dials a relay slot nobody
  // is answering, and the person reading the code is told the machine cannot be
  // found — a fault dressed up as a refusal.
  const identity = rendezvousIdentity(CODE)
  assert(identity !== null, `${CODE} is no longer a code this build accepts`)
  assert(identity.hostId === CODE_HOST_ID, `rendezvous slot: expected ${CODE_HOST_ID}, got ${identity.hostId}`)
  assert(
    identity.fingerprint === CODE_FINGERPRINT,
    `responder fingerprint: expected ${CODE_FINGERPRINT}, got ${identity.fingerprint}`,
  )
  equalBytes(
    identity.keys.publicKey,
    Buffer.from(CODE_PUBLIC_KEY, 'base64'),
    'the responder public key derived from the code',
  )
})

/* -------------------------------------------------------------------------- */

function report(): never {
  process.stdout.write(
    `\n${checks - failures}/${checks} checks passed under Electron${failures === 0 ? '' : ` — ${failures} FAILED`}\n\n`,
  )
  process.exit(failures === 0 ? 0 : 1)
}

/*
 * The last check is asynchronous, and it is here rather than above because
 * `device-auth.ts` does not call `scryptSync` — it calls the callback form, on
 * the main process, once per attach. Two entry points into one primitive is two
 * places it can be missing, and the one that is missing is always the one
 * nobody ran.
 *
 * `process.exitCode` is set first, so a callback that never fires cannot be
 * read as a pass. Node exits 0 when its queue drains, and "quietly succeeded
 * because nothing happened" is the precise shape of the bug this whole file was
 * written after.
 */
process.exitCode = 1
scryptCallback(
  credentialSecret,
  credentialSalt,
  32,
  { ...SCRYPT, maxmem: SCRYPT_MAXMEM },
  (err: Error | null, key: Buffer) => {
    check('scrypt through the callback form, the way device-auth verifies a device', () => {
      assert(err === null, `scrypt reported ${err?.message ?? 'an error'}`)
      equalBytes(key, Buffer.from(CREDENTIAL_KAT, 'hex'), 'the callback form')
    })
    report()
  },
)
