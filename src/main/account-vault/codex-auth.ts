/**
 * Codex's login, kept by the app and placed where Codex reads it.
 *
 * ## Why a file, and why that is not the same compromise as it sounds
 *
 * Codex keeps its login in one place: `$CODEX_HOME/auth.json`, mode 0600 —
 * `provider-accounts.ts` has the measurement (*"three homes, and only the real
 * one is signed in"*). It never asks a command for it, so there is no lookup
 * this app can answer the way `keychain-shim.ts` answers Claude Code's. The
 * only place Codex will read a login from is that file, in that account's own
 * directory.
 *
 * So for an account this app keeps:
 *
 *  - the **vault** holds the login, encrypted, and is the copy that survives —
 *    a deleted account directory, a crash, a reinstall of Codex;
 *  - while the app runs, the file is **placed** in the account's own directory
 *    (0600, written atomically) so every session and every status check on that
 *    account finds it — and every session on *another* account finds its own,
 *    because each account is a different `CODEX_HOME`;
 *  - every write Codex makes to it — the sign-in, each token refresh — is
 *    **captured** back into the vault, so the kept copy is never older than the
 *    one in use;
 *  - when the app quits the file is captured one last time and **removed**, so
 *    at rest the login exists only inside the vault.
 *
 * That is strictly better than Codex's own default, which leaves the file in
 * place for ever, and it is honest about the one window where it is not
 * encrypted: while the app that owns it is running and the agent needs it.
 *
 * ## A Codex sign-out is a sign-out here too
 *
 * `codex logout` deletes the file. The watcher sees it go and drops the kept
 * copy — otherwise the next launch would put back a login the person had just
 * removed. The app's own removal at quit is told apart by `releasing`, which is
 * set before the file is touched.
 */

import { existsSync, readFileSync, unlinkSync, watch, type FSWatcher } from 'node:fs'
import { join } from 'node:path'
import { writeSecretFile } from '../remote/secret-file'
import type { AccountVault } from './store'

/** Where Codex keeps its login, relative to `CODEX_HOME`. */
export const CODEX_AUTH_FILE = 'auth.json'

/** The vault slot it is kept in. */
export const CODEX_AUTH_SLOT = `file:${CODEX_AUTH_FILE}`

/** A login file is a few kilobytes. Anything this big is not one. */
const MAX_AUTH_BYTES = 256 * 1024

/** One account, as much of it as this module needs. */
export interface CodexAccount {
  id: string
  /** Its `CODEX_HOME`. */
  configDir: string
}

/** Start watching a directory; returns the stop. Injected so tests drive events. */
export type DirWatch = (dir: string, onEvent: () => void) => () => void

const defaultWatch: DirWatch = (dir, onEvent) => {
  let watcher: FSWatcher | null = null
  try {
    watcher = watch(dir, { persistent: false }, (_event, filename) => {
      // Some platforms report no filename; an event we cannot attribute is
      // treated as possibly ours, because a missed refresh is a stale login.
      if (filename === null || filename === undefined || String(filename) === CODEX_AUTH_FILE) onEvent()
    })
    watcher.on('error', () => {
      // The directory went away (the account was deleted). Nothing to follow.
    })
  } catch {
    watcher = null
  }
  return () => watcher?.close()
}

/**
 * The file's contents when it holds something that can be a login, or null.
 *
 * "Can be" is a JSON object and nothing more: Codex owns the shape, and an
 * app that refused a field it did not recognise would drop a perfectly good
 * login the first time Codex changed its format. Half-written text — a reader
 * catching the file mid-write — does not parse, and is ignored rather than kept.
 */
export function readAuthFile(path: string): string | null {
  try {
    if (!existsSync(path)) return null
    const raw = readFileSync(path, 'utf8')
    if (raw.length === 0 || raw.length > MAX_AUTH_BYTES) return null
    const parsed = JSON.parse(raw) as unknown
    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed) ? raw : null
  } catch {
    return null
  }
}

export interface CodexAuthOptions {
  watch?: DirWatch
  /** How long to wait for a burst of writes to settle. */
  debounceMs?: number
  onCapture?(event: { accountId: string; kind: 'sign-in' | 'refresh' | 'adopted' | 'signed-out' }): void
}

export type SettleResult = 'kept' | 'placed' | 'none'

export class CodexAuthKeeper {
  private readonly watchers = new Map<string, { stop(): void; timer: ReturnType<typeof setTimeout> | null }>()
  private readonly releasing = new Set<string>()
  private readonly watchDir: DirWatch
  private readonly debounceMs: number

  constructor(
    private readonly vault: AccountVault,
    private readonly options: CodexAuthOptions = {},
  ) {
    this.watchDir = options.watch ?? defaultWatch
    this.debounceMs = options.debounceMs ?? 250
  }

