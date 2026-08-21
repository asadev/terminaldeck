import { createHash } from 'node:crypto'
import { existsSync, readFileSync, unlinkSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { clipboard, safeStorage, shell, type IpcMain } from 'electron'
import { protectSecretFile, writeSecretFile } from './remote/secret-file'

/**
 * Saved logins for the embedded browser — a real store, not a screen shaped
 * like one.
 *
 * ## The decision this module *is*
 *
 * He asked for *"password saving, like Chrome — profiles, saved logins."*
 * Profiles are a Chromium feature Electron hands over directly, and
 * `browser-profiles.ts` uses it. **Chromium's password manager is not.** There
 * is no `session.passwords`, no autofill API, no way to read or write the
 * `Login Data` database Chrome keeps, and no version of Electron in which any of
 * that has been true. Anybody who says otherwise is describing Chrome, not
 * Electron.
 *
 * So there were exactly two honest answers, and shipping a passwords screen that
 * does not save passwords was not one of them — that is the single most repeated
 * complaint in the whole recorded review. The two were: say plainly that saved
 * passwords are not possible and offer profiles and cookies, which are; or build
 * the store. This builds the store, because the ingredients were already here —
 * an encrypted-at-rest pattern proven in `voice.ts`, and a guest preload
 * (`browser-preload.ts`) that already runs in every page and already knows how
 * to find a form control.
 *
 * ## Where a password is, at every moment
 *
 * Four places, and the renderer is not one of them:
 *
 *  1. **On disk**, inside a `safeStorage` blob — Keychain on macOS, DPAPI on
 *     Windows, the session keyring on Linux. Where no secure store is available
 *     this refuses to save rather than falling back to a plain file, exactly as
 *     `voice.ts` does and for the same reason: a cleartext password in a
 *     user-data directory is a real cost to a real person, and "we saved it
 *     anyway" is not a decision to make on somebody's behalf and certainly not
 *     one to make silently.
 *  2. **In this process's memory**, decrypted, while the app runs.
 *  3. **In the guest page**, filled into the field it belongs to — which is the
 *     entire point, and no worse than typing it.
 *  4. **On the clipboard**, briefly, if the person presses Copy. Put there by
 *     this process; the renderer asks for a copy and is told only whether it
 *     happened.
 *
 * The React tree never holds one. That is the same rule `browser-session.ts`
 * applies to cookie values — *"those values are session tokens… sending them to
 * the renderer would put them in a React tree, in devtools, and in any future
 * crash report"* — and a password deserves it at least as much. Every shape that
 * crosses to the renderer here is a {@link SavedLoginSummary}, which has no
 * `password` field to forget to strip.
 *
 * ## Matching is exact, and that is a choice
 *
 * A saved login belongs to one **origin**: scheme, host and port, the same
 * triple Chrome calls a signon realm. `https://example.com` and
 * `https://app.example.com` are two entries, and a login saved for one is never
 * offered on the other.
 *
 * Chrome is broader than this — it groups by registrable domain through the
 * public suffix list, and by publisher through digital asset links. Both need
 * data this app does not have and cannot derive correctly, and the failure mode
 * of guessing is offering somebody's bank password to a page on a subdomain
 * somebody else controls. Narrow and predictable beats broad and occasionally
 * catastrophic, and the manager shows the origin on every row so nothing about
 * it is a surprise.
 *
 * ## What `safeStorage` actually gives, measured rather than assumed
 *
 * Electron 41.10.5 on macOS 27, in a probe with no window, reading the real
 * thing:
 *
 * | Question                                   | Answer                              |
 * |--------------------------------------------|-------------------------------------|
 * | `isEncryptionAvailable()` before app ready  | `true` (Linux is the one that lies) |
 * | `getSelectedStorageBackend()`               | does not exist off Linux            |
 * | ciphertext of `"hunter2"`, encrypted twice  | **byte-identical**                  |
 * | first three bytes                           | `v10`, then binary                  |
 * | one flipped bit in the *last* block         | throws                              |
 * | one flipped bit in an *earlier* block       | **accepted**, plaintext rewritten   |
 * | another app's blob, same Mac, same user     | throws                              |
 * | a zero-length file                          | decrypts to `""`, does not throw    |
 *
 * Three of those rows are decisions rather than trivia.
 *
 * **It is confidentiality, not integrity.** Chromium's OSCrypt is AES-CBC with a
 * key from the login keychain; deterministic output and a surviving mid-block
 * flip are exactly the fingerprint of CBC with no authentication tag. Flipping a
 * byte in block *N* garbles block *N* and flips the same bit in block *N+1*'s
 * plaintext — so anybody who can **write this file** can choose sixteen bytes of
 * the JSON. They cannot read a password that way. They can try to move one: turn
 * a stored `https://bank.example` into a host they control, and the next visit
 * types the person's password into it. That is a credential exfiltration through
 * a file whose only other guard is `0600`, which stops other users and stops
 * nothing running as this person — including an agent with a shell, which is
 * most of what this app is for.
 *
 * So the payload carries {@link STORE_VERSION} 2: a SHA-256 over the entries,
 * **inside** the encrypted blob. Forging a row now means also producing a
 * matching digest in ciphertext, and every attempt at that garbles another
 * block. There is no padding-oracle to work with either, because nothing here
 * ever tells anybody why a decrypt failed — it is one sentence on one screen,
 * to the person whose store it is.
 *
 * **A store that does not verify is not "empty".** Everything unreadable used to
 * become an empty list, which is right for a blob from another machine and badly
 * wrong for a blob somebody edited: the person sees nothing saved, saves it all
 * again, and hands it to whoever is editing the file. So a digest mismatch is a
 * {@link StoreFault}, it is said out loud, nothing is written over the top of it,
 * and the file is named so it can be looked at or deleted.
 *
 * **Version 1 payloads still read**, undigested, and are upgraded on the next
 * save. A store that was written before this existed cannot be proved either way
 * and refusing it would delete somebody's passwords to make a point.
 */

/* ------------------------------------------------------------------ shape -- */

/** What is stored. Never leaves the main process in this shape. */
export interface SavedLogin {
  /** Which browser profile it belongs to — see `browser-profiles.ts`. */
  profileId: string
  /** `scheme://host[:port]`, normalised by {@link originOf}. */
  origin: string
  username: string
  password: string
  updatedAt: number
}

/** What the renderer is allowed to see. Note the absence of `password`. */
export interface SavedLoginSummary {
  profileId: string
  origin: string
  username: string
  updatedAt: number
}

export function summarizeLogin(entry: SavedLogin): SavedLoginSummary {
  return {
    profileId: entry.profileId,
    origin: entry.origin,
    username: entry.username,
    updatedAt: entry.updatedAt,
  }
}

/**
 * The origin a login is filed under, or null when the URL is not one a password
 * may be saved for.
 *
 * `http:` is allowed but `file:`, `data:`, `about:` and every custom scheme are
 * not — a saved login is meaningless without a host to bind it to, and an entry
 * filed under `null` would match every page that also failed to parse.
 *
 * Plain http is *not* refused, because localhost is plain http and a dev server
 * with a login form is the most common page this browser will ever see. It is
 * the caller's business to say so on screen; refusing outright would make the
 * feature useless for exactly the audience it was built for.
 */
export function originOf(url: unknown): string | null {
  if (typeof url !== 'string' || url.trim() === '') return null
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null
    if (parsed.hostname === '') return null
    return parsed.origin
  } catch {
    return null
  }
}

