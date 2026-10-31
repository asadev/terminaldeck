/**
 * Which of the *running* sessions each paired device may see.
 *
 * ## Why a second axis
 *
 * `folder-grants.ts` answers "where may this device start a session", and
 * `device-reach.ts` turns that into "which running sessions may it touch" by
 * asking whether the session's cwd is inside a granted folder. That is one axis
 * and `session-fanout.ts` says out loud what it costs: a folder grant is "to
 * grant whatever else happens to be running in it." Share a project and every
 * agent in it comes with it, now and for as long as the grant stands.
 *
 * Asad, 2026-08-20: *"when we give remote access we should be able to choose
 * between running sessions which ones to give and which ones not, i mean select
 * vs all type of options"*. That is not the folder question asked again — the
 * two sessions he wants told apart are usually in the *same* folder — so it is
 * a second store and a second predicate, ANDed with the first.
 *
 * ## The three states, and why `all` is not an empty list
 *
 *  - **No record.** Nobody has narrowed this device. It sees whatever its
 *    folders reach, which is exactly what it saw before this file existed.
 *  - **`all`.** A person chose "everything", which behaves identically today and
 *    is a different fact: it survives a device being re-listed, and it is what
 *    the panel draws as pressed.
 *  - **`selected`.** Only the ticked ids. An empty tick list means *nothing*,
 *    and that is a person's answer rather than a gap — the same distinction
 *    `FolderGrants` spends a paragraph on, for the same reason.
 *
 * `all` is stored as a mode rather than as "a list containing every id" because
 * the set of running sessions changes every few minutes. A list would go stale
 * the moment a session started, and the only way to keep it honest would be to
 * rewrite this file from a pty callback.
 *
 * ## A session started after the choice is not shared
 *
 * With `selected`, a session that starts later is not in the list, so it is not
 * shared until somebody ticks it. That is the decision and it is the fail-closed
 * one: the opposite would mean a device that was narrowed to one terminal
 * silently gains a keyboard on the next one the owner opens.
 *
 * The one exception is a session **that device itself started** — see
 * {@link SessionGrants.include}. It already passed the folder rule to be started
 * at all, the device asked for it by name, and refusing it would make `create`
 * a button that hands back something the caller cannot open.
 *
 * ## Why its own file
 *
 * The argument `folder-grants.ts` makes about `remote-auth.json`: that parser
 * drops every field it does not recognise, so a second module writing into it
 * would have its work erased by the next approve or revoke. Losing this file
 * costs a preference; losing that one costs the trust store. Written through
 * {@link writeSecretFile} for the two properties it exists for — all-or-nothing
 * replacement, and never following a symlink somewhere else.
 *
 * ## What an unreadable file does, said out loud
 *
 * It is read as "no record for anybody", which **widens** rather than narrows:
 * a device that had been cut down to one session would see everything its
 * folders reach until the panel is used again. That is the same direction
 * `FolderGrants.load` chose and it is chosen here for the same reason — the
 * alternative is a hand-edited JSON typo leaving every paired device with an
 * empty session list, with the failure landing on a phone and the fix living on
 * the desktop. The file is written atomically by this app and by nothing else,
 * so the only way to reach that state is to edit it by hand.
 *
 * A single *row* that is malformed is a different matter and narrows: an
 * unrecognised mode is read as `selected`, which shares only the ids that did
 * parse. Corruption inside a record cannot widen what that record says.
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { writeSecretFile } from './secret-file'

/** All of them, or only the ones ticked. */
export type SessionShare = 'all' | 'selected'

/** One device's choice, as the settings panel lists it. */
export interface DeviceSessionGrant {
  deviceId: string
  mode: SessionShare
  /** Ticked session ids. Meaningful only under `selected`; always `[]` under `all`. */
  sessions: string[]
}

export const REMOTE_SESSIONS_FILE = 'remote-sessions.json'

/**
 * Written into the file so a future format change can tell itself apart from
 * this one instead of guessing from the shape.
 */
const FORMAT_VERSION = 1

/**
 * Ceilings, so a caller that has gone wrong cannot turn a preferences file into
 * something that has to be read at every launch. Sixty-four devices matches
 * `MAX_DEVICES` in the trust store and in `folder-grants.ts` — a device that
 * cannot be paired cannot be narrowed — and the per-device session count is well
 * past what a machine runs at once.
 */
const MAX_DEVICES = 64
const MAX_SESSIONS_PER_DEVICE = 256
const MAX_ID_LENGTH = 128
const MAX_FILE_BYTES = 256 * 1024

