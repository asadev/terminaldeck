/**
 * The list of servers somebody has added, and nothing secret.
 *
 * ## The split, and why it is a hard line
 *
 * A server is two records in two files. This one holds what a person can see on
 * a screen — a name, an address, a username, when it was added — and
 * `credentials.ts` holds the password or key. They are separate because the
 * first crosses the bridge to the window and the second never does, and a
 * single record would mean every list call carried a secret through a place it
 * has no business being. `remote/machines/store.ts` states the same rule for
 * paired devices: *"a bridge that carries a bearer secret is one screenshot
 * away from publishing it."*
 *
 * What this file *does* hold and is easy to underrate is the **host key
 * fingerprint**. It is not a secret — it is public by construction, and the
 * whole point of it is that a person can check it against any other tool — but
 * it is the thing the identity check in `connection.ts` compares against. An
 * account that can rewrite this file can silently retarget somebody's server to
 * a machine that is not theirs, and the check would still pass. So it is
 * written through `writeSecretFile`, which on POSIX means 0600 and on Windows
 * means an ACL granting this account only. `folder-grants.json` is written the
 * same way for the same class of reason, and that file's header says so.
 *
 * ## No Electron
 *
 * The storage directory is a constructor argument, so this runs against a
 * temporary directory under vitest with no app object anywhere near it. Same
 * rule as `device-auth.ts` and `remote/machines/store.ts`.
 */

import { randomUUID } from 'node:crypto'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { protectSecretFile, writeSecretFile } from '../remote/secret-file'

export const SERVERS_FILE = 'servers.json'

/** A real file is a few hundred bytes per server; anything larger is not ours to parse. */
const MAX_FILE_BYTES = 256 * 1024

/** Names are shown in this window and go into logs, so they are bounded. */
const MAX_NAME_LENGTH = 64

/**
 * A hostname's maximum length. An address longer than this cannot resolve, so
 * accepting it would only move the failure somewhere with a worse message.
 */
const MAX_ADDRESS_LENGTH = 255

const MAX_USERNAME_LENGTH = 64

/** Refuses to grow without bound if adding ever runs in a loop. */
const MAX_SERVERS = 64

/** The port a server is reached on when nobody says otherwise. */
export const DEFAULT_PORT = 22

/**
 * Which kind of sign-in is stored for a server, without any of it.
 *
 * This is the only thing about a credential that crosses the bridge, and it is
 * here rather than in `credentials.ts` because the window genuinely needs it: a
 * server signed in with a key shows no "change the password" row, and a server
 * with nothing stored has to ask before it can connect. Note that it says
 * *which kind*, never *what*.
 */
export type CredentialKind = 'password' | 'key' | 'none'

/**
 * The identity a server answered with the first time, and every time since.
 *
 * `fingerprint` is the `SHA256:…` form, which is byte-identical to what
 * `ssh-keyscan` and every other tool prints — verified against both on the test
 * box. That equality is the entire value of showing it: a person asked whether
 * they recognise a fingerprint can go and check it somewhere else.
 */
export interface HostKeyRecord {
  /** The key's own algorithm name, as the server announced it. */
  algorithm: string
  /** `SHA256:` followed by unpadded base64, exactly as other tools print it. */
  fingerprint: string
  firstSeenAt: number
}

/** One server, as the window is allowed to see it. */
export interface StoredServer {
  id: string
  /** The person's own name for it. Never an internal id. */
  name: string
  address: string
  port: number
  username: string
  credential: CredentialKind
  hostKey: HostKeyRecord | null
  addedAt: number
  lastConnectedAt: number | null
}

/** What is needed to add one. Everything else is filled in here. */
export interface NewServer {
  name: string
  address: string
  port?: number
  username: string
}

/* --------------------------------------------------------- what is legal -- */

function clean(raw: unknown, max: number): string {
  if (typeof raw !== 'string') return ''
  // Control characters cannot be typed into a field, so their presence means
  // something other than a person produced this — and a newline inside a stored
  // name would break every one-line row that shows it.
  const flat = raw.replace(/[\u0000-\u001f\u007f]/g, '').trim()
  return flat.length > max ? flat.slice(0, max) : flat
}