/** A username or password longer than this is a paste accident, not a secret. */
export const MAX_FIELD = 512

function cleanField(raw: unknown): string {
  if (typeof raw !== 'string') return ''
  // Control characters cannot be typed into a form field, so their presence
  // means something other than a person produced this — and a newline inside a
  // stored username would break the one-line rows in the manager.
  const flat = raw.replace(/[\u0000-\u001f\u007f]/g, '')
  return flat.length > MAX_FIELD ? flat.slice(0, MAX_FIELD) : flat
}

/**
 * Read a stored file into a list, dropping anything that is not a login.
 *
 * Defensive rather than trusting even though this app wrote the file: an entry
 * with no origin would be offered on every page, and an entry with no password
 * would fill a form with the empty string and look like a bug in the site.
 */
export function readLogins(raw: unknown): SavedLogin[] {
  return readStore(raw).entries
}

/** The payload spelling this build writes. See the header for what changed. */
export const STORE_VERSION = 2

/**
 * What is wrong with the store on disk, if anything.
 *
 * `'none'` is both "fine" and "there is no store yet"; those are the same to
 * every caller. `'tampered'` is the one that must never be shown as an empty
 * list — see the header.
 */
export type StoreFault = 'none' | 'tampered' | 'unreadable'

export interface StoreRead {
  entries: SavedLogin[]
  fault: StoreFault
  /** True for a version-1 payload, which is upgraded on the next save. */
  legacy: boolean
}

