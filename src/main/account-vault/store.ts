/**
 * The account vault — every agent login this app keeps, encrypted, in its own
 * data folder.
 *
 * ## Why the app keeps them now
 *
 * Asad, 2026-10-03:
 *
 *   > *"currently accounts switching is not that reliable and [we] cannot add as
 *   > many accounts as we want. It should save within app the tokens and all
 *   > that stuff."*
 *
 * Until this module an account was a directory and nothing else: the app handed
 * an agent CLI a config directory and the CLI kept the login wherever it keeps
 * logins — on macOS, a login-keychain item whose *name* is a hash of that
 * directory's path. `ACCOUNT-MODEL.md` measured that end to end, and it is why
 * `profiles.ts` could say *"this app never holds the credential"*. It is also
 * why every one of the faults the accounts lane found is a fault of something
 * the app could not see: whether an account is signed in at all is a question
 * only a spawned CLI can answer, slowly; a login is filed under a path, so a
 * moved data folder is a signed-out account; and the store the switch depends
 * on belongs to a program that deletes it on the first 401.
 *
 * `ACCOUNT-MODEL.md` already said what would change the recommendation: *"if
 * the CLI grows a supported way to export a token… B becomes the right answer."*
 * What changed is narrower and better — the app does not have to export
 * anything. The agent asks for its credential through a command it looks up on
 * `PATH` (`keychain-shim.ts`) or reads it from a file in its own directory
 * (`codex-auth.ts`), and both of those are places this app can answer *for one
 * session*. So the login is captured the moment the agent writes it, kept here,
 * and handed back to exactly the sessions running as that account.
 *
 * ## Where a secret is, at every moment
 *
 *  1. **On disk**, in one `safeStorage` blob (the key is held by the macOS
 *     keychain, under this app's own entry), written through `writeSecretFile`:
 *     atomic, fsynced, mode 0600. Where no secure store is available this
 *     **refuses to save** rather than writing plaintext — the rule
 *     `servers/credentials.ts`, `voice.ts` and `browser-passwords.ts` already
 *     live by — and the account carries on being held by the agent itself,
 *     exactly as before this module existed.
 *  2. **In this process's memory**, decrypted, while the app runs.
 *  3. **In the agent's hands**, for the length of one request: the answer to
 *     its keychain lookup, or the credential file in its own directory.
 *
 * The window is never one of them. {@link AccountVault.read} is the only
 * reader, it is called from two places — the socket the shim talks to and the
 * Codex file placer — and {@link AccountVault.summary} is the only thing that
 * crosses the bridge: which slots are held and when, never what is in them.
 *
 * ## Why this file knows nothing about Electron
 *
 * `profiles.ts` reaches this module, and the headless host imports
 * `profiles.ts` under plain Node. An `import { safeStorage } from 'electron'`
 * here would stop that build at its first instruction. So the cipher is handed
 * in ({@link VaultCipher}); the desktop shell hands it `safeStorage`
 * (`electron-cipher.ts`) and the tests hand it a fake with the same shape.
 */

import { existsSync, readFileSync, renameSync, statSync } from 'node:fs'
import { join } from 'node:path'
import type { ProviderId } from '../../shared/types'
import { protectSecretFile, writeSecretFile } from '../remote/secret-file'

/* ---------------------------------------------------------------- shapes -- */

/** The file, inside the app's data folder. */
export const VAULT_FILE = 'account-vault.bin'

/** Bumped only when an older build could not read what this one writes. */
export const VAULT_VERSION = 1

/** Bigger than any real credential, small enough that a wrong file is refused. */
const MAX_SECRET_LENGTH = 256 * 1024

/** A whole vault; anything larger is not ours to parse. */
const MAX_FILE_BYTES = 8 * 1024 * 1024

/**
 * The three things `safeStorage` does, and nothing else.
 *
 * An interface rather than the Electron object so that this module can be
 * loaded where Electron cannot (see the header), and so a test can stand one up
 * that behaves like the real thing in the one way that matters: ciphertext that
 * is not the plaintext.
 */
export interface VaultCipher {
  available(): boolean
  encrypt(plain: string): Buffer
  decrypt(blob: Buffer): string
}

