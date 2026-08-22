/**
 * The machines this desktop has paired **to**.
 *
 * ## The mirror image of `device-auth.ts`, and the one place they differ
 *
 * `device-auth.ts` is the host's list: who may reach *this* machine. It stores
 * scrypt hashes and no key material, so a stolen `remote-auth.json` names the
 * devices and cannot become one. That promise is the whole design of that file.
 *
 * This is the guest's list: the machines *this* one may reach. It cannot make
 * the same promise, and pretending otherwise would be the more dangerous of the
 * two options. A guest has to hold a bearer credential in plaintext — that is
 * what a credential *is*, and a hash of one authenticates nobody — exactly the
 * way the phone client holds its own in `localStorage`. So the file is written
 * through `writeSecretFile`, alongside the private key next door — 0600 on
 * POSIX and, since the mode means nothing on NTFS, an ACL granting this account
 * and no other on Windows — and this comment says plainly what it contains
 * rather than leaving somebody to work it out from a field name.
 *
 * Losing it costs pairings and nothing else: the machines on the other end still
 * hold their side, and a device that disappears from here is one somebody
 * revokes over there.
 *
 * ## Why every machine gets its own guest key
 *
 * A phone has one X25519 static key and presents it to every desktop it pairs
 * with. This store mints a fresh one per machine instead, for two reasons and
 * neither of them is caution for its own sake.
 *
 * The relay sees a device's key material only as ciphertext — Noise IK encrypts
 * the initiator's static key under `es` precisely so a passive observer cannot
 * tell which device is connecting — but the *host* sees it in the clear, and it
 * is stored beside the credential. One key across every machine would mean two
 * machines that never talk to each other can each recognise the other's device
 * row as the same desktop. There is no reason for them to be able to.
 *
 * The second reason is the useful one: `deviceHoldsKey` binds a credential to
 * the key that paired with it, so a credential lifted out of this file is
 * useless without the private key that sits beside it. Per-machine keys mean
 * that binding is per-machine too, and one compromised pairing does not carry
 * to the rest.
 *
 * ## No Electron here on purpose
 *
 * The storage directory is a constructor argument, so this runs against a temp
 * dir under vitest with no app object anywhere near it — the same rule
 * `device-auth.ts` follows.
 */