/**
 * The digest that makes an unauthenticated cipher behave like an authenticated
 * one for this file's threat model.
 *
 * Over `JSON.stringify(entries)` and not over the whole payload, so that adding
 * a field to the envelope later is not a false alarm on every existing store.
 * It is a plain SHA-256 rather than an HMAC because it lives **inside** the
 * encryption: an attacker who cannot decrypt cannot compute a digest that will
 * land in the right place, and one who can decrypt already has the passwords.
 */
function digestOf(entries: readonly SavedLogin[]): string {
  return createHash('sha256').update(JSON.stringify(entries)).digest('hex')
}

/**
 * Read a decrypted payload, and say whether it is trustworthy.
 *
 * Split from {@link readLogins} rather than replacing it because the entry
 * cleaning below is used on both paths and is worth keeping in one place, and
 * because most callers only ever want the list.
 */
export function readStore(raw: unknown): StoreRead {
  if (typeof raw !== 'object' || raw === null) return { entries: [], fault: 'none', legacy: false }
  const value = raw as Record<string, unknown>
  const list = Array.isArray(value.entries) ? value.entries : []
  const out: SavedLogin[] = []
  for (const entry of list) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    const origin = originOf(record.origin)
    const password = cleanField(record.password)
    if (origin === null || password === '') continue
    out.push({
      profileId: typeof record.profileId === 'string' ? record.profileId : 'default',
      origin,
      username: cleanField(record.username),
      password,
      updatedAt: typeof record.updatedAt === 'number' ? record.updatedAt : 0,
    })
  }

  /*
   * The digest is checked against what was *stored*, not against what survived
   * the cleaning above — a payload whose entries were rewritten by a bit flip
   * may well have lost some of them to `originOf` on the way through here, and
   * comparing the cleaned list would then report "no fault" for exactly the
   * file this check exists to catch.
   */
  const stored = typeof value.digest === 'string' ? value.digest : ''
  if (stored === '') {
    // Version 1, or a payload from a build older than digests. Read it, and say
    // it is old so the next save writes it forward.
    return { entries: out, fault: 'none', legacy: true }
  }
  if (stored !== digestOf(list as SavedLogin[])) {
    // Nothing is returned. A tampered store must not be *used* either — the
    // whole risk is a rewritten origin being offered to a page.
    return { entries: [], fault: 'tampered', legacy: false }
  }
  return { entries: out, fault: 'none', legacy: false }
}

/**
 * Put `entry` in, replacing any login for the same profile, origin and username.
 *
 * Same username means the same account, so a changed password updates the row
 * rather than adding a second one that will be offered alongside the stale one
 * forever. A different username on the same origin is a different account and
 * gets its own row — which is why the fill path has to cope with more than one
 * match rather than assuming a single answer.
 */
export function upsertLogin(list: readonly SavedLogin[], entry: SavedLogin): SavedLogin[] {
  const rest = list.filter(
    (item) =>
      !(
        item.profileId === entry.profileId &&
        item.origin === entry.origin &&
        item.username === entry.username
      ),
  )
  return [...rest, entry]
}

/** Every login saved for this exact origin, in this profile. */
export function loginsFor(
  list: readonly SavedLogin[],
  profileId: string,
  origin: string,
): SavedLogin[] {
  return list.filter((item) => item.profileId === profileId && item.origin === origin)
}