/**
 * Is this something we can dial?
 *
 * Deliberately permissive about *shape* and strict about *characters*. A
 * hostname, an IPv4 address, an IPv6 literal and a `.local` name are all
 * legitimate and look nothing like each other, so pattern-matching the shape
 * would refuse somebody's real server. What is refused is anything that could
 * not be an address at all: whitespace, control characters, and the punctuation
 * that means this is a web address or a `user@host` string rather than a host.
 * That last one is worth catching here rather than later, because a person
 * pasting a whole connection line into the address box is the most likely
 * mistake there is, and this sentence is better than a name-resolution failure
 * twenty seconds afterwards.
 */
export function addressProblem(raw: string): string | null {
  const value = raw.trim()
  if (value === '') return 'An address is needed — the name or number this server answers on.'
  if (value.length > MAX_ADDRESS_LENGTH) return 'That address is too long to be a real one.'
  if (/\s/.test(value)) return 'An address cannot contain a space.'
  if (value.includes('@')) {
    return 'Put only the address here — the part after the @ — and the username in its own box.'
  }
  if (value.includes('/')) return 'Put only the address here, with no web address around it.'
  return null
}

/** The address as it will be dialled: an IPv6 literal loses its brackets. */
export function normaliseAddress(raw: string): string {
  const value = raw.trim()
  return value.startsWith('[') && value.endsWith(']') ? value.slice(1, -1) : value
}

function validPort(raw: unknown): number {
  if (typeof raw !== 'number' || !Number.isInteger(raw) || raw < 1 || raw > 65535) {
    return DEFAULT_PORT
  }
  return raw
}

function readHostKey(raw: unknown): HostKeyRecord | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const fingerprint = clean(record.fingerprint, 128)
  if (!fingerprint.startsWith('SHA256:')) return null
  return {
    algorithm: clean(record.algorithm, 64),
    fingerprint,
    firstSeenAt: typeof record.firstSeenAt === 'number' ? record.firstSeenAt : 0,
  }
}

/**
 * Read a stored file into a list, dropping anything that is not a server.
 *
 * Defensive even though this app wrote the file, for the reason
 * `browser-passwords.ts` gives about its own reader: a row with no address
 * would be a card that cannot connect and cannot be repaired, and a row with no
 * id could not be removed.
 */
export function readServers(raw: unknown): StoredServer[] {
  if (typeof raw !== 'object' || raw === null) return []
  const value = raw as Record<string, unknown>
  const list = Array.isArray(value.servers) ? value.servers : []
  const out: StoredServer[] = []
  for (const entry of list) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    const id = clean(record.id, 64)
    const address = normaliseAddress(clean(record.address, MAX_ADDRESS_LENGTH))
    if (id === '' || addressProblem(address) !== null) continue
    const credential = record.credential
    out.push({
      id,
      name: clean(record.name, MAX_NAME_LENGTH) || address,
      address,
      port: validPort(record.port),
      username: clean(record.username, MAX_USERNAME_LENGTH),
      credential: credential === 'password' || credential === 'key' ? credential : 'none',
      hostKey: readHostKey(record.hostKey),
      addedAt: typeof record.addedAt === 'number' ? record.addedAt : 0,
      lastConnectedAt: typeof record.lastConnectedAt === 'number' ? record.lastConnectedAt : null,
    })
    if (out.length >= MAX_SERVERS) break
  }
  return out
}

/* ------------------------------------------------------------- the store -- */

export class ServerStore {
  private readonly path: string
  private cache: StoredServer[] | null = null

  constructor(private readonly storageDir: string) {
    this.path = join(storageDir, SERVERS_FILE)
  }

