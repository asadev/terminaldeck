/**
 * The refusals that survive being downgraded through.
 *
 * ## The defect this exists for
 *
 * `StoredServer.drivesWindows` and `Machine.drivesWindows` both read **absent
 * as on** — the person added that server, or paired that machine, with their
 * own hands, and T30's accepted rule is that the connection is the
 * authorization. Both of those stores keep the person's *no* as a literal
 * `false` in the same record, in `servers/servers.json` and
 * `remote/machines.json`.
 *
 * 0.9.1 knows neither field. Its `readServers` and its `asStoredMachine`
 * reconstruct a **fixed field set** — verified against the 0.9.1 tree: exactly
 * one key differs between the two releases in each of those records, and it is
 * `drivesWindows` — and both stores rewrite the *whole* list on any change. So
 * running 0.9.1 once and renaming one server erases every `drivesWindows` key
 * on the machine, including the ones on rows nobody touched. Back on 0.10.0
 * every one of them reads absent, and absent means on.
 *
 * That is a person's explicit refusal turning into a yes while they were not
 * looking, and it is reproducible end to end. We cannot change 0.9.1. So the
 * refusal has to be kept somewhere 0.9.1 cannot reach.
 *
 * ## Why a sidecar, and not a schema version
 *
 * The obvious alternative is to stamp `version: 2` into `servers.json`, notice
 * that it came back as `1`, and stop applying absent-means-on to that file. It
 * does not work, for two reasons that compound:
 *
 *  - **A version marker in the rewritten file is rewritten too.** 0.9.1's
 *    writer hardcodes `version: 1`, so the marker is gone with everything else.
 *    Keeping the marker somewhere 0.9.1 does not rewrite means keeping a
 *    sidecar — at which point the sidecar may as well hold the answers.
 *  - **Detection is not recovery.** Even granting perfect detection, a stripped
 *    file does not say *which* rows were off. The only rules available are
 *    "close everything", which breaks the never-asked-stays-on default Asad
 *    accepted and would silently disarm servers nobody ever refused, or "ask",
 *    which is a modal about a file. Neither restores the answer that was given.
 *
 * A sidecar cannot itself be lost the way the field can, because the loss
 * mechanism is specific: 0.9.1 rewrites files it parses, and it parses this one
 * nowhere. It has no reader for it, no writer for it, and — checked across every
 * non-test module in the 0.9.1 tree — nothing that enumerates or prunes either
 * `servers/` or `remote/`, so an unrecognised file in those directories is left
 * exactly where it was found. The one thing that removes it is removing the
 * profile, which takes the servers and the pairings with it; the sidecar shares
 * the fate of the file it guards and never a worse one. That is the same
 * property `remote-windows.json` already has by accident — `WindowGrants` is a
 * 0.10.0 file end to end, so the `denied` set it keeps for paired *devices*
 * already survives a downgrade untouched. This file gives the other two id
 * spaces what that one has.
 *
 * ## What it holds, and what it does not
 *
 * Only the noes. A yes is never written here, because a yes is what the store
 * already says when the field is missing — recording it would be a second copy
 * of the default with its own way of going stale, and losing it would cost
 * nothing anyway. So this file is one-sided on purpose: it can only ever close
 * something, and a reader that cannot parse it falls back to the store's own
 * answer rather than to a refusal nobody typed.
 *
 * ## Two id spaces, two files, one class
 *
 * `WindowGrants`'s header makes the argument against a single table keyed on a
 * bare string: "that PC's sessions may move my browser" and "my phone's
 * sessions may" are different sentences, and one map would be a typo away from
 * answering the wrong one. The same holds here, so a server's refusals and a
 * machine's live in separate files under separate directories — beside the
 * store each one is about — and this class is instantiated twice rather than
 * shared once.
 *
 * ## No Electron
 *
 * The storage directory is a constructor argument, the rule `secret-file.ts`'s
 * callers all follow, so this runs against a temp directory under vitest with
 * no `app` object anywhere near it.
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { writeSecretFile } from './secret-file'

/** The refusals about servers, beside `servers.json` in the servers directory. */
export const SERVER_WINDOW_DENIES_FILE = 'window-denies.json'

/** And about paired machines, beside `machines.json` in the remote directory. */
export const MACHINE_WINDOW_DENIES_FILE = 'machine-window-denies.json'

/**
 * Written into the file so a later format can tell itself apart from this one
 * instead of guessing from the shape — the reason `window-grants.ts` stamps its
 * own. Note what it is *not*: a marker anything upgrades on. See the header for
 * why a version number cannot do this file's job.
 */
const FORMAT_VERSION = 1

/**
 * Ceilings that match the stores this guards — 64 servers (`MAX_SERVERS`) and
 * 64 machines (`MAX_MACHINES`) — because a refusal about a row that cannot
 * exist is not a refusal. The id length covers a UUID and a host id with room
 * to spare.
 */
const MAX_IDS = 64
const MAX_ID_LENGTH = 200
const MAX_FILE_BYTES = 64 * 1024

interface StoredState {
  version: number
  /** The ids a person said **no** about. Nothing else is ever in here. */
  denied: string[]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * The durable half of one `drivesWindows` switch.
 *
 * Held alongside the store rather than inside it: the store's field is still
 * the record a person edits and a support log reads, and this is the copy that
 * outlives an older build having rewritten that record. When the two disagree,
 * **this one wins**, because the only way they can disagree is the field having
 * been stripped — nothing else writes one without the other.
 */
export class WindowDenies {
  /** Absolute path of the file. Exposed for diagnostics and tests. */
  readonly file: string