/**
 * Is this offer worth showing?
 *
 * A page that submits the same credentials it was just filled with produces a
 * "save this password?" prompt for a password that is already saved, every time
 * anybody signs in. Chrome suppresses that and so does this: an offer is only
 * new when nothing stored for the origin already holds both halves.
 *
 * An offer with the *same* username and a *different* password is not
 * suppressed — that is a password change, and it is the one moment the store has
 * to be updated or it goes stale forever.
 */
export function isNewLogin(
  list: readonly SavedLogin[],
  candidate: { profileId: string; origin: string; username: string; password: string },
): boolean {
  return !list.some(
    (item) =>
      item.profileId === candidate.profileId &&
      item.origin === candidate.origin &&
      item.username === candidate.username &&
      item.password === candidate.password,
  )
}

/* ------------------------------------------------------------ persistence -- */

export function loginsPath(userData: string): string {
  return join(userData, 'browser-logins.bin')
}

export interface SaveOutcome {
  ok: boolean
  /** Shown to a person verbatim, so it says what to do rather than what broke. */
  message: string
}

/**
 * The sentence shown wherever saving is impossible.
 *
 * One string, exported, because it has to be identical in the save path and in
 * the manager's empty state — a person told two different things about the same
 * machine will reasonably conclude one of them is a bug.
 */
export const NO_SECURE_STORE =
  'This machine has no secure store available, so logins cannot be saved here. On Linux that usually means no keyring is running; start one and try again.'

/**
 * In-memory, decrypted, for the life of the process.
 *
 * Read once on first use. Every page load asks whether it has a login, and a
 * decrypt per page load would put a Keychain call on the critical path of every
 * navigation.
 */
let cache: SavedLogin[] | null = null
let cacheDir: string | null = null
/**
 * What was wrong with the store the last time it was read.
 *
 * Alongside the cache rather than derived on demand, because the read that
 * discovers it happens once per process and the screen that has to say so is
 * opened much later. A fault that was only visible during the read would be a
 * fault nobody ever sees.
 */
let fault: StoreFault = 'none'
/** True when the store on disk predates digests and is due an upgrade. */
let legacy = false

/** For tests, which must not inherit each other's store. */
export function resetLoginsForTests(): void {
  cache = null
  cacheDir = null
  fault = 'none'
  legacy = false
}

/**
 * The bytes on disk, in either of the two spellings this file has used.
 *
 * Older builds wrote the `safeStorage` buffer raw; this one writes it base64
 * through `writeSecretFile`. Reading only the new spelling would turn every
 * existing user's saved logins into "unreadable", which this module treats as
 * "absent" — so the passwords would not be lost so much as silently forgotten,
 * which is worse, because nothing on screen would say a store had ever existed.
 *
 * The new form is tried first and only when the bytes are *entirely* base64
 * text, which a `safeStorage` blob is not: on Windows and Linux it opens with
 * the literal marker `v10`/`v11` followed by binary, and on macOS it is
 * keychain ciphertext — either way a byte outside the base64 alphabet appears
 * within the first few. A raw blob that did happen to look like base64 falls
 * through to the second attempt anyway, because decryption of the wrong bytes
 * throws.
 */
function decryptBlob(raw: Buffer): string {
  const text = raw.toString('utf8')
  if (/^[A-Za-z0-9+/\r\n]+={0,2}\s*$/.test(text)) {
    try {
      return safeStorage.decryptString(Buffer.from(text, 'base64'))
    } catch {
      // Not the new spelling after all — fall through and read it as written.
    }
  }
  return safeStorage.decryptString(raw)
}

