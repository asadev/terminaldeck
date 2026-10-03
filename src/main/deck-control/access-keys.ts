/**
 * Access keys: one per AI app the owner lets in.
 *
 * ## What a key is
 *
 * Asad, on what this release is for:
 *
 *   > *"I will give [it] to my copilot in any other application… that copilot
 *   > can also drive this terminal deck living in my Mac Mini, I just keep it
 *   > open and any other AI from any other application from internet through
 *   > the MCP can connect to it."*
 *
 * So an AI app outside this one — claude.ai, ChatGPT, Cursor, a Claude Code on
 * another laptop — needs a credential it can keep across restarts and that the
 * owner can take back. That is a key: a name he chose ("ChatGPT"), a level, a
 * secret shown to him once, and nothing else. It reaches the same
 * `deck-control` tools the in-app copilot uses, through the same dispatcher, and
 * every call it makes is a row in the same action log with its name on it.
 *
 * ## The three levels, and why they are words rather than tiers
 *
 * | Level           | Tiers              | In his words, roughly              |
 * |-----------------|--------------------|------------------------------------|
 * | `look`          | read               | *look for the answers*             |
 * | `work`          | read, act          | *start sessions, drive sessions*   |
 * | `full`          | read, act, alter   | *everything I can do manually*     |
 *
 * A level maps to a `TierGrant`, and the mapping lives in one function so a
 * level can never mean two things. Three named rungs rather than three
 * checkboxes because the person choosing is not a programmer, and "act without
 * read" — which three checkboxes can express — is not a thing anybody means.
 *
 * Be plain about `work`, because the settings page is: a session started
 * through a key runs as the owner and has a shell, so a key that may start
 * sessions is very nearly a key to the machine. The level bounds what the
 * *tools* will do; it does not make a session less than a session.
 *
 * ## What is stored, and what never is
 *
 * The key itself is shown once, by {@link AccessKeys.create}, and then exists
 * only in the app it was pasted into. This file keeps a **SHA-256** of it.
 * SHA-256 rather than scrypt, which `device-auth.ts` uses, and the difference is
 * the input: a device credential can be derived from something a person typed,
 * so it has to be slow to guess; these are 32 random bytes, and there is nothing
 * to search — a slow hash would buy nothing and cost every tool call a
 * deliberate stall.
 *
 * Matching compares the offered key's hash against **every** stored hash in
 * constant time and never stops early, for the reason `callers.ts` gives about
 * its own table: an early exit would make "how far down the list is your key"
 * measurable.
 *
 * ## Where the file is, and who may write it
 *
 * `<userData>/remote/access-keys.json`, written through `remote/secret-file.ts`
 * (0600, atomic) like every other file whose loss or edit changes who can reach
 * this machine. It sits beside the device trust store on purpose: the records
 * fence (`confine/records.ts`) keeps the copilot's own shell off it, because a
 * copilot that could append a hash it chose would have minted itself a way in
 * from the internet with no tool call, no confirmation and no log row.
 *
 * ## Fail closed
 *
 * A file that cannot be read or parsed is an empty store with internet reach
 * off. The unreadable copy is set aside rather than overwritten, so a person
 * who hand-edited it can recover their names — but nothing in it is honoured,
 * because a corrupted byte must never be what lets something in.
 */

import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto'
import { copyFileSync, existsSync, readFileSync } from 'node:fs'
import { isAbsolute, join } from 'node:path'
import { writeSecretFile } from '../remote/secret-file'
import { SECRET_PREFIX, newWebhookSecret, webhookUrlProblem } from './notify-webhook'
import { ALL_TIERS, type TierGrant } from './surface'

/* -------------------------------------------------------------- constants -- */

/** The file, inside `<userData>/remote/`. `confine/records.ts` fences this name. */
export const ACCESS_KEYS_FILE = 'access-keys.json'

