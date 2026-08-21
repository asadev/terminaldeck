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
 * ## Why this one defaults closed, unlike the three next to it
 *
 * Folders, sessions and logins fail open because they were added to a product
 * that already worked without them, and a store whose empty state silently took
 * a working chip away would be a worse bug than the one it fixed. Nothing has
 * ever been able to drive a window in this app from another computer, so there
 * is no working behaviour to preserve: `false` is what every device already does,
 * and the first thing a person does after ticking this is watch it work.
 *
 * That also decides what an unreadable file does. `FolderGrants.load` and
 * `AccountGrants.load` widen on a parse failure, deliberately, because the
 * alternative leaves a phone with nothing and the fix on the desktop. Here the
 * unreadable file is read as **nobody is allowed**, which is the same direction
 * the default points and the only direction a grant like this may fail in: a
 * hand-edited typo must not hand somebody's browser to a machine across a relay.
 *
 * ## Why the file holds only the yeses
 *
 * A row per device with a boolean in it would have three states — true, false and
 * absent — and two of them mean the same thing. So the file is the set of device
 * ids that are allowed, and everything else is not; there is no way to write a
 * row that reads as permission by accident, and a device that is revoked simply
 * stops being in the set.
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
  /** The device ids that are allowed. Absence is the answer for everyone else. */
  devices: string[]
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
  /** The allowed device ids. Absent means no. */
  private allowed = new Set<string>()

  constructor(storageDir: string) {
    this.dir = storageDir
    this.file = join(storageDir, REMOTE_WINDOWS_FILE)
    this.load()
  }

  /**
   * May this device's sessions act on browser windows in this app?
   *
   * Read **per call** rather than captured when a link comes up, for the reason
   * `callers.ts` gives about `TokenGrant.caller` and `window-serve.ts` repeats
   * about its own `allowed`: a person unticking this has to land on the very next
   * call, not on the next reconnection.
   */
  drives(deviceId: string): boolean {
    if (typeof deviceId !== 'string' || deviceId === '') return false
    return this.allowed.has(deviceId)
  }

  /** Every device that has been allowed, for the settings panel. */
  list(): string[] {
    return [...this.allowed]
  }

  /**
   * Turn it on or off for one device. Answers what the store now says, which is
   * not always what was asked: a new id past the ceiling is refused, and the
   * answer is the truth rather than the request echoed back.
   */
  set(deviceId: unknown, drives: unknown): boolean {
    if (typeof deviceId !== 'string') return false
    const id = deviceId.trim()
    if (id === '' || id.length > MAX_ID_LENGTH) return false
    const wanted = drives === true
    if (this.allowed.has(id) === wanted) return wanted
    const next = new Set(this.allowed)
    if (wanted) {
      // The ceiling is only enforced against *new* ids: a device that is already
      // allowed must always be able to be turned off, however many the file has
      // grown to. Turning one on is the direction that has to be bounded.
      if (next.size >= MAX_DEVICES) return false
      next.add(id)
    } else {
      next.delete(id)
    }
    this.commit(next)
    return wanted
  }

  /**
   * Drop a device's grant entirely.
   *
   * Called when a device is revoked, for the reason `FolderGrants.forget` gives:
   * revocation is permanent, a returning machine pairs again and is issued a
   * **new** device id, so the entry left behind could never be reached again and
   * keeping it would mean the file only ever grows. Here it is also the one that
   * matters most — an id left in this set is a permission with nobody attached
   * to it.
   */
  forget(deviceId: string): boolean {
    if (!this.allowed.has(deviceId)) return false
    const next = new Set(this.allowed)
    next.delete(deviceId)
    this.commit(next)
    return true
  }

  /* ------------------------------------------------------------- internals */

  private commit(next: Set<string>): void {
    const state: StoredState = { version: FORMAT_VERSION, devices: [...next] }
    writeSecretFile(this.dir, this.file, `${JSON.stringify(state, null, 2)}\n`)
    // Only after the disk agrees, the ordering `AccountGrants.commit` uses: the
    // in-memory set is what every `drives` consults, so swapping it first would
    // leave a grant live for the rest of the run that no longer exists after a
    // restart.
    this.allowed = next
  }

  /** Read the file. See the header for why an unreadable one grants nothing. */
  private load(): void {
    let text: string
    try {
      text = readFileSync(this.file, 'utf8')
    } catch {
      // Missing is the normal case: nobody has allowed a device yet.
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

    if (!isRecord(parsed) || !Array.isArray(parsed.devices)) return
    const allowed = new Set<string>()
    for (const entry of parsed.devices) {
      if (allowed.size >= MAX_DEVICES) break
      if (typeof entry !== 'string') continue
      const id = entry.trim()
      if (id === '' || id.length > MAX_ID_LENGTH) continue
      allowed.add(id)
    }
    this.allowed = allowed
  }
}