interface StoredRow {
  mode: SessionShare
  sessions: string[]
}

interface StoredState {
  version: number
  devices: Record<string, StoredRow>
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * The per-device session choice, on disk, with the app's copy in memory.
 *
 * No Electron import, for the reason `FolderGrants` has none: the storage
 * directory is a constructor argument, so the whole thing runs against a temp
 * directory under vitest with no `app` object anywhere near it.
 */
export class SessionGrants {
  /** Absolute path of the file. Exposed for diagnostics and tests. */
  readonly file: string

  private readonly dir: string
  /** Device id → its choice. Absent key means nobody has narrowed it. */
  private rows = new Map<string, StoredRow>()

  constructor(storageDir: string) {
    this.dir = storageDir
    this.file = join(storageDir, REMOTE_SESSIONS_FILE)
    this.load()
  }

  /**
   * One device's choice, or **null** when nobody has made one.
   *
   * Null and `{ mode: 'all' }` behave identically today and are still not the
   * same fact — the panel draws one as nothing pressed and the other as *All* —
   * so this returns the difference rather than flattening it, the same way
   * `FolderGrants.granted` does.
   */
  granted(deviceId: string): DeviceSessionGrant | null {
    if (typeof deviceId !== 'string' || deviceId === '') return null
    const row = this.rows.get(deviceId)
    return row ? { deviceId, mode: row.mode, sessions: [...row.sessions] } : null
  }

  /** Every device that has a choice, for the settings panel. */
  list(): DeviceSessionGrant[] {
    return [...this.rows].map(([deviceId, row]) => ({
      deviceId,
      mode: row.mode,
      sessions: [...row.sessions],
    }))
  }

  /**
   * May this device see this session — this axis only.
   *
   * The folder rule is the other half and is asked separately in
   * `session-fanout.ts`; both must say yes. Absence is *not* denial here, and
   * that is the one direction this predicate is permissive in: a device nobody
   * has narrowed keeps exactly what it had before this feature existed.
   *
   * Ids are compared exactly. They are opaque identifiers this app minted, not
   * paths, so there is no normalisation to do and inventing one would be a way
   * for two spellings of a session to disagree about who may type into it.
   */
  shares(deviceId: string, sessionId: string): boolean {
    if (typeof deviceId !== 'string' || typeof sessionId !== 'string') return false
    const row = this.rows.get(deviceId)
    if (!row) return true
    if (row.mode === 'all') return true
    return row.sessions.includes(sessionId)
  }

  /**
   * Record one device's choice, replacing whatever was there.
   *
   * One write rather than tick/untick pairs, for the reason `FolderGrants.set`
   * gives: the panel always knows the whole list it is showing, and two mutating
   * verbs would need their own answers to questions this has exactly one answer
   * to.
   *
   * The ticked ids are dropped under `all`, rather than kept as a shadow the
   * next press would restore. A stored list that decides nothing is a list that
   * goes stale invisibly, and a person who switches back to *Selected* expecting
   * their old ticks would instead get whichever of them are still running —
   * which is not a state they chose, it is a state the clock chose.
   */
  set(deviceId: string, mode: unknown, sessions: readonly unknown[]): DeviceSessionGrant {
    const chosen: SessionShare = mode === 'all' ? 'all' : 'selected'
    const cleaned = chosen === 'all' ? [] : this.clean(sessions)
    if (typeof deviceId !== 'string' || deviceId === '') {
      return { deviceId: '', mode: chosen, sessions: cleaned }
    }
    const next = new Map(this.rows)
    // The ceiling is only enforced against *new* device ids: a device that
    // already has a row must always be able to have it edited, however many
    // rows the file has grown. The same rule `FolderGrants.set` follows.
    if (!next.has(deviceId) && next.size >= MAX_DEVICES) {
      return { deviceId, mode: chosen, sessions: cleaned }
    }
    next.set(deviceId, { mode: chosen, sessions: cleaned })
    this.commit(next)
    return { deviceId, mode: chosen, sessions: cleaned }
  }

