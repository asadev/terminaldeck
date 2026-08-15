/**
 * Which folders each paired device may start a session in.
 *
 * ## The problem this replaces
 *
 * Until now a phone could start a session in "whatever this desktop happens to
 * be offering" — its open projects, plus the working directory of any session
 * that was already running. Nobody chose that list. It changes when a project
 * is closed on the desktop, it is different on every machine, and the person
 * holding the phone has no way to find out why it contains one folder today and
 * four tomorrow. That was observed exactly as it sounds: one folder in the
 * picker and no explanation available from the phone.
 *
 * So the list becomes something a person decides, per device, on the machine
 * that owns the files. The device gets what it was given and nothing else.
 *
 * ## Be honest about what this is
 *
 * It decides **where a session starts**. It is not a sandbox. A shell that
 * starts in a granted folder can `cd` anywhere the user account can reach, read
 * any file that account can read, and push to any remote its keys open. Nothing
 * here confines a process, and no wording in this app may suggest it does —
 * this is organisation for your own machines, in the same spirit as choosing
 * which folder a file dialog opens in.
 *
 * The security boundary is the one that was already there and is unchanged:
 * pairing, plus a human approving the device on the desktop. A device that gets
 * past that has a shell. This file decides which door it opens on.
 *
 * ## Absence is not denial
 *
 * A device with **no record here** falls back to the old behaviour rather than
 * being locked out. Two phones were already paired when this was written, and
 * shipping a feature that silently stops them starting sessions — with the
 * refusal arriving on a phone, away from the machine that could fix it — would
 * be a worse bug than the one being fixed.
 *
 * An **empty recorded list** is a different fact and is honoured: that is a
 * person having removed every folder, which means "nowhere", not "anywhere".
 * The distinction is the whole reason {@link FolderGrants.granted} answers
 * `null` rather than an empty array for an unlisted device.
 *
 * ## Why its own file
 *
 * `remote-auth.json` is written for an attacker: scrypt hashes, 0600, fsynced
 * before the rename, and a parser that drops every field it does not recognise.
 * That last part is the practical reason a folder list cannot live in it — a
 * second module writing a field `asStoredDevice` has never heard of would have
 * it erased by the next approve or revoke. It is also the right split: losing
 * this file costs a preference, losing that one costs the trust store.
 *
 * It is still written through {@link writeSecretFile}. Not because a folder path
 * is a secret, but because the two properties that function exists for —
 * all-or-nothing replacement, and never following a symlink into somewhere else
 * — are exactly as wanted here, and a second hand-rolled write is how the two
 * eventually disagree about which steps mattered.
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { currentPlatform, type Platform } from '../platform/host'
import { isAbsoluteFolder, sameFolder } from './session-create'
import { writeSecretFile } from './secret-file'

/** One device's chosen folders, as the settings panel lists them. */
export interface DeviceFolderGrant {
  deviceId: string
  /** Absolute paths, in the order they were chosen. May be empty — see the header. */
  folders: string[]
}

export const REMOTE_FOLDERS_FILE = 'remote-folders.json'

/**
 * Written into the file so a future format change can tell itself apart from
 * this one instead of guessing from the shape.
 */
const FORMAT_VERSION = 1

/**
 * Ceilings, so a caller that has gone wrong cannot turn a preferences file into
 * something that has to be read at every launch. Sixty-four devices matches
 * `MAX_DEVICES` in the trust store — a device that cannot be paired cannot be
 * granted anything — and the per-device folder count is well past what a person
 * would ever choose by hand.
 */
const MAX_DEVICES = 64
const MAX_FOLDERS_PER_DEVICE = 64
const MAX_PATH_LENGTH = 4096
const MAX_FILE_BYTES = 256 * 1024

interface StoredState {
  version: number
  devices: Record<string, string[]>
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * The per-device folder list, on disk, with the app's copy in memory.
 *
 * No Electron import, on purpose and for the same reason `device-auth.ts` has
 * none: the storage directory is a constructor argument, so the whole thing runs
 * against a temp directory under vitest with no `app` object anywhere near it.
 */
export class FolderGrants {
  /** Absolute path of the file. Exposed for diagnostics and tests. */
  readonly file: string

  private readonly dir: string
  private readonly platform: Platform
  /** Device id → the folders chosen for it. Absent key means nobody has chosen. */
  private grants = new Map<string, string[]>()

  constructor(storageDir: string, platform: Platform = currentPlatform()) {
    this.dir = storageDir
    this.file = join(storageDir, REMOTE_FOLDERS_FILE)
    this.platform = platform
    this.load()
  }

  /**
   * The folders chosen for one device, or **null** when nobody has chosen.
   *
   * The two answers are not the same and the caller must not flatten them: null
   * means "fall back to what this desktop offers", and `[]` means a person
   * removed the last folder. Returning a copy because the caller is the folder
   * rule in `session-create.ts`, and a list it could sort in place would be this
   * store's state being edited by something that only asked to read it.
   */
  granted(deviceId: string): string[] | null {
    if (typeof deviceId !== 'string' || deviceId === '') return null
    const chosen = this.grants.get(deviceId)
    return chosen ? [...chosen] : null
  }

  /** Every device that has a list, for the settings panel. */
  list(): DeviceFolderGrant[] {
    return [...this.grants].map(([deviceId, folders]) => ({ deviceId, folders: [...folders] }))
  }

