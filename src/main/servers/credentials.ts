/**
 * The passwords and keys that sign in to servers, and the four rules about them.
 *
 * ## Where a secret is, at every moment
 *
 * Three places, and the window is not one of them:
 *
 *  1. **On disk**, inside a `safeStorage` blob — Keychain on macOS, DPAPI on
 *     Windows, the session keyring on Linux — written through `writeSecretFile`
 *     so it is atomic, 0600 on POSIX, and restricted by ACL on Windows. Where
 *     no secure store is available this **refuses to save** rather than falling
 *     back to a plain file, exactly as `voice.ts` and `browser-passwords.ts`
 *     do, and for the same reason: a cleartext password in a user-data
 *     directory is a real cost to a real person, and "we saved it anyway" is
 *     not a decision to make on somebody's behalf and certainly not one to make
 *     silently.
 *  2. **In this process's memory**, decrypted, while the app runs.
 *  3. **On the wire to the server it belongs to**, inside the encrypted
 *     transport, which is the entire purpose.
 *
 * The React tree never holds one. Nothing this module exports returns a secret
 * to anything that could cross the preload bridge — {@link ServerCredentials.read}
 * is the only reader and its result goes straight into a connection. The rule
 * is already written down next door in `renderer/machines/types.ts` about the
 * paired-device credential: *"a screen that held one would be a screenshot away
 * from publishing it."*
 *
 * ## Why base64 and not the raw blob
 *
 * `safeStorage.encryptString` returns a `Buffer`; `writeSecretFile` takes a
 * string. The obvious shortcut is to skip `writeSecretFile` and use
 * `writeFileSync` with the buffer, which is what `browser-passwords.ts` does —
 * and that file predates the argument in `remote/secret-file.ts`, which is
 * that a plain write is not atomic, is not fsynced before its name moves, and
 * on Windows leaves the file readable by every other account on the PC because
 * NTFS ignores the mode. Encoding the blob as base64 costs a third more disk
 * and buys all three. That is the right trade for a file whose loss of
 * confidentiality is somebody else's production server.
 *
 * ## "Don't save this"
 *
 * A pasted key or a typed password can be held for the life of the process and
 * never written down. Somebody trying this out on a borrowed machine should not
 * have to trust us to be careful, and the honest way to earn that is to make
 * the not-saving real rather than a checkbox that writes the file anyway and
 * deletes it later. A session-held credential lives in a `Map` that dies with
 * the process; there is deliberately no code path that promotes one to disk
 * without the person asking again.
 *
 * ## What a key failure is allowed to say
 *
 * Three failures, three different sentences, and they are different because the
 * *action* is different: paste the whole file, type the passphrase, or type a
 * different passphrase. The library distinguishes them and it would be a
 * needless cruelty not to pass that on. See {@link keyProblem} — the strings it
 * matches were captured from the library running against real keys, not guessed.
 */

import { safeStorage } from 'electron'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { utils as sshUtils } from 'ssh2'
import { protectSecretFile, writeSecretFile } from '../remote/secret-file'
import type { CredentialKind } from './store'

export const CREDENTIALS_FILE = 'server-credentials.bin'

/** Bigger than any real key, small enough that a wrong file is refused early. */
const MAX_SECRET_LENGTH = 64 * 1024

/** A whole file of encrypted credentials; anything larger is not ours to parse. */
const MAX_FILE_BYTES = 4 * 1024 * 1024

/**
 * How somebody signs in to one server.
 *
 * A discriminated union rather than three optional fields, so that "a key with
 * a password as well" is not a shape this type can even express. It is not a
 * thing the sign-in flow offers and a type that allowed it would eventually be
 * handed one.
 */
export type ServerCredential =
  | { kind: 'password'; password: string }
  | { kind: 'key'; privateKey: string; passphrase: string | null }

export interface SaveOutcome {
  ok: boolean
  /** Shown to a person verbatim, so it says what to do rather than what broke. */
  message: string
}

/**
 * The sentence shown wherever saving is impossible.
 *
 * One string, exported, because it has to be identical in the sign-in flow and
 * on the server's own page — a person told two different things about the same
 * machine will reasonably conclude one of them is a bug.
 */
export const NO_SECURE_STORE =
  'This computer has no secure store available, so a sign-in cannot be saved here. On Linux ' +
  'that usually means no keyring is running; start one and try again.'

/* ------------------------------------------------------------ key checks -- */

