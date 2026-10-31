/**
 * What kind of thing is on the other end: one of yours, or somebody else's.
 *
 * ## The two, in his words
 *
 * From the recorded review of 2026-08-17, which is also where the wording on the
 * approval screen comes from verbatim:
 *
 *   > **My device** — Full access. It's you at another keyboard.
 *   > **Guest** — You choose what they can reach. The copilot is never shared.
 *
 * Both sentences are load-bearing and neither is decoration. The first is why a
 * device of your own is not made to pick folders at all: a person approving
 * their own laptop is not making a security decision, they are logging in, and a
 * folder picker in front of that is a form standing between somebody and their
 * own files. The second is why a guest is never *offered* the copilot — not
 * offered and defaulted off, **absent** — because an unchecked box still
 * advertises a feature and invites the ask, and the answer to the ask is always
 * no.
 *
 * ## Why this could not be a field on the folder list
 *
 * `folder-grants.ts` says at length that its file fails **open**: a truncated or
 * hand-edited `remote-folders.json` puts every device back to whatever the
 * desktop is offering rather than locking anyone out, and that is the right
 * direction for a preference about *where a session starts*.
 *
 * This is not that. The kind decides whether a device may reach the copilot —
 * an agent holding this machine's shell — and whether the folder list is
 * enforced at all. A file that fails open would mean a corrupted byte promotes
 * every guest in the house to an owner. So it is a separate file with the
 * opposite failure direction, and the two are separate for exactly the reason
 * that sentence gives: a file holding both would have the worse of the two
 * failure modes.
 *
 * The same argument rules out `remote-auth.json`, and there it is mechanical
 * rather than a judgement: `asStoredDevice` drops every field it does not
 * recognise, so a `kind` written into it would be erased by the next approve or
 * revoke — silently, and in the direction that removes a restriction.
 *
 * ## Fail closed, and what "closed" is here
 *
 * Unknown is `guest`. Every read path answers `guest` for a device this file has
 * never heard of, for a record it cannot parse, and for a file it cannot read.
 * That is a deliberate reversal of the neighbouring module's rule and it costs
 * something real, which is worth naming rather than glossing: **a device paired
 * by a build older than this one is a guest with no folders, so it can start
 * nothing until somebody chooses for it.**
 *
 * That is a regression for exactly the people who had it working, and it is
 * still right. The bug being fixed is that six digits typed into a phone bought
 * the whole machine; a fix that keeps working for everyone who already had the
 * whole machine has not fixed anything. The mitigation is that the refusal is
 * *legible* — the desktop names those devices and offers the choice in one
 * press, and the sentence the phone gets says which machine to go and fix it on.
 * A silent grant has no such remedy because nobody knows it happened.
 *
 * ## A kind cannot change after pairing
 *
 * {@link DeviceKinds.claim} writes once. A second call with a different kind is
 * refused, and there is deliberately no method that overwrites one.
 *
 * A toggle would make the distinction one tap deep, and this app has spent a
 * week removing exactly that shape — an escalation that needs no second act is
 * not an escalation, it is a default with a delay on it. Changing what a device
 * is means pairing it again, which is a person at this keyboard minting a code
 * and a person at the other end typing it: the same two acts that decided it the
 * first time. The screen says so plainly rather than hiding a control it would
 * refuse.
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { writeSecretFile } from './secret-file'

/**
 * The two kinds. There is no third, and no "unknown" member.
 *
 * Unknown is not a kind a device can *be* — it is a question this file answers
 * with `guest`, at the point of asking, in one place. A third member would
 * spread that decision to every switch statement downstream, and the first one
 * to forget a branch would be the one that decides whether the copilot answers.
 */
export type DeviceKind = 'mine' | 'guest'

export const DEVICE_KINDS: readonly DeviceKind[] = ['mine', 'guest']

/** Anything that is not literally one of the two reads as a guest. */
export function asDeviceKind(value: unknown): DeviceKind | null {
  return value === 'mine' || value === 'guest' ? value : null
}

/** One device's kind, as the settings panel and the approval flow list it. */
export interface DeviceKindRecord {
  deviceId: string
  kind: DeviceKind
  /** Epoch ms the choice was made. Shown as "decided when you approved it". */
  decidedAt: number
}

export const REMOTE_KINDS_FILE = 'remote-device-kinds.json'

/** Written into the file so a later format can tell itself apart from this one. */
const FORMAT_VERSION = 1

/**
 * Matches `MAX_DEVICES` in the trust store for the reason `folder-grants.ts`
 * gives about its own copy: a device that cannot be paired cannot be given a
 * kind, so a larger ceiling here would only be room for rows nothing can reach.
 */
const MAX_DEVICES = 64
const MAX_FILE_BYTES = 64 * 1024

interface StoredState {
  version: number
  devices: Record<string, { kind: DeviceKind; decidedAt: number }>
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * The per-device kind, on disk, with the app's copy in memory.
 *
 * No Electron import, the same as `device-auth.ts` and `folder-grants.ts` and
 * for the same reason: the storage directory is a constructor argument, so the
 * whole thing runs against a temp directory under vitest with no `app` object
 * anywhere near it.
 */
export class DeviceKinds {
  /** Absolute path of the file. Exposed for diagnostics and tests. */
  readonly file: string

