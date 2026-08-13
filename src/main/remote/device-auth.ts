/**
 * Pairing and device trust for remote access.
 *
 * ## What is behind this door
 *
 * A remote client that gets past this module reaches a PTY running a coding
 * agent on someone's Mac, with that person's shell, their keys and their
 * source tree. There is no second gate further in. So this file is written for
 * the attacker rather than for the happy path, and every relaxation below is
 * one that was argued for rather than one that was convenient.
 *
 * ## Two gates, not one
 *
 * Pairing alone is not trust. A pairing token is a bearer secret that has to
 * survive being read aloud, typed into a phone, photographed off a screen or
 * shoulder-surfed in a café, and any of those hands it to someone else. So
 * redeeming a token does **not** grant access: it creates a device in
 * `pending`, which cannot attach to anything. A human at the Mac has to
 * approve it. Stealing the token inside its 60-second life gets an attacker a
 * row in a list the owner is about to look at, and nothing else.
 *
 * That is also why the 60 seconds is short enough to be slightly annoying. The
 * person pairing is standing in front of the machine; a token that lives long
 * enough to be convenient is one that lives long enough to leak.
 *
 * ## What is on disk, and what is not
 *
 * Device credentials are stored as scrypt hashes with a per-device salt, so the
 * file is not a set of keys. Reading `remote-auth.json` off a backup, a synced
 * folder or a stolen laptop gives you the names of the devices and no way to
 * become one. The credential exists in plaintext exactly once, in the return
 * value of `redeemPairingToken`, and is never written anywhere.
 *
 * A device's X25519 **public** key is stored beside it once relayed access
 * exists, and that does not weaken the sentence above. The public half verifies
 * a signature-shaped claim and produces nothing: an attacker holding it can
 * check a guess they already made, not become the device. The private half never
 * leaves the phone, and this Mac's own private key lives in a different file
 * that holds nothing else.
 *
 * Pairing tokens are held in memory only. They live for 60 seconds and the
 * person is at the keyboard, so persisting them buys nothing and would put a
 * second bearer secret on disk for no reason. A restart cancels a pairing in
 * flight, which is the correct direction to fail.
 *
 * ## Why the failure reasons are shaped the way they are
 *
 * `verifyCredential` answers `denied` for a bad credential whatever the state
 * of the device — unknown id, wrong secret, revoked device presenting the wrong
 * secret. `pending` and `revoked` are only ever told to a caller that proved it
 * holds the real credential. So the answers cannot be used to enumerate device
 * ids or to learn that an id is real, and an unknown id costs the same wall
 * time as a known one because the hash runs either way.
 *
 * These reasons are for the log on the Mac. Whatever transport wires this up
 * must collapse them before they cross the network — telling a remote caller
 * `rate-limited` and how long is a small gift, and telling it `pending` is a
 * larger one.
 *
 * No Electron imports on purpose: the storage directory is a constructor
 * argument, so the whole thing runs against a temp dir under vitest with no app
 * object anywhere near it.
 */

