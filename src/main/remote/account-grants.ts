/**
 * Which of this machine's coding logins each paired device may use.
 *
 * ## Why a third axis
 *
 * `folder-grants.ts` answers *where* a device may start a session and
 * `session-grants.ts` answers *which running sessions* it may touch. Neither
 * says anything about the logins those sessions run as — so a device that was
 * given one folder was also, silently, given every account on this machine to
 * run it under and to switch a session onto. Asad, 2026-08-21:
 *
 *   > *"Maybe we can give one selection step when we give access to any remote
 *   > device, we can give them some step where they choose also… If they wants
 *   > to give access of the accounts too, so they can give it."*
 *
 * and, later in the same recording, the shape of the choice:
 *
 *   > *"So that person, whoever is giving access, he can choose if he wants to
 *   > give multiple or one or whatever."*
 *
 * That is not the folder question asked again — the logins he wants told apart
 * are all on one machine and reachable from every folder — so it is a third
 * store and a third predicate, ANDed with the other two at the one door that
 * serves accounts over the wire.
 *
 * ## The three states, and why "none" is a list and not a mode
 *
 *  - **No record.** Nobody has narrowed this device. It reaches every login on
 *    this machine, which is exactly what every device paired before this file
 *    existed already had. See "absence is not denial" below.
 *  - **`all`.** A person chose *everything*. It behaves identically today and is
 *    a different fact: it survives an account being added tomorrow, and the
 *    panel draws it as pressed.
 *  - **`selected`.** Only the ticked ids — and an **empty** tick list is the
 *    third answer he asked for, *none*. That is a person's decision rather than
 *    a gap, which is why it is spelled as an empty `selected` and never as a
 *    missing row.
 *
 * `all` is a mode rather than "a list holding every id" for the reason
 * `SessionGrants` gives: the set changes underneath. An account added or signed
 * in next week would not be in a frozen list, and the only way to keep one
 * honest would be to rewrite this file from the accounts pane.
 *
 * ## What `none` does, one layer up
 *
 * Nothing here draws anything, but the consequence is worth stating where the
 * decision is: a device granted no logins is not sent the `account` capability
 * at all, so the chip over a session on this machine is **absent** on its
 * screen rather than present and empty. That is `capabilitiesFor` in
 * `server.ts`, and it is the same rule this codebase applies everywhere else —
 * a control that can do nothing is not drawn.
 *
 * ## Absence is not denial, and this one fails open on purpose
 *
 * A device with **no record** reaches every login, exactly as an unlisted device
 * reaches every offered folder in `folder-grants.ts`. Two machines were already
 * paired when this was written and both had account chips that worked; shipping
 * a store whose empty state silently took that away — with the loss showing up
 * on the other machine and the fix living here — would be a worse bug than the
 * one being fixed. Approval writes a record for every guest from now on, so the
 * open state is a fact about devices that predate the choice rather than a
 * default anybody new gets.
 *
 * A single malformed **row** narrows instead: an unreadable mode is read as
 * `selected`, which shares only the ids that did parse. Corruption inside a
 * record cannot widen what that record says.
 *
 * ## Why its own file
 *
 * The argument `folder-grants.ts` makes about `remote-auth.json`: that parser
 * drops every field it does not recognise, so a second module writing into it
 * would have its work erased by the next approve or revoke. Losing this file
 * costs a preference; losing that one costs the trust store. Written through
 * {@link writeSecretFile} for the two properties it exists for — all-or-nothing
 * replacement, and never following a symlink somewhere else.
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { writeSecretFile } from './secret-file'

/** All of this machine's logins, or only the ones ticked. */
export type AccountShare = 'all' | 'selected'

/** One device's choice, as the approval flow makes it and the panel lists it. */
export interface DeviceAccountGrant {
  deviceId: string
  mode: AccountShare
  /** Ticked account ids. Meaningful only under `selected`; always `[]` under `all`. */
  accounts: string[]
}

export const REMOTE_ACCOUNTS_FILE = 'remote-accounts.json'