  private readonly dir: string
  private ids = new Set<string>()

  constructor(storageDir: string, fileName: string) {
    this.dir = storageDir
    this.file = join(storageDir, fileName)
    this.load()
  }

  /** Did the person say no about this one? */
  has(id: string): boolean {
    return typeof id === 'string' && id !== '' && this.ids.has(id)
  }

  /** Every refusal on file, for a test and for a diagnostic. */
  list(): string[] {
    return [...this.ids]
  }

  /** How many, so the read path can skip the fold without allocating a list. */
  get size(): number {
    return this.ids.size
  }

  /**
   * Record a refusal, or take one back.
   *
   * Answers whether anything moved, so a caller can skip a write it does not
   * need. Throws when the disk refuses, exactly as `writeSecretFile` does for
   * every other file that decides what may reach what: a refusal this process
   * believes and the disk does not is one that disappears at the next launch,
   * which is the whole failure this module exists to close.
   */
  set(id: unknown, denied: boolean): boolean {
    if (typeof id !== 'string') return false
    const trimmed = id.trim()
    if (trimmed === '' || trimmed.length > MAX_ID_LENGTH) return false
    if (this.ids.has(trimmed) === denied) return false
    // The ceiling is enforced only against *adding* a refusal, and never
    // against taking one back: an id already on file must always be able to
    // come off, however large the file has grown.
    if (denied && this.ids.size >= MAX_IDS) return false
    const next = new Set(this.ids)
    if (denied) next.add(trimmed)
    else next.delete(trimmed)
    this.commit(next)
    return true
  }

  /**
   * Drop a refusal about something that no longer exists.
   *
   * Called when a server is forgotten and when a machine is paired again, for
   * the reason `WindowGrants.forget` gives about revocation — but here it does
   * a second, sharper job. A machine's id **is** its host id, so re-pairing the
   * same computer produces the same key. Without this, a machine somebody
   * refused, forgot, and then deliberately paired again — reading the code off
   * its screen and typing it here, which is the authorizing act — would come
   * back mysteriously unable to drive a window, with a stale line in a file as
   * the only explanation.
   */
  forget(id: string): boolean {
    return this.set(id, false)
  }

  /* ------------------------------------------------------------- internals */

  private commit(ids: Set<string>): void {
    const state: StoredState = { version: FORMAT_VERSION, denied: [...ids] }
    writeSecretFile(this.dir, this.file, `${JSON.stringify(state, null, 2)}\n`)
    // Only after the disk agrees — the order `WindowGrants.commit` and
    // `device-auth.ts` both use, so a failed write leaves this process and the
    // file saying the same thing rather than drifting until a restart shows it.
    this.ids = ids
  }

  private load(): void {
    let text: string
    try {
      text = readFileSync(this.file, 'utf8')
    } catch {
      // Missing is the ordinary case: nobody has refused anything yet, and
      // every store's own field stands on its own.
      return
    }
    if (text.length > MAX_FILE_BYTES) {
      console.error(`[window-denies] ${this.file} is implausibly large; ignoring it`)
      return
    }
    let parsed: unknown
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      // Falls back to the store's own field, which is the *open* direction —
      // deliberately, and it is the only direction available. Inventing
      // refusals out of an unreadable file would disarm servers nobody refused.
      console.error(`[window-denies] could not read ${this.file}:`, error)
      return
    }
    if (!isRecord(parsed) || !Array.isArray(parsed.denied)) return
    const ids = new Set<string>()
    for (const entry of parsed.denied) {
      if (ids.size >= MAX_IDS) break
      if (typeof entry !== 'string') continue
      const id = entry.trim()
      if (id === '' || id.length > MAX_ID_LENGTH) continue
      ids.add(id)
    }
    this.ids = ids
  }
}

/**
 * Fold the durable refusals into a freshly-read list, and say so in the log.
 *
 * Shared by both stores because both do the identical thing at the identical
 * moment, and because the log line is the only place a downgrade is ever
 * *visible*: a row whose field says on while this file says no can only have
 * got that way one way — an older build rewrote the record and dropped the key.
 * That is a precise detector, and it costs nothing, but it is a report and not
 * the repair. The repair is the returned value.
 *
 * Nothing is written here. The corrected value goes into the store's in-memory
 * list, so the *next* write the store makes for any reason puts the field back
 * into the record by itself — self-healing without a write on the read path,
 * which would otherwise mean every launch writing two files before the window
 * has drawn, on a profile that may be read-only.
 */
export function applyWindowDenies<T extends { id: string; drivesWindows?: boolean }>(
  rows: T[],
  denies: WindowDenies,
  subject: string,
): T[] {
  if (denies.size === 0) return rows
  let stripped = 0
  const out = rows.map((row) => {
    if (!denies.has(row.id)) return row
    if (row.drivesWindows !== false) stripped += 1
    // The cast is for one thing TypeScript will not do on its own: narrowing a
    // property of a generic to a literal and calling the result `T` again. The
    // constraint above already fixes the property's type, so nothing is being
    // asserted here that the signature does not already require.
    return { ...row, drivesWindows: false } as T
  })
  if (stripped > 0) {
    console.error(
      `[window-denies] ${stripped} ${subject} refusal(s) were missing from the record and have ` +
        `been restored from ${denies.file} — a build older than this one rewrote that file.`,
    )
  }
  return out
}