/**
 * Where a slot's value came from — kept so a screen can say "kept since you
 * signed in" and so a log line can tell a refresh from a first capture.
 *
 *  - `sign-in`  the agent wrote it while nothing was held: a login.
 *  - `refresh`  the agent rewrote one that was held: a token refresh.
 *  - `adopted`  read from where the agent kept it before the app kept it — the
 *               one-time move of an account that predates this module.
 *  - `typed`    a person pasted it in (an API key).
 */
export type VaultSource = 'sign-in' | 'refresh' | 'adopted' | 'typed'

interface StoredSlot {
  value: string
  source: VaultSource
  updatedAt: number
}

interface StoredEntry {
  accountId: string
  provider: ProviderId
  capturedAt: number
  slots: Record<string, StoredSlot>
}

/**
 * What may be said about one account's stored login, anywhere — the window, a
 * log line, an MCP tool. **No value, ever.** Slot names are fixed strings this
 * app chose (`keychain:Claude Code-credentials`, `file:auth.json`), never
 * anything an agent wrote.
 */
export interface VaultSummary {
  accountId: string
  provider: ProviderId
  /** True when at least one slot holds something the agent can sign in with. */
  held: boolean
  slots: string[]
  /** When the app first kept a login for this account. */
  capturedAt: number
  /** When anything in it last changed — a refresh moves this. */
  updatedAt: number
  /** How the newest value arrived. */
  lastSource: VaultSource
  /**
   * The plan the agent recorded for this login (`max`, `pro`, …), when its
   * credential carries one. A label the agent wrote about itself, read out of a
   * value this module already holds — not a secret, and not fetched.
   */
  plan: string | null
}

export interface VaultWrite {
  ok: boolean
  /** True when the stored value is different from what was there. */
  changed: boolean
  /** Shown to a person verbatim when `ok` is false. */
  message: string
}

/** The sentence wherever the vault cannot save. One string, so two screens agree. */
export const NO_SECURE_STORE =
  'This computer has no secure store available, so this app cannot keep logins itself. ' +
  'Each agent keeps its own login instead, as it always has.'

/** The sentence while the vault is there and will not open. See `AccountVault.state`. */
export const VAULT_LOCKED =
  'The logins this app keeps could not be unlocked just now, so nothing was changed. ' +
  'They are safe; quit and reopen the app to try again.'

/* ------------------------------------------------------------ validation -- */

/**
 * A slot name this module will accept.
 *
 * Deliberately small: a prefix that says how the agent reaches it, a colon,
 * and a name from a short alphabet. Slot names are chosen by this app, so
 * anything outside the alphabet is a caller bug — refusing it means a slot can
 * never smuggle a path separator into a log line or a filename.
 */
export function isSlotName(slot: unknown): slot is string {
  return typeof slot === 'string' && /^(keychain|file|env):[A-Za-z0-9 ._-]{1,80}$/.test(slot)
}

function isProvider(value: unknown): value is ProviderId {
  return value === 'claude' || value === 'codex' || value === 'gemini' || value === 'shell'
}

function isSource(value: unknown): value is VaultSource {
  return value === 'sign-in' || value === 'refresh' || value === 'adopted' || value === 'typed'
}

function readEntries(raw: unknown): Map<string, StoredEntry> {
  const out = new Map<string, StoredEntry>()
  if (typeof raw !== 'object' || raw === null) return out
  const entries = (raw as { entries?: unknown }).entries
  if (!Array.isArray(entries)) return out
  for (const candidate of entries) {
    if (typeof candidate !== 'object' || candidate === null) continue
    const record = candidate as Record<string, unknown>
    const accountId = typeof record.accountId === 'string' ? record.accountId : ''
    if (accountId === '' || !isProvider(record.provider)) continue
    const slots: Record<string, StoredSlot> = {}
    const rawSlots = record.slots
    if (typeof rawSlots === 'object' && rawSlots !== null) {
      for (const [name, slot] of Object.entries(rawSlots as Record<string, unknown>)) {
        if (!isSlotName(name) || typeof slot !== 'object' || slot === null) continue
        const value = (slot as Record<string, unknown>).value
        if (typeof value !== 'string' || value === '' || value.length > MAX_SECRET_LENGTH) continue
        const source = (slot as Record<string, unknown>).source
        const updatedAt = (slot as Record<string, unknown>).updatedAt
        slots[name] = {
          value,
          source: isSource(source) ? source : 'sign-in',
          updatedAt: typeof updatedAt === 'number' ? updatedAt : 0,
        }
      }
    }
    if (Object.keys(slots).length === 0) continue
    out.set(accountId, {
      accountId,
      provider: record.provider,
      capturedAt: typeof record.capturedAt === 'number' ? record.capturedAt : 0,
      slots,
    })
  }
  return out
}