/**
 * What is wrong with this key, in the words of the thing to do about it.
 *
 * Returns `null` when the key parses. The three matched strings are the
 * library's own, captured running it against a real encrypted ed25519 key:
 *
 *   - *"Encrypted private OpenSSH key detected, but no passphrase given"*
 *   - *"integrity check failed -- bad passphrase?"*
 *   - *"Unsupported key format"*
 *
 * Matching on a message is ordinarily a bad idea and it is the only option
 * here: the library returns a plain `Error` with no code. The mitigation is
 * that the fallback is a *usable* sentence rather than a wrong one, so a
 * library that rewords itself degrades to "we could not read that" instead of
 * to a confident lie about which half was wrong.
 */
export function keyProblem(privateKey: string, passphrase: string | null): string | null {
  if (privateKey.trim() === '') return 'Paste the key file, including its first and last lines.'
  if (privateKey.length > MAX_SECRET_LENGTH) return 'That is much too long to be a key file.'
  const parsed = sshUtils.parseKey(privateKey, passphrase ?? undefined)
  if (!(parsed instanceof Error)) return null
  const said = parsed.message.toLowerCase()
  if (said.includes('no passphrase given')) {
    return 'That key is locked. What is its passphrase?'
  }
  if (said.includes('bad passphrase') || said.includes('integrity check failed')) {
    return 'That passphrase does not open the key.'
  }
  if (said.includes('unsupported key format') || said.includes('cannot parse')) {
    return 'That does not look like a key. Paste the whole file, including its first and last lines.'
  }
  return 'That key could not be read.'
}

/**
 * True when the only thing missing is the passphrase.
 *
 * The sign-in step uses this to decide whether to *reveal a passphrase field*
 * rather than to refuse, which is the difference between a flow that works and
 * one where somebody with a perfectly good locked key concludes the app does
 * not support keys.
 */
export function keyNeedsPassphrase(privateKey: string): boolean {
  const parsed = sshUtils.parseKey(privateKey)
  return parsed instanceof Error && parsed.message.toLowerCase().includes('no passphrase given')
}

/* ------------------------------------------------- what the window typed -- */

/**
 * The sign-in half of the "add a server" form, as the window sends it.
 *
 * Named here rather than in `ipc.ts` for a reason that is enforced by a test in
 * this folder: **two files may name a secret and the rest of the feature may
 * not.** `credentials-never-cross.test.ts` scans every identifier in this
 * directory for `password`, `privateKey` and `passphrase`, and the whole point
 * of that scan is that the leak which actually happens is never the obvious
 * one — a shape grows a field, and it type-checks perfectly.
 *
 * So the conversion from *what somebody typed* into a {@link ServerCredential}
 * lives beside the store that keeps them, and the registration hands the form
 * straight through without ever naming what is inside it.
 */
export interface SignInDraft {
  method: 'password' | 'key'
  password?: string
  key?: string
  passphrase?: string
}

/** Why a sign-in could not be made from what was typed. */
export type SignInProblem = 'needs-passphrase' | 'bad-passphrase' | 'key-unreadable' | 'nothing-typed'

/**
 * Turn what the window typed into a credential, or into the reason it is not
 * one yet.
 *
 * The key is parsed **before** anything is stored or dialled, because its three
 * failures are the ones with a useful next step and none of them needs a
 * network: a locked key wants a passphrase field to appear, a wrong one wants
 * that field cleared, and something that is not a key at all wants the whole
 * file pasted rather than one line of it. Sending all three to the server and
 * waiting for a handshake to fail would give the same person the same generic
 * refusal three times.
 */
export function credentialFromDraft(
  draft: SignInDraft,
): { ok: true; credential: ServerCredential } | { ok: false; problem: SignInProblem; sentence: string } {
  if (draft.method === 'password') {
    const typed = draft.password ?? ''
    if (typed === '') {
      return { ok: false, problem: 'nothing-typed', sentence: 'Type the password for that server.' }
    }
    return { ok: true, credential: { kind: 'password', password: typed } }
  }
  const pasted = draft.key ?? ''
  const opener = draft.passphrase ?? null
  const problem = keyProblem(pasted, opener)
  if (problem === null) {
    return { ok: true, credential: { kind: 'key', privateKey: pasted, passphrase: opener } }
  }
  return {
    ok: false,
    problem: keyNeedsPassphrase(pasted)
      ? opener === null
        ? 'needs-passphrase'
        : 'bad-passphrase'
      : 'key-unreadable',
    sentence: problem,
  }
}

/* ------------------------------------------------------------- the store -- */