/**
 * What every key starts with.
 *
 * A fixed prefix so a person — or a secret scanner in somebody's repository —
 * can tell what a leaked string is and where to revoke it. Not the product's
 * name: that lives in `brand.ts` alone, and "access key" is what the settings
 * page calls these.
 */
export const KEY_PREFIX = 'ak_'

/** Random bytes behind the prefix. 256 bits: nothing anybody enumerates. */
const KEY_BYTES = 32

/**
 * Most keys one machine keeps.
 *
 * A list a person scans and revokes from, not a database. Fifty is far more AI
 * apps than anybody runs, and a cap means a loop that somehow reached the create
 * channel would stop at a list someone can still read.
 */
export const MAX_KEYS = 50

/** Longest name. It is a label in a list and in a log line. */
export const MAX_KEY_NAME = 60

/** Most folders one key may be limited to. */
export const MAX_KEY_FOLDERS = 20

/**
 * How often "last used" reaches the disk.
 *
 * Every tool call updates it in memory; writing the file on every call would be
 * a disk write per `sessions.list`, which a chatty AI app makes several times a
 * minute. A minute's precision is plenty for a column that says "3 minutes ago",
 * and a change of *which app* used the key is written at once.
 */
const USE_FLUSH_MS = 60_000

/** Longest "which app" label kept. It comes from the far side, so it is capped. */
const MAX_APP_LABEL = 80

/* ------------------------------------------------------------------ types -- */

export type AccessLevel = 'look' | 'work' | 'full'

export const ACCESS_LEVELS: readonly AccessLevel[] = ['look', 'work', 'full']

/** How the last call arrived: this Mac's own loopback, or the internet via the relay. */
export type AccessVia = 'this-mac' | 'internet'

/** One key as it is kept. `hash` never leaves this module. */
interface StoredKey {
  id: string
  name: string
  level: AccessLevel
  /**
   * Put alter-tier calls to the owner before they run. Default on.
   *
   * Off is a standing pre-authorisation, and `consent.ts` set the terms for
   * one before it existed: scoped (one key), decided while composing rather
   * than while being interrupted (here, in Settings), revocable in one press,
   * and every use writing a row that names the key it spent — so "allowed
   * without asking" never reads the same as "allowed by the person".
   */
  askFirst: boolean
  /** Folders sessions may be started in, or null for every folder the app has open. */
  folders: string[] | null
  hash: string
  createdAt: number
  lastUsedAt: number | null
  lastApp: string | null
  lastVia: AccessVia | null
  /**
   * How this app is told about its sessions. See `notify-hub.ts`.
   *
   * `wait` (the default) keeps its notifications for `notifications.wait` and
   * `notifications.list`; `webhook` also posts each one to `url`, signed with
   * `secret`; `off` keeps nothing. The secret is kept here in the clear because
   * it *signs* — a hash cannot — and this file is 0600 and fenced from the
   * copilot's own shell, like the hashes beside it.
   */
  notify: StoredNotify
}

interface StoredNotify {
  mode: NotifyMode
  url: string | null
  secret: string | null
}

export type NotifyMode = 'off' | 'wait' | 'webhook'

export const NOTIFY_MODES: readonly NotifyMode[] = ['off', 'wait', 'webhook']

/** One key as anything outside this module may see it. No hash, no secret. */
export interface AccessKeyView {
  id: string
  name: string
  level: AccessLevel
  askFirst: boolean
  folders: string[] | null
  createdAt: number
  lastUsedAt: number | null
  lastApp: string | null
  lastVia: AccessVia | null
  /** How the app is told about its sessions. The webhook secret is never in a view — only whether there is one. */
  notify: { mode: NotifyMode; url: string | null; hasSecret: boolean }
}

interface StoredFile {
  v: 1
  /** Whether keys work from the internet, through the relay. Default off. */
  internet: boolean
  /**
   * The loopback port the tools were last served on.
   *
   * Remembered so a local app's configuration keeps working after a restart.
   * See `server.ts`'s preferred-port fallback for what happens when somebody
   * else has taken it.
   */
  port: number | null
  keys: StoredKey[]
}

