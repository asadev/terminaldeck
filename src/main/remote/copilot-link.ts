/**
 * The copilot connection: a second act of authorisation, with its own code, its
 * own credential and its own record.
 *
 * ## What this replaces, and why the old argument did not survive
 *
 * This file supersedes `copilot-grants.ts`, which held copilot access as a
 * per-device *grant* riding the session channel: a device that had been paired
 * for terminals got a Copilot tab the moment somebody ticked a box beside its
 * name. That file argued, at length and correctly for what it knew, that the
 * `alter` tier could never be granted to a device:
 *
 * > *The alter tier's entire safety property is a human at the machine says yes.
 * > A dialog that appears on the device that raised the request is answered by
 * > the party being confirmed. If holding the phone is sufficient to approve
 * > what the phone asked for, then the phone holds `alter` and the grant was a
 * > ceremony.*
 *
 * That argument is preserved here in full because it is a good one and because
 * the next person to read it needs to find out why it was superseded rather than
 * wonder whether it was forgotten. Asad, 2026-08-17, having read it:
 *
 * > *"Phones will have full control over copilot, same as the actual machine
 * > app. But connecting copilot will be a separate connection than the
 * > sessions."*
 *
 * The second sentence dissolves the first argument rather than overriding it.
 * The old reasoning assumed the second factor behind `alter` was **geography** —
 * that being at the desk is what made a yes meaningful. It is not, and it never
 * was: a person who walks away from an unlocked Mac has taken their geography
 * with them. What made the desktop dialog meaningful was that reaching it
 * required an authorisation the requesting party did not already hold.
 *
 * So the second factor moves. It is no longer *be at the desk*; it is **have
 * deliberately authorised this specific device for the copilot**, in a ceremony
 * separate from pairing it for terminals, producing a credential separate from
 * the one that opens a session channel. A device paired to run terminals has no
 * copilot reach whatsoever — not a tab, not a frame, not a refusal it could
 * measure — until somebody at this machine mints a copilot code and it is
 * redeemed. That is a real boundary, it is checkable, and it is the one the
 * phone cannot grant itself: the code is minted here and shown on this screen.
 *
 * ## The three properties this has to have, and where each one lives
 *
 * **A session-paired device has no copilot reach until separately connected.**
 * {@link CopilotLinks.granted} answers {@link NO_TIERS} for a device with no
 * link, so `DeckControl.call` refuses every tool call; `server.ts` requires an
 * open copilot connection on the socket before it will serve a `copilot.*` verb
 * at all. Two independent refusals, at two layers, for the reason `control.ts`
 * gives about itself — *a rule enforced in one transport is a rule the next
 * transport does not have*.
 *
 * **Revoking one does not revoke the other.** {@link CopilotLinks.disconnect}
 * drops the copilot record and touches nothing in `remote-auth.json`: the phone
 * keeps its terminals and loses the copilot, immediately, because the grant is
 * read per tool call and per frame. The other direction is not symmetric and
 * should not be: revoking the *device* also drops the copilot link, because a
 * revoked device can never open a channel again, so the record would be a live
 * credential with nobody's name against it. That is garbage collection, not
 * cascade — the same argument `CopilotGrants.forget` already made.
 *
 * **It rides the same sealed channel.** Nothing here is a transport. The code,
 * the credential and every frame that carries them are ordinary
 * `ClientMessage`/`ServerMessage` values, sealed under the Noise IK session keys
 * exactly like a keystroke. The relay sees a type byte, a channel id and
 * ciphertext. See `COPILOT-REMOTE.md` §7.
 *
 * ## Why the credential carries no device id
 *
 * `device-auth.ts` mints `"<id>.<secret>"` because a session credential arrives
 * on an anonymous socket and has to say who it is. A copilot credential arrives
 * on a socket that has **already** proved which device it is, so the id would be
 * a field nobody reads and one more thing a client could get wrong. Leaving it
 * out also buys a property worth having: a copilot credential is useless on any
 * socket that is not that device's, so a leaked one is not a bearer token for
 * the copilot — it is half of a pair, and the other half is the device's session
 * credential and its static key.
 *
 * ## Why its own file, and not a field in the trust store
 *
 * The same argument `folder-grants.ts` makes for not living in
 * `remote-auth.json`: that file's parser drops every field it does not
 * recognise, so a second module writing into it would have its data erased by
 * the next approve or revoke. And the split is right anyway — losing a folder
 * list costs a preference, losing this costs a credential and a permission, and
 * a file holding both is a file whose worst case is the worse of the two.
 */