  private load(): StoredServer[] {
    if (this.cache !== null) return this.cache
    if (!existsSync(this.path)) {
      this.cache = []
      return this.cache
    }
    // Repairs the permissions of a file an older version wrote, on the way to
    // reading it. See `protectSecretFile`'s header for why this does not throw.
    protectSecretFile(this.storageDir, this.path)
    try {
      if (statSync(this.path).size > MAX_FILE_BYTES) {
        this.cache = []
        return this.cache
      }
      this.cache = readServers(JSON.parse(readFileSync(this.path, 'utf8')) as unknown)
    } catch {
      // Unreadable is the same as absent from here. The alternative is a panel
      // that will not open because a file it cannot parse exists.
      this.cache = []
    }
    return this.cache
  }

  private persist(list: StoredServer[]): void {
    writeSecretFile(this.storageDir, this.path, JSON.stringify({ version: 1, servers: list }))
    this.cache = list
  }

  list(): StoredServer[] {
    return this.load().map((server) => ({ ...server }))
  }

  get(id: string): StoredServer | null {
    const found = this.load().find((server) => server.id === id)
    return found === undefined ? null : { ...found }
  }

  /**
   * Add a server, or throw with the sentence explaining why it cannot be.
   *
   * Throws rather than returning a result because every reason is something a
   * person can fix in the box they just typed into, and the sentence is the
   * whole answer.
   */
  add(candidate: NewServer): StoredServer {
    const address = normaliseAddress(clean(candidate.address, MAX_ADDRESS_LENGTH))
    const problem = addressProblem(address)
    if (problem !== null) throw new Error(problem)
    const username = clean(candidate.username, MAX_USERNAME_LENGTH)
    if (username === '') {
      throw new Error('A username is needed — the name you sign in to this server with.')
    }
    const list = this.load()
    if (list.length >= MAX_SERVERS) {
      throw new Error(`This app keeps up to ${MAX_SERVERS} servers. Remove one to add another.`)
    }
    const server: StoredServer = {
      id: randomUUID(),
      name: clean(candidate.name, MAX_NAME_LENGTH) || address,
      address,
      port: validPort(candidate.port ?? DEFAULT_PORT),
      username,
      credential: 'none',
      hostKey: null,
      addedAt: Date.now(),
      lastConnectedAt: null,
    }
    this.persist([...list, server])
    return { ...server }
  }

  rename(id: string, name: unknown): boolean {
    const cleaned = clean(name, MAX_NAME_LENGTH)
    if (cleaned === '') return false
    return this.update(id, (server) => ({ ...server, name: cleaned }))
  }

  /** Record which kind of sign-in is stored, after `credentials.ts` stored it. */
  setCredentialKind(id: string, credential: CredentialKind): boolean {
    return this.update(id, (server) => ({ ...server, credential }))
  }

  /**
   * Record the identity this server answered with — the first time only.
   *
   * Returns false when one is already recorded, and does **not** overwrite it.
   * Overwriting is what a "connect anyway" button does, and there is not one:
   * the value of the check is precisely that it cannot be clicked through.
   * Replacing a recorded identity is {@link forgetHostKey}, which is a
   * deliberate act on the server's own page and says what it means.
   */
  rememberHostKey(id: string, algorithm: string, fingerprint: string): boolean {
    const server = this.get(id)
    if (server === null || server.hostKey !== null) return false
    return this.update(id, (existing) => ({
      ...existing,
      hostKey: {
        algorithm: clean(algorithm, 64),
        fingerprint: clean(fingerprint, 128),
        firstSeenAt: Date.now(),
      },
    }))
  }

  forgetHostKey(id: string): boolean {
    return this.update(id, (server) => ({ ...server, hostKey: null }))
  }

  markConnected(id: string): boolean {
    return this.update(id, (server) => ({ ...server, lastConnectedAt: Date.now() }))
  }

  forget(id: string): boolean {
    const list = this.load()
    const next = list.filter((server) => server.id !== id)
    if (next.length === list.length) return false
    this.persist(next)
    return true
  }

  private update(id: string, change: (server: StoredServer) => StoredServer): boolean {
    const list = this.load()
    const index = list.findIndex((server) => server.id === id)
    if (index === -1) return false
    const next = [...list]
    next[index] = change(list[index])
    this.persist(next)
    return true
  }
}