export function allLogins(userData: string): SavedLogin[] {
  if (cache !== null && cacheDir === userData) return cache
  cacheDir = userData
  const path = loginsPath(userData)
  if (!existsSync(path)) {
    cache = []
    return cache
  }
  // Lock down a file an older build left with inherited permissions. The write
  // path above protects everything it writes from the moment this version
  // first saves; a store that already exists is only reached here. No-op off
  // Windows, and idempotent, so this costs one `icacls` per process at most.
  protectSecretFile(dirname(path), path)
  try {
    const read = readStore(JSON.parse(decryptBlob(readFileSync(path))) as unknown)
    cache = read.entries
    fault = read.fault
    legacy = read.legacy
  } catch {
    // Encrypted by a different OS user, a different machine, or an older
    // format. Unreadable is the same as absent from here — the alternative is a
    // browser that will not open because a file it cannot read exists.
    //
    // Note what is NOT in this branch: a payload that decrypted cleanly and
    // then failed its digest. That is somebody editing the file, it comes back
    // from `readStore` as a fault rather than an exception, and treating it as
    // absent is the mistake the header spends a paragraph on.
    //
    // This is still *said*, though, and that is new. The list is empty either
    // way — there is nothing to read and no key to read it with — but "nothing
    // saved yet" and "there is a file here this app cannot open" are different
    // facts, and only one of them explains where somebody's passwords went
    // after they moved a profile between machines. A machine with no secure
    // store at all is excluded, because that has its own sentence and two
    // explanations for one screen is worse than one.
    cache = []
    fault = safeStorage.isEncryptionAvailable() ? 'unreadable' : 'none'
    legacy = false
  }
  /*
   * Carry an old store forward the moment it is opened, rather than the next
   * time somebody happens to save a password.
   *
   * A version-1 payload has no digest, so until it is rewritten the integrity
   * guard is not guarding anything — and nobody is going to be told "re-save
   * your passwords to get the new format", which would be resistance invented
   * out of nothing. One write, once, on the first read after the update.
   *
   * It is deliberately not a failure if it cannot happen: a machine with no
   * secure store cannot write and does not need to, because it has no store to
   * upgrade in the first place.
   */
  if (legacy && cache.length > 0) persist(userData, cache)
  return cache
}

/**
 * What the manager needs to tell the truth about this machine's store, in one
 * answer.
 *
 * One call rather than four, because the four are only ever wanted together and
 * because a screen assembled from four awaits renders three intermediate states
 * that are each a lie for a frame.
 */
export interface StoreState {
  /** Can anything be saved here at all? False refuses rather than degrading. */
  available: boolean
  /** Where the file is. Named on screen; a person should not have to find it. */
  path: string
  /** True once something has been saved. */
  exists: boolean
  fault: StoreFault
  /** Empty when there is nothing wrong. Shown verbatim. */
  message: string
}

/**
 * The sentence for a store that decrypted and then failed its own digest.
 *
 * It says what happened, what was *not* done about it, and what to do — in that
 * order, because the middle one is the part somebody will not assume. "Could
 * not read your passwords" on its own reads as data loss, and the natural next
 * move after data loss is to save everything again, which is precisely the move
 * this fault must not provoke.
 */
export const TAMPERED_STORE =
  'The saved-login file on this machine did not verify — its contents have been altered since this app wrote them. Nothing has been used from it and nothing has been deleted. Look at the file, or forget every saved password and start again.'

/**
 * The sentence for a file that will not decrypt at all.
 *
 * A calmer one, and deliberately so: this is almost always a profile folder
 * carried over from another machine or another user account, where the key
 * simply is not on this keychain, and nothing has gone wrong. It is said at all
 * because the alternative is a screen that reads "nothing saved yet" over a file
 * full of somebody's passwords — which is the sentence that makes them think the
 * app lost them.
 *
 * It names the consequence of carrying on, because carrying on is allowed here:
 * saving a new password writes over this file, and that is a thing to know
 * before rather than after.
 */
export const UNREADABLE_STORE =
  'There is a saved-login file here that this app cannot open — it was encrypted on a different machine or by a different user account, and the key for it is not on this one. Nothing can be recovered from it. Saving a new password will write over it.'

export function storeState(userData: string): StoreState {
  // Through `allLogins` so the fault is the one from an actual read rather than
  // from whenever the last one happened to be.
  allLogins(userData)
  return {
    available: safeStorage.isEncryptionAvailable(),
    path: loginsPath(userData),
    exists: existsSync(loginsPath(userData)),
    fault,
    message:
      fault === 'tampered' ? TAMPERED_STORE : fault === 'unreadable' ? UNREADABLE_STORE : '',
  }
}