export class KeyRefused extends Error {}

export interface AccessKeysOptions {
  /** `<userData>/remote`. Created 0700 on first write. */
  dir: string
  now?: () => number
}

/* --------------------------------------------------------------- helpers -- */

/** Which tiers a level holds. The one place a level is turned into power. */
export function tiersFor(level: AccessLevel): TierGrant {
  switch (level) {
    case 'look':
      return Object.freeze({ read: true, act: false, alter: false })
    case 'work':
      return Object.freeze({ read: true, act: true, alter: false })
    case 'full':
      return ALL_TIERS
  }
}

function isLevel(value: unknown): value is AccessLevel {
  return value === 'look' || value === 'work' || value === 'full'
}

function hashOf(key: string): Buffer {
  return createHash('sha256').update(key, 'utf8').digest()
}

/**
 * A name as a person typed it, tidied, or a refusal saying why not.
 *
 * Control characters are stripped because the name is printed into the action
 * log's one-line `detail`, and a newline there would forge a second row.
 */
export function cleanName(raw: unknown): string {
  if (typeof raw !== 'string') throw new KeyRefused('Give the key a name, such as the app it is for.')
  // eslint-disable-next-line no-control-regex
  const name = raw.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim()
  if (name === '') throw new KeyRefused('Give the key a name, such as the app it is for.')
  if (name.length > MAX_KEY_NAME) throw new KeyRefused(`Keep the name under ${MAX_KEY_NAME} characters.`)
  return name
}

function cleanFolders(raw: unknown): string[] | null {
  if (raw === null || raw === undefined) return null
  if (!Array.isArray(raw)) throw new KeyRefused('Folders must be a list.')
  const folders = [...new Set(raw.filter((entry): entry is string => typeof entry === 'string' && isAbsolute(entry)))]
  if (folders.length === 0) return null
  if (folders.length > MAX_KEY_FOLDERS) throw new KeyRefused(`A key can be limited to at most ${MAX_KEY_FOLDERS} folders.`)
  return folders
}

/** An app's own name for itself, made safe to keep and print. Null when there is nothing usable. */
export function cleanAppLabel(raw: unknown): string | null {
  if (typeof raw !== 'string') return null
  // eslint-disable-next-line no-control-regex
  const label = raw.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim()
  if (label === '') return null
  return label.length > MAX_APP_LABEL ? `${label.slice(0, MAX_APP_LABEL - 1)}…` : label
}

function view(key: StoredKey): AccessKeyView {
  return {
    id: key.id,
    name: key.name,
    level: key.level,
    askFirst: key.askFirst,
    folders: key.folders === null ? null : [...key.folders],
    createdAt: key.createdAt,
    lastUsedAt: key.lastUsedAt,
    lastApp: key.lastApp,
    lastVia: key.lastVia,
    notify: { mode: key.notify.mode, url: key.notify.url, hasSecret: key.notify.secret !== null },
  }
}

function asNotify(raw: unknown): StoredNotify {
  const r = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
  const mode: NotifyMode = r.mode === 'off' || r.mode === 'webhook' ? r.mode : 'wait'
  const url = typeof r.url === 'string' && webhookUrlProblem(r.url) === null ? r.url : null
  const secret = typeof r.secret === 'string' && r.secret.startsWith(SECRET_PREFIX) ? r.secret : null
  // A webhook with no usable address or secret is waiting, not posting into nothing.
  return { mode: mode === 'webhook' && (url === null || secret === null) ? 'wait' : mode, url, secret }
}

