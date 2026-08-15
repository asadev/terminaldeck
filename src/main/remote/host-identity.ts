/**
 * Who this Mac is, to a relay and to a phone.
 *
 * Two values, invented once and then kept forever, because both of them are
 * printed into a pairing QR that people photograph and phones remember:
 *
 *  - **A 32-byte host secret.** Its SHA-256, in base32, is the `hostId` — the
 *    public name a phone asks the relay for. Claiming that name means presenting
 *    the secret, a preimage nobody else can produce, so the name in a
 *    photographed QR cannot be squatted or impersonated. The relay stores
 *    neither value; it hashes and forgets.
 *  - **An X25519 static key pair.** The public half goes in the same QR and is
 *    what makes the phone's handshake a Noise **IK** rather than a leap of
 *    faith: the phone already knows which key it expects to be talking to, so a
 *    relay in the middle cannot answer for this Mac.
 *
 * ## The private key is the only new secret on disk
 *
 * `device-auth.ts` deliberately stores no key material — devices are scrypt
 * hashes, so a stolen `remote-auth.json` cannot become a device. This file is
 * the one exception in the feature, and it is unavoidable: a responder that
 * cannot prove it is this Mac is a responder any relay can impersonate. So it is
 * 0600, written through the same atomic-rename discipline as the trust file, and
 * it holds nothing else — no device list, no credentials, nothing whose loss
 * would compound.
 *
 * Losing it is recoverable and losing it is loud: a new identity means a new
 * `hostId`, so every paired phone stops finding this Mac and has to be paired
 * again. That is why a file we cannot read is moved aside rather than
 * overwritten, and why the console says so.
 *
 * ## Why the pair is checked rather than trusted
 *
 * A public key that does not match the private key beside it produces exactly
 * one symptom: every phone in the world fails with `handshake failed
 * authentication`, which is the same message a genuinely unpaired device gets.
 * That is an afternoon of debugging in exchange for four X25519 operations at
 * startup, so the pair is exercised through the real handshake — the public API
 * of `sealed.ts`, not a re-derivation of it — before it is handed to anything.
 *
 * ## The check must never be able to destroy what it is checking
 *
 * Running the real handshake has a failure mode that a re-derivation would not:
 * if the handshake cannot run at all, the check fails for a reason that has
 * nothing to do with the key. That is not hypothetical. Electron links
 * BoringSSL, BoringSSL has no ChaCha20-Poly1305, so `respondToHandshake` threw
 * `Unknown cipher` on every launch — and this file read that as "the identity
 * is corrupt", moved a perfectly good file to `relay-identity.json.corrupt-…`
 * and minted a new `hostId`. Every paired phone was orphaned, every launch, and
 * the only trace was a growing pile of quarantine files.
 *
 * So the verdict is three-way now, not two — see `PairVerdict`. A refusal
 * condemns the key; a fault condemns the build and leaves the key alone. A
 * self-check that can delete good data on a bad day is worse than no self-check
 * at all.
 */

import { renameSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import {
  SealedRefusal,
  fingerprint,
  generateStatic,
  respondToHandshake,
  secretBytes,
  startHandshake,
  type StaticKeyPair,
} from '../../shared/sealed'
import { HOST_SECRET_BYTES, hostIdFor } from '../../shared/relay-wire'
import { protectSecretFile, writeSecretFile } from './secret-file'

export const HOST_IDENTITY_FILE = 'relay-identity.json'

/** A real file is a few hundred bytes; anything larger is not ours to parse. */
const MAX_FILE_BYTES = 64 * 1024

const KEY_BYTES = 32

export interface HostIdentity {
  /** Presented to the relay to claim `hostId`. Never leaves this process. */
  hostSecret: Buffer
  /** The public name. Goes in the pairing QR and is not a secret. */
  hostId: string
  /** The Noise IK responder identity. Only the public half is ever published. */
  keys: StaticKeyPair
  /** The public key in the form a person can compare against their phone. */
  fingerprint: string
}

interface StoredIdentity {
  version: 1
  hostSecret: string
  publicKey: string
  privateKey: string
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function bytes(value: unknown, length: number): Buffer | null {
  if (typeof value !== 'string' || value.length > 128) return null
  const raw = Buffer.from(value, 'base64')
  return raw.length === length ? raw : null
}

/**
 * What a self-check can conclude.
 *
 * There are three outcomes here and the first version of this file only had
 * two, which is the bug that cost every paired phone on the machine.
 *
 *  - `sound` — the pair is a pair. Use it.
 *  - `corrupt` — the handshake *refused*. The public half does not match the
 *    private half, or one of them is not a key. Nothing on this machine can
 *    make that identity work again, so it is moved aside and a new one minted.
 *  - `runtime-broken` — the handshake could not run **at all**. Under Electron
 *    that meant `Unknown cipher`, because BoringSSL has no ChaCha. The identity
 *    was very probably perfect; the machine simply could not check it.
 *
 * Collapsing the third into the second is what turned a build problem into data
 * loss: a good identity was quarantined and regenerated on every single launch,
 * each new `hostId` orphaning every phone that had ever been paired. The file
 * is now left exactly where it is in that case.
 */
type PairVerdict = 'sound' | 'corrupt' | 'runtime-broken'

/**
 * Prove the stored pair is a pair, using nothing but the handshake it will do
 * for real. Throws nothing: a broken identity is an answer, not an exception.
 *
 * The `SealedRefusal` test is the whole point. That type means the sealed
 * channel ran correctly and said no — the only conclusion from which "this key
 * is bad" follows. Any other error means the crypto did not run, which says
 * nothing whatsoever about the key.
 */
function pairIsSound(keys: StaticKeyPair): { verdict: PairVerdict; error?: unknown } {
  try {
    const probe = generateStatic()
    const { message } = startHandshake(probe, keys.publicKey)
    respondToHandshake(keys, message, () => true)
    return { verdict: 'sound' }
  } catch (err) {
    if (err instanceof SealedRefusal) return { verdict: 'corrupt', error: err }
    return { verdict: 'runtime-broken', error: err }
  }
}

type Decoded =
  | { verdict: 'sound'; identity: HostIdentity }
  | { verdict: 'corrupt' }
  | { verdict: 'runtime-broken'; identity: HostIdentity; error: unknown }

function decode(raw: unknown): Decoded {
  if (!isRecord(raw)) return { verdict: 'corrupt' }
  const hostSecret = bytes(raw.hostSecret, HOST_SECRET_BYTES)
  const publicKey = bytes(raw.publicKey, KEY_BYTES)
  const privateKey = bytes(raw.privateKey, KEY_BYTES)
  if (!hostSecret || !publicKey || !privateKey) return { verdict: 'corrupt' }

  const keys: StaticKeyPair = { publicKey, privateKey }
  const identity: HostIdentity = {
    hostSecret,
    hostId: hostIdFor(hostSecret),
    keys,
    fingerprint: fingerprint(publicKey),
  }

  const checked = pairIsSound(keys)
  if (checked.verdict === 'sound') return { verdict: 'sound', identity }
  if (checked.verdict === 'corrupt') return { verdict: 'corrupt' }
  return { verdict: 'runtime-broken', identity, error: checked.error }
}

function fresh(): { identity: HostIdentity; stored: StoredIdentity } {
  const hostSecret = secretBytes(HOST_SECRET_BYTES)
  const keys = generateStatic()
  return {
    identity: {
      hostSecret,
      hostId: hostIdFor(hostSecret),
      keys,
      fingerprint: fingerprint(keys.publicKey),
    },
    stored: {
      version: 1,
      hostSecret: hostSecret.toString('base64'),
      publicKey: keys.publicKey.toString('base64'),
      privateKey: keys.privateKey.toString('base64'),
    },
  }
}

/**
 * Move a file we refuse to parse out of the way.
 *
 * Starting fresh is the only way forward — an identity that cannot be read
 * cannot answer a handshake — but the next write would overwrite whatever was
 * there, and if the damage was something recoverable that is every paired phone
 * gone for good.
 */
function quarantine(file: string, reason: string): void {
  const aside = `${file}.corrupt-${Date.now()}-${secretBytes(4).toString('hex')}`
  try {
    renameSync(file, aside)
    console.error(
      `[relay] the relay identity was ${reason}; moved aside to ${aside}. This Mac has a new ` +
        'host id, so every paired phone has to be paired again.',
    )
  } catch (err) {
    console.error(`[relay] the relay identity was ${reason} and could not be moved aside:`, err)
  }
}

/**
 * Read this Mac's identity, inventing one on first run.
 *
 * Synchronous on purpose. It runs once, when remote access is switched on, and
 * everything downstream — the relay dial, the pairing QR, the handshake — needs
 * the answer before it can do anything at all; an async read here would only
 * move the wait somewhere it is harder to see.
 *
 * Throws only when the identity cannot be *written*. A relay client running on
 * an identity it could not persist would work until the next launch and then
 * hand every paired phone a host id that no longer exists, which is worse than
 * refusing to start.
 */
export function loadHostIdentity(dir: string): HostIdentity {
  const file = join(dir, HOST_IDENTITY_FILE)

  /*
   * Repair the file's protection before reading it, on Windows.
   *
   * This file holds the X25519 PRIVATE KEY that is this machine's identity to
   * every paired device — the one secret here that is written **once** and from
   * then on only ever read. Every other secret in this app is rewritten
   * regularly (a credential on pairing, the daemon record on every start), so
   * the write path's protection reaches them on its own. This one it never
   * reaches: an install created by a build that predates that protection keeps
   * whatever ACL `%APPDATA%` handed down — on a shared PC, routinely readable by
   * the other accounts on it — and keeps it forever.
   *
   * Idempotent, memoised, and a no-op off Windows, so this costs one process on
   * the first launch after an upgrade and nothing afterwards.
   */
  protectSecretFile(dir, file)

  let raw: string | null = null
  try {
    const { size } = statSync(file)
    raw = size > MAX_FILE_BYTES ? null : readFileSync(file, 'utf8')
    if (raw === null) quarantine(file, `oversized (${size} bytes)`)
  } catch (err) {
    // No file is the normal first run; anything else is worth a line, because
    // the consequence is a new host id.
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.error('[relay] the relay identity could not be read:', err)
    }
  }

  if (raw !== null) {
    let parsed: unknown = null
    try {
      parsed = JSON.parse(raw)
    } catch {
      parsed = null
    }
    const existing = decode(parsed)
    if (existing.verdict === 'sound') return existing.identity

    if (existing.verdict === 'runtime-broken') {
      // Kept, deliberately. The identity is almost certainly fine — this build
      // cannot run the handshake that would prove it, which is a problem with
      // the build and not with the file. Throwing the file away would mint a
      // new hostId and unpair every phone, permanently, to work around a fault
      // that a fixed build repairs by itself.
      //
      // Remote access will not work until that is fixed, and the relay client
      // says so loudly on every attempt. But the pairings survive it.
      console.error(
        '[relay] this build cannot run the sealed handshake, so the stored identity could not be ' +
          'verified. It has been KEPT and is being used as-is — every paired device stays paired. ' +
          'Remote access will not work until the build is fixed:',
        existing.error,
      )
      return existing.identity
    }

    quarantine(file, 'not a usable identity')
  }

  const { identity, stored } = fresh()
  writeSecretFile(dir, file, JSON.stringify(stored, null, 2))
  return identity
}