  /**
   * Record the folders for one device, replacing whatever was there.
   *
   * One write rather than add/remove pairs. The panel always knows the whole
   * list it is showing, and two mutating verbs would need their own answers to
   * "what does adding a folder that is already there do" and "what does removing
   * one that is spelled differently do" — questions this has exactly one answer
   * to, in {@link clean}.
   *
   * Throws if the file cannot be written, rather than reporting success. A grant
   * the panel believes and the disk does not is a list that reverts at the next
   * launch, and the user would have no way to tell that apart from a device that
   * ignored it.
   */
  set(deviceId: string, folders: readonly unknown[]): string[] {
    if (typeof deviceId !== 'string' || deviceId === '') return []
    const cleaned = this.clean(folders)
    const next = new Map(this.grants)
    // The ceiling is only enforced against *new* device ids: a device that
    // already has a list must always be able to have it edited, including
    // emptied, however many rows the file has grown.
    if (!next.has(deviceId) && next.size >= MAX_DEVICES) return cleaned
    next.set(deviceId, cleaned)
    this.commit(next)
    return cleaned
  }

  /**
   * Drop a device's list entirely, putting it back to "nobody has chosen".
   *
   * Called when a device is revoked. Revocation is permanent — the trust store
   * never un-revokes, a returning phone pairs again and gets a **new** device id
   * — so the row left behind here could never be reached again by anything, and
   * keeping it would mean the file only ever grows.
   */
  forget(deviceId: string): boolean {
    if (!this.grants.has(deviceId)) return false
    const next = new Map(this.grants)
    next.delete(deviceId)
    this.commit(next)
    return true
  }

  /* ------------------------------------------------------------- internals */

  /**
   * What a folder list is allowed to contain.
   *
   * Absolute only, because the value is compared against absolute paths and
   * `normalize('projects/..')` is `'.'` — a relative path would lose that
   * comparison for a reason that has nothing to do with what the user meant.
   * Deduplicated with the same rule the enforcement uses, so a Windows user who
   * adds `C:\Users\Asad\proj` twice with different casing sees one row rather
   * than two that behave identically.
   */
  private clean(folders: readonly unknown[]): string[] {
    const kept: string[] = []
    for (const entry of folders) {
      if (typeof entry !== 'string') continue
      const path = entry.trim()
      if (path === '' || path.length > MAX_PATH_LENGTH) continue
      if (!isAbsoluteFolder(path, this.platform)) continue
      if (kept.some((seen) => sameFolder(seen, path, this.platform))) continue
      kept.push(path)
      if (kept.length >= MAX_FOLDERS_PER_DEVICE) break
    }
    return kept
  }

  private commit(next: Map<string, string[]>): void {
    const devices: Record<string, string[]> = {}
    for (const [deviceId, folders] of next) devices[deviceId] = folders
    const state: StoredState = { version: FORMAT_VERSION, devices }
    writeSecretFile(this.dir, this.file, `${JSON.stringify(state, null, 2)}\n`)
    // Only after the disk agrees. The in-memory map is what every `create`
    // consults, so swapping it first would leave a grant live for the rest of
    // the run that no longer exists after a restart.
    this.grants = next
  }

  /**
   * Read the file, and treat anything unreadable as "nobody has chosen yet".
   *
   * That is a decision worth stating, because it fails **open**: a truncated or
   * hand-edited file puts every device back to the desktop's own folder list
   * rather than locking them all out. It is the right direction here and would
   * not be in `device-auth.ts`, and the difference is what this module is. These
   * grants decide which folder a session starts in for machines their owner has
   * already approved; they are not a boundary anyone is kept behind. Failing
   * closed would strand every paired phone over a JSON typo, with the failure
   * showing up on the phone and the fix living on the desktop.
   *
   * The next {@link set} rewrites the file, so a corrupt one repairs itself the
   * first time somebody edits a device.
   */
  private load(): void {
    let text: string
    try {
      text = readFileSync(this.file, 'utf8')
    } catch {
      // Missing is the normal case: no device has been given a list yet.
      return
    }

    if (text.length > MAX_FILE_BYTES) {
      console.error('[remote] the remote folder list is implausibly large; ignoring it')
      return
    }

    let parsed: unknown
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      console.error('[remote] could not read the remote folder list:', error)
      return
    }

    if (!isRecord(parsed) || !isRecord(parsed.devices)) return
    const grants = new Map<string, string[]>()
    for (const [deviceId, value] of Object.entries(parsed.devices)) {
      if (deviceId === '' || grants.size >= MAX_DEVICES) continue
      if (!Array.isArray(value)) continue
      // Re-cleaned on the way in rather than trusted. This file can be edited by
      // hand, and the rule that a stored folder is absolute is the one the
      // comparison in `session-create.ts` depends on.
      grants.set(deviceId, this.clean(value))
    }
    this.grants = grants
  }
}

/**
 * The one list a device may start a session in — the answer `folders()` gives
 * the remote session rule, and the same array the phone's picker is sent.
 *
 * It is one function because it must be one answer. The picker showing a folder
 * the rule would refuse is the failure this whole feature exists to end, and two
 * places computing "what may this device use" is how that comes back.
 *
 * `offered` and `home` are called lazily: a device with its own list must not
 * cost a walk of the desktop's projects and sessions, and `home` is only the
 * answer in the one case below.
 *
 * The home directory is in this list rather than kept as a separate fallback for
 * a request that named nothing. There used to be two rules — a list, and a
 * "when the list is empty, use home" — and with grants that second rule quietly
 * turns "this device may use no folders" into "this device may start in the
 * user's home directory", which is the opposite of what was chosen. One list,
 * and an empty one means nothing, is the only version without that hole.
 */
export function foldersForDevice(
  grants: Pick<FolderGrants, 'granted'>,
  deviceId: string,
  offered: () => readonly string[],
  home: () => string,
): string[] {
  const chosen = grants.granted(deviceId)
  if (chosen !== null) return chosen

  const list = [...offered()]
  // A first launch: nothing open, nothing running, and a phone starting a
  // session is at its most useful and least able to name a folder.
  return list.length > 0 ? list : [home()]
}