function asStoredKey(raw: unknown): StoredKey | null {
  if (typeof raw !== 'object' || raw === null) return null
  const r = raw as Record<string, unknown>
  if (typeof r.id !== 'string' || r.id === '') return null
  if (typeof r.hash !== 'string' || !/^[0-9a-f]{64}$/.test(r.hash)) return null
  if (!isLevel(r.level)) return null
  let name: string
  try {
    name = cleanName(r.name)
  } catch {
    return null
  }
  let folders: string[] | null
  try {
    folders = cleanFolders(r.folders)
  } catch {
    // A list that no longer parses is narrowed to nothing rather than widened
    // to everything: drop the key.
    return null
  }
  return {
    id: r.id,
    name,
    level: r.level,
    // Anything but a literal false is "ask". The default is the narrow value.
    askFirst: r.askFirst !== false,
    folders,
    hash: r.hash,
    createdAt: typeof r.createdAt === 'number' ? r.createdAt : 0,
    lastUsedAt: typeof r.lastUsedAt === 'number' ? r.lastUsedAt : null,
    lastApp: cleanAppLabel(r.lastApp),
    lastVia: r.lastVia === 'this-mac' || r.lastVia === 'internet' ? r.lastVia : null,
    notify: asNotify(r.notify),
  }
}

/* ------------------------------------------------------------------ store -- */

export class AccessKeys {
  private readonly file: string
  private readonly now: () => number
  private state: StoredFile = { v: 1, internet: false, port: null, keys: [] }
  private readonly listeners = new Set<() => void>()
  private lastFlush = 0
  private dirty = false
  /** Set when the file on disk could not be read. Said on the settings page. */
  private problem: string | null = null

  constructor(private readonly options: AccessKeysOptions) {
    this.file = join(options.dir, ACCESS_KEYS_FILE)
    this.now = options.now ?? Date.now
    this.load()
  }

  /** Why the stored keys could not be read, or null. */
  loadProblem(): string | null {
    return this.problem
  }

  /** Every key, newest first. */
  list(): AccessKeyView[] {
    return [...this.state.keys].sort((a, b) => b.createdAt - a.createdAt).map(view)
  }

  /** One key by id, or null for a key that does not exist — or has been revoked. */
  get(id: string): AccessKeyView | null {
    const found = this.state.keys.find((key) => key.id === id)
    return found ? view(found) : null
  }

  /**
   * Make a key. The secret is in the return value and nowhere else, ever.
   *
   * The caller shows it once and forgets it. There is no method that returns it
   * again, deliberately: a key that can be re-displayed is a key whose secret is
   * sitting somewhere waiting to be re-displayed.
   */
  create(input: { name: unknown; level: unknown; askFirst?: unknown; folders?: unknown }): {
    key: string
    view: AccessKeyView
  } {
    if (this.state.keys.length >= MAX_KEYS) {
      throw new KeyRefused(`There are already ${MAX_KEYS} keys. Revoke one you no longer use first.`)
    }
    const name = cleanName(input.name)
    if (!isLevel(input.level)) throw new KeyRefused('Choose what the app may do: look, work, or full control.')
    const secret = `${KEY_PREFIX}${randomBytes(KEY_BYTES).toString('base64url')}`
    const stored: StoredKey = {
      id: randomUUID(),
      name,
      level: input.level,
      askFirst: input.askFirst !== false,
      folders: cleanFolders(input.folders),
      hash: hashOf(secret).toString('hex'),
      createdAt: this.now(),
      lastUsedAt: null,
      lastApp: null,
      lastVia: null,
      notify: { mode: 'wait', url: null, secret: null },
    }
    this.state = { ...this.state, keys: [...this.state.keys, stored] }
    this.save()
    return { key: secret, view: view(stored) }
  }

  rename(id: string, name: unknown): AccessKeyView {
    return this.change(id, (key) => ({ ...key, name: cleanName(name) }))
  }

  setLevel(id: string, level: unknown): AccessKeyView {
    if (!isLevel(level)) throw new KeyRefused('Choose what the app may do: look, work, or full control.')
    return this.change(id, (key) => ({ ...key, level }))
  }