/**
 * Written into the file so a future format change can tell itself apart from
 * this one instead of guessing from the shape.
 */
const FORMAT_VERSION = 1

/**
 * Ceilings, so a caller that has gone wrong cannot turn a preferences file into
 * something that has to be read at every launch. Sixty-four devices matches
 * `MAX_DEVICES` in the trust store and in the other two grant stores — a device
 * that cannot be paired cannot be narrowed — and the per-device account count
 * matches `MAX_ACCOUNTS_REPORTED` on the wire, which is the most logins this
 * machine will ever report about itself.
 */
const MAX_DEVICES = 64
const MAX_ACCOUNTS_PER_DEVICE = 64
/** The same ceiling `MAX_ACCOUNT_ID_LENGTH` puts on the wire. Ids are slugs. */
const MAX_ID_LENGTH = 200
const MAX_FILE_BYTES = 256 * 1024

interface StoredRow {
  mode: AccountShare
  accounts: string[]
}

interface StoredState {
  version: number
  devices: Record<string, StoredRow>
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * The per-device login choice, on disk, with the app's copy in memory.
 *
 * No Electron import, for the reason `FolderGrants` has none: the storage
 * directory is a constructor argument, so the whole thing runs against a temp
 * directory under vitest with no `app` object anywhere near it.
 */
export class AccountGrants {
  /** Absolute path of the file. Exposed for diagnostics and tests. */
  readonly file: string

  private readonly dir: string
  /** Device id → its choice. Absent key means nobody has narrowed it. */
  private rows = new Map<string, StoredRow>()

  constructor(storageDir: string) {
    this.dir = storageDir
    this.file = join(storageDir, REMOTE_ACCOUNTS_FILE)
    this.load()
  }

  /**
   * One device's choice, or **null** when nobody has made one.
   *
   * Null and `{ mode: 'all' }` behave identically today and are still not the
   * same fact — the panel draws one as nothing chosen and the other as *All* —
   * so this returns the difference rather than flattening it, the same way
   * `FolderGrants.granted` and `SessionGrants.granted` do.
   */
  granted(deviceId: string): DeviceAccountGrant | null {
    if (typeof deviceId !== 'string' || deviceId === '') return null
    const row = this.rows.get(deviceId)
    return row ? { deviceId, mode: row.mode, accounts: [...row.accounts] } : null
  }

  /** Every device that has a choice, for the settings panel. */
  list(): DeviceAccountGrant[] {
    return [...this.rows].map(([deviceId, row]) => ({
      deviceId,
      mode: row.mode,
      accounts: [...row.accounts],
    }))
  }

  /**
   * May this device use this login at all — to be told about it, and to move a
   * session onto it.
   *
   * Ids are compared exactly. They are opaque identifiers `profiles.ts` minted,
   * not paths, so there is no normalisation to do and inventing one would be a
   * way for two spellings of an account to disagree about who may run as it.
   */
  shares(deviceId: string, accountId: string): boolean {
    if (typeof deviceId !== 'string' || typeof accountId !== 'string') return false
    const row = this.rows.get(deviceId)
    if (!row) return true
    if (row.mode === 'all') return true
    return row.accounts.includes(accountId)
  }

  /**
   * Does this device reach **any** login here?
   *
   * Its own question rather than "is the list empty", because the answer decides
   * something bigger than a filter: a device that reaches none is not sent the
   * account capability, so no chip is drawn on its screen at all. Kept here, next
   * to the state it reads, so the capability and the filter cannot come to
   * disagree about what "none" is.
   */
  any(deviceId: string): boolean {
    if (typeof deviceId !== 'string' || deviceId === '') return true
    const row = this.rows.get(deviceId)
    if (!row) return true
    return row.mode === 'all' || row.accounts.length > 0
  }

