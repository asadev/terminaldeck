/**
 * Which paired devices may drive the browser windows in **this** app.
 *
 * ## Why a fourth axis, and why on this side too
 *
 * `folder-grants.ts` answers *where* a device may start a session,
 * `session-grants.ts` answers *which running sessions* it may touch, and
 * `account-grants.ts` answers *which logins* those sessions run as. None of them
 * says anything about the browser on this screen — the one holding this person's
 * signed-in mail, bank and source control — and a device that was given a folder
 * has not thereby been handed it.
 *
 * The same argument is already written down one hop away, in
 * `MachineStore.drivesWindows`, for a machine this desktop *dialled out to*. This
 * file is the mirror: the same question about a device that dialled *in*. Two
 * stores rather than one because the two id spaces are different and the two
 * decisions are different — "that PC's sessions may move my browser" is not the
 * same sentence as "my phone's sessions may" — and a single table keyed on a
 * string would be one typo away from answering the wrong one.
 *
 * ## Where the default comes from: the device's kind
 *
 * T30's accepted done-when is *"the connection IS the authorization"*, and the
 * approval screen is where a person authorizes a device — by approving it, and
 * by saying which kind it is. So the default is the kind's:
 *
 *  - a device approved as **mine** drives by default. The person at this
 *    keyboard said "this is my own machine" with their own hands, which is the
 *    same vouching that adding a server or pairing out to a machine is, and
 *    those two default open for it (`StoredServer.drivesWindows`,
 *    `Machine.drivesWindows`). What it reaches is still bounded window by
 *    window, by what the person attaches.
 *  - a device approved as a **guest** stays off until the person ticks it. A
 *    guest is the one peer nobody here vouched for — *"You choose what they can
 *    reach"* is the approval screen's own sentence — and a stranger's phone
 *    must never inherit this person's signed-in browser from a folder grant.
 *  - a device whose kind nobody recorded is a guest. `DeviceKinds.kindOf`
 *    already answers that way, and a host that cannot tell its own laptop from
 *    a stranger's phone has to treat both as the phone.
 *
 * The seam is {@link WindowGrantsOptions.kindOf} rather than a captured set,
 * so a kind decided while a device is connected lands on its very next call —
 * and a build that passes no seam (the headless host, an old test) has every
 * device read as a guest, which is the closed default this store has always
 * had.
 *
 * ## What the file holds: the explicit answers, and only those
 *
 * `devices` is the set a person said yes about; `denied` is the set they said
 * no about. Everything else takes the kind's default. Both sets are needed now
 * that a default can be open: without `denied`, unticking one of your own
 * machines would delete a yes that was never stored and change nothing — a
 * control that looks like it works and does not, the defect this whole round
 * is about. The `devices` name survives from the yes-only format so every file
 * the previous release wrote reads back with its answers intact.
 *
 * An unreadable file still grants nothing beyond the kind defaults, and a
 * hand-edited entry that cannot be read is dropped rather than guessed — a typo
 * must not hand somebody's browser to a machine across a relay.
 *
 * ## Why its own file
 *
 * The argument `folder-grants.ts` makes about `remote-auth.json`: that parser
 * drops every field it does not recognise, so a second module writing into it
 * would have its work erased by the next approve or revoke. Written through
 * {@link writeSecretFile} for the two properties it exists for — all-or-nothing
 * replacement, and never following a symlink somewhere else.
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { DeviceKind } from './device-kind'
import { writeSecretFile } from './secret-file'

export const REMOTE_WINDOWS_FILE = 'remote-windows.json'

/**
 * Written into the file so a future format change can tell itself apart from
 * this one instead of guessing from the shape.
 */
const FORMAT_VERSION = 1

/**
 * Ceilings, so a caller that has gone wrong cannot turn a preferences file into
 * something that has to be read at every launch. Sixty-four devices matches
 * `MAX_DEVICES` in the trust store and in the other three grant stores — a
 * device that cannot be paired cannot be granted — and the id length is the one
 * `device-auth.ts` mints against.
 */
const MAX_DEVICES = 64
const MAX_ID_LENGTH = 200
const MAX_FILE_BYTES = 64 * 1024

interface StoredState {
  version: number
  /** The device ids a person said yes about. */
  devices: string[]
  /** And the ones they said no about. Everyone else takes their kind's default. */
  denied: string[]
}

export interface WindowGrantsOptions {
  /**
   * What kind of device this is — the answer `DeviceKinds.kindOf` gives, read
   * per call so a kind decided while the device is connected lands on its next
   * verb. Absent, every device reads as a guest: the closed default, and the
   * only one a build that has no kinds store may assume.
   */
  kindOf?: (deviceId: string) => DeviceKind
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * The per-device window grant, on disk, with the app's copy in memory.
 *
 * No Electron import, for the reason the other three grant stores have none: the
 * storage directory is a constructor argument, so the whole thing runs against a
 * temp directory under vitest with no `app` object anywhere near it.
 */
export class WindowGrants {
  /** Absolute path of the file. Exposed for diagnostics and tests. */
  readonly file: string

  private readonly dir: string
  private readonly kindOf: (deviceId: string) => DeviceKind
  /** The ids a person said yes about. */
  private allowed = new Set<string>()
  /** And the ids they said no about. Absent from both means the kind decides. */
  private denied = new Set<string>()