  setAskFirst(id: string, askFirst: unknown): AccessKeyView {
    // Only a literal `false` turns asking off. A wiring mistake that sent
    // `undefined` must leave the narrow setting in place.
    return this.change(id, (key) => ({ ...key, askFirst: askFirst !== false }))
  }

  /**
   * How this app is told about its sessions.
   *
   * Switching to `webhook` needs an address this Mac may post to
   * (`webhookUrlProblem`) and mints the signing secret the first time; the
   * secret is in the return value then and never again, like the key itself.
   * Switching away keeps the address and secret, so switching back needs no
   * new setup on the receiver.
   */
  setNotify(id: string, input: { mode: unknown; url?: unknown }): { view: AccessKeyView; secret: string | null } {
    if (input.mode !== 'off' && input.mode !== 'wait' && input.mode !== 'webhook') {
      throw new KeyRefused('Choose how this app hears about its sessions: off, waiting, or a webhook.')
    }
    const mode = input.mode
    let minted: string | null = null
    const view = this.change(id, (key) => {
      if (mode !== 'webhook') return { ...key, notify: { ...key.notify, mode } }
      const url = typeof input.url === 'string' && input.url.trim() !== '' ? input.url.trim() : key.notify.url
      if (url === null) throw new KeyRefused('Give the web address to post notifications to.')
      const problem = webhookUrlProblem(url)
      if (problem !== null) throw new KeyRefused(problem)
      let secret = key.notify.secret
      if (secret === null) {
        secret = newWebhookSecret()
        minted = secret
      }
      return { ...key, notify: { mode, url, secret } }
    })
    return { view, secret: minted }
  }

  /** A new signing secret for the key's webhook. The old one stops verifying at once. Shown once. */
  rotateWebhookSecret(id: string): { view: AccessKeyView; secret: string } {
    const secret = newWebhookSecret()
    const view = this.change(id, (key) => ({ ...key, notify: { ...key.notify, secret } }))
    return { view, secret }
  }

  /**
   * What the notification queue needs to deliver for a key, secret included —
   * or null when the key no longer exists. For `notify-hub.ts` and nothing
   * else: no view and no channel ever carries the secret.
   */
  notifySettings(id: string): { mode: NotifyMode; url: string | null; secret: string | null } | null {
    const key = this.state.keys.find((entry) => entry.id === id)
    return key ? { ...key.notify } : null
  }

  setFolders(id: string, folders: unknown): AccessKeyView {
    return this.change(id, (key) => ({ ...key, folders: cleanFolders(folders) }))
  }

  /** Take a key back. Returns whether there was one. Lands on the very next call. */
  revoke(id: string): boolean {
    const before = this.state.keys.length
    this.state = { ...this.state, keys: this.state.keys.filter((key) => key.id !== id) }
    if (this.state.keys.length === before) return false
    this.save()
    return true
  }

  internet(): boolean {
    return this.state.internet
  }

  setInternet(on: unknown): boolean {
    this.state = { ...this.state, internet: on === true }
    this.save()
    return this.state.internet
  }

  port(): number | null {
    return this.state.port
  }

  /** Remember the port the tools are served on. Written only when it changed. */
  setPort(port: number): void {
    if (!Number.isInteger(port) || port <= 0 || port > 65535 || port === this.state.port) return
    this.state = { ...this.state, port }
    this.save(false)
  }

  /**
   * Which key this is, or null.
   *
   * Every stored hash is compared, whichever matches — see the header. Hashes
   * are all 32 bytes, so there is no length to leak.
   */
  match(offered: string | null | undefined): AccessKeyView | null {
    if (typeof offered !== 'string' || !offered.startsWith(KEY_PREFIX)) return null
    const digest = hashOf(offered)
    let found: StoredKey | null = null
    for (const key of this.state.keys) {
      const stored = Buffer.from(key.hash, 'hex')
      if (timingSafeEqual(digest, stored) && found === null) found = key
    }
    return found ? view(found) : null
  }