  private readonly dir: string
  private kinds = new Map<string, { kind: DeviceKind; decidedAt: number }>()

  constructor(storageDir: string, private readonly now: () => number = Date.now) {
    this.dir = storageDir
    this.file = join(storageDir, REMOTE_KINDS_FILE)
    this.load()
  }

  /**
   * What this device is, and never null.
   *
   * The absence of a record is an answer rather than a gap — see the header —
   * and it is answered here rather than by every caller, so that no downstream
   * `if (kind === undefined)` can be written the other way round by somebody in
   * a hurry.
   */
  kindOf(deviceId: string): DeviceKind {
    if (typeof deviceId !== 'string' || deviceId === '') return 'guest'
    return this.kinds.get(deviceId)?.kind ?? 'guest'
  }

  /**
   * Has anybody actually decided about this device?
   *
   * Distinct from {@link kindOf} on purpose, and only one screen is allowed to
   * care: the desktop needs to tell "somebody chose guest" from "this predates
   * the choice existing", because the second one deserves a sentence explaining
   * why a phone that worked yesterday does not today. Nothing that *enforces*
   * anything may branch on this — enforcement reads `kindOf`, which folds the
   * two together in the safe direction.
   */
  decided(deviceId: string): boolean {
    return this.kinds.has(deviceId)
  }

  /** Every device that has a recorded kind, for the settings panel. */
  list(): DeviceKindRecord[] {
    return [...this.kinds].map(([deviceId, entry]) => ({
      deviceId,
      kind: entry.kind,
      decidedAt: entry.decidedAt,
    }))
  }

  /**
   * Record what this device is, once.
   *
   * Returns false when a *different* kind is already recorded, and true when the
   * write happened or when the same kind was already there. Idempotent rather
   * than refusing a repeat, because the caller is an approval flow that can be
   * retried — a network blip between "approve" and the list refresh should not
   * turn the second press into an error the person cannot act on.
   *
   * Throws if the file cannot be written, rather than reporting success. A kind
   * the panel believes and the disk does not is a device that is an owner until
   * the next launch and a guest afterwards, which is the worst of both.
   */
  claim(deviceId: string, kind: DeviceKind): boolean {
    if (typeof deviceId !== 'string' || deviceId === '') return false
    const existing = this.kinds.get(deviceId)
    if (existing) return existing.kind === kind
    if (this.kinds.size >= MAX_DEVICES) return false
    const next = new Map(this.kinds)
    next.set(deviceId, { kind, decidedAt: this.now() })
    this.commit(next)
    return true
  }

  /**
   * Drop a device's record entirely.
   *
   * Called when a device is revoked, for the reason `FolderGrants.forget` gives:
   * revocation is permanent and a returning phone pairs again with a **new**
   * device id, so the row left behind could never be reached by anything and the
   * file would only ever grow.
   *
   * This is also the only way a kind is ever *un*-recorded, which is what makes
   * re-pairing the answer to "I chose wrong": revoke, pair again, choose again.
   */
  forget(deviceId: string): boolean {
    if (!this.kinds.has(deviceId)) return false
    const next = new Map(this.kinds)
    next.delete(deviceId)
    this.commit(next)
    return true
  }

  /* ------------------------------------------------------------- internals */

  private commit(next: Map<string, { kind: DeviceKind; decidedAt: number }>): void {
    const devices: StoredState['devices'] = {}
    for (const [deviceId, entry] of next) devices[deviceId] = entry
    const state: StoredState = { version: FORMAT_VERSION, devices }
    writeSecretFile(this.dir, this.file, `${JSON.stringify(state, null, 2)}\n`)
    // Only after the disk agrees, the same ordering `FolderGrants.commit` uses:
    // the in-memory map is what every reach check consults, so swapping it first
    // would leave a kind live for the rest of the run that a restart undoes.
    this.kinds = next
  }

  /**
   * Read the file, treating anything unreadable as "nobody has decided".
   *
   * Which, because {@link kindOf} folds that into `guest`, means an unreadable
   * file demotes every device rather than promoting one. That is the whole
   * reason this module is not a field in the neighbouring file, and it is the
   * one place the difference is actually implemented, so it is worth being
   * explicit: **there is no branch below that can produce `mine` from bad
   * input.** A record whose `kind` is not literally the string `mine` is a guest.
   */
  private load(): void {
    let text: string
    try {
      text = readFileSync(this.file, 'utf8')
    } catch {
      // Missing is the normal case: no device has been approved yet.
      return
    }

    if (text.length > MAX_FILE_BYTES) {
      console.error('[remote] the device-kind file is implausibly large; ignoring it')
      return
    }

    let parsed: unknown
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      console.error('[remote] could not read the device-kind file:', error)
      return
    }

    if (!isRecord(parsed) || !isRecord(parsed.devices)) return
    const kinds = new Map<string, { kind: DeviceKind; decidedAt: number }>()
    for (const [deviceId, value] of Object.entries(parsed.devices)) {
      if (deviceId === '' || kinds.size >= MAX_DEVICES) continue
      if (!isRecord(value)) continue
      const kind = asDeviceKind(value.kind)
      if (kind === null) continue
      const decidedAt = typeof value.decidedAt === 'number' ? value.decidedAt : 0
      kinds.set(deviceId, { kind, decidedAt })
    }
    this.kinds = kinds
  }
}