  constructor(storageDir: string, options: WindowGrantsOptions = {}) {
    this.dir = storageDir
    this.file = join(storageDir, REMOTE_WINDOWS_FILE)
    this.kindOf = options.kindOf ?? (() => 'guest')
    this.load()
  }

  /**
   * May this device's sessions act on browser windows in this app?
   *
   * Read **per call** rather than captured when a link comes up, for the reason
   * `callers.ts` gives about `TokenGrant.caller` and `window-serve.ts` repeats
   * about its own `allowed`: a person unticking this has to land on the very next
   * call, not on the next reconnection. The kind is read per call too, through
   * the same rule — re-approving a guest as one of your own is an authorization,
   * and it must not wait for a restart to mean anything.
   */
  drives(deviceId: string): boolean {
    if (typeof deviceId !== 'string' || deviceId === '') return false
    if (this.denied.has(deviceId)) return false
    if (this.allowed.has(deviceId)) return true
    return this.kindOf(deviceId) === 'mine'
  }

  /**
   * Every device a person explicitly allowed.
   *
   * The explicit yeses only — a device driving on its kind's default is not in
   * this list, because this store does not hold the roster and cannot name it.
   * The settings channel answers the *effective* question by walking the paired
   * devices through {@link drives}; see `remote:windows` in `server.ts`.
   */
  list(): string[] {
    return [...this.allowed]
  }

  /**
   * Turn it on or off for one device. Answers what the store now says about the
   * device, which is not always what was asked: a new id past the ceiling is
   * refused, and the answer is the truth rather than the request echoed back.
   */
  set(deviceId: unknown, drives: unknown): boolean {
    if (typeof deviceId !== 'string') return false
    const id = deviceId.trim()
    if (id === '' || id.length > MAX_ID_LENGTH) return false
    const wanted = drives === true
    const into = wanted ? this.allowed : this.denied
    const outOf = wanted ? this.denied : this.allowed
    if (into.has(id) && !outOf.has(id)) return this.drives(id)
    // The ceiling is only enforced against *new* ids in the direction being
    // written: an id already recorded must always be able to be flipped,
    // however many the file has grown to.
    if (!into.has(id) && into.size >= MAX_DEVICES) return this.drives(id)
    const nextAllowed = new Set(this.allowed)
    const nextDenied = new Set(this.denied)
    ;(wanted ? nextAllowed : nextDenied).add(id)
    ;(wanted ? nextDenied : nextAllowed).delete(id)
    this.commit(nextAllowed, nextDenied)
    return this.drives(id)
  }

  /**
   * Drop a device's answers entirely.
   *
   * Called when a device is revoked, for the reason `FolderGrants.forget` gives:
   * revocation is permanent, a returning machine pairs again and is issued a
   * **new** device id, so the entry left behind could never be reached again and
   * keeping it would mean the file only ever grows. Here it is also the one that
   * matters most — an id left in the yes set is a permission with nobody
   * attached to it.
   */
  forget(deviceId: string): boolean {
    if (!this.allowed.has(deviceId) && !this.denied.has(deviceId)) return false
    const nextAllowed = new Set(this.allowed)
    const nextDenied = new Set(this.denied)
    nextAllowed.delete(deviceId)
    nextDenied.delete(deviceId)
    this.commit(nextAllowed, nextDenied)
    return true
  }

  /* ------------------------------------------------------------- internals */

  private commit(allowed: Set<string>, denied: Set<string>): void {
    const state: StoredState = {
      version: FORMAT_VERSION,
      devices: [...allowed],
      denied: [...denied],
    }
    writeSecretFile(this.dir, this.file, `${JSON.stringify(state, null, 2)}\n`)
    // Only after the disk agrees, the ordering `AccountGrants.commit` uses: the
    // in-memory sets are what every `drives` consults, so swapping them first
    // would leave an answer live for the rest of the run that no longer exists
    // after a restart.
    this.allowed = allowed
    this.denied = denied
  }

  /** Read one list of ids, dropping whatever cannot be one. */
  private static readIds(raw: unknown): Set<string> {
    const ids = new Set<string>()
    if (!Array.isArray(raw)) return ids
    for (const entry of raw) {
      if (ids.size >= MAX_DEVICES) break
      if (typeof entry !== 'string') continue
      const id = entry.trim()
      if (id === '' || id.length > MAX_ID_LENGTH) continue
      ids.add(id)
    }
    return ids
  }

  /** Read the file. See the header for why an unreadable one records nothing. */
  private load(): void {
    let text: string
    try {
      text = readFileSync(this.file, 'utf8')
    } catch {
      // Missing is the normal case: nobody has answered about a device yet, and
      // every kind's default stands.
      return
    }

    if (text.length > MAX_FILE_BYTES) {
      console.error('[remote] the remote window grant list is implausibly large; ignoring it')
      return
    }

    let parsed: unknown
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      console.error('[remote] could not read the remote window grant list:', error)
      return
    }

    if (!isRecord(parsed)) return
    const allowed = WindowGrants.readIds(parsed.devices)
    // Absent in every file the yes-only format wrote, and that reads as an
    // empty set: those files never held a no, so there is no answer to lose.
    const denied = WindowGrants.readIds(parsed.denied)
    // An id in both sets is a file somebody edited by hand, and the no wins:
    // the one direction a grant over somebody's browser may fail in.
    for (const id of denied) allowed.delete(id)
    this.allowed = allowed
    this.denied = denied
  }
}