function readStored(raw: unknown): Map<string, ServerCredential> {
  const out = new Map<string, ServerCredential>()
  if (typeof raw !== 'object' || raw === null) return out
  const value = raw as Record<string, unknown>
  const entries = Array.isArray(value.entries) ? value.entries : []
  for (const entry of entries) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    const serverId = typeof record.serverId === 'string' ? record.serverId : ''
    if (serverId === '') continue
    if (record.kind === 'password' && typeof record.password === 'string') {
      out.set(serverId, { kind: 'password', password: record.password })
      continue
    }
    if (record.kind === 'key' && typeof record.privateKey === 'string') {
      out.set(serverId, {
        kind: 'key',
        privateKey: record.privateKey,
        passphrase: typeof record.passphrase === 'string' ? record.passphrase : null,
      })
    }
  }
  return out
}

export class ServerCredentials {
  private readonly path: string
  private saved: Map<string, ServerCredential> | null = null

  /**
   * Credentials the person asked us not to write down.
   *
   * Separate map, checked first, never persisted, gone when the process ends.
   * Keeping it separate from `saved` rather than tagging entries means there is
   * no field anybody can flip to make a session credential permanent.
   */
  private readonly held = new Map<string, ServerCredential>()

  constructor(private readonly storageDir: string) {
    this.path = join(storageDir, CREDENTIALS_FILE)
  }

  available(): boolean {
    return safeStorage.isEncryptionAvailable()
  }

  private load(): Map<string, ServerCredential> {
    if (this.saved !== null) return this.saved
    if (!existsSync(this.path)) {
      this.saved = new Map()
      return this.saved
    }
    protectSecretFile(this.storageDir, this.path)
    try {
      if (statSync(this.path).size > MAX_FILE_BYTES) {
        this.saved = new Map()
        return this.saved
      }
      const blob = Buffer.from(readFileSync(this.path, 'utf8'), 'base64')
      this.saved = readStored(JSON.parse(safeStorage.decryptString(blob)) as unknown)
    } catch {
      // Encrypted by a different OS user, a different machine, or an older
      // format. Unreadable is the same as absent from here — the alternative is
      // a panel that will not open because a file it cannot read exists. The
      // person is asked to sign in again, which they can do.
      this.saved = new Map()
    }
    return this.saved
  }

  private persist(next: Map<string, ServerCredential>): SaveOutcome {
    if (!safeStorage.isEncryptionAvailable()) return { ok: false, message: NO_SECURE_STORE }
    const entries = [...next.entries()].map(([serverId, credential]) => ({
      serverId,
      ...credential,
    }))
    const blob = safeStorage.encryptString(JSON.stringify({ version: 1, entries }))
    writeSecretFile(this.storageDir, this.path, blob.toString('base64'))
    this.saved = next
    return { ok: true, message: 'Saved.' }
  }

  /** Write this sign-in down, encrypted, for next time. */
  save(serverId: string, credential: ServerCredential): SaveOutcome {
    const next = new Map(this.load())
    next.set(serverId, credential)
    // A saved credential replaces a held one, so that the two can never
    // disagree about which is current.
    this.held.delete(serverId)
    return this.persist(next)
  }

  /**
   * Use this sign-in until the app closes, and never write it down.
   *
   * Returns nothing to check because it cannot fail — that is the point of it.
   * It is the answer for a borrowed computer, and it is also the honest answer
   * on a machine with no secure store, where {@link save} refuses.
   */
  holdForSession(serverId: string, credential: ServerCredential): void {
    this.held.set(serverId, credential)
  }

  /**
   * The credential for one server, or null.
   *
   * **Main process only.** Nothing that can reach the preload bridge may call
   * this. The one caller is `connection.ts`, on its way into a handshake.
   */
  read(serverId: string): ServerCredential | null {
    return this.held.get(serverId) ?? this.load().get(serverId) ?? null
  }

  /** Which kind is stored, without any of it. Safe to send to the window. */
  kindOf(serverId: string): CredentialKind {
    return this.read(serverId)?.kind ?? 'none'
  }

  /** True when this sign-in only lives in memory and will be gone at the next launch. */
  isHeldForSessionOnly(serverId: string): boolean {
    return this.held.has(serverId)
  }

  forget(serverId: string): SaveOutcome {
    this.held.delete(serverId)
    const current = this.load()
    if (!current.has(serverId)) return { ok: true, message: 'Nothing was stored.' }
    const next = new Map(current)
    next.delete(serverId)
    return this.persist(next)
  }
}