import { createHash, randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto'
import { readFileSync, renameSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { fingerprint } from '../../shared/sealed'
import { writeSecretFile } from './secret-file'

/* -------------------------------------------------------------------------- */
/* Public shapes                                                               */
/* -------------------------------------------------------------------------- */

export type DeviceStatus = 'pending' | 'approved' | 'revoked'

export interface Device {
  id: string
  name: string
  addedAt: number
  /** null until the device has attached successfully at least once. */
  lastSeenAt: number | null
  approved: boolean
  revoked: boolean
  /** Derived from the two flags above; revocation outranks approval. */
  status: DeviceStatus
  /**
   * The device's X25519 public key in the short form a person can compare, or
   * null for a device that paired before it had one.
   *
   * Shown on the approval screen beside the same six groups on the phone. It is
   * not a security boundary on its own — the pairing code and the approval step
   * are — but it is what turns "trust this device" from a dialog you dismiss
   * into one you can actually check. Null means the device can only be reached
   * over the tailnet: without a key there is no sealed channel, so there is no
   * way for it to come in through a relay.
   */
  fingerprint: string | null
}

export interface PairingToken {
  /** Shown once, to a person standing at the Mac. Never persisted. */
  token: string
  expiresAt: number
}

export type RedeemFailure =
  | 'malformed'
  | 'unknown'
  | 'used'
  | 'expired'
  | 'rate-limited'
  | 'bad-name'
  | 'too-many-devices'
  | 'storage'

export type RedeemResult =
  | { ok: true; credential: string; device: Device }
  | { ok: false; reason: RedeemFailure; retryAfterMs?: number }

export type VerifyFailure = 'malformed' | 'denied' | 'pending' | 'revoked' | 'rate-limited'

export type VerifyResult =
  | { ok: true; device: Device }
  | { ok: false; reason: VerifyFailure; retryAfterMs?: number }

export interface RemoteAuthOptions {
  /**
   * Injected clock. Everything in this file reads time through it — expiry,
   * lockouts and `lastSeenAt` — so a test can move time without sleeping and
   * without a single comparison quietly falling back to `Date.now()`.
   */
  now?: () => number
}

/* -------------------------------------------------------------------------- */
/* Tunables                                                                    */
/* -------------------------------------------------------------------------- */

/** Long enough to carry a code to a phone, short enough to be useless later. */
export const PAIRING_TTL_MS = 60_000

/** Failed credential attempts tolerated per device and per source address. */
export const MAX_FAILED_ATTEMPTS = 5

/** How long a tripped limiter stays tripped. */
export const LOCKOUT_MS = 15 * 60_000

export const REMOTE_AUTH_FILE = 'remote-auth.json'

/** A person pairs one device at a time; more than this is a stuck UI. */
const MAX_LIVE_TOKENS = 16

/** Device names are shown in the UI and go into logs, so they are bounded. */
const MAX_NAME_LENGTH = 64

/** Refuses to grow the trust list without bound if pairing ever runs in a loop. */
const MAX_DEVICES = 64

/** A real file is a few kilobytes; anything larger is not ours to parse. */
const MAX_FILE_BYTES = 256 * 1024

/**
 * Nothing this module mints is anywhere near this long. The bound exists so a
 * caller that forgets to check a frame size cannot hand this file a megabyte to
 * hash or to base64-decode; the transport bounding its own messages is the
 * first line, not the only one.
 */
const MAX_TOKEN_LENGTH = 512
const MAX_CREDENTIAL_LENGTH = 512

/** base64url, no padding — the only alphabet anything here mints. */
const BASE64URL = /^[A-Za-z0-9_-]+$/

/**
 * Cap on limiter bookkeeping. An attacker who can forge this many source
 * addresses has already escaped the per-address limiter by definition — that is
 * what the per-device limiter is for — so this cap protects memory rather than
 * pretending to be a defence.
 */
const MAX_TRACKED_KEYS = 1024

/**
 * `lastSeenAt` is written through at most this often. Without it, a client
 * reconnecting in a loop turns every attach into a disk write, which is a
 * denial of service that needs nothing but a valid credential to run.
 */
const LAST_SEEN_WRITE_MS = 60_000

const TOKEN_BYTES = 32
const CREDENTIAL_BYTES = 32
const DEVICE_ID_BYTES = 12
const SALT_BYTES = 16

interface ScryptParams {
  n: number
  r: number
  p: number
  keylen: number
}

/**
 * scrypt parameters, stored alongside each hash so they can be raised later
 * without locking out every device paired before the change.
 *
 * These are deliberately below what a password would need. A credential here is
 * 256 bits from `randomBytes`, not something a person chose, so there is no
 * dictionary to run and the KDF is defence in depth for the stored file rather
 * than the thing standing between an attacker and the shell. Measured at ~36ms
 * per verification on this machine, which an attach can afford and a guessing
 * loop cannot.
 */
const SCRYPT: ScryptParams = { n: 16384, r: 8, p: 1, keylen: 32 }

/**
 * Ceilings on the parameters read back off disk.
 *
 * Storing the parameters per record is what lets them be raised later; it also
 * means the file decides how much work a verification costs. Unbounded, a
 * single damaged or planted record turns one attach into seconds of CPU and
 * gigabytes of address space — `n` of 2^20 with `keylen` of 900MB measured at
 * 17 seconds for one call. The point of storing them was headroom, not a blank
 * cheque, so the headroom is stated: 2^18 is sixteen times today's cost and
 * still finishes in well under a second.
 */
const MAX_SCRYPT_N = 1 << 18
const MAX_SCRYPT_R = 32
const MAX_SCRYPT_P = 16
const MAX_SCRYPT_KEYLEN = 128
/** Base64 of a 16-byte salt and a 128-byte key both fit inside this. */
const MAX_STORED_FIELD_LENGTH = 256

/* -------------------------------------------------------------------------- */
/* Stored shapes                                                               */
/* -------------------------------------------------------------------------- */

interface StoredCredential extends ScryptParams {
  salt: string
  hash: string
}

interface StoredDevice {
  id: string
  name: string
  addedAt: number
  lastSeenAt: number | null
  approved: boolean
  revoked: boolean
  credential: StoredCredential
  /**
   * The device's X25519 **public** key, base64, or absent.
   *
   * This is the one thing in the file that is a key rather than a hash of one,
   * and it is safe to store precisely because it is the public half: it lets
   * this Mac verify that whoever is dialling holds the matching private key, and
   * it lets an attacker who steals the file verify a guess they already made.
   * It cannot become a device. The promise at the top of this module — that
   * `remote-auth.json` is not a set of keys — is unchanged.
   *
   * Optional because devices paired before relayed access existed do not have
   * one. Those keep working on the tailnet and are refused at the relay, which
   * is the correct direction: a channel we cannot authenticate is not opened.
   */
  publicKey?: string
}

interface StoredState {
  version: 1
  devices: StoredDevice[]
}

interface TokenRecord {
  /** sha256 of the token. The token itself is never held after minting. */
  hash: Buffer
  expiresAt: number
  usedAt: number | null
}

interface Attempts {
  failures: number
  blockedUntil: number
  updatedAt: number
}

/* -------------------------------------------------------------------------- */
/* Small helpers                                                               */
/* -------------------------------------------------------------------------- */

function sha256(value: string): Buffer {
  return createHash('sha256').update(value, 'utf8').digest()
}

function scrypt(secret: Buffer, salt: Buffer, params: ScryptParams): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scryptCallback(
      secret,
      salt,
      params.keylen,
      // maxmem defaults to 32MB and scrypt throws — rather than degrade — the
      // moment 128*N*r crosses it. Deriving it from the parameters means
      // raising N later stays a one-line change instead of a runtime failure.
      { N: params.n, r: params.r, p: params.p, maxmem: 256 * params.n * params.r },
      (err, key) => (err ? reject(err) : resolve(key)),
    )
  })
}

