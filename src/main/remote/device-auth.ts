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
import { CODE_ENTROPY_BYTES, codeFromBytes } from '../../shared/short-code'
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

export type EnrollFailure = 'malformed' | 'bad-name' | 'too-many-devices' | 'storage' | 'rate-limited'

export type EnrollResult =
  | { ok: true; credential: string; device: Device }
  | { ok: false; reason: EnrollFailure; retryAfterMs?: number }

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
 * The device ids the wire can carry — and therefore the ids a device can be
 * revoked by.
 *
 * The same rule as `DEVICE_ID_RE` in `protocol.ts`, restated here rather than
 * imported because that file imports nothing and this one owns what its ids look
 * like; `device-auth.test.ts` runs both a minted id and a stored one through the
 * real `parseClientMessage`, so the two cannot drift apart without a red test.
 *
 * It is enforced on the way *in* from disk, in {@link asStoredDevice}, and that
 * is the point of having it at all. A stored device whose id this refuses could
 * never be named in a `devices.revoke` — the frame is refused at the parser — so
 * keeping the record would put a row on the device screen with a Remove button
 * beside it that cannot work. Dropped instead: a record whose shape cannot be
 * read is already dropped rather than repaired in this file, a dropped record is
 * a device that cannot attach (nothing matches its id), and "cannot attach" is
 * the safe direction for a record nothing can take away. In practice it refuses
 * nothing this app has ever minted — device ids have been base64url since the
 * first version of this file — it refuses a hand-edited or damaged one.
 */
const WIRE_DEVICE_ID = /^[A-Za-z0-9_-]{1,64}$/

/** Whether the wire can name this id in a `devices.revoke`. See {@link WIRE_DEVICE_ID}. */
export function isWireDeviceId(value: unknown): value is string {
  return typeof value === 'string' && WIRE_DEVICE_ID.test(value)
}

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

/**
 * A fresh device id, in the one alphabet this module mints, and never one that
 * begins with a dash.
 *
 * ## What this used to be load bearing for
 *
 * base64url is `[A-Za-z0-9_-]`, and `protocol.ts`'s shared `ID_RE` — which
 * `devices.revoke`, the one wire verb carrying a device id rather than reading it
 * off the socket, used to run that id through — additionally requires the first
 * character to be `[A-Za-z0-9]`. A raw base64url id leads with `-` or `_` about
 * one time in thirty, and such an id parsed on this side, stored, signed in, and
 * then could not be named in a `devices.revoke` at all: the frame was refused as
 * "without a device id" before it ever reached the gate — and a refused frame
 * closes the asking socket, so Remove knocked the *asking* phone off and left the
 * target signed in. ~3% of paired devices were unrevokable from a phone.
 *
 * Resampling here fixed that for new devices and could never fix it for the ones
 * already on disk, so `protocol.ts` grew a `DEVICE_ID_RE` for that one field —
 * the full base64url alphabet — and {@link isWireDeviceId} states the same rule
 * from this side. Every stored device is nameable now, whatever it was minted
 * with.
 *
 * ## Why it stays anyway
 *
 * A different reason, and a smaller one: these ids are printed by `terminaldeck
 * devices` and typed back into `terminaldeck revoke <id>`, and a value beginning
 * with a dash is a value that reads as a flag in most argument parsers. This
 * host's own parser takes it as a positional and `cli.test.ts` holds it to that,
 * but not every parser an id is ever pasted into will. Resampled rather than
 * mangled, so the id stays a clean 96 bits of the same alphabet a credential's
 * second half is.
 */