import { randomBytes, scrypt as scryptCallback, timingSafeEqual, createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { CODE_ENTROPY_BYTES, codeFromBytes } from '../../shared/short-code'
import { NO_TIERS, TIERS, type Tier, type TierGrant } from '../deck-control/surface'
import { writeSecretFile } from './secret-file'

/* --------------------------------------------------------------- tunables -- */

export const COPILOT_LINK_FILE = 'copilot-link.json'

/** Written into the file so a later format can tell itself apart from this one. */
const FORMAT_VERSION = 1

/**
 * Tiers a copilot connection may be given.
 *
 * **All three, and `alter` is the change.** `copilot-grants.ts` published this
 * same constant as `['read', 'act']` and called the absence *the mechanism*:
 * `set()` clamped `alter` to false and `load()` scrubbed it out of a
 * hand-edited file, so there was no argument, no file edit and no future toggle
 * that could put it in memory. That clamp and that scrub are both gone, on
 * purpose, and the reason is in the header — the second factor is now the
 * separate connection rather than the desk.
 *
 * The constant stays, rather than being deleted as a no-op, for two reasons. It
 * is still the ceiling every path into this store filters against, so a fourth
 * tier added to `deck-control` does not become remotely grantable by existing;
 * and the *list* is what a reader checks against the code, which an absent
 * check is not.
 */
export const REMOTE_GRANTABLE_TIERS: readonly Tier[] = ['read', 'act', 'alter']

/**
 * How long a copilot connect code lives.
 *
 * Sixty seconds, the same as `PAIRING_TTL_MS`, and the sameness is deliberate
 * rather than lazy: this is the identical ceremony one layer up — a person reads
 * six digits off this screen and types them into a device they are holding — so
 * a second number would be a second thing to explain for no difference in what
 * anybody does.
 */
export const COPILOT_CODE_TTL_MS = 60_000

/** Wrong guesses tolerated before the code itself is dead. */
export const MAX_CODE_ATTEMPTS = 5

/** Wrong credentials tolerated from one device before it is locked out. */
export const MAX_OPEN_ATTEMPTS = 5

/** How long a tripped limiter stays tripped. */
export const LOCKOUT_MS = 15 * 60_000

/** A person connects one device at a time; more than this is a stuck UI. */
const MAX_LIVE_CODES = 8

/**
 * Matches `MAX_DEVICES` in the trust store: a device that cannot be paired
 * cannot be connected, so a larger ceiling here would only bound a file nothing
 * can reach.
 */
const MAX_LINKS = 64
const MAX_FILE_BYTES = 64 * 1024

const CREDENTIAL_BYTES = 32
const SALT_BYTES = 16
const MAX_CREDENTIAL_LENGTH = 512

/** base64url, no padding — the only alphabet this file mints. */
const BASE64URL = /^[A-Za-z0-9_-]+$/

interface ScryptParams {
  n: number
  r: number
  p: number
  keylen: number
}

/**
 * The same parameters `device-auth.ts` uses, and for the same reason: a
 * credential here is 256 bits from `randomBytes` rather than something a person
 * chose, so there is no dictionary to run and the KDF is defence in depth for
 * the stored file rather than the thing standing between an attacker and the
 * copilot. Measured at ~36ms per verification on this machine, which one
 * connection can afford and a guessing loop cannot.
 */
const SCRYPT: ScryptParams = { n: 16384, r: 8, p: 1, keylen: 32 }

/** Ceilings on parameters read back off disk. See `device-auth.ts` for the numbers. */
const MAX_SCRYPT_N = 1 << 18
const MAX_SCRYPT_R = 32
const MAX_SCRYPT_P = 16
const MAX_SCRYPT_KEYLEN = 128
const MAX_STORED_FIELD_LENGTH = 256

/* ----------------------------------------------------------------- shapes -- */

/** One connected device, as the settings panel lists it. */
export interface CopilotLink {
  deviceId: string
  tiers: TierGrant
  connectedAt: number
  lastSeenAt: number | null
}

/** A copilot connect code, shown once to a person standing at this machine. */
export interface CopilotCode {
  /** Six digits. Never persisted — only its digest is. */
  code: string
  expiresAt: number
  /** What redeeming it will grant. Chosen at the desk, when the code is minted. */
  tiers: TierGrant
}

export type CopilotConnectFailure =
  | 'malformed'
  | 'unknown'
  | 'used'
  | 'expired'
  | 'rate-limited'
  | 'too-many-links'
  | 'storage'

export type CopilotConnectResult =
  | { ok: true; credential: string; link: CopilotLink }
  | { ok: false; reason: CopilotConnectFailure; retryAfterMs?: number }

export type CopilotOpenFailure = 'malformed' | 'unknown' | 'denied' | 'rate-limited'

export type CopilotOpenResult =
  | { ok: true; link: CopilotLink }
  | { ok: false; reason: CopilotOpenFailure; retryAfterMs?: number }

export interface CopilotLinksOptions {
  /**
   * Injected clock. Everything here reads time through it — code expiry,
   * lockouts, `lastSeenAt` — so a test can move time without sleeping and
   * without one comparison quietly falling back to `Date.now()`.
   */
  now?: () => number
}

/* ----------------------------------------------------------------- stored -- */

interface StoredCredential extends ScryptParams {
  salt: string
  hash: string
}

interface StoredLink {
  connectedAt: number
  lastSeenAt: number | null
  tiers: Record<string, boolean>
  credential: StoredCredential
}

interface StoredState {
  version: number
  links: Record<string, StoredLink>
}

interface CodeRecord {
  hash: Buffer
  expiresAt: number
  usedAt: number | null
  tiers: TierGrant
  wrong: number
}

interface Attempts {
  count: number
  until: number
}

/* --------------------------------------------------------------- helpers -- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function sha256(value: string): Buffer {
  return createHash('sha256').update(value, 'utf8').digest()
}

function scrypt(secret: Buffer, salt: Buffer, params: ScryptParams): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scryptCallback(secret, salt, params.keylen, { N: params.n, r: params.r, p: params.p }, (error, key) => {
      if (error) reject(error)
      else resolve(key)
    })
  })
}

/**
 * Read anything into a grant, keeping only what is both a tier and grantable.
 *
 * Exported because it is the whole of the rule and it is worth being able to
 * test it without a filesystem. Three properties, all load-bearing, and all
 * inherited unchanged from `copilot-grants.ts` — the only thing that moved is
 * which tiers {@link REMOTE_GRANTABLE_TIERS} contains:
 *
 *  - **A non-object is nothing.** Including `true`. Guessing generously at a
 *    permission is how a permission gets widened by a bug in a parser.
 *  - **Only literal `true` grants.** `"yes"`, `1` and `"true"` are all false. A
 *    JSON file a person may edit will eventually contain one of them, and the
 *    difference between reading it as an intention and reading it as a mistake
 *    is a difference in who gets access.
 *  - **Nothing outside the ceiling survives**, whatever it says.
 */
export function copilotGrantFrom(raw: unknown): TierGrant {
  if (!isRecord(raw)) return NO_TIERS
  const grant: Record<Tier, boolean> = { read: false, act: false, alter: false }
  for (const tier of REMOTE_GRANTABLE_TIERS) {
    grant[tier] = raw[tier] === true
  }
  return Object.freeze(grant)
}

/** True when this grant permits nothing at all. */
export function grantsNothing(grant: TierGrant): boolean {
  return TIERS.every((tier) => !grant[tier])
}

function readStoredCredential(raw: unknown): StoredCredential | null {
  if (!isRecord(raw)) return null
  const { salt, hash, n, r, p, keylen } = raw
  if (typeof salt !== 'string' || salt === '' || salt.length > MAX_STORED_FIELD_LENGTH) return null
  if (typeof hash !== 'string' || hash === '' || hash.length > MAX_STORED_FIELD_LENGTH) return null
  if (typeof n !== 'number' || !Number.isInteger(n) || n < 2 || n > MAX_SCRYPT_N) return null
  if (typeof r !== 'number' || !Number.isInteger(r) || r < 1 || r > MAX_SCRYPT_R) return null
  if (typeof p !== 'number' || !Number.isInteger(p) || p < 1 || p > MAX_SCRYPT_P) return null
  if (typeof keylen !== 'number' || !Number.isInteger(keylen) || keylen < 16 || keylen > MAX_SCRYPT_KEYLEN) {
    return null
  }
  return { salt, hash, n, r, p, keylen }
}

/* ------------------------------------------------------------------ store -- */

export class CopilotLinks {
  /** Absolute path of the file. Exposed for diagnostics and tests. */
  readonly file: string

  private readonly dir: string
  private readonly now: () => number
  private links = new Map<string, StoredLink>()
  private readonly codes = new Map<string, CodeRecord>()
  private readonly attempts = new Map<string, Attempts>()

  /**
   * Salt for the decoy hash run when a device has no link. Per instance and
   * never stored: its only job is to make the wall time of an open say nothing
   * about whether a link exists. `device-auth.ts` does the same thing for the
   * same reason.
   */
  private readonly decoySalt = randomBytes(SALT_BYTES)

  constructor(storageDir: string, options: CopilotLinksOptions = {}) {
    this.dir = storageDir
    this.file = join(storageDir, COPILOT_LINK_FILE)
    this.now = options.now ?? Date.now
    this.load()
  }

  /* ---------------------------------------------------------------- codes */

  /**
   * Mint a copilot connect code, and decide there and then what it grants.
   *
   * The tiers travel with the *code* rather than being ticked afterwards, and
   * that is the whole ceremony: the person minting it is standing at this
   * machine, looking at a screen that says what they are about to hand over,
   * and the device gets exactly that. A code that granted nothing and left the
   * tiers to a later click would make connecting and authorising two separate
   * moments, and the second one is the one people skip.
   *
   * Only the code's digest is kept, so nothing in this process holds a live
   * bearer secret after the call returns — the caller shows it and drops it.
   * The entropy argument is `device-auth.ts`'s and is unchanged: a million codes
   * guarded by a sixty-second life, a single use, and five wrong answers killing
   * the code itself.
   */
  offer(tiers: unknown = { read: true, act: true, alter: true }): CopilotCode {
    const now = this.now()
    this.pruneCodes(now)
    // Oldest first, so a stuck UI minting codes in a loop cannot squeeze out the
    // one a person is about to type. It never happens with a cap of eight and it
    // costs one line to not have to reason about.
    while (this.codes.size >= MAX_LIVE_CODES) {
      const oldest = [...this.codes.keys()][0]
      if (oldest === undefined) break
      this.codes.delete(oldest)
    }
    const code = codeFromBytes(randomBytes(CODE_ENTROPY_BYTES))
    const granted = copilotGrantFrom(tiers)
    const record: CodeRecord = {
      hash: sha256(code),
      expiresAt: now + COPILOT_CODE_TTL_MS,
      usedAt: null,
      tiers: granted,
      wrong: 0,
    }
    this.codes.set(record.hash.toString('hex'), record)
    return { code, expiresAt: record.expiresAt, tiers: granted }
  }

  /** Every live code is dead. Called when the panel closes or the app quits. */
  cancelCodes(): void {
    this.codes.clear()
  }

  /** How many codes are outstanding. For the panel, and for the tests. */
  get liveCodes(): number {
    this.pruneCodes(this.now())
    return this.codes.size
  }

  /**
   * Redeem a code for this device, producing the copilot credential.
   *
   * The device is already authenticated as itself — this is only ever reached
   * from a socket `RemoteAuth` has matched and a human has approved — so the id
   * is a fact rather than a claim, and the code is the *second* thing being
   * proved rather than the first.
   *
   * Returns the credential exactly once. It is stored as a scrypt hash, so a
   * caller that loses it has to be given a new code; there is no path in this
   * file that can show it again, which is the property that makes the file safe
   * to read.
   */
  async redeem(code: unknown, deviceId: string, address?: string): Promise<CopilotConnectResult> {
    const now = this.now()
    if (typeof deviceId !== 'string' || deviceId === '') return { ok: false, reason: 'malformed' }
    if (typeof code !== 'string' || code === '' || code.length > MAX_CREDENTIAL_LENGTH) {
      return { ok: false, reason: 'malformed' }
    }

    const keys = [`device:${deviceId}`, ...(address === undefined ? [] : [`addr:${address}`])]
    const blocked = this.blockedFor(keys, now)
    if (blocked > 0) return { ok: false, reason: 'rate-limited', retryAfterMs: blocked }

    this.pruneCodes(now)
    const record = this.matchCode(code)
    if (!record) {
      this.noteFailure(keys, now)
      // Every live code takes a wrong guess against it, because the guess was
      // against the whole space rather than against one of them. Five wrong
      // answers and the codes are dead — which is what makes six digits enough,
      // and it is `device-auth.ts`'s argument reproduced one layer up.
      for (const live of this.codes.values()) {
        live.wrong += 1
        if (live.wrong >= MAX_CODE_ATTEMPTS) live.usedAt = now
      }
      return { ok: false, reason: 'unknown' }
    }

    // Burn first. Everything below this line is allowed to fail.
    const alreadyUsed = record.usedAt !== null
    record.usedAt = now
    if (alreadyUsed) {
      this.noteFailure(keys, now)
      return { ok: false, reason: 'used' }
    }
    // `>=`, not `>`: a code minted at t with a 60s TTL is dead at t+60000, not
    // alive for one more millisecond.
    if (now >= record.expiresAt) return { ok: false, reason: 'expired' }

    const next = new Map(this.links)
    if (!next.has(deviceId) && next.size >= MAX_LINKS) return { ok: false, reason: 'too-many-links' }

    const secret = randomBytes(CREDENTIAL_BYTES)
    const salt = randomBytes(SALT_BYTES)
    const hash = await scrypt(secret, salt, SCRYPT)

    const stored: StoredLink = {
      connectedAt: now,
      lastSeenAt: null,
      tiers: serialiseTiers(record.tiers),
      credential: { ...SCRYPT, salt: salt.toString('base64'), hash: hash.toString('base64') },
    }
    next.set(deviceId, stored)

    try {
      // Persist before handing the credential out. A credential we returned but
      // never stored is one nobody can ever make work, and the device would have
      // no way to tell that apart from a refusal.
      this.commit(next)
    } catch (error) {
      console.error('[remote] could not persist a copilot connection:', error)
      return { ok: false, reason: 'storage' }
    }

    this.clearFailures(keys)
    return {
      ok: true,
      credential: secret.toString('base64url'),
      link: toPublic(deviceId, stored),
    }
  }

  /* ----------------------------------------------------------- connection */

  /**
   * Does this credential open this device's copilot connection?
   *
   * The limiter is consulted before any hashing, so a guessing loop cannot spend
   * this machine's CPU on scrypt; and the hash runs even for a device with no
   * link, against a decoy salt, so the timing does not answer a question the
   * reasons refuse to.
   */
  async open(deviceId: string, credential: unknown, address?: string): Promise<CopilotOpenResult> {
    const now = this.now()
    if (typeof deviceId !== 'string' || deviceId === '') return { ok: false, reason: 'malformed' }
    if (
      typeof credential !== 'string' ||
      credential === '' ||
      credential.length > MAX_CREDENTIAL_LENGTH ||
      !BASE64URL.test(credential)
    ) {
      return { ok: false, reason: 'malformed' }
    }

    const keys = [`open:${deviceId}`, ...(address === undefined ? [] : [`addr:${address}`])]
    const blocked = this.blockedFor(keys, now)
    if (blocked > 0) return { ok: false, reason: 'rate-limited', retryAfterMs: blocked }

    const stored = this.links.get(deviceId)
    const offered = Buffer.from(credential, 'base64url')
    if (!stored) {
      // Spend the same work as a real check. `unknown` and `denied` are two
      // reasons on purpose — the first says *ask for a code*, the second says
      // *this credential is wrong* — and neither of them is allowed to be the
      // faster one to reach.
      await scrypt(offered, this.decoySalt, SCRYPT)
      this.noteFailure(keys, now)
      return { ok: false, reason: 'unknown' }
    }

    const params: ScryptParams = {
      n: stored.credential.n,
      r: stored.credential.r,
      p: stored.credential.p,
      keylen: stored.credential.keylen,
    }
    const derived = await scrypt(offered, Buffer.from(stored.credential.salt, 'base64'), params)
    const expected = Buffer.from(stored.credential.hash, 'base64')
    // `timingSafeEqual` throws on unequal lengths, so a length mismatch is
    // answered without calling it rather than by letting it decide.
    const matched = derived.length === expected.length && timingSafeEqual(derived, expected)
    if (!matched) {
      this.noteFailure(keys, now)
      return { ok: false, reason: 'denied' }
    }

    this.clearFailures(keys)
    this.touch(deviceId, now)
    return { ok: true, link: toPublic(deviceId, stored) }
  }

  /* --------------------------------------------------------------- grants */

  /**
   * What this device may do, which for almost every device is nothing.
   *
   * Returns a grant rather than `null`. There is no "nobody has chosen yet"
   * state to distinguish: the answer to never having connected is the same as
   * the answer to having been disconnected — no access — and one return type
   * means no caller can forget to handle the absent case, which is the case that
   * matters.
   *
   * **This is the function the whole feature rests on.** It is called per tool
   * call through `remoteCopilotCaller`, never cached, so disconnecting a device
   * lands on the next tool call rather than on the next reconnect.
   */
  granted(deviceId: string): TierGrant {
    if (typeof deviceId !== 'string' || deviceId === '') return NO_TIERS
    const stored = this.links.get(deviceId)
    if (!stored) return NO_TIERS
    return copilotGrantFrom(stored.tiers)
  }

  /** Has this device ever been connected to the copilot? */
  linked(deviceId: string): boolean {
    return typeof deviceId === 'string' && deviceId !== '' && this.links.has(deviceId)
  }

  /** Every connected device, for the settings panel. */
  list(): CopilotLink[] {
    return [...this.links].map(([deviceId, stored]) => toPublic(deviceId, stored))
  }

  /**
   * Change what a connected device may do.
   *
   * **Refuses to create a link.** A device with no copilot connection cannot be
   * granted anything by ticking a box, because the box is not the authorisation
   * — the connection is. This is the single most important line in the file for
   * the property in the header: without it, the panel would be a second door
   * onto copilot access and the separate connection would be decoration.
   *
   * Returns what was actually stored, which is not always what was asked for.
   * The caller is a settings panel and it should render the answer rather than
   * its own request, so that a UI cannot show a switch as on when the store says
   * off.
   */
  set(deviceId: string, tiers: unknown): TierGrant {
    if (typeof deviceId !== 'string' || deviceId === '') return NO_TIERS
    const stored = this.links.get(deviceId)
    if (!stored) return NO_TIERS
    const cleaned = copilotGrantFrom(tiers)
    const next = new Map(this.links)
    next.set(deviceId, { ...stored, tiers: serialiseTiers(cleaned) })
    this.commit(next)
    return cleaned
  }

  /**
   * End a device's copilot connection: the credential dies with the record.
   *
   * This is what "revoke copilot access" means, and it is deliberately not
   * "untick every box". A record with all-false tiers would still hold a working
   * credential, so the device could still open a copilot connection and sit
   * there being refused — a connection nobody authorised any more. Dropping the
   * record makes the next `copilot.hello` answer `unknown`, which is the same
   * answer a device that was never connected gets.
   *
   * It touches nothing in `remote-auth.json`: the phone keeps its terminals.
   */
  disconnect(deviceId: string): boolean {
    if (!this.links.has(deviceId)) return false
    const next = new Map(this.links)
    next.delete(deviceId)
    this.commit(next)
    this.clearFailures([`open:${deviceId}`, `device:${deviceId}`])
    return true
  }

  /**
   * The device itself was revoked, so its copilot link is unreachable.
   *
   * Not a cascade and not a policy: revocation in `device-auth.ts` is permanent
   * and a returning phone pairs again with a *new* device id, so a link left
   * behind here could never be opened by anything. Keeping it would mean the
   * file only ever grows, and a stale record is a credential sitting in a file
   * with nobody's name against it.
   */
  forget(deviceId: string): boolean {
    return this.disconnect(deviceId)
  }

  /* ------------------------------------------------------------- internals */

  private touch(deviceId: string, at: number): void {
    const stored = this.links.get(deviceId)
    if (!stored) return
    // In memory only. `lastSeenAt` is a diagnostic, and writing the file on every
    // reconnect would turn a phone in a loop into a disk-write denial of service
    // that needs nothing but a valid credential to run — the hole
    // `LAST_SEEN_WRITE_MS` closes one layer down. It is persisted the next time
    // something real changes.
    stored.lastSeenAt = at
  }

  private matchCode(code: string): CodeRecord | null {
    const offered = sha256(code)
    let found: CodeRecord | null = null
    for (const record of this.codes.values()) {
      // No `break`: every live code is compared whichever one matches, so the
      // wall time says nothing about how far down the map a guess landed.
      if (record.hash.length === offered.length && timingSafeEqual(record.hash, offered) && found === null) {
        found = record
      }
    }
    return found
  }

  private pruneCodes(now: number): void {
    for (const [key, record] of [...this.codes]) {
      if (now >= record.expiresAt || record.usedAt !== null) this.codes.delete(key)
    }
  }

  private blockedFor(keys: readonly string[], now: number): number {
    let longest = 0
    for (const key of keys) {
      const entry = this.attempts.get(key)
      if (!entry) continue
      /*
       * `until === 0` is a **counter**, not an expired lockout, and telling them
       * apart is load-bearing.
       *
       * The first version of this deleted any entry whose `until` had passed —
       * and zero has always passed, so every entry was dropped on the way in and
       * the count restarted at one on every attempt. The limiter existed,
       * compiled, read correctly, and let an unlimited number of guesses
       * through; `copilot-link.test.ts` is what noticed. Nothing about a
       * rate limiter is observable from the code that has one.
       */
      if (entry.until !== 0 && entry.until <= now) {
        this.attempts.delete(key)
        continue
      }
      if (entry.until > now) longest = Math.max(longest, entry.until - now)
    }
    return longest
  }

  private noteFailure(keys: readonly string[], now: number): void {
    for (const key of keys) {
      const entry = this.attempts.get(key) ?? { count: 0, until: 0 }
      entry.count += 1
      if (entry.count >= MAX_OPEN_ATTEMPTS) {
        entry.until = now + LOCKOUT_MS
        entry.count = 0
      }
      this.attempts.set(key, entry)
    }
    // A cap on bookkeeping rather than a defence: an attacker who can forge this
    // many keys has already escaped the per-address limiter by definition, which
    // is what the per-device one is for.
    while (this.attempts.size > 1024) {
      const oldest = [...this.attempts.keys()][0]
      if (oldest === undefined) break
      this.attempts.delete(oldest)
    }
  }

  private clearFailures(keys: readonly string[]): void {
    for (const key of keys) this.attempts.delete(key)
  }

  private commit(next: Map<string, StoredLink>): void {
    const links: Record<string, StoredLink> = {}
    for (const [deviceId, stored] of next) links[deviceId] = stored
    const state: StoredState = { version: FORMAT_VERSION, links }
    writeSecretFile(this.dir, this.file, `${JSON.stringify(state, null, 2)}\n`)
    // Only after the disk agrees. The in-memory map is what every call consults,
    // so swapping it first would leave a connection live for the rest of the run
    // that no longer exists after a restart.
    this.links = next
  }

  /**
   * Read the file, and treat anything unreadable as no copilot for anybody.
   *
   * Fails **closed**, the opposite of `folder-grants.ts` and the right way round
   * for the same reason that file gives for its own choice. That one decides
   * which folder a session starts in for a machine its owner has already
   * approved, and failing closed would strand a paired phone over a JSON typo.
   * This one decides whether a device can drive an agent that spends money,
   * edits files and — now — answers its own confirmations, and the worst case of
   * failing closed is that somebody mints a new code at the machine where the
   * code is minted anyway.
   */
  private load(): void {
    let text: string
    try {
      text = readFileSync(this.file, 'utf8')
    } catch {
      // Missing is the normal case and will stay the normal case: this is a
      // capability nobody has until they go looking for it.
      return
    }

    if (text.length > MAX_FILE_BYTES) {
      console.error('[remote] the copilot link file is implausibly large; ignoring it')
      return
    }

    let parsed: unknown
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      console.error('[remote] could not read the copilot connections:', error)
      return
    }

    if (!isRecord(parsed) || !isRecord(parsed.links)) return
    const links = new Map<string, StoredLink>()
    for (const [deviceId, value] of Object.entries(parsed.links)) {
      if (deviceId === '' || links.size >= MAX_LINKS) continue
      if (!isRecord(value)) continue
      const credential = readStoredCredential(value.credential)
      // **No credential, no link.** A record hand-written into this file with
      // tiers and no credential would be a grant with no connection behind it,
      // which is exactly the shape this whole design replaced. It is dropped
      // rather than repaired: there is no honest way to invent the second factor
      // for somebody.
      if (!credential) continue
      const tiers = copilotGrantFrom(value.tiers)
      // An all-false record is a connection that can be opened and can do
      // nothing, which is a real state — somebody unticked everything without
      // disconnecting — so unlike the grant store this replaced, it is kept.
      links.set(deviceId, {
        connectedAt: typeof value.connectedAt === 'number' ? value.connectedAt : 0,
        lastSeenAt: typeof value.lastSeenAt === 'number' ? value.lastSeenAt : null,
        tiers: serialiseTiers(tiers),
        credential,
      })
    }
    this.links = links
  }
}