/** Equal-length inputs only, which is why everything compared here is a digest. */
function sameBytes(a: Buffer, b: Buffer): boolean {
  return a.length === b.length && timingSafeEqual(a, b)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

/**
 * Device names are typed by whoever is pairing and are then rendered next to
 * terminal output in this app. Control characters in that position are an
 * escape-sequence injection, so they never make it into storage.
 */
function cleanName(value: unknown): string | null {
  if (typeof value !== 'string') return null
  // Truncated before the scan, not after: a megabyte of control characters is
  // still a megabyte to walk, and the answer was never going to be longer than
  // MAX_NAME_LENGTH.
  const cleaned = value
    .slice(0, MAX_NAME_LENGTH * 8)
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .trim()
    .slice(0, MAX_NAME_LENGTH)
  return cleaned === '' ? null : cleaned
}

/** Bounded, so a hostile address string cannot bloat the limiter's keys. */
function addressKey(address: string): string {
  const trimmed = typeof address === 'string' ? address.trim().toLowerCase().slice(0, 64) : ''
  return `addr:${trimmed === '' ? 'unknown' : trimmed}`
}

function statusOf(device: { approved: boolean; revoked: boolean }): DeviceStatus {
  if (device.revoked) return 'revoked'
  return device.approved ? 'approved' : 'pending'
}

function toPublic(device: StoredDevice): Device {
  const key = publicKeyBytes(device.publicKey)
  return {
    id: device.id,
    name: device.name,
    addedAt: device.addedAt,
    lastSeenAt: device.lastSeenAt,
    approved: device.approved,
    revoked: device.revoked,
    status: statusOf(device),
    // The fingerprint rather than the key: the screen that reads this is asking
    // a person to compare six groups of characters with a phone, and 44
    // characters of base64 is a thing people tick rather than read.
    fingerprint: key === null ? null : fingerprint(key),
  }
}

/** X25519 public keys are exactly 32 bytes; a stored value of any other shape is not one. */
const PUBLIC_KEY_BYTES = 32

/**
 * Decode a stored public key, or null.
 *
 * A damaged key reads as *absent* rather than as a parse failure that drops the
 * whole record: the key is the relay's business and the credential hash is
 * everything else's, so losing the first must not revoke a device that is still
 * perfectly able to connect over the tailnet. Absent then fails closed at the
 * relay, which is the only place the key is consulted.
 */
function publicKeyBytes(stored: string | undefined): Buffer | null {
  if (typeof stored !== 'string' || stored === '') return null
  const raw = Buffer.from(stored, 'base64')
  return raw.length === PUBLIC_KEY_BYTES ? raw : null
}

function asStoredCredential(value: unknown): StoredCredential | null {
  if (!isRecord(value)) return null
  const { salt, hash, n, r, p, keylen } = value
  if (typeof salt !== 'string' || typeof hash !== 'string') return null
  if (salt.length > MAX_STORED_FIELD_LENGTH || hash.length > MAX_STORED_FIELD_LENGTH) return null
  // The parameters are stored so they can be raised, which also means the file
  // decides how much work an attach costs. Unbounded, one damaged record is a
  // seconds-long, gigabyte-wide stall on the main process every time the device
  // knocks — a fail-closed module that fails closed slowly is still a way to
  // take the machine down. Out-of-range reads as unreadable: the record is
  // dropped and the device is not trusted.
  if (typeof n !== 'number' || typeof r !== 'number' || typeof p !== 'number') return null
  if (typeof keylen !== 'number') return null
  if (!Number.isInteger(n) || n < 2 || n > MAX_SCRYPT_N || (n & (n - 1)) !== 0) return null
  if (!Number.isInteger(r) || r < 1 || r > MAX_SCRYPT_R) return null
  if (!Number.isInteger(p) || p < 1 || p > MAX_SCRYPT_P) return null
  if (!Number.isInteger(keylen) || keylen < 16 || keylen > MAX_SCRYPT_KEYLEN) return null
  return { salt, hash, n, r, p, keylen }
}

function asStoredDevice(value: unknown): StoredDevice | null {
  if (!isRecord(value)) return null
  const credential = asStoredCredential(value.credential)
  if (!credential) return null
  const name = cleanName(value.name)
  if (typeof value.id !== 'string' || value.id === '' || name === null) return null
  if (typeof value.addedAt !== 'number') return null
  const lastSeenAt = typeof value.lastSeenAt === 'number' ? value.lastSeenAt : null
  const publicKey =
    typeof value.publicKey === 'string' && value.publicKey.length <= MAX_STORED_FIELD_LENGTH
      ? value.publicKey
      : undefined
  return {
    id: value.id,
    name,
    addedAt: value.addedAt,
    lastSeenAt,
    ...(publicKey === undefined ? {} : { publicKey }),
    // Anything that is not literally `true` reads as not approved, so a
    // corrupted or truncated flag fails closed rather than open.
    approved: value.approved === true,
    // The mirror image: anything that is not literally `false` reads as
    // revoked, so a damaged record cannot resurrect access.
    revoked: value.revoked !== false,
    credential,
  }
}

/**
 * `<deviceId>.<secret>`.
 *
 * The id travels with the secret so a lookup is one device and one hash. The
 * alternative — trying every stored device — turns a single guess into N scrypt
 * runs, which hands an attacker an amplifier pointed at the Mac's CPU.
 */
function parseCredential(credential: unknown): { id: string; secret: Buffer } | null {
  if (typeof credential !== 'string') return null
  if (credential.length === 0 || credential.length > MAX_CREDENTIAL_LENGTH) return null
  const dot = credential.indexOf('.')
  if (dot <= 0 || dot === credential.length - 1) return null
  const id = credential.slice(0, dot)
  const encoded = credential.slice(dot + 1)
  // Both halves are checked against the alphabet they were minted in, because
  // `Buffer.from(_, 'base64url')` silently drops anything it does not
  // recognise. Without this, `<credential>.=!!` decodes to the same bytes as
  // `<credential>` and verifies — a credential with no canonical form is one
  // that cannot be compared, counted or blocklisted as a string anywhere
  // upstream.
  if (!BASE64URL.test(id) || !BASE64URL.test(encoded)) return null
  const secret = Buffer.from(encoded, 'base64url')
  if (secret.length === 0) return null
  return { id, secret }
}

/* -------------------------------------------------------------------------- */
/* RemoteAuth                                                                  */
/* -------------------------------------------------------------------------- */

export class RemoteAuth {
  /** Absolute path of the trust file. Exposed for diagnostics and tests. */
  readonly file: string

  private readonly dir: string
  private readonly now: () => number
  private devices: StoredDevice[] = []
  private readonly tokens = new Map<string, TokenRecord>()
  private readonly attempts = new Map<string, Attempts>()

  /**
   * Salt for the decoy hash run when a device id is unknown. Per instance and
   * never stored: its only job is to make the wall time of a lookup say nothing
   * about whether the id exists.
   */
  private readonly decoySalt = randomBytes(SALT_BYTES)

  constructor(storageDir: string, options: RemoteAuthOptions = {}) {
    this.dir = storageDir
    this.file = join(storageDir, REMOTE_AUTH_FILE)
    this.now = options.now ?? Date.now
    this.load()
  }

  /* ---------------------------------------------------------------- pairing */

  /**
   * Mint a single-use pairing token.
   *
   * Only the token's digest is kept, so nothing in this process holds a live
   * bearer secret after the call returns — the caller shows it and drops it.
   */
  createPairingToken(): PairingToken {
    const now = this.now()
    this.pruneTokens(now)

    const token = randomBytes(TOKEN_BYTES).toString('base64url')
    const hash = sha256(token)
    const expiresAt = now + PAIRING_TTL_MS
    this.tokens.set(hash.toString('hex'), { hash, expiresAt, usedAt: null })
    return { token, expiresAt }
  }

  /**
   * Trade a pairing token for a per-device credential, returned exactly once.
   *
   * The token is burned the instant it matches — before the name is checked,
   * before the file is written, before anything else can throw. A caller that
   * fails halfway gets no second attempt with the same token, which is the
   * difference between "one-shot" and "one-shot when it works".
   *
   * `address` is optional because the local UI may not have one, but any
   * transport that has it should pass it: without it, token guessing is capped
   * only by the token's own entropy.
   *
   * `devicePublicKey` is the device's X25519 static key, and it arrives
   * **already authenticated** — the relay transport only calls this after a
   * Noise handshake in which the far end proved it holds the matching private
   * key. It is stored so that every later connection from that device can be
   * tied to the same key, which is what makes a stolen credential useless
   * without the phone. Absent for a device on the tailnet, which has no
   * handshake to have proved anything with.
   */
  async redeemPairingToken(
    token: unknown,
    deviceName: unknown,
    address?: string,
    devicePublicKey?: Buffer,
  ): Promise<RedeemResult> {
    const now = this.now()
    if (typeof token !== 'string' || token === '' || token.length > MAX_TOKEN_LENGTH) {
      return { ok: false, reason: 'malformed' }
    }

    const keys = address === undefined ? [] : [addressKey(address)]
    const blocked = this.blockedFor(keys, now)
    if (blocked > 0) return { ok: false, reason: 'rate-limited', retryAfterMs: blocked }

    const record = this.matchToken(token)
    if (!record) {
      this.noteFailure(keys, now)
      return { ok: false, reason: 'unknown' }
    }

    // Burn first. Everything below this line is allowed to fail.
    const alreadyUsed = record.usedAt !== null
    record.usedAt = now
    if (alreadyUsed) {
      this.noteFailure(keys, now)
      return { ok: false, reason: 'used' }
    }
    // `>=`, not `>`: a token minted at t with a 60s TTL is dead at t+60000, not
    // alive for one more millisecond.
    if (now >= record.expiresAt) return { ok: false, reason: 'expired' }

    const name = cleanName(deviceName)
    if (name === null) return { ok: false, reason: 'bad-name' }
    if (this.rosterWithRoom().length >= MAX_DEVICES) return { ok: false, reason: 'too-many-devices' }

    const id = randomBytes(DEVICE_ID_BYTES).toString('base64url')
    const secret = randomBytes(CREDENTIAL_BYTES)
    const salt = randomBytes(SALT_BYTES)
    const hash = await scrypt(secret, salt, SCRYPT)

    const device: StoredDevice = {
      id,
      name,
      addedAt: now,
      lastSeenAt: null,
      // Pending, deliberately. The credential is real and still opens nothing
      // until a human at the Mac approves it.
      approved: false,
      revoked: false,
      credential: { ...SCRYPT, salt: salt.toString('base64'), hash: hash.toString('base64') },
      // Refused rather than truncated or padded: a key of the wrong length is a
      // caller bug, and storing it would bind the device to something no
      // handshake can ever match.
      ...(devicePublicKey !== undefined && devicePublicKey.length === PUBLIC_KEY_BYTES
        ? { publicKey: devicePublicKey.toString('base64') }
        : {}),
    }

    try {
      // Persist before handing the credential out. A credential we returned but
      // never stored is one the user can never make work, and they would have
      // no way to tell that apart from a rejection.
      // Recomputed here rather than reused from the pre-check: the roster can
      // have changed while scrypt was running.
      this.commit([...this.rosterWithRoom(), device])
    } catch (err) {
      console.error('[remote-auth] could not persist a newly paired device:', err)
      return { ok: false, reason: 'storage' }
    }

    this.clearFailures(keys)
    return { ok: true, credential: `${id}.${secret.toString('base64url')}`, device: toPublic(device) }
  }

  /* ---------------------------------------------------------------- devices */

  listDevices(): Device[] {
    return this.devices.map(toPublic).sort((a, b) => b.addedAt - a.addedAt)
  }

  /**
   * Approve a pending device. False when there is nothing to approve.
   *
   * A revoked device is never approved back into service. Revocation means the
   * credential is assumed to be in someone else's hands, and un-revoking would
   * hand it back to them — the device pairs again and gets a new one.
   */
  approveDevice(id: string): boolean {
    const next = structuredClone(this.devices)
    const device = next.find((candidate) => candidate.id === id)
    if (!device || device.revoked || device.approved) return false
    device.approved = true
    this.commit(next)
    return true
  }

  /**
   * Revoke a device. Throws if the write fails rather than reporting success: a
   * revocation the UI believes and the disk does not is exactly the failure
   * that puts a stolen device back on the shell after the next restart.
   */
  revokeDevice(id: string): boolean {
    const next = structuredClone(this.devices)
    const device = next.find((candidate) => candidate.id === id)
    if (!device || device.revoked) return false
    device.revoked = true
    this.commit(next)
    // Any lockout recorded against this device is meaningless now, and keeping
    // it only wastes an entry.
    this.clearFailures([`device:${id}`])
    return true
  }

  /**
   * Decide whether a presented credential may attach, from `address`.
   *
   * The order here matters: the limiter is consulted before any hashing, so a
   * guessing loop cannot spend the Mac's CPU on scrypt, and the hash runs even
   * for an unknown device so the timing does not answer questions the reasons
   * refuse to.
   */
  async verifyCredential(credential: unknown, address: string): Promise<VerifyResult> {
    const now = this.now()
    const parsed = parseCredential(credential)
    if (!parsed) return { ok: false, reason: 'malformed' }

    const keys = [`device:${parsed.id}`, addressKey(address)]
    const blocked = this.blockedFor(keys, now)
    if (blocked > 0) return { ok: false, reason: 'rate-limited', retryAfterMs: blocked }

    const device = this.devices.find((candidate) => candidate.id === parsed.id)
    const matched = device
      ? await this.matchesCredential(device.credential, parsed.secret)
      : await this.decoyHash(parsed.secret)

    if (!device || !matched) {
      this.noteFailure(keys, now)
      return { ok: false, reason: 'denied' }
    }

    if (device.revoked) {
      // Counted: a revoked credential still being presented is either a stolen
      // one or a client refusing to take no for an answer, and both should stop
      // costing this machine a scrypt per attempt.
      this.noteFailure(keys, now)
      return { ok: false, reason: 'revoked' }
    }

    // Not counted. Polling until the owner presses approve is the intended
    // flow, and locking a device out for doing what it was told to do would
    // turn pairing into a coin flip.
    if (!device.approved) return { ok: false, reason: 'pending' }

    this.clearFailures(keys)
    this.touch(device, now)
    return { ok: true, device: toPublic(device) }
  }

  /* ------------------------------------------------------------ public keys */

  /**
   * Is this X25519 key one a device here holds?
   *
   * Asked by the relay transport in the middle of a Noise handshake, before any
   * reply exists, so that an unpaired device never gets a channel it could send
   * anything down. A revoked device is not one: revocation outranks everything,
   * and cutting it here costs the attacker the connection before the app layer
   * has spent a scrypt on it.
   *
   * Every stored key is compared, with no early exit, so the answer does not
   * depend on where in the list a match sat. There are at most 64 of them.
   */
  knowsDeviceKey(publicKey: Buffer): boolean {
    if (publicKey.length !== PUBLIC_KEY_BYTES) return false
    let found = false
    for (const device of this.devices) {
      if (device.revoked) continue
      const stored = publicKeyBytes(device.publicKey)
      if (stored !== null && sameBytes(stored, publicKey)) found = true
    }
    return found
  }

  /**
   * Does *this* device hold that key?
   *
   * The question `knowsDeviceKey` cannot answer, and the one that closes the
   * hole between the two authentications a relayed connection carries: the
   * handshake proves possession of a private key, the credential proves
   * possession of a bearer secret, and without this they could belong to two
   * different devices. A credential copied off one phone onto another is then
   * refused, because the other phone cannot produce the first one's key.
   *
   * False when the device has no stored key: an unbindable device is not one
   * that binds to anything.
   */
  deviceHoldsKey(id: string, publicKey: Buffer): boolean {
    if (publicKey.length !== PUBLIC_KEY_BYTES) return false
    const device = this.devices.find((candidate) => candidate.id === id)
    if (!device) return false
    const stored = publicKeyBytes(device.publicKey)
    return stored !== null && sameBytes(stored, publicKey)
  }

  /* ------------------------------------------------------------- internals */

  /**
   * Constant-time lookup across every live token.
   *
   * No early exit: returning as soon as a digest matches would make the answer
   * depend on where in the map the match sat. There are at most MAX_LIVE_TOKENS
   * of them, so scanning them all costs nothing worth saving.
   */
  private matchToken(token: string): TokenRecord | null {
    const presented = sha256(token)
    let found: TokenRecord | null = null
    for (const record of this.tokens.values()) {
      if (sameBytes(presented, record.hash)) found = record
    }
    return found
  }

  private pruneTokens(now: number): void {
    for (const [key, record] of this.tokens) {
      if (now >= record.expiresAt) this.tokens.delete(key)
    }
    // A used-but-unexpired record is kept on purpose, so a replay can be told
    // apart from a guess for as long as the token would have lived.
    while (this.tokens.size >= MAX_LIVE_TOKENS) {
      const oldest = [...this.tokens.entries()].sort((a, b) => a[1].expiresAt - b[1].expiresAt)[0]
      if (!oldest) break
      this.tokens.delete(oldest[0])
    }
  }

  /**
   * The device list with room for one more, if room can be made honestly.
   *
   * A revoked record refuses the same credential whether it is here (`revoked`)
   * or gone (`denied`), so it is not carrying any trust — it is carrying a
   * slot. Without this, sixty-four pair-and-revoke cycles fill MAX_DEVICES with
   * tombstones and pairing stops working for good, and there is no delete
   * anywhere in this API to undo it: the only cure is deleting the file by
   * hand, which is also how a user loses every device they still trust.
   *
   * Approved and pending rows are never dropped. Running out of room for real
   * devices is the user's problem to solve by revoking one, not this file's to
   * solve by guessing which one they meant.
   */
  private rosterWithRoom(): StoredDevice[] {
    if (this.devices.length < MAX_DEVICES) return this.devices
    const surplus = this.devices.length - MAX_DEVICES + 1
    const doomed = new Set(
      this.devices
        .filter((device) => device.revoked)
        .sort((a, b) => a.addedAt - b.addedAt)
        .slice(0, surplus),
    )
    if (doomed.size === 0) return this.devices
    return this.devices.filter((device) => !doomed.has(device))
  }

  private async matchesCredential(stored: StoredCredential, secret: Buffer): Promise<boolean> {
    try {
      const expected = Buffer.from(stored.hash, 'base64')
      const actual = await scrypt(secret, Buffer.from(stored.salt, 'base64'), {
        n: stored.n,
        r: stored.r,
        p: stored.p,
        keylen: stored.keylen,
      })
      return sameBytes(expected, actual)
    } catch (err) {
      // Unusable parameters in a stored record must read as "no", never as an
      // exception some caller upstream turns into a pass.
      console.error('[remote-auth] a stored credential could not be checked:', err)
      return false
    }
  }

  /** Always false. Exists only to spend the same time as a real check. */
  private async decoyHash(secret: Buffer): Promise<boolean> {
    await scrypt(secret, this.decoySalt, SCRYPT)
    return false
  }

  private touch(device: StoredDevice, now: number): void {
    const previous = device.lastSeenAt
    device.lastSeenAt = now
    if (previous !== null && now - previous < LAST_SEEN_WRITE_MS) return
    try {
      this.commit(this.devices)
    } catch (err) {
      // The attach itself already succeeded; losing the timestamp is cosmetic
      // and must not turn into a refusal.
      console.error('[remote-auth] could not record lastSeenAt:', err)
      device.lastSeenAt = previous
    }
  }

  /* -------------------------------------------------------------- limiting */

  /** Milliseconds remaining on the longest active block across `keys`. */
  private blockedFor(keys: string[], now: number): number {
    let longest = 0
    for (const key of keys) {
      const entry = this.attempts.get(key)
      if (entry && entry.blockedUntil > now) longest = Math.max(longest, entry.blockedUntil - now)
    }
    return longest
  }

  private noteFailure(keys: string[], now: number): void {
    for (const key of keys) {
      const entry = this.attempts.get(key) ?? { failures: 0, blockedUntil: 0, updatedAt: now }
      // Two things reset the count: having served a cooldown, and simply not
      // having failed in a long time. Without the second, four typos spread
      // over a month would add up to a lockout.
      if (now >= entry.blockedUntil && now - entry.updatedAt > LOCKOUT_MS) entry.failures = 0
      if (entry.blockedUntil !== 0 && now >= entry.blockedUntil) {
        entry.failures = 0
        entry.blockedUntil = 0
      }
      entry.failures += 1
      entry.updatedAt = now
      // An attempt made *during* a cooldown never reaches here, so a blocked
      // caller cannot extend its own block by retrying — which would lock out
      // the legitimate owner of a device far more often than an attacker.
      if (entry.failures >= MAX_FAILED_ATTEMPTS) entry.blockedUntil = now + LOCKOUT_MS
      this.attempts.set(key, entry)
    }
    this.pruneAttempts(now)
  }

  private clearFailures(keys: string[]): void {
    for (const key of keys) this.attempts.delete(key)
  }

  private pruneAttempts(now: number): void {
    if (this.attempts.size <= MAX_TRACKED_KEYS) return
    const cold = [...this.attempts.entries()]
      .filter(([, entry]) => entry.blockedUntil <= now)
      .sort((a, b) => a[1].updatedAt - b[1].updatedAt)
    // Only entries that are not currently blocking anyone are dropped. An
    // active lockout is the one thing in this map worth keeping.
    for (const [key] of cold) {
      if (this.attempts.size <= MAX_TRACKED_KEYS) break
      this.attempts.delete(key)
    }
  }

  /* -------------------------------------------------------------- storage */

  /**
   * Swap in a new device list, on disk first.
   *
   * In-memory state is only replaced once the write lands, so a failed write
   * leaves this process and the file agreeing with each other rather than
   * drifting until the next restart reveals it.
   */
  private commit(devices: StoredDevice[]): void {
    this.persist({ version: 1, devices })
    this.devices = devices
  }

  private persist(state: StoredState): void {
    // Every step of that write is load-bearing and is explained where it lives;
    // the private key file next door needs exactly the same one, and two copies
    // of it is how the two end up disagreeing about which steps mattered.
    writeSecretFile(this.dir, this.file, JSON.stringify(state, null, 2))
  }

  private load(): void {
    let raw: string
    try {
      const { size } = statSync(this.file)
      if (size > MAX_FILE_BYTES) {
        this.quarantine(`oversized (${size} bytes)`)
        return
      }
      raw = readFileSync(this.file, 'utf8')
    } catch (err) {
      // No file is the normal first run. Anything else — unreadable, wrong
      // permissions — leaves the allow-list empty, which refuses every device
      // rather than guessing at who was trusted.
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
        console.error('[remote-auth] trust file unreadable; no device will be trusted:', err)
      }
      return
    }

    let parsed: unknown
    try {
      parsed = JSON.parse(raw)
    } catch {
      this.quarantine('not valid JSON')
      return
    }

    if (!isRecord(parsed) || !Array.isArray(parsed.devices)) {
      this.quarantine('not a trust file')
      return
    }

    const devices: StoredDevice[] = []
    for (const entry of parsed.devices.slice(0, MAX_DEVICES)) {
      const device = asStoredDevice(entry)
      // A record we cannot read is dropped, not repaired. Guessing at the
      // missing half of a trust record is how a device gets trusted by
      // accident.
      if (device) devices.push(device)
      else console.error('[remote-auth] dropped an unreadable device record')
    }

    // Two rows claiming one device id is a damaged file, and `find` would
    // answer with whichever came first — so a planted row saying `approved:
    // true, revoked: false` in front of a revoked one puts the revoked device
    // back on the shell. The only safe reading of "is this still trusted?" when
    // the file contradicts itself is no.
    const byId = new Map<string, StoredDevice>()
    for (const device of devices) {
      const existing = byId.get(device.id)
      if (!existing) {
        byId.set(device.id, device)
        continue
      }
      existing.approved = false
      existing.revoked = true
      console.error('[remote-auth] duplicate device id in the trust file; treating it as revoked')
    }
    this.devices = [...byId.values()]
  }

  /**
   * Move a file we refuse to parse out of the way.
   *
   * Starting empty is the safe direction — nobody is trusted — but the next
   * write would overwrite whatever was there, and if the damage was something
   * recoverable that is the user's device list gone for good.
   */
  private quarantine(reason: string): void {
    // The clock alone is not unique enough: two processes starting together —
    // or an injected clock that does not move — would rename the second damaged
    // file over the first, destroying the copy this whole function exists to
    // keep.
    const aside = `${this.file}.corrupt-${this.now()}-${randomBytes(4).toString('hex')}`
    try {
      renameSync(this.file, aside)
      console.error(`[remote-auth] trust file ${reason}; moved aside to ${aside}`)
    } catch (err) {
      console.error(`[remote-auth] trust file ${reason} and could not be moved aside:`, err)
    }
  }
}
