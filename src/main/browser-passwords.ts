import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { clipboard, safeStorage, type IpcMain } from 'electron'

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
  if (typeof raw !== 'object' || raw === null) return []
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
  return out
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

/** For tests, which must not inherit each other's store. */
export function resetLoginsForTests(): void {
  cache = null
  cacheDir = null
}

export function allLogins(userData: string): SavedLogin[] {
  if (cache !== null && cacheDir === userData) return cache
  cacheDir = userData
  const path = loginsPath(userData)
  if (!existsSync(path)) {
    cache = []
    return cache
  }
  try {
    cache = readLogins(JSON.parse(safeStorage.decryptString(readFileSync(path))) as unknown)
  } catch {
    // Encrypted by a different OS user, a different machine, or an older
    // format. Unreadable is the same as absent from here — the alternative is a
    // browser that will not open because a file it cannot read exists.
    cache = []
  }
  return cache
}

function persist(userData: string, list: SavedLogin[]): SaveOutcome {
  if (!safeStorage.isEncryptionAvailable()) return { ok: false, message: NO_SECURE_STORE }
  const path = loginsPath(userData)
  mkdirSync(dirname(path), { recursive: true })
  const blob = safeStorage.encryptString(JSON.stringify({ version: 1, entries: list }))
  const temporary = `${path}.tmp`
  writeFileSync(temporary, blob)
  renameSync(temporary, path)
  cache = list
  cacheDir = userData
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
 * - `browser-password:list`      (invoke, profileId)              → {@link SavedLoginSummary}[]
 * - `browser-password:forget`    (invoke, profileId, origin, user) → {@link SaveOutcome}
 * - `browser-password:forget-all`(invoke)                          → {@link SaveOutcome}
 * - `browser-password:copy`      (invoke, profileId, origin, user) → boolean
 * - `browser-password:offer`     (invoke)                          → the pending offer, without its password
 * - `browser-password:answer`    (invoke, keep)                    → {@link SaveOutcome}
 */
export function registerBrowserPasswordIpc(ipcMain: IpcMain, userData: () => string): void {
  ipcMain.handle('browser-password:available', () => safeStorage.isEncryptionAvailable())

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