/**
 * The plan label inside a Claude credential, when there is one.
 *
 * Claude Code writes `{"claudeAiOauth": {…, "subscriptionType": "max"}}` and
 * nothing in that object besides this field is anything a screen should ever
 * hold. Read defensively: an unparseable value is still a login the agent can
 * use, and "no plan" is the honest answer about it.
 */
function planOf(slots: Record<string, StoredSlot>): string | null {
  for (const slot of Object.values(slots)) {
    try {
      const parsed = JSON.parse(slot.value) as { claudeAiOauth?: { subscriptionType?: unknown } }
      const plan = parsed?.claudeAiOauth?.subscriptionType
      if (typeof plan === 'string' && /^[a-z0-9_-]{1,32}$/i.test(plan)) return plan
    } catch {
      // Not JSON — an API key, a file this does not parse. No plan to name.
    }
  }
  return null
}

/* ------------------------------------------------------------- the vault -- */

export interface AccountVaultOptions {
  /** The folder the vault file lives in — the app's own data folder. */
  dir: string
  cipher: VaultCipher
  now?: () => number
  /**
   * How the encrypted text reaches the disk. `writeSecretFile` by default —
   * atomic, fsynced, 0600 — and injectable only so a test can make it fail.
   */
  writeFile?: (dir: string, file: string, contents: string) => void
}

export type VaultListener = (accountId: string) => void

export class AccountVault {
  readonly path: string
  private readonly dir: string
  private readonly cipher: VaultCipher
  private readonly now: () => number
  private readonly writeFile: (dir: string, file: string, contents: string) => void
  private loaded: Map<string, StoredEntry> | null = null
  private readonly listeners = new Set<VaultListener>()
  /**
   * Set when a vault file exists that this process could not open — another
   * OS user's, another machine's, or damaged. It is the only copy of somebody's
   * logins, so the first write moves it aside rather than replacing it.
   * `profiles.ts` keeps the same flag for the same reason.
   */
  private setAsideBeforeWrite = false
  /** The file is there and would not decrypt. See {@link AccountVault.state}. */
  private lockedOut = false

  constructor(options: AccountVaultOptions) {
    this.dir = options.dir
    this.path = join(options.dir, VAULT_FILE)
    this.cipher = options.cipher
    this.now = options.now ?? Date.now
    this.writeFile = options.writeFile ?? ((dir, file, contents) => writeSecretFile(dir, file, contents))
  }

  /** Whether logins can be kept here at all on this computer. */
  available(): boolean {
    try {
      return this.cipher.available()
    } catch {
      return false
    }
  }

  /**
   * Whether the vault could be opened, as of the last attempt.
   *
   *  - `ready`   opened (or there was nothing to open yet).
   *  - `locked`  the file is there and **would not decrypt** — the keychain
   *              entry that holds the key was denied, the keychain is locked,
   *              or this is a different build of the app (a dev build and a
   *              release one have different keys) reading the other's file.
   *
   * The second is not "empty". It is every login this app keeps, behind a key
   * that is not available right now, and the only safe things to do with it
   * are nothing and try again later: no write (a write would replace it), no
   * setting it aside (the next write would then start a new, empty vault over
   * every login the person had), and no caching of the failure (the next ask
   * might succeed).
   */
  state(): 'ready' | 'locked' {
    return this.lockedOut ? 'locked' : 'ready'
  }