export function newDeviceId(): string {
  for (;;) {
    const id = randomBytes(DEVICE_ID_BYTES).toString('base64url')
    if (/^[A-Za-z0-9]/.test(id)) return id
  }
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

/**
 * The limiter key a sign-in attempt from this address counts against.
 *
 * A prefix rather than the bare `addressKey`, so a burst of wrong sign-ins and a
 * burst of wrong credentials never fill the same bucket: locking a device out of
 * reconnecting because somebody guessed a password from the same tailnet address
 * would be a worse bug than the one the limiter exists for. Same table, same
 * MAX_FAILED_ATTEMPTS and LOCKOUT_MS — a different door onto it.
 */
function enrollKey(address: string): string {
  return `enroll:${addressKey(address)}`
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

/* -------------------------------------------------------------------------- */
/* One live row per device key                                                 */
/* -------------------------------------------------------------------------- */

/**
 * **A device key names one row here, not a row per sign-in.**
 *
 * Photographed on his own phone, 0.10.1: Settings → Devices listed *iPhone ·
 * This phone · Your device · Connected now* and, directly under it, *iPhone ·
 * Your device · Seen 7m ago* — the same name, the same kind, and the **same
 * fingerprint**, `VK6R-M299-Q8P6-YJPK-BYNT-Q358`. One phone, one X25519 key, two
 * rows. Nothing on that screen tells them apart, and Remove on the wrong one
 * cuts off the phone in your hand.
 *
 * It happened because both mint paths below started from `newDeviceId()` and
 * looked at nothing first. Signing in again is an ordinary thing to do — after a
 * revoke, after a password change, or simply because somebody was not sure it
 * had worked — and it cost a duplicate row every time. The phone side settled
 * this exact argument for *servers* a week earlier, in `ServerStore.add`:
 * *"three logins to one box left three identical rows… the same login twice is
 * the **same server**, not a second one."* This is the device half of it, and it
 * belongs here rather than on the phone because the roster is the host's: the
 * trust file is the only place that knows a key was already enrolled, and a
 * client that merely hid the second row would still be one of two live
 * credentials away from a stranger's device list.
 *
 * ## Identity is the public key, and it can only be the public key
 *
 * Not the name — every iPhone since iOS 16 calls itself "iPhone". Not the
 * address, which moves with the network. The X25519 static key is what the
 * handshake proves possession of, it is what `deviceHoldsKey` already binds
 * every later connection to, and it is what the fingerprint on that screen is
 * made of. Two rows with one key are, provably, one device.
 *
 * A row with **no** key is never matched by any of this. A device that paired
 * over the tailnet has nothing to prove it is itself with, so two of them are
 * two devices as far as this file can honestly tell, and guessing otherwise
 * would merge two strangers' phones on the strength of a display name.
 *
 * A **revoked** row is never matched either. Revocation is permanent and
 * un-revoking would hand the credential back to whoever the revoke was about;
 * `device-kind.ts` also names *"revoke, pair again, choose again"* as the way to
 * change what a device is, and that only works if a revoked row stops being
 * something a later pairing can land back on.
 */

/**
 * How recently a row meant anything, for choosing between two that name one
 * device.
 *
 * Neither field answers it alone: a row minted a second ago has never been seen,
 * and the row that has been carrying the connection all week was added long
 * before it. The later of the two is when this record was last live.
 */
function freshness(device: StoredDevice): number {
  return Math.max(device.addedAt, device.lastSeenAt ?? 0)
}

/**
 * Which of two rows for one device is the one to keep.
 *
 * Approved beats pending, because a pending row opens nothing and keeping it
 * over a working one would sign the device out until somebody walked to the
 * machine. Then the fresher of the two, because a device stores the credential
 * it was handed last and forgets the one before it — the newest row is the one
 * whose secret the phone is actually holding, which is exactly what his frames
 * showed: the newest row was *Connected now* and the older one *Seen 7m ago*.
 *
 * Strictly `>`, so a genuine tie keeps whichever was met first and the answer
 * does not depend on the iteration turning over.
 */
function outranks(candidate: StoredDevice, holder: StoredDevice): boolean {
  if (candidate.approved !== holder.approved) return candidate.approved
  return freshness(candidate) > freshness(holder)
}

/**
 * Collapse rows that name one device, keeping the one row per key `outranks`
 * chooses. Rows with no key, and revoked rows, are left exactly as they are.
 *
 * The losers are **dropped**, not tombstoned. A duplicate is not a device that
 * was taken away — it is a second record of a device that is still trusted — so
 * marking it revoked would be the file saying something untrue about the phone
 * in his hand, and it would spend a `MAX_DEVICES` slot saying it. Dropping the
 * row is also what retires its credential: the id no longer resolves, so the
 * stale secret is refused at `verifyCredential` like any other unknown one.
 *
 * The array identity of the survivors is preserved, so a caller can tell whether
 * anything moved by comparing lengths.
 */
/**
 * The roster with `device` in it — replacing the row of the same id if there is
 * one, appended if there is not.
 *
 * Both mint paths write through this so that "refresh the row I already have"
 * and "add a row" are one line rather than two branches that can disagree about
 * ordering. Replacing **in place** keeps the file's order stable across a
 * re-login, which matters for nothing the code reads and quite a lot for a human
 * comparing two copies of `remote-auth.json`.
 */
function withDevice(devices: StoredDevice[], device: StoredDevice): StoredDevice[] {
  let replaced = false
  const next = devices.map((row) => {
    if (row.id !== device.id) return row
    replaced = true
    return device
  })
  return replaced ? next : [...next, device]
}

function collapseByKey(devices: StoredDevice[]): StoredDevice[] {
  const best = new Map<string, StoredDevice>()
  for (const device of devices) {
    if (device.revoked) continue
    const key = publicKeyBytes(device.publicKey)
    if (key === null) continue
    const slot = key.toString('base64')
    const holder = best.get(slot)
    if (holder === undefined || outranks(device, holder)) best.set(slot, device)
  }
  if (best.size === 0) return devices
  const kept = devices.filter((device) => {
    if (device.revoked) return true
    const key = publicKeyBytes(device.publicKey)
    if (key === null) return true
    return best.get(key.toString('base64')) === device
  })
  return kept.length === devices.length ? devices : kept
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
  // The id is held to the shape the wire can name — see {@link WIRE_DEVICE_ID}.
  // A record that fails it is one no `devices.revoke` could ever reach, which
  // means a device that could not be taken away; it is dropped rather than
  // trusted-but-unremovable.
  if (!isWireDeviceId(value.id) || name === null) return null
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
   *
   * ## Why this is six digits and not forty-three characters
   *
   * It used to be `randomBytes(32).toString('base64url')`, which is 256 bits and
   * unreadable. That was fine while the only thing on the other end was a phone
   * with a camera: the token went into a QR code and nobody ever saw it. The QR
   * did not work, and the link it carried was a bearer secret that had to travel
   * through a messaging app to reach a second machine. Both are gone.
   *
   * So every pairing now happens the one way that never needed a camera: a
   * person reads a code off one screen and types it into another. Six digits,
   * because a phone can put a numeric keypad under them and there is no case, no
   * alphabet and no ambiguous glyph to explain.
   *
   * The entropy argument is written out in full in `shared/short-code.ts`, with
   * the numbers, and it is not a comfortable one: 10^6 codes against 32^8
   * before. The short version is that a million is guarded by the sixty-second
   * life below, by a single use, and by five wrong answers killing **the code
   * itself** in `pairingDesk.offers` — which puts a guess at 5 × 10⁻⁶ per
   * pairing — and that redeeming it still only produces a *pending* device
   * somebody has to approve. The other half of the argument lives in
   * `machines/rendezvous.ts`: the code names a relay slot through scrypt rather
   * than a hash, so the million cannot be swept to find out which code is live.
   *
   * Nothing downstream cares about the shape: the token is hashed here, matched
   * as an opaque string, and told apart from a credential by the dot a code
   * cannot contain.
   */
  createPairingToken(): PairingToken {
    const now = this.now()
    this.pruneTokens(now)

    const token = codeFromBytes(randomBytes(CODE_ENTROPY_BYTES))
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

    /*
     * Refused rather than truncated or padded: a key of the wrong length is a
     * caller bug, and storing it would bind the device to something no handshake
     * can ever match. Null is also how the tailnet path arrives, which has no
     * handshake and therefore nothing to be recognised by.
     */
    const key =
      devicePublicKey !== undefined && devicePublicKey.length === PUBLIC_KEY_BYTES ? devicePublicKey : null

    /*
     * And pairing again from a phone this machine already knows refreshes that
     * phone's row rather than adding a second one — the same rule the sign-in
     * path keeps, argued in full above `freshness`.
     *
     * What is **not** touched here is `approved`. A row that a human has already
     * approved stays approved, because the only way to reach this branch is to
     * hold the device's private key, which is to *be* the phone that was
     * approved — making it pending again would sign a trusted device out until
     * somebody walked to the machine, and it would prove nothing that the
     * handshake has not already proved. A row still waiting stays waiting, for
     * the same reason read the other way: a second code does not approve
     * anything, and a human at the machine is still what the pending state is
     * for.
     *
     * And the kind is not re-asked, which is what keeps `device-kind.ts`'s rule
     * whole: *"revoke, pair again, choose again."* A revoked row is not matched
     * here, so that sentence still works exactly as written — the revoke is what
     * frees the key to land on a fresh id with a fresh choice. Pairing again
     * *without* revoking never re-asked the question either; it only used to
     * leave a second row behind while not asking it.
     */
    const already = key === null ? null : this.liveDeviceWithKey(key)
    if (already === null && this.rosterWithRoom().length >= MAX_DEVICES) {
      return { ok: false, reason: 'too-many-devices' }
    }

    const secret = randomBytes(CREDENTIAL_BYTES)
    const salt = randomBytes(SALT_BYTES)
    const hash = await scrypt(secret, salt, SCRYPT)
    const credential: StoredCredential = {
      ...SCRYPT,
      salt: salt.toString('base64'),
      hash: hash.toString('base64'),
    }

    const device: StoredDevice = already !== null && key !== null
      ? { ...already, name, credential, publicKey: key.toString('base64') }
      : {
          id: newDeviceId(),
          name,
          addedAt: now,
          lastSeenAt: null,
          // Pending, deliberately. The credential is real and still opens nothing
          // until a human at the Mac approves it.
          approved: false,
          revoked: false,
          credential,
          ...(key === null ? {} : { publicKey: key.toString('base64') }),
        }

    try {
      // Persist before handing the credential out. A credential we returned but
      // never stored is one the user can never make work, and they would have
      // no way to tell that apart from a rejection.
      // Recomputed here rather than reused from the pre-check: the roster can
      // have changed while scrypt was running.
      this.commit(withDevice(this.rosterWithRoom(), device))
    } catch (err) {
      console.error('[remote-auth] could not persist a newly paired device:', err)
      return { ok: false, reason: 'storage' }
    }

    this.clearFailures(keys)
    return { ok: true, credential: `${device.id}.${secret.toString('base64url')}`, device: toPublic(device) }
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

  /* ----------------------------------------------------------------- sign-in */

  /**
   * May this address try to sign in right now, or is it serving a lockout?
   *
   * Consulted by the sign-in layer **before** it spends this machine on an SSH
   * probe — that ordering is the whole point. Without it a guessing loop turns
   * this host into an amplifier pointed at its own sshd, one scrypt-free network
   * round-trip per guess. The limiter is the same one {@link verifyCredential}
   * reads, under {@link enrollKey}'s own prefix, so the two doors cannot lock
   * each other's users out.
   */
  enrollAllowed(address: string): { ok: true } | { ok: false; retryAfterMs: number } {
    const blocked = this.blockedFor([enrollKey(address)], this.now())
    return blocked > 0 ? { ok: false, retryAfterMs: blocked } : { ok: true }
  }

  /** Count a refused sign-in from this address; the fifth trips the lockout. */
  noteEnrollFailure(address: string): void {
    this.noteFailure([enrollKey(address)], this.now())
  }

  /**
   * Mint a **pre-approved** device bound to a public key, credential returned once.
   *
   * The sign-in counterpart to {@link redeemPairingToken}. The proof that got
   * here was a loopback SSH login to this machine's own sshd — strictly more
   * power than any paired device already holds — so the row is born `approved`
   * rather than `pending`: there is no weaker thing left for a human to approve.
   *
   * The public key is **required**, not optional as it is on the pairing path.
   * A device that cannot seal a channel cannot sign in at all, and a row with no
   * key could never be tied to the handshake that reaches it — which is the bind
   * {@link deviceHoldsKey} enforces on every later connection. A key of the
   * wrong length is a caller bug and is refused rather than stored.
   *
   * The credential is plaintext exactly once, in the return value, and a scrypt
   * hash on disk — the standing contract of this file. The secret that got here
   * is the caller's to forget; nothing in this method writes or logs it.
   */
  async enrollDevice(name: string, address: string, publicKey: Buffer): Promise<EnrollResult> {
    const now = this.now()
    if (!Buffer.isBuffer(publicKey) || publicKey.length !== PUBLIC_KEY_BYTES) {
      return { ok: false, reason: 'malformed' }
    }
    const cleaned = cleanName(name)
    if (cleaned === null) return { ok: false, reason: 'bad-name' }
    /*
     * The same key signing in again is the **same device**, not a second one.
     *
     * The whole argument is above `freshness`; the shape here is
     * `ServerStore.add`'s, deliberately: what is refreshed is the credential and
     * the name — the two things this sign-in just restated — and what is kept is
     * the `id`, which is what every per-device store in this app is keyed on.
     * Keeping it is not tidiness: a new id silently drops that phone's folder
     * grants, its window grants and its recorded kind on the floor and starts it
     * again as a stranger that happens to still be trusted.
     *
     * `addedAt` and `lastSeenAt` are kept for the same reason — *when this
     * machine first trusted this phone* is a fact about the phone, not about the
     * form that was just filled in — so the row does not jump to the top of a
     * list sorted by when devices arrived.
     *
     * The room check is skipped when a row is being refreshed, and that matters:
     * without it, the one person whose roster is full — quite possibly *because*
     * of duplicates this bug minted — would be refused a sign-in from a phone
     * that is already in the list.
     */
    const already = this.liveDeviceWithKey(publicKey)
    if (already === null && this.rosterWithRoom().length >= MAX_DEVICES) {
      return { ok: false, reason: 'too-many-devices' }
    }

    const secret = randomBytes(CREDENTIAL_BYTES)
    const salt = randomBytes(SALT_BYTES)
    const hash = await scrypt(secret, salt, SCRYPT)
    const credential: StoredCredential = {
      ...SCRYPT,
      salt: salt.toString('base64'),
      hash: hash.toString('base64'),
    }

    const device: StoredDevice = already
      ? {
          ...already,
          // The phone may have been renamed since; the row it already has is
          // display text and there is no reason to keep yesterday's copy.
          name: cleaned,
          // A pending row that signs in is approved by the sign-in, exactly as a
          // fresh one is: the login this machine accepted is the thing the
          // pending state was waiting for.
          approved: true,
          // And the old secret dies with the write. That is not a side effect to
          // be worked around — a re-login the user asked for should retire the
          // credential it replaces, which is the second half of what those two
          // rows were: two live secrets for one phone.
          credential,
          publicKey: publicKey.toString('base64'),
        }
      : {
          id: newDeviceId(),
          name: cleaned,
          addedAt: now,
          lastSeenAt: null,
          // Approved on mint. The sign-in already was the approval — a login this
          // machine accepts is a human at this machine, which is the exact thing the
          // pending state waits for on the pairing path.
          approved: true,
          revoked: false,
          credential,
          publicKey: publicKey.toString('base64'),
        }

    try {
      // Persist before returning the credential, and recompute the roster: the
      // list can have changed while scrypt ran. Same ordering redeemPairingToken
      // uses and for the same reason — a credential we returned but never stored
      // is one the user can never make work.
      this.commit(withDevice(this.rosterWithRoom(), device))
    } catch (err) {
      console.error('[remote-auth] could not persist a signed-in device:', err)
      return { ok: false, reason: 'storage' }
    }

    this.clearFailures([enrollKey(address)])
    return { ok: true, credential: `${device.id}.${secret.toString('base64url')}`, device: toPublic(device) }
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

  /**
   * The one live row holding this key, or null — the question both mint paths
   * ask before they write.
   *
   * Distinct from {@link knowsDeviceKey}, which answers *may this handshake
   * proceed* and is deliberately branch-free for timing; this one has to hand
   * back the row itself, so it is a plain search. It is also not on the hot
   * path: it runs once per sign-in or pairing, behind a rate limiter and an SSH
   * probe or a burned one-shot token.
   *
   * Revoked rows are skipped, and a file that somehow still holds two live rows
   * for one key answers with the one {@link outranks} chooses, so this and
   * {@link collapseByKey} cannot disagree about which row is the device.
   */
  private liveDeviceWithKey(publicKey: Buffer): StoredDevice | null {
    if (publicKey.length !== PUBLIC_KEY_BYTES) return null
    let found: StoredDevice | null = null
    for (const device of this.devices) {
      if (device.revoked) continue
      const stored = publicKeyBytes(device.publicKey)
      if (stored === null || !sameBytes(stored, publicKey)) continue
      if (found === null || outranks(device, found)) found = device
    }
    return found
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

    /*
     * And two rows claiming one **device key** — which is the file every phone
     * that ever signed in twice already has on disk, so the fix has to reach
     * backwards or it only stops the next duplicate.
     *
     * The opposite reading from the id collision above, and the opposite
     * direction, deliberately. Two rows with one id is a *damaged* file — the
     * two records contradict each other about one row, so neither can be
     * believed and both are refused. Two rows with one key is a file this
     * program wrote on purpose, twice, about a phone that is still trusted and
     * very possibly the one being held. Failing closed there would sign somebody
     * out of their own machine to tidy up after us.
     *
     * So the freshest live row survives, the rest are dropped, and the file is
     * rewritten if anything moved — *"existing duplicates must collapse, not
     * just stop appearing"*. A write that fails changes nothing about this run:
     * the collapse is already in memory, the roster already lists one row, and
     * the next ordinary commit writes it out anyway.
     */
    const parsedRows = [...byId.values()]
    const devices2 = collapseByKey(parsedRows)
    this.devices = devices2
    if (devices2.length !== parsedRows.length) {
      console.error(
        `[remote-auth] collapsed ${parsedRows.length - devices2.length} duplicate device row(s): ` +
          'one device key is one device.',
      )
      try {
        this.persist({ version: 1, devices: devices2 })
      } catch (err) {
        console.error('[remote-auth] could not rewrite the trust file after collapsing duplicates:', err)
      }
    }
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