import { randomBytes } from 'node:crypto'
import { readFileSync, renameSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { fingerprint, generateStatic, type StaticKeyPair } from '../../../shared/sealed'
import { isHostId } from '../../../shared/relay-wire'
import { protectSecretFile, writeSecretFile } from '../secret-file'
import {
  MACHINE_WINDOW_DENIES_FILE,
  WindowDenies,
  applyWindowDenies,
} from '../window-denies'

export const MACHINES_FILE = 'machines.json'

/** A real file is a few kilobytes per machine; anything larger is not ours to parse. */
const MAX_FILE_BYTES = 256 * 1024

/** Names are shown in this window and go into logs, so they are bounded. */
const MAX_NAME_LENGTH = 64

/** Refuses to grow without bound if pairing ever runs in a loop. */
const MAX_MACHINES = 64

const KEY_BYTES = 32

/** Base64 of a 32-byte key is 44 characters; a credential is under 128. */
const MAX_STORED_FIELD_LENGTH = 256

/**
 * What the renderer is allowed to see.
 *
 * Deliberately not the stored shape. The credential and the private key never
 * cross the IPC bridge — nothing in the window has any use for either, and a
 * bridge that carries a bearer secret is one screenshot away from publishing it.
 * `fingerprint` is here instead, because the one thing a person may genuinely
 * want to check is that the six groups on this screen match the six groups on
 * the other machine.
 */
export interface Machine {
  id: string
  /** What this machine is called here. Editable; it is a label, not an identity. */
  name: string
  /** The far machine's public name at the relay. Not a secret. */
  hostId: string
  /** Its X25519 public key, in the form a person can compare. */
  fingerprint: string
  /** `darwin`, `win32`, `linux`, or empty when it has never said. */
  platform: string
  pairedAt: number
  /** Null until a `welcome` has arrived from it at least once. */
  lastConnectedAt: number | null
  /**
   * May sessions on that machine act on browser windows **in this app**?
   *
   * ## Why windows are their own axis
   *
   * The host side of this app already separates three grants a device can be
   * given — folders (`folder-grants.ts`), running sessions
   * (`session-grants.ts`) and coding logins (`account-grants.ts`) — for the
   * reason `AccountGrants`'s header states: a device given one folder had
   * silently been given every login on the machine to run it under. This is the
   * same argument, one machine over. A machine this desktop paired with, and
   * whose sessions it can start and read, has not thereby been handed the
   * browser on **this** screen — the one holding this person's logged-in mail,
   * bank and GitHub. Attaching a window and driving one are two different acts
   * and the second is not implied by any of the first three.
   *
   * ## And why this one now defaults open, like the three beside it
   *
   * It defaulted closed for one release, on the argument that nothing had ever
   * driven a window from another machine and so there was nothing to preserve.
   * That argument lost to the requirement it contradicted: T30's accepted
   * done-when is *"the connection IS the authorization"*, and Asad's sentence —
   * *"Other sessions can drive any connected browser which we allow to the
   * session"* — allowing is connecting, not a second switch. Every row in this
   * store is a machine the person at this keyboard paired with their own hands:
   * they read the code off its screen and typed it here. That act is the
   * authorization, and it is bounded exactly as before by which windows they
   * attach, window by window.
   *
   * So the switch on the machine card is an **off**-switch — `false` is a
   * person having said no about this one machine — and absent, which is every
   * `machines.json` written before the field existed (his own DESKTOP row
   * reproduced the filmed refusal that way), reads as **on**.
   * `StoredServer.drivesWindows` makes the identical reading for a server the
   * person added; the closed default lives on where it belongs, in
   * `window-grants.ts`, for the one peer nobody at this keyboard vouched for —
   * a device approved as a guest.
   *
   * ## Which is why the `false` is also kept somewhere 0.9.1 cannot reach
   *
   * With an open default the refusal is the *presence* of a key, so anything
   * that drops the key hands the capability back. 0.9.1 drops it:
   * `asStoredMachine` there rebuilds this record from a field list that
   * predates `drivesWindows`, and `commit` rewrites the whole file on any
   * change — a machine sending one `welcome` is enough. `window-denies.ts`
   * keeps the durable copy in a file 0.9.1 neither reads nor writes, and
   * `load` folds it back in. See `downgrade-to-0-9-1.test.ts`.
   */
  drivesWindows: boolean
}

/** Everything needed to dial one. Main-process only; see {@link Machine}. */
export interface MachineSecrets {
  hostId: string
  hostPublicKey: Buffer
  relayUrl: string
  /** `<deviceId>.<secret>` from that machine's `redeemPairingToken`. */
  credential: string
  guestKeys: StaticKeyPair
}

/** What pairing produces, before anything is stored. */
export interface NewMachine {
  name: string
  hostId: string
  hostPublicKey: Buffer
  relayUrl: string
  credential: string
  guestKeys: StaticKeyPair
  platform?: string
}

interface StoredMachine {
  id: string
  name: string
  hostId: string
  hostPublicKey: string
  relayUrl: string
  credential: string
  guestPublicKey: string
  guestPrivateKey: string
  platform: string
  pairedAt: number
  lastConnectedAt: number | null
  /** See {@link Machine.drivesWindows}. Absent in every file written before it. */
  drivesWindows?: boolean
}

interface StoredState {
  version: 1
  machines: StoredMachine[]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

/**
 * Names come from the far machine and are rendered next to terminal output
 * here, so control characters in that position are an escape-sequence
 * injection and never make it into storage. The same rule `cleanName` applies
 * in `device-auth.ts`, and for the same reason.
 */
function cleanName(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const cleaned = value
    .slice(0, MAX_NAME_LENGTH * 8)
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .trim()
    .slice(0, MAX_NAME_LENGTH)
  return cleaned === '' ? null : cleaned
}

function keyBytes(stored: unknown): Buffer | null {
  if (typeof stored !== 'string' || stored === '' || stored.length > MAX_STORED_FIELD_LENGTH) return null
  const raw = Buffer.from(stored, 'base64')
  return raw.length === KEY_BYTES ? raw : null
}

/**
 * A stored row, or null.
 *
 * Every field is load-bearing: without the host id there is nothing to dial,
 * without the public key the handshake is a leap of faith, without the guest
 * private key the far end refuses the credential, and without the credential
 * there is nothing to say hello with. A row missing any of them cannot be
 * repaired by guessing — it can only be paired again — so it is dropped rather
 * than half-read.
 */
function asStoredMachine(value: unknown): StoredMachine | null {
  if (!isRecord(value)) return null
  const name = cleanName(value.name)
  const hostPublicKey = keyBytes(value.hostPublicKey)
  const guestPublicKey = keyBytes(value.guestPublicKey)
  const guestPrivateKey = keyBytes(value.guestPrivateKey)
  if (typeof value.id !== 'string' || value.id === '' || name === null) return null
  if (typeof value.hostId !== 'string' || !isHostId(value.hostId)) return null
  if (hostPublicKey === null || guestPublicKey === null || guestPrivateKey === null) return null
  if (typeof value.relayUrl !== 'string' || value.relayUrl === '') return null
  if (typeof value.credential !== 'string' || value.credential === '') return null
  if (value.credential.length > MAX_STORED_FIELD_LENGTH) return null
  if (typeof value.pairedAt !== 'number' || !Number.isFinite(value.pairedAt)) return null
  return {
    id: value.id,
    name,
    hostId: value.hostId,
    hostPublicKey: hostPublicKey.toString('base64'),
    relayUrl: value.relayUrl,
    credential: value.credential,
    guestPublicKey: guestPublicKey.toString('base64'),
    guestPrivateKey: guestPrivateKey.toString('base64'),
    platform: typeof value.platform === 'string' ? value.platform.slice(0, 32) : '',
    pairedAt: value.pairedAt,
    lastConnectedAt:
      typeof value.lastConnectedAt === 'number' && Number.isFinite(value.lastConnectedAt)
        ? value.lastConnectedAt
        : null,
    // Only the literal `false` closes it. Absent is every file written before
    // the field existed, and it reads as **on** — the person paired this
    // machine with their own hands, and the connection is the authorization
    // (see {@link Machine.drivesWindows}). A truthy string or a `1` in a
    // hand-edited file reads as the default rather than as an answer, the same
    // refusal to parse by truthiness that `credential.answer`'s `remember`
    // makes.
    drivesWindows: value.drivesWindows !== false,
  }
}

function toPublic(machine: StoredMachine): Machine {
  return {
    id: machine.id,
    name: machine.name,
    hostId: machine.hostId,
    // The fingerprint rather than the key: this is read by a screen asking a
    // person to compare six groups of characters with another screen, and 44
    // characters of base64 is a thing people tick rather than read.
    fingerprint: fingerprint(Buffer.from(machine.hostPublicKey, 'base64')),
    platform: machine.platform,
    pairedAt: machine.pairedAt,
    lastConnectedAt: machine.lastConnectedAt,
    // The reader above has already resolved absent to the open default, so
    // what the screen sees is what every forwarded verb is checked against —
    // one answer, not a second parse.
    drivesWindows: machine.drivesWindows === true,
  }
}

export interface MachineStoreOptions {
  /** Injected clock, so a test can move time without sleeping. */
  now?: () => number
  /** Injected key source, so a test can pair without spending X25519 work. */
  freshKeys?: () => StaticKeyPair
}

export class MachineStore {
  /** Absolute path of the file. Exposed for diagnostics and tests. */
  readonly file: string

  private readonly dir: string
  private readonly now: () => number
  private readonly freshKeys: () => StaticKeyPair
  private machines: StoredMachine[] = []
  /**
   * The refusals, in the one place an older build cannot rewrite them.
   *
   * `asStoredMachine` in 0.9.1 reconstructs this record from a fixed field set
   * that does not include `drivesWindows`, and `commit` rewrites the whole list
   * on any change — so one rename under 0.9.1 erases every stored `false` on
   * the machine, and absent means on. This file is the copy that survives it.
   * See `window-denies.ts` for why it is a sidecar and not a version number.
   */
  private readonly denies: WindowDenies

  constructor(storageDir: string, options: MachineStoreOptions = {}) {
    this.dir = storageDir
    this.file = join(storageDir, MACHINES_FILE)
    this.now = options.now ?? Date.now
    this.freshKeys = options.freshKeys ?? generateStatic
    // Before `load`, which reads it. Its own file rather than a section of
    // `remote-windows.json` next door: that one is keyed on *device* ids and
    // this one on host ids, and `WindowGrants`'s header says why one table
    // across two id spaces is a typo away from answering the wrong question.
    this.denies = new WindowDenies(storageDir, MACHINE_WINDOW_DENIES_FILE)
    this.load()
  }

  /**
   * A guest identity for a machine that has not been paired yet.
   *
   * Minted before the pairing rather than after it, because the key has to be
   * in the handshake that pairs — the far end stores whatever key completed it
   * and binds the credential to that. Generating one afterwards would produce a
   * credential the next connection cannot present.
   */
  mintGuestKeys(): StaticKeyPair {
    return this.freshKeys()
  }

  list(): Machine[] {
    return this.machines.map(toPublic).sort((a, b) => b.pairedAt - a.pairedAt)
  }

  /** Everything needed to dial one, or null when it is not here. */
  secrets(id: string): MachineSecrets | null {
    const machine = this.machines.find((candidate) => candidate.id === id)
    if (!machine) return null
    return {
      hostId: machine.hostId,
      hostPublicKey: Buffer.from(machine.hostPublicKey, 'base64'),
      relayUrl: machine.relayUrl,
      credential: machine.credential,
      guestKeys: {
        publicKey: Buffer.from(machine.guestPublicKey, 'base64'),
        privateKey: Buffer.from(machine.guestPrivateKey, 'base64'),
      },
    }
  }

  /**
   * Remember a machine this desktop just paired with.
   *
   * Pairing the same machine twice replaces the row rather than adding a second
   * one. Two rows for one host id would each hold a different credential, both
   * of them valid, and the window would offer the same machine twice with no
   * way to tell which was which — while the far end quietly accumulated device
   * rows nobody could match to anything. Host id is the identity here; the name
   * is a label.
   *
   * Throws when the write fails. A machine this process believes it paired with
   * and the disk does not is one that works until the next launch and then
   * cannot explain why it stopped.
   */
  remember(candidate: NewMachine): Machine {
    const name = cleanName(candidate.name) ?? 'Another machine'
    if (!isHostId(candidate.hostId)) throw new Error('that is not a host id')
    if (candidate.hostPublicKey.length !== KEY_BYTES) throw new Error('that is not an x25519 key')

    const machine: StoredMachine = {
      // Keyed by host id rather than by a fresh random id, so the "same machine
      // twice" case above resolves by itself: `commit` writes over the row with
      // the same key. It is already unique — it is a hash of a secret only that
      // machine holds — and it is not a secret here.
      id: candidate.hostId,
      name,
      hostId: candidate.hostId,
      hostPublicKey: candidate.hostPublicKey.toString('base64'),
      relayUrl: candidate.relayUrl,
      credential: candidate.credential,
      guestPublicKey: candidate.guestKeys.publicKey.toString('base64'),
      guestPrivateKey: candidate.guestKeys.privateKey.toString('base64'),
      platform: candidate.platform ?? '',
      pairedAt: this.now(),
      lastConnectedAt: null,
      // Written explicitly rather than left off, so a row this run created and a
      // row it read back off disk are the same shape. `true`, because pairing it
      // was the authorization — see {@link Machine.drivesWindows}; the switch on
      // the card is the way to say no.
      drivesWindows: true,
    }

    const next = this.machines.filter((existing) => existing.id !== machine.id)
    if (next.length >= MAX_MACHINES) throw new Error('there is no room for another machine')
    next.push(machine)
    // Before the row lands, so the row and the sidecar never both exist saying
    // opposite things. Pairing is the authorizing act — a person read a code
    // off that machine's screen and typed it here — and it is a *fresh* one, so
    // it clears a refusal recorded about the same host id before. Without this,
    // re-pairing a machine somebody had once refused would silently come back
    // unable to drive, because the id is the host id and never changes.
    this.denies.forget(machine.id)
    this.commit(next)
    return toPublic(machine)
  }

  /** Drop one. False when there was nothing to drop. */
  forget(id: string): boolean {
    const next = this.machines.filter((machine) => machine.id !== id)
    if (next.length === this.machines.length) return false
    this.commit(next)
    // After the row is gone, so a failed commit leaves the refusal standing
    // over a machine that is still paired. Unlike a server's, this id is a host
    // id and **is** reissued — the same computer paired again is the same key —
    // so leaving the entry would mean a deliberate re-pairing came back unable
    // to drive a window with nothing on screen to explain it. `remember` clears
    // it too, for the pairing that replaces a row rather than following a
    // forget.
    this.denies.forget(id)
    return true
  }

  /** Rename one. The name is a label on this machine and travels nowhere. */
  rename(id: string, name: unknown): boolean {
    const cleaned = cleanName(name)
    if (cleaned === null) return false
    const next = structuredClone(this.machines)
    const machine = next.find((candidate) => candidate.id === id)
    if (!machine || machine.name === cleaned) return false
    machine.name = cleaned
    this.commit(next)
    return true
  }

  /**
   * May sessions on that machine drive browser windows here?
   *
   * Read on **every** inbound `window.call` rather than captured when the link
   * connected, for the reason `callers.ts` makes its grant a function: a person
   * unticking this would otherwise be editing a store the live link no longer
   * consults, and the untick would not land until the machine reconnected — a
   * permission control that changes nothing.
   */
  drivesWindows(id: string): boolean {
    return this.machines.find((machine) => machine.id === id)?.drivesWindows === true
  }

  /**
   * Say whether it may, and hand back what is now true.
   *
   * Returns the value that was stored rather than a success flag, so a caller
   * that asked about a machine this store has never heard of draws `false`
   * instead of drawing the tick it just pressed. A control that shows a state
   * nothing behind it holds is the defect this whole round is about.
   */
  setDrivesWindows(id: string, allowed: boolean): boolean {
    const next = structuredClone(this.machines)
    const machine = next.find((candidate) => candidate.id === id)
    if (!machine) return false
    // The durable copy first, and outside the early return below: a row whose
    // field already says the right thing can still be missing its refusal on
    // disk — that is exactly the state a downgrade leaves behind once `load`
    // has healed the in-memory value — and pressing the switch again has to be
    // able to put it back. If the record write then fails, the refusal stands
    // and the reader resolves the disagreement closed, which is the only
    // direction a half-finished "no" may fail in.
    this.denies.set(id, !allowed)
    if (machine.drivesWindows === allowed) return allowed
    machine.drivesWindows = allowed
    this.commit(next)
    return allowed
  }

  /**
   * Record that a machine answered, and what kind of machine it said it is.
   *
   * Written through on every `welcome` rather than throttled, because a welcome
   * is one per connection and a person does not connect in a loop — unlike
   * `lastSeenAt` on the host side, which a reconnecting client can drive as fast
   * as it likes. A failed write is cosmetic and must not turn into a refusal:
   * the connection it is describing already succeeded.
   */
  sawWelcome(id: string, platform: string): void {
    const next = structuredClone(this.machines)
    const machine = next.find((candidate) => candidate.id === id)
    if (!machine) return
    machine.lastConnectedAt = this.now()
    if (platform !== '') machine.platform = platform.slice(0, 32)
    try {
      this.commit(next)
    } catch (err) {
      console.error('[machines] could not record a connection:', err)
    }
  }

  /* -------------------------------------------------------------- storage */

  private commit(machines: StoredMachine[]): void {
    // On disk first, then in memory, so a failed write leaves this process and
    // the file agreeing with each other rather than drifting until a restart
    // reveals it. The same order `device-auth.ts` commits in.
    writeSecretFile(this.dir, this.file, JSON.stringify({ version: 1, machines } satisfies StoredState, null, 2))
    this.machines = machines
  }

  private load(): void {
    // A file this app wrote before it knew how to set an NTFS ACL is still
    // sitting there readable by every account on the PC, and it holds a bearer
    // credential per paired machine. The write path repairs it on the next
    // commit; this repairs it now, on the way in, for the desktop that pairs
    // once and is never touched again. No-op off Windows, and it reports rather
    // than throws — `secret-file.ts` says why.
    protectSecretFile(this.dir, this.file)
    let raw: string
    try {
      const { size } = statSync(this.file)
      if (size > MAX_FILE_BYTES) {
        this.quarantine(`oversized (${size} bytes)`)
        return
      }
      raw = readFileSync(this.file, 'utf8')
    } catch (err) {
      // No file is the normal first run. Anything else leaves the list empty,
      // which means this desktop reaches no other machine until somebody pairs
      // again — the safe direction, and a visible one.
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
        console.error('[machines] the machine list could not be read:', err)
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
    if (!isRecord(parsed) || !Array.isArray(parsed.machines)) {
      this.quarantine('not a machine list')
      return
    }

    const machines: StoredMachine[] = []
    const seen = new Set<string>()
    for (const entry of parsed.machines.slice(0, MAX_MACHINES)) {
      const machine = asStoredMachine(entry)
      if (!machine) {
        console.error('[machines] dropped an unreadable machine record')
        continue
      }
      // Two rows for one machine is a damaged file, and `find` would answer with
      // whichever came first — so the app would dial with one credential and
      // rename with the other. The only safe reading is the first row and a line
      // in the log.
      if (seen.has(machine.id)) {
        console.error('[machines] duplicate machine in the list; keeping the first')
        continue
      }
      seen.add(machine.id)
      machines.push(machine)
    }
    // Folded in here rather than at every reader, so `list`, `drivesWindows`
    // and every `commit` built on this array all see one answer — and so the
    // next write for any reason puts the stripped field back into the record by
    // itself, without this read path having to write anything. See
    // `applyWindowDenies`.
    this.machines = applyWindowDenies(machines, this.denies, 'machine')
  }

  /**
   * Move a file we refuse to parse out of the way.
   *
   * Starting empty is safe — nothing is reachable — but the next write would
   * overwrite whatever was there, and if the damage was recoverable that is
   * every pairing on this machine gone for good.
   */
  private quarantine(reason: string): void {
    // The clock alone is not unique enough: two processes starting together —
    // or an injected clock that does not move — would rename the second damaged
    // file over the first, destroying the copy this exists to keep.
    const aside = `${this.file}.corrupt-${this.now()}-${randomBytes(4).toString('hex')}`
    try {
      renameSync(this.file, aside)
      console.error(`[machines] the machine list was ${reason}; moved aside to ${aside}`)
    } catch (err) {
      console.error(`[machines] the machine list was ${reason} and could not be moved aside:`, err)
    }
  }
}