  /**
   * Open the vault now, rather than on the first lookup. Called at boot so the
   * first decrypt — the one that can raise a keychain prompt — never happens
   * inside a session's lookup, where a prompt would outlast the shim's timeout.
   */
  open(): 'ready' | 'locked' {
    this.load()
    return this.state()
  }

  private load(): Map<string, StoredEntry> {
    if (this.loaded !== null) return this.loaded
    if (!existsSync(this.path)) {
      this.lockedOut = false
      this.loaded = new Map()
      return this.loaded
    }
    protectSecretFile(this.dir, this.path)

    let plain: string
    try {
      if (statSync(this.path).size > MAX_FILE_BYTES) {
        // Not a vault this app could have written. Moved aside on the next
        // write, which is safe because it was never anybody's logins.
        this.setAsideBeforeWrite = true
        this.lockedOut = false
        this.loaded = new Map()
        return this.loaded
      }
      const blob = Buffer.from(readFileSync(this.path, 'utf8'), 'base64')
      plain = this.cipher.decrypt(blob)
    } catch {
      // Would not decrypt. See `state()`: nothing is cached and nothing is
      // marked for setting aside, so the file is exactly as it was and the next
      // ask tries again.
      this.lockedOut = true
      return new Map()
    }

    this.lockedOut = false
    try {
      this.loaded = readEntries(JSON.parse(plain) as unknown)
    } catch {
      // It decrypted, so it is ours, and it does not parse — damaged. That one
      // is set aside before the next write rather than overwritten, so whatever
      // can be recovered from it still can be.
      this.setAsideBeforeWrite = true
      this.loaded = new Map()
    }
    return this.loaded
  }

  private persist(next: Map<string, StoredEntry>): VaultWrite {
    if (!this.available()) return { ok: false, changed: false, message: NO_SECURE_STORE }
    if (this.lockedOut) return { ok: false, changed: false, message: VAULT_LOCKED }
    const entries = [...next.values()]
    let blob: Buffer
    try {
      blob = this.cipher.encrypt(JSON.stringify({ version: VAULT_VERSION, entries }))
    } catch (cause) {
      return {
        ok: false,
        changed: false,
        message: `The login could not be encrypted: ${cause instanceof Error ? cause.message : String(cause)}`,
      }
    }
    if (this.setAsideBeforeWrite) {
      try {
        renameSync(this.path, `${this.path}.unreadable-${this.now()}`)
      } catch {
        // Already gone. Nothing left to preserve.
      }
      this.setAsideBeforeWrite = false
    }
    try {
      this.writeFile(this.dir, this.path, blob.toString('base64'))
    } catch (cause) {
      return {
        ok: false,
        changed: false,
        message: `The login could not be saved: ${cause instanceof Error ? cause.message : String(cause)}`,
      }
    }
    this.loaded = next
    return { ok: true, changed: true, message: '' }
  }

  private announce(accountId: string): void {
    for (const listener of this.listeners) {
      try {
        listener(accountId)
      } catch {
        // A listener that throws must not stop a login being kept.
      }
    }
  }

  /** Told the account id whenever anything about it changes. Never the value. */
  onChange(listener: VaultListener): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /** True when the app holds something this account can sign in with. */
  has(accountId: string): boolean {
    const entry = this.load().get(accountId)
    return entry !== undefined && Object.keys(entry.slots).length > 0
  }

  /**
   * One slot's value, or null.
   *
   * **Main process only, and only on the way to an agent.** The two callers
   * are the shim socket (`server.ts`) answering a session's own lookup and the
   * Codex placer writing that account's own file. Nothing that can reach the
   * preload bridge or an MCP tool may call this; `vault-never-leaks.test.ts`
   * holds the line.
   */
  read(accountId: string, slot: string): string | null {
    if (!isSlotName(slot)) return null
    return this.load().get(accountId)?.slots[slot]?.value ?? null
  }