/* --------------------------------------------------------------- helpers -- */

function serialiseTiers(grant: TierGrant): Record<string, boolean> {
  const stored: Record<string, boolean> = {}
  // Only the grantable tiers are written. A field for a tier this store cannot
  // hand out would read, to somebody opening the file, like a switch that could
  // be turned on.
  for (const tier of REMOTE_GRANTABLE_TIERS) stored[tier] = grant[tier]
  return stored
}

function toPublic(deviceId: string, stored: StoredLink): CopilotLink {
  return {
    deviceId,
    tiers: copilotGrantFrom(stored.tiers),
    connectedAt: stored.connectedAt,
    lastSeenAt: stored.lastSeenAt,
  }
}

/**
 * The {@link Caller} a relayed copilot request must be dispatched with.
 *
 * One function, so that there is a single obvious thing to call and no
 * temptation to assemble a `Caller` by hand with `ALL_TIERS` in it while getting
 * something working. The device id rides along into the action log, which is the
 * only place "which of my devices did that" can be answered from.
 *
 * It re-reads the store on every call — that is the point, and it is why every
 * run registers `() => remoteCopilotCaller(links, deviceId)` rather than a
 * snapshot. Disconnecting a device in Settings lands on the *next tool call*.
 */
export function remoteCopilotCaller(
  links: Pick<CopilotLinks, 'granted'>,
  deviceId: string,
): { kind: 'remote'; deviceId: string; tiers: TierGrant } {
  return { kind: 'remote', deviceId, tiers: links.granted(deviceId) }
}