/**
 * Write the store, through the same door every other secret in this app uses.
 *
 * This file was the one exception, and `servers/credentials.ts` calls it out by
 * name for it: it wrote the blob with a bare `writeFileSync` — no mode, no
 * fsync, and, the part that matters here, no `icacls /inheritance:r`. On
 * Windows NTFS ignores the POSIX mode entirely, so the file sat in `%APPDATA%`
 * with whatever the parent folder's inherited ACL happened to be, while every
 * other credential this app writes — pairing tokens, GitHub tokens, server
 * credentials, `deck-control.json`, the hook endpoint config — carries an
 * explicit owner-only entry. On macOS the 0600 the other path sets is the same
 * boundary, so this was a Windows-only hole in an otherwise uniform rule.
 *
 * The contents are DPAPI-encrypted by `safeStorage`, so another standard user
 * on the PC cannot decrypt them — which is why this is a small hole and not an
 * exposure. It is still the app's own stated rule with one file exempted, and
 * an exemption nobody can see is the kind that survives.
 *
 * Base64 rather than the raw buffer, for the reason `servers/credentials.ts`
 * gives: `writeSecretFile` writes text, because the sequence it performs —
 * open exclusive, write, fsync, ACL, rename, chmod — is written once for
 * strings and a second binary variant of it would be a second thing to keep
 * correct. {@link decryptBlob} reads both spellings so a store written by an
 * older build is not lost.
 */
function persist(userData: string, list: SavedLogin[]): SaveOutcome {
  if (!safeStorage.isEncryptionAvailable()) return { ok: false, message: NO_SECURE_STORE }
  /*
   * Never write over a store that failed its digest.
   *
   * The person is being told the file was altered and offered the two honest
   * answers — look at it, or forget everything. Quietly saving a new password
   * on top would destroy the evidence and produce a file that verifies, which
   * is the one outcome worse than the fault.
   */
  if (fault === 'tampered') return { ok: false, message: TAMPERED_STORE }
  /*
   * `'unreadable'` is deliberately not refused. A blob from another machine
   * cannot be recovered by anybody, so refusing to save would leave somebody
   * permanently unable to use this feature on a profile they carried over —
   * resistance with nothing at the end of it. {@link UNREADABLE_STORE} says on
   * screen that the file will be written over, which is the honest place for
   * that fact: before the save, not after it.
   */
  const path = loginsPath(userData)
  const blob = safeStorage.encryptString(
    JSON.stringify({ version: STORE_VERSION, entries: list, digest: digestOf(list) }),
  )
  writeSecretFile(dirname(path), path, blob.toString('base64'))
  cache = list
  cacheDir = userData
  legacy = false
  // Whatever was unreadable is gone, replaced by something this machine wrote.
  fault = 'none'
  return { ok: true, message: 'Saved.' }
}

export function saveLogin(userData: string, entry: SavedLogin): SaveOutcome {
  return persist(userData, upsertLogin(allLogins(userData), entry))
}

export function forgetLogin(
  userData: string,
  profileId: string,
  origin: string,
  username: string,
): SaveOutcome {
  const next = allLogins(userData).filter(
    (item) => !(item.profileId === profileId && item.origin === origin && item.username === username),
  )
  return persist(userData, next)
}

export function forgetAllLogins(userData: string): SaveOutcome {
  const path = loginsPath(userData)
  if (existsSync(path)) unlinkSync(path)
  cache = []
  cacheDir = userData
  // The one way out of a fault, and the reason the sentence for it offers this
  // rather than only describing the problem: the file is gone, so there is
  // nothing left to be wrong.
  fault = 'none'
  legacy = false
  return { ok: true, message: 'Cleared.' }
}

/* --------------------------------------------------------------- the ask -- */

/**
 * A login a page just submitted, waiting on an answer.
 *
 * Held here rather than sent to the renderer, which is the whole reason the
 * prompt can show a password's *origin and username* without the password ever
 * leaving this process. The renderer is told an offer exists and answers yes or
 * no; the secret never makes the trip.
 *
 * One slot, not a queue. Two sign-in forms submitted before either is answered
 * is not a real sequence, and a queue would mean a prompt about a page the
 * person left three navigations ago.
 */