  /**
   * Record one device's choice, replacing whatever was there.
   *
   * One write rather than tick/untick pairs, for the reason `FolderGrants.set`
   * gives: the panel always knows the whole list it is showing, and two mutating
   * verbs would need their own answers to questions this has exactly one answer
   * to.
   *
   * The ticked ids are dropped under `all` rather than kept as a shadow the next
   * press would restore — the same trade `SessionGrants.set` makes, and here the
   * stale list would be worse: an account can be deleted, and a hidden tick
   * naming a deleted one would come back as a grant for whatever id is minted
   * next.
   */
  set(deviceId: string, mode: unknown, accounts: readonly unknown[]): DeviceAccountGrant {
    const chosen: AccountShare = mode === 'all' ? 'all' : 'selected'
    const cleaned = chosen === 'all' ? [] : this.clean(accounts)
    if (typeof deviceId !== 'string' || deviceId === '') {
      return { deviceId: '', mode: chosen, accounts: cleaned }
    }
    const next = new Map(this.rows)
    // The ceiling is only enforced against *new* device ids: a device that
    // already has a row must always be able to have it edited, including
    // emptied, however many rows the file has grown. The same rule the other two
    // grant stores follow.
    if (!next.has(deviceId) && next.size >= MAX_DEVICES) {
      return { deviceId, mode: chosen, accounts: cleaned }
    }
    next.set(deviceId, { mode: chosen, accounts: cleaned })
    this.commit(next)
    return { deviceId, mode: chosen, accounts: cleaned }
  }

  /**
   * Drop a device's row entirely.
   *
   * Called when a device is revoked, for the reason `FolderGrants.forget` gives:
   * revocation is permanent, a returning machine pairs again and is issued a
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
   * Forget an account every device has been ticked for.
   *
   * An account that has been deleted can come back only as a *different* id —
   * `profiles.ts` mints one per account — so a tick naming a deleted one is a
   * row that only ever grows. Deliberately **not** a permission change: dropping
   * the id from a `selected` list cannot widen anything, because the id it drops
   * names nothing.
   */
  dropAccount(accountId: string): boolean {
    if (typeof accountId !== 'string' || accountId === '') return false
    let changed = false
    const next = new Map(this.rows)
    for (const [deviceId, row] of next) {
      if (!row.accounts.includes(accountId)) continue
      next.set(deviceId, { mode: row.mode, accounts: row.accounts.filter((id) => id !== accountId) })
      changed = true
    }
    if (changed) this.commit(next)
    return changed
  }

  /* ------------------------------------------------------------- internals */

  /** What a tick list may contain: non-empty opaque ids, deduplicated, bounded. */
  private clean(accounts: readonly unknown[]): string[] {
    const kept: string[] = []
    if (!Array.isArray(accounts)) return kept
    for (const entry of accounts) {
      if (typeof entry !== 'string') continue
      const id = entry.trim()
      if (id === '' || id.length > MAX_ID_LENGTH) continue
      if (kept.includes(id)) continue
      kept.push(id)
      if (kept.length >= MAX_ACCOUNTS_PER_DEVICE) break
    }
    return kept
  }

  private commit(next: Map<string, StoredRow>): void {
    const devices: Record<string, StoredRow> = {}
    for (const [deviceId, row] of next) devices[deviceId] = { mode: row.mode, accounts: row.accounts }
    const state: StoredState = { version: FORMAT_VERSION, devices }
    writeSecretFile(this.dir, this.file, `${JSON.stringify(state, null, 2)}\n`)
    // Only after the disk agrees. The in-memory map is what every `shares`
    // consults, so swapping it first would leave a choice live for the rest of
    // the run that no longer exists after a restart — the ordering
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
      console.error('[remote] the remote account list is implausibly large; ignoring it')
      return
    }

    let parsed: unknown
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      console.error('[remote] could not read the remote account list:', error)
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
      const mode: AccountShare = value.mode === 'all' ? 'all' : 'selected'
      const accounts = mode === 'all' ? [] : this.clean(Array.isArray(value.accounts) ? value.accounts : [])
      rows.set(deviceId, { mode, accounts })
    }
    this.rows = rows
  }
}