  /**
   * A call just arrived on this key. Kept in memory, flushed at most once a
   * minute — and at once when the app on the other end is a different one.
   */
  noteUsed(id: string, via: AccessVia, app: string | null): void {
    const at = this.now()
    const label = cleanAppLabel(app)
    let appChanged = false
    this.state = {
      ...this.state,
      keys: this.state.keys.map((key) => {
        if (key.id !== id) return key
        appChanged = (label !== null && label !== key.lastApp) || via !== key.lastVia
        return { ...key, lastUsedAt: at, lastVia: via, lastApp: label ?? key.lastApp }
      }),
    }
    this.dirty = true
    if (!appChanged && at - this.lastFlush < USE_FLUSH_MS) return
    try {
      this.save()
    } catch (error) {
      // "Last used" is a column, not a permission. A disk that refuses it must
      // not turn into an AI app's tool call failing — the call is on its way
      // through the door already, and the next flush tries again.
      this.dirty = true
      console.error('[access-keys] could not save when a key was last used:', error)
    }
  }

  /** Write whatever "last used" is still held only in memory. Called at quit. */
  flush(): void {
    if (this.dirty) this.save(false)
  }

  /** Told after every change a person made. Not told for "last used". */
  onChange(listener: () => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /* ------------------------------------------------------------ internals */

  private change(id: string, edit: (key: StoredKey) => StoredKey): AccessKeyView {
    const found = this.state.keys.find((key) => key.id === id)
    if (!found) throw new KeyRefused('That key no longer exists. It may have been revoked.')
    const next = edit(found)
    this.state = { ...this.state, keys: this.state.keys.map((key) => (key.id === id ? next : key)) }
    this.save()
    return view(next)
  }

  /**
   * Write the file, then tell whoever is listening.
   *
   * Throws when the write fails, and the in-memory state has already moved —
   * that is the direction `secret-file.ts` chooses and it is right here too for
   * revocation, which must not wait on a disk to take effect. The settings page
   * reports the throw, so a person knows the change may not survive a restart.
   */
  private save(announce = true): void {
    this.lastFlush = this.now()
    this.dirty = false
    writeSecretFile(this.options.dir, this.file, `${JSON.stringify(this.state, null, 2)}\n`)
    if (!announce) return
    for (const listener of [...this.listeners]) {
      try {
        listener()
      } catch (error) {
        console.error('[access-keys] a listener threw:', error)
      }
    }
  }

  private load(): void {
    if (!existsSync(this.file)) return
    let parsed: unknown
    try {
      parsed = JSON.parse(readFileSync(this.file, 'utf8'))
    } catch (error) {
      this.setAside(error)
      return
    }
    if (typeof parsed !== 'object' || parsed === null || (parsed as { v?: unknown }).v !== 1) {
      this.setAside(new Error('not a version-1 key file'))
      return
    }
    const record = parsed as Record<string, unknown>
    const keys = Array.isArray(record.keys)
      ? record.keys.map(asStoredKey).filter((key): key is StoredKey => key !== null)
      : []
    const port = typeof record.port === 'number' && Number.isInteger(record.port) ? record.port : null
    this.state = {
      v: 1,
      // Only a literal true. A file that says anything else keeps the door shut.
      internet: record.internet === true,
      port,
      keys: keys.slice(0, MAX_KEYS),
    }
  }

  private setAside(error: unknown): void {
    this.problem =
      'The saved access keys could not be read, so none of them work. Make new keys for the apps that need one.'
    console.error('[access-keys] could not read the key file; starting with none:', error)
    try {
      copyFileSync(this.file, `${this.file}.unreadable-${this.now()}`)
    } catch {
      /* best effort: the point is that nothing in it is honoured */
    }
  }
}