let pending: SavedLogin | null = null

export function pendingOffer(): SavedLogin | null {
  return pending
}

export function setPendingOffer(entry: SavedLogin | null): void {
  pending = entry
}

/* -------------------------------------------------------------- register -- */

/**
 * Wire saved logins. Call once from `registerIpc()`:
 *
 *     import { registerBrowserPasswordIpc } from './browser-passwords'
 *     registerBrowserPasswordIpc(ipcMain, () => app.getPath('userData'))
 *
 * Channels:
 * - `browser-password:available` (invoke)                         → boolean
 * - `browser-password:state`     (invoke)                          → {@link StoreState}
 * - `browser-password:show-file` (invoke)                          → boolean
 * - `browser-password:list`      (invoke, profileId)              → {@link SavedLoginSummary}[]
 * - `browser-password:forget`    (invoke, profileId, origin, user) → {@link SaveOutcome}
 * - `browser-password:forget-all`(invoke)                          → {@link SaveOutcome}
 * - `browser-password:copy`      (invoke, profileId, origin, user) → boolean
 * - `browser-password:offer`     (invoke)                          → the pending offer, without its password
 * - `browser-password:answer`    (invoke, keep)                    → {@link SaveOutcome}
 */
export function registerBrowserPasswordIpc(ipcMain: IpcMain, userData: () => string): void {
  ipcMain.handle('browser-password:available', () => safeStorage.isEncryptionAvailable())

  /**
   * Everything the manager needs to say what is stored and where, in one call.
   *
   * The path is on it because "kept in this machine's secure store" is a
   * sentence that sounds like an answer and is not one — it names no file,
   * nowhere to look and nothing to delete. See {@link StoreState}.
   */
  ipcMain.handle('browser-password:state', () => storeState(userData()))

  /**
   * Show the file, rather than print where it is.
   *
   * A path in a paragraph is a thing somebody has to select, copy, open a
   * Finder window for and paste into a Go-to-Folder box. `showItemInFolder`
   * is the same information with the work already done. It reveals an
   * encrypted blob, which is the honest thing to reveal: it is what is actually
   * there.
   */
  ipcMain.handle('browser-password:show-file', () => {
    const path = loginsPath(userData())
    if (!existsSync(path)) return false
    shell.showItemInFolder(path)
    return true
  })

  ipcMain.handle('browser-password:list', (_event, profileId: unknown) => {
    const wanted = typeof profileId === 'string' ? profileId : 'default'
    return allLogins(userData())
      .filter((item) => item.profileId === wanted)
      .map(summarizeLogin)
      .sort((a, b) => a.origin.localeCompare(b.origin) || a.username.localeCompare(b.username))
  })

  ipcMain.handle(
    'browser-password:forget',
    (_event, profileId: unknown, origin: unknown, username: unknown) =>
      forgetLogin(
        userData(),
        typeof profileId === 'string' ? profileId : 'default',
        typeof origin === 'string' ? origin : '',
        typeof username === 'string' ? username : '',
      ),
  )

  ipcMain.handle('browser-password:forget-all', () => forgetAllLogins(userData()))

  /**
   * Copy, from here, so the password never crosses the bridge.
   *
   * The renderer names the row and is told only whether a copy happened. A
   * `browser-password:read` returning the string would be the single line that
   * undoes everything above it.
   */
  ipcMain.handle(
    'browser-password:copy',
    (_event, profileId: unknown, origin: unknown, username: unknown) => {
      const match = allLogins(userData()).find(
        (item) =>
          item.profileId === profileId && item.origin === origin && item.username === username,
      )
      if (!match) return false
      clipboard.writeText(match.password)
      return true
    },
  )

  ipcMain.handle('browser-password:offer', () => {
    const offer = pending
    return offer === null ? null : summarizeLogin(offer)
  })

  ipcMain.handle('browser-password:answer', (_event, keep: unknown) => {
    const offer = pending
    pending = null
    if (offer === null) return { ok: false, message: 'Nothing to save.' }
    if (keep !== true) return { ok: true, message: 'Not saved.' }
    return saveLogin(userData(), offer)
  })
}