  private file(account: CodexAccount): string {
    return join(account.configDir, CODEX_AUTH_FILE)
  }

  /**
   * Bring the file and the vault into agreement, then follow the file.
   *
   * A file that is there is the newer copy: the vault only ever changes by
   * capturing it, so a difference means Codex wrote it while nothing was
   * watching — the app had crashed, or this is an account made before the app
   * kept logins and this is its one-time move. A file that is not there is
   * placed from the vault.
   */
  settle(account: CodexAccount): SettleResult {
    let result: SettleResult = 'none'
    const onDisk = readAuthFile(this.file(account))
    const kept = this.vault.read(account.id, CODEX_AUTH_SLOT)
    if (onDisk !== null) {
      if (onDisk !== kept) {
        const written = this.vault.put(account.id, 'codex', CODEX_AUTH_SLOT, onDisk, kept === null ? 'adopted' : 'refresh')
        if (written.ok && written.changed) {
          this.options.onCapture?.({ accountId: account.id, kind: kept === null ? 'adopted' : 'refresh' })
        }
      }
      result = 'kept'
    } else if (kept !== null && existsSync(account.configDir)) {
      this.place(account, kept)
      result = 'placed'
    }
    this.follow(account)
    return result
  }

  private place(account: CodexAccount, value: string): void {
    writeSecretFile(account.configDir, this.file(account), value)
  }

  /** Read the file and keep it if it changed. What every watcher event ends in. */
  capture(account: CodexAccount): 'kept' | 'unchanged' | 'signed-out' | 'ignored' {
    if (this.releasing.has(account.id)) return 'ignored'
    const path = this.file(account)
    const kept = this.vault.read(account.id, CODEX_AUTH_SLOT)
    if (!existsSync(path)) {
      if (kept === null) return 'unchanged'
      // Codex removed its own login: `codex logout`. Kept copy goes too.
      this.vault.drop(account.id, CODEX_AUTH_SLOT)
      this.options.onCapture?.({ accountId: account.id, kind: 'signed-out' })
      return 'signed-out'
    }
    const onDisk = readAuthFile(path)
    if (onDisk === null) return 'ignored'
    if (onDisk === kept) return 'unchanged'
    const kind = kept === null ? 'sign-in' : 'refresh'
    const written = this.vault.put(account.id, 'codex', CODEX_AUTH_SLOT, onDisk, kind)
    if (!written.ok) return 'ignored'
    this.options.onCapture?.({ accountId: account.id, kind })
    return 'kept'
  }

  /** Watch this account's directory for Codex writing its login. Idempotent. */
  follow(account: CodexAccount): void {
    if (this.watchers.has(account.id)) return
    const entry: { stop(): void; timer: ReturnType<typeof setTimeout> | null } = {
      stop: () => undefined,
      timer: null,
    }
    entry.stop = this.watchDir(account.configDir, () => {
      if (entry.timer !== null) clearTimeout(entry.timer)
      entry.timer = setTimeout(() => {
        entry.timer = null
        this.capture(account)
      }, this.debounceMs)
    })
    this.watchers.set(account.id, entry)
  }

  private unfollow(accountId: string): void {
    const entry = this.watchers.get(accountId)
    if (!entry) return
    if (entry.timer !== null) clearTimeout(entry.timer)
    entry.stop()
    this.watchers.delete(accountId)
  }

  /**
   * The app is quitting: keep the newest copy, stop watching, remove the file.
   *
   * In that order. Capturing after the unlink would read nothing; unlinking
   * while still watching would be seen as a sign-out and drop the login the
   * app is about to need at the next launch.
   */
  release(account: CodexAccount): void {
    this.capture(account)
    this.releasing.add(account.id)
    this.unfollow(account.id)
    if (this.vault.read(account.id, CODEX_AUTH_SLOT) === null) {
      // Nothing kept, so the file is not ours to take away — it may be a login
      // the vault could not save (no secure store), and removing it would sign
      // the account out for nothing.
      this.releasing.delete(account.id)
      return
    }
    try {
      unlinkSync(this.file(account))
    } catch {
      // Already gone.
    }
    this.releasing.delete(account.id)
  }

  /** The account was deleted: stop watching and take its file away. */
  forget(account: CodexAccount): void {
    this.releasing.add(account.id)
    this.unfollow(account.id)
    try {
      unlinkSync(this.file(account))
    } catch {
      // Already gone, or the directory went with the account.
    }
    this.releasing.delete(account.id)
  }

  /** Every account this keeper is following. */
  following(): string[] {
    return [...this.watchers.keys()]
  }

  /** Stop every watcher without touching any file. */
  dispose(): void {
    for (const id of [...this.watchers.keys()]) this.unfollow(id)
  }
}