  /**
   * Keep a value. A write of the value already held is a no-op that reports
   * `changed: false` — the agent rewrites its credential far more often than it
   * changes it, and a disk write per lookup would be a disk write per request.
   */
  put(
    accountId: string,
    provider: ProviderId,
    slot: string,
    value: string,
    source: VaultSource,
  ): VaultWrite {
    if (typeof accountId !== 'string' || accountId === '') {
      return { ok: false, changed: false, message: 'An account id is required.' }
    }
    if (!isSlotName(slot)) return { ok: false, changed: false, message: 'That is not a slot this app keeps.' }
    if (typeof value !== 'string' || value === '') {
      return { ok: false, changed: false, message: 'There was nothing to keep.' }
    }
    if (value.length > MAX_SECRET_LENGTH) {
      return { ok: false, changed: false, message: 'That is much too long to be a login.' }
    }
    const current = this.load()
    const held = current.get(accountId)
    if (held?.slots[slot]?.value === value && held.provider === provider) {
      return { ok: true, changed: false, message: '' }
    }
    const at = this.now()
    const next = new Map(current)
    next.set(accountId, {
      accountId,
      // An account belongs to one agent. A write naming a different one is the
      // account having been re-made under the same id, and the old agent's
      // slots mean nothing to the new one — so they go.
      provider,
      capturedAt: held && held.provider === provider ? held.capturedAt : at,
      slots: {
        ...(held && held.provider === provider ? held.slots : {}),
        [slot]: { value, source, updatedAt: at },
      },
    })
    const result = this.persist(next)
    if (result.ok) this.announce(accountId)
    return result
  }

  /** Remove one slot — the agent signed out, or deleted its own copy. */
  drop(accountId: string, slot: string): VaultWrite {
    const current = this.load()
    const held = current.get(accountId)
    if (!held || held.slots[slot] === undefined) return { ok: true, changed: false, message: '' }
    const next = new Map(current)
    const slots = { ...held.slots }
    delete slots[slot]
    if (Object.keys(slots).length === 0) next.delete(accountId)
    else next.set(accountId, { ...held, slots })
    const result = this.persist(next)
    if (result.ok) this.announce(accountId)
    return result
  }

  /**
   * Delete everything kept for this account.
   *
   * Called when the account is removed, and it is the reason the vault is one
   * file rather than a file per account: the delete and the rewrite are the
   * same atomic rename, so there is no moment where the list says an account is
   * gone and a file still holds its token.
   */
  forget(accountId: string): VaultWrite {
    const current = this.load()
    if (!current.has(accountId)) return { ok: true, changed: false, message: '' }
    const next = new Map(current)
    next.delete(accountId)
    const result = this.persist(next)
    /*
     * Gone from memory whether or not the disk took it. An account that has
     * been removed must not be answered for one more request — least of all to
     * an account re-made under the same id — and a failed write is reported to
     * the caller rather than quietly leaving the login live. What can still be
     * on disk is cleared the next time the vault is written, and `createProfile`
     * forgets an id before reusing it.
     */
    if (this.loaded !== null) this.loaded = next
    this.announce(accountId)
    return result
  }

  /** What may be said about one account. See {@link VaultSummary}. */
  summary(accountId: string): VaultSummary | null {
    const entry = this.load().get(accountId)
    if (!entry) return null
    const slots = Object.entries(entry.slots)
    const newest = slots.reduce<StoredSlot | null>(
      (best, [, slot]) => (best === null || slot.updatedAt > best.updatedAt ? slot : best),
      null,
    )
    return {
      accountId,
      provider: entry.provider,
      held: slots.length > 0,
      slots: slots.map(([name]) => name).sort(),
      capturedAt: entry.capturedAt,
      updatedAt: newest?.updatedAt ?? entry.capturedAt,
      lastSource: newest?.source ?? 'sign-in',
      plan: planOf(entry.slots),
    }
  }

  /** Every account the vault holds anything for. */
  summaries(): VaultSummary[] {
    return [...this.load().keys()]
      .map((id) => this.summary(id))
      .filter((summary): summary is VaultSummary => summary !== null)
  }

  /** Drop the in-memory copy. Tests swap files underneath; nothing else should. */
  reload(): void {
    this.loaded = null
    this.setAsideBeforeWrite = false
    this.lockedOut = false
  }
}