  /**
   * Tick a session this device just started.
   *
   * Called from `SessionFanout.create` after a successful spawn, and only there.
   * Without it, a device on *Selected* that starts its own session is handed an
   * id it may not attach to — `create` becomes a button whose result is
   * invisible, which is the "control that cannot act" this product is removing
   * everywhere else.
   *
   * It is not a hole in the fail-closed rule. The device passed the folder rule
   * to get the spawn at all, and it named the session itself; what it must not
   * gain is a session **somebody else** started, which is untouched.
   *
   * A no-op for a device with no row or on `all` — both of those already see it
   * — and for one that is already ticked. Returns whether the file was written.
   */
  include(deviceId: string, sessionId: string): boolean {
    if (typeof deviceId !== 'string' || deviceId === '') return false
    if (typeof sessionId !== 'string' || sessionId === '' || sessionId.length > MAX_ID_LENGTH) return false
    const row = this.rows.get(deviceId)
    if (!row || row.mode === 'all') return false
    if (row.sessions.includes(sessionId)) return false
    if (row.sessions.length >= MAX_SESSIONS_PER_DEVICE) return false
    const next = new Map(this.rows)
    next.set(deviceId, { mode: 'selected', sessions: [...row.sessions, sessionId] })
    this.commit(next)
    return true
  }

  /**
   * Drop a device's row entirely.
   *
   * Called when a device is revoked, for the reason `FolderGrants.forget` gives:
   * revocation is permanent, a returning phone pairs again and is issued a
   * **new** device id, so the row left behind could never be reached again and
   * keeping it would mean the file only ever grows.
   */
  forget(deviceId: string): boolean {
    if (!this.rows.has(deviceId)) return false
    const next = new Map(this.rows)
    next.delete(deviceId)
    this.commit(next)
    return true
  }

  /**
   * Forget a session every device has now been ticked for.
   *
   * A session that has exited can never come back — ids are minted once — so a
   * tick naming one is a row that only ever grows. Called from the same place
   * the app already learns a session ended.
   *
   * Deliberately **not** a permission change: dropping the id from a `selected`
   * list cannot widen anything, because the id it drops names nothing.
   */
  dropSession(sessionId: string): boolean {
    if (typeof sessionId !== 'string' || sessionId === '') return false
    let changed = false
    const next = new Map(this.rows)
    for (const [deviceId, row] of next) {
      if (!row.sessions.includes(sessionId)) continue
      next.set(deviceId, { mode: row.mode, sessions: row.sessions.filter((id) => id !== sessionId) })
      changed = true
    }
    if (changed) this.commit(next)
    return changed
  }

  /* ------------------------------------------------------------- internals */

  /** What a tick list may contain: non-empty opaque ids, deduplicated, bounded. */
  private clean(sessions: readonly unknown[]): string[] {
    const kept: string[] = []
    if (!Array.isArray(sessions)) return kept
    for (const entry of sessions) {
      if (typeof entry !== 'string') continue
      const id = entry.trim()
      if (id === '' || id.length > MAX_ID_LENGTH) continue
      if (kept.includes(id)) continue
      kept.push(id)
      if (kept.length >= MAX_SESSIONS_PER_DEVICE) break
    }
    return kept
  }

  private commit(next: Map<string, StoredRow>): void {
    const devices: Record<string, StoredRow> = {}
    for (const [deviceId, row] of next) devices[deviceId] = { mode: row.mode, sessions: row.sessions }
    const state: StoredState = { version: FORMAT_VERSION, devices }
    writeSecretFile(this.dir, this.file, `${JSON.stringify(state, null, 2)}\n`)
    // Only after the disk agrees. The in-memory map is what every `visible`
    // consults, so swapping it first would leave a choice live for the rest of
    // the run that no longer exists after a restart. The ordering
    // `FolderGrants.commit` uses, for the same reason.
    this.rows = next
  }

  /** Read the file. See the header for what an unreadable one does, and why. */
  private load(): void {
    let text: string
    try {
      text = readFileSync(this.file, 'utf8')
    } catch {
      // Missing is the normal case: nobody has narrowed a device yet.
      return
    }

    if (text.length > MAX_FILE_BYTES) {
      console.error('[remote] the remote session list is implausibly large; ignoring it')
      return
    }

    let parsed: unknown
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      console.error('[remote] could not read the remote session list:', error)
      return
    }

    if (!isRecord(parsed) || !isRecord(parsed.devices)) return
    const rows = new Map<string, StoredRow>()
    for (const [deviceId, value] of Object.entries(parsed.devices)) {
      if (deviceId === '' || rows.size >= MAX_DEVICES) continue
      if (!isRecord(value)) continue
      // Anything that is not exactly `all` is read as `selected`, which shares
      // only what parsed. A row this file cannot understand must never come out
      // wider than it went in.
      const mode: SessionShare = value.mode === 'all' ? 'all' : 'selected'
      const sessions = mode === 'all' ? [] : this.clean(Array.isArray(value.sessions) ? value.sessions : [])
      rows.set(deviceId, { mode, sessions })
    }
    this.rows = rows
  }
}
