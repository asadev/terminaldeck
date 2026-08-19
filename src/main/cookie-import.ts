import { execFile } from 'node:child_process'
import { createDecipheriv, createHash, pbkdf2Sync } from 'node:crypto'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { app, type IpcMain, type Session } from 'electron'
import { cookieRemovalUrl, guestSession } from './browser-session'
import {
  browserDataAccess,
  canRead,
  describeAccessFailure,
  detectBrowsers,
  snapshotDatabase,
  type BrowserId,
  type DatabaseOpener,
  type PrivacyPane,
  type ReadonlyDatabase,
} from './chrome-import'
import { currentPlatform, type Platform } from './platform/host'

/**
 * Cookie import — carry the sign-ins already in an installed Chromium browser
 * into the app's own browser tab, so a dev server behind a Google login does not
 * have to be signed into twice.
 *
 * This is the one place in the app that reads another application's secrets, so
 * it is worth being explicit about what it does and what it refuses to do.
 *
 * ## The encryption, and why it needs the keychain
 *
 * Chromium does not store cookie values in the clear. Each `encrypted_value`
 * blob is `v10` followed by AES-128-CBC ciphertext. The key is derived —
 * PBKDF2-HMAC-SHA1, salt `saltysalt`, 1003 iterations on macOS, 16 bytes out —
 * from a random password the browser keeps in the login keychain as a generic
 * password. The service and account names were read off this machine rather
 * than assumed: `svce="Chrome Safe Storage"`, `acct="Chrome"`, and a second item
 * for Chromium. Reading the *attributes* of those items needs no permission;
 * reading the password does, and macOS asks the user with a dialog naming this
 * app.
 *
 * That dialog is the whole reason this module exists separately from
 * `chrome-import.ts`, which is documented as read-only and is not extended here.
 * An import is an explicit, user-initiated act with a visible consequence, and
 * when the prompt is denied — or never answered — the result says so in a
 * sentence. It never returns "0 cookies" as if the profile were empty.
 *
 * ## Two things about the format that were checked, not assumed
 *
 * 1. **Where the cookie database lives.** Modern Chromium is documented as
 *    keeping it at `<profile>/Network/Cookies`. On the Chrome 151 install on
 *    this machine there is no `Network` directory at all and the file is at
 *    `<profile>/Cookies` — verified by `stat`, which works on a protected path
 *    where `readdir` does not. Both are probed, newer location first.
 * 2. **The plaintext is not just the value.** Since Chrome 127 the cookie is
 *    bound to its domain: the encrypted plaintext is the 32-byte SHA-256 of the
 *    cookie's `host_key` followed by the value. Decrypting without stripping
 *    that gives every cookie 32 bytes of binary garbage on the front, which no
 *    site accepts and no error reports. {@link stripDomainHash} strips it when
 *    it is there and leaves older blobs alone.
 *
 * ## Why this is macOS-only, and why that is not simply a gap to be filled
 *
 * A read of the Windows build on 2026-08-19 found the browser sign-in handover
 * offering its second half — *"I have signed in — bring it back"* — on every
 * platform, while everything below {@link readSafeStorageKey} answers on macOS
 * and nowhere else. The obvious repair is to write the Windows key path: read
 * `os_crypt.encrypted_key` out of `Local State`, strip its `DPAPI` prefix,
 * `CryptUnprotectData` it, and AES-256-GCM the values. That was considered and
 * rejected, and the reasoning is written down here because the next person to
 * open this file will have the same idea and deserves the counter-argument
 * rather than an unexplained hole.
 *
 * **On Windows the key is not the blocker; the cookies are.** Since Chrome 127
 * (July 2024) Windows Chromium encrypts cookies with *app-bound* encryption:
 * the blobs are `v20`, and the key that opens them is held by Chrome's own
 * elevation service — a SYSTEM service that hands it back only to a caller
 * whose executable lives inside the Chrome installation it belongs to. That is
 * not an accident of the format. It is a measure aimed precisely at other
 * programs reading the cookie store, which is exactly what this module is.
 * Edge shipped the same thing.
 *
 * This file had already written that fact down once, before any of this: see
 * {@link decryptCookieValue}, which refuses `v20` by name rather than mangling
 * it. So a Windows key path would unwrap a key perfectly and then meet a
 * database in which every row is `v20` — {@link planImport} counts each one as
 * `failed`, and {@link importMessage} tells the user *"the keychain key did not
 * fit its cookie database"*, which is both wrong and unactionable. That outcome
 * is pinned by a test against `v20` fixtures, run on this Mac, so the claim is
 * measured rather than asserted: several hundred lines of DPAPI plumbing to
 * arrive at the same dead button with a worse sentence under it.
 *
 * **What was *not* done, stated plainly.** None of the Windows behaviour above
 * was measured on a Windows machine, because there is not one here. It is taken
 * from Chrome's app-bound encryption design and from this module's own prior
 * refusal of `v20`, and it should be re-checked rather than trusted if Chrome
 * ever unwinds it. What did not need a Windows machine is the part that was
 * done: {@link cookieImportSupported} is now the single answer to "can this
 * platform do this at all", and the two places that would otherwise draw a
 * control anyway both ask it before offering — the settings pane through
 * `CookieImportStatus.supported`, and `SignInBanner`, which cannot import from
 * `src/main` and so asks its own side's copy of the question for the reason
 * `src/renderer/platform.ts` sets out at length. The rule being applied is the
 * house one: a control that cannot act is absent with its reason stated, never
 * drawn hopefully.
 *
 * ## What never leaves this module
 *
 * Cookie values and the keychain key. Nothing here logs, and nothing here puts
 * either into a return value, an error message or an IPC payload — the ledger
 * that makes "Clear imported cookies" possible records only name, domain, path
 * and the secure flag. `browser-session.ts` makes the same promise for the same
 * reason and this module reuses its helpers rather than restating them.
 */

/* ------------------------------------------------------------------ types -- */

/** Why a keychain read did not produce a key. Never carries the key itself. */
export type KeychainFailure = 'not-found' | 'denied' | 'no-answer' | 'unsupported' | 'failed'

export type KeychainResult =
  | { ok: true; secret: string }
  | { ok: false; reason: KeychainFailure; detail: string }

export interface CookieSource {
  browserId: BrowserId
  browserName: string
  profileId: string
  profileName: string
  /** The cookie database found for this profile. */
  path: string
  /** False when the profile is readable but the browser has no keychain item. */
  keychainItem: boolean
}

/** A cookie as the import remembers it. Deliberately no value. */
export interface ImportedCookieRef {
  name: string
  domain: string
  path: string
  secure: boolean
}

export interface CookieLedger {
  version: 1
  /** Unix ms of the last import, or null when nothing has been imported. */
  importedAt: number | null
  /** Where they came from, for the sentence the panel shows. */
  source: string
  entries: ImportedCookieRef[]
}

export interface CookieImportStatus {
  /** Ledger entries still present in the guest session. */
  present: number
  /** Ledger entries, whether or not they are still there. */
  recorded: number
  importedAt: number | null
  source: string
  /** False on a platform this cannot decrypt on. */
  supported: boolean
}

export interface CookieImportReport {
  ok: boolean
  browserId: string
  browserName: string
  profileId: string
  imported: number
  /** Rows deliberately passed over — expired, or a domain the filter excluded. */
  skipped: number
  /** Rows that would not decrypt or would not set. */
  failed: number
  domains: number
  /** null when the keychain was never reached. */
  keychain: KeychainFailure | 'ok' | null
  /** One sentence, safe to show. Never contains a value or a key. */
  message: string
  /**
   * A System Settings pane that would unblock this, or null.
   *
   * Set only when the run stopped on a permission the user can actually grant,
   * so a panel can put a button beside the sentence instead of leaving somebody
   * to find Full Disk Access by hand. Null for every other outcome, including a
   * denied keychain — that one is re-asked by running the import again, and
   * sending a person into a security pane to fix it would be the wrong door.
   */
  settings: PrivacyPane | null
}

/* ---------------------------------------------------------- the keychain -- */

/**
 * Which generic-password item holds each browser's key.
 *
 * Chrome's and Chromium's were read off this machine. The rest follow the same
 * `"<Product> Safe Storage"` / `"<Product>"` convention every Chromium fork
 * uses, and a wrong guess fails as `not-found` with a sentence rather than
 * silently importing nothing.
 */
export const SAFE_STORAGE_ITEMS: Readonly<Record<BrowserId, { service: string; account: string }>> =
  {
    chrome: { service: 'Chrome Safe Storage', account: 'Chrome' },
    'chrome-canary': { service: 'Chrome Safe Storage', account: 'Chrome' },
    chromium: { service: 'Chromium Safe Storage', account: 'Chromium' },
    arc: { service: 'Arc Safe Storage', account: 'Arc' },
    edge: { service: 'Microsoft Edge Safe Storage', account: 'Microsoft Edge' },
    brave: { service: 'Brave Safe Storage', account: 'Brave' },
    vivaldi: { service: 'Vivaldi Safe Storage', account: 'Vivaldi' },
  }

/**
 * Can this platform carry cookies over at all?
 *
 * One function rather than three inline `platform === 'darwin'` comparisons,
 * because there were three of them and they are one decision. They had already
 * begun to drift: {@link readSafeStorageKey} refused off macOS, `statusOf`
 * reported `supported: false` off macOS, and the sign-in banner asked neither
 * and offered the button everywhere — so on Windows the settings pane said
 * "Importing cookies works on macOS only" while a band at the top of the same
 * browser offered to do it. Two answers to one question is how that happens,
 * and a named predicate is the cheapest way to have only one.
 *
 * It takes the platform rather than reading it, for the reason `platform/host.ts`
 * argues at length and this file has already been bitten by once: a branch that
 * reads `process.platform` inline can only ever be exercised by the machine it
 * was written on, and the macOS answer was asserted unconditionally here until
 * the first Windows CI run failed on it.
 *
 * The answer is `darwin` and nothing else, and that is not laziness about
 * Linux either — the key there lives behind libsecret or KWallet, the blobs are
 * `v11`, and neither is written. Linux has no build target today, so the honest
 * answer for it is the same "no" with the same sentence attached rather than a
 * half-path nobody can run.
 */
export function cookieImportSupported(platform: Platform): boolean {
  return platform === 'darwin'
}

/** How long to leave the keychain dialog on screen before giving up. */
const KEYCHAIN_TIMEOUT_MS = 120_000

/**
 * Turn a failed `security` invocation into a reason the user can act on.
 *
 * Pure and exported because the three outcomes that matter are impossible to
 * reproduce on demand — a denied prompt, an unanswered one and a missing item —
 * and getting them confused is how "you clicked Deny" ends up rendered as
 * "Chrome is not installed".
 */
export function classifyKeychainFailure(
  code: number | null,
  stderr: string,
  timedOut: boolean,
): KeychainFailure {
  if (timedOut) return 'no-answer'
  const text = stderr.toLowerCase()
  if (text.includes('could not be found') || code === 44) return 'not-found'
  // errSecUserCanceled is -128, which the shell reports as exit status 128.
  if (text.includes('user canceled') || text.includes('user cancelled') || code === 128) {
    return 'denied'
  }
  if (text.includes('interaction') || text.includes('not authorized')) return 'denied'
  return 'failed'
}

/**
 * Why an import cannot happen on this platform, said differently per platform
 * because the reason genuinely is different.
 *
 * The old sentence was one line for every platform — *"only implemented for
 * macOS, where the key lives in the login keychain"* — and it is kept below,
 * unchanged, for Linux, where it is exactly true: the key is behind libsecret
 * or KWallet, the blobs are `v11`, and nobody has written that path.
 *
 * It is wrong on Windows, and wrong in the direction that invites somebody to
 * fix the wrong thing. *"Only implemented"* reads as "so implement it", and the
 * module header explains at length why implementing the DPAPI key path would
 * produce a working key and a still-dead feature: Chrome seals the cookies
 * themselves, not the key, and it does it specifically against readers like
 * this one. A person reading a refusal deserves to know it is a wall rather
 * than a to-do — otherwise the next thing they do is file the same bug again.
 */
export function unsupportedMessage(browserName: string, platform: Platform): string {
  if (platform === 'win32') {
    return `Carrying ${browserName}’s cookies over works on macOS only. Chrome on Windows locks its cookie store to Chrome itself — no other program can read those sign-ins, and this app will not pretend to.`
  }
  return `Importing cookies from ${browserName} is only implemented for macOS, where the key lives in the login keychain.`
}

/**
 * The sentence for each failure. Written for someone who did not read this file.
 *
 * `platform` is threaded in rather than read here so that both wordings can be
 * pinned side by side on one machine. This file's tests already make that
 * argument for the access-failure sentence, and it applies unchanged: a branch
 * that reads the host is a branch only the host can ever check.
 */
export function keychainMessage(
  reason: KeychainFailure,
  browserName: string,
  platform: Platform = currentPlatform(),
): string {
  switch (reason) {
    case 'not-found':
      return `macOS has no “Safe Storage” keychain item for ${browserName}, so there is no key to decrypt its cookies with. Open ${browserName} once and try again.`
    case 'denied':
      return `The keychain request was denied, so ${browserName}’s cookies stayed encrypted. Nothing was imported. Run the import again and choose Allow to let this app read the key.`
    case 'no-answer':
      return `The keychain asked for permission and nothing answered it, so the import stopped. Run it again and answer the dialog.`
    case 'unsupported':
      return unsupportedMessage(browserName, platform)
    case 'failed':
      return `macOS refused to hand over ${browserName}’s encryption key, so nothing could be decrypted.`
  }
}

type Runner = (
  file: string,
  args: readonly string[],
) => Promise<{ code: number | null; stdout: string; stderr: string; timedOut: boolean }>

const runSecurity: Runner = (file, args) =>
  new Promise((resolve) => {
    execFile(
      file,
      [...args],
      { timeout: KEYCHAIN_TIMEOUT_MS, maxBuffer: 64 * 1024, encoding: 'utf8' },
      (error, stdout, stderr) => {
        const err = error as (NodeJS.ErrnoException & { code?: number | string }) | null
        const timedOut = Boolean(error && (error as { killed?: boolean }).killed)
        const code = typeof err?.code === 'number' ? err.code : error ? 1 : 0
        resolve({ code, stdout, stderr, timedOut })
      },
    )
  })

/**
 * Ask the login keychain for a browser's storage key.
 *
 * `security -w` prints the password on stdout. It is returned to the caller and
 * nowhere else: not logged, not attached to an error, and not kept after the
 * key has been derived from it.
 */
export async function readSafeStorageKey(
  browserId: BrowserId,
  browserName: string,
  platform: NodeJS.Platform = process.platform,
  run: Runner = runSecurity,
): Promise<KeychainResult> {
  if (!cookieImportSupported(platform)) {
    return {
      ok: false,
      reason: 'unsupported',
      detail: keychainMessage('unsupported', browserName, platform),
    }
  }
  const item = SAFE_STORAGE_ITEMS[browserId]
  if (!item) {
    return { ok: false, reason: 'not-found', detail: keychainMessage('not-found', browserName) }
  }

  const result = await run('/usr/bin/security', [
    'find-generic-password',
    '-w',
    '-s',
    item.service,
    '-a',
    item.account,
  ])

  const secret = result.stdout.trim()
  if (result.code === 0 && secret !== '') return { ok: true, secret }

  const reason = classifyKeychainFailure(result.code, result.stderr, result.timedOut)
  return { ok: false, reason, detail: keychainMessage(reason, browserName) }
}

/* --------------------------------------------------------------- crypto -- */

/** Chromium's constants. Fixed by the format, not choices this app gets to make. */
const KEY_SALT = 'saltysalt'
const KEY_LENGTH = 16
/** macOS uses 1003 rounds; the Linux fallback key uses 1. */
const KEY_ITERATIONS_DARWIN = 1003
const KEY_ITERATIONS_LINUX = 1
/** Sixteen spaces. Chromium uses a fixed IV, which is why the salt is fixed too. */
const COOKIE_IV = Buffer.alloc(16, ' ')

export function deriveCookieKey(secret: string, platform: NodeJS.Platform = process.platform): Buffer {
  const rounds = platform === 'darwin' ? KEY_ITERATIONS_DARWIN : KEY_ITERATIONS_LINUX
  return pbkdf2Sync(secret, KEY_SALT, rounds, KEY_LENGTH, 'sha1')
}

/**
 * Undo PKCS#7 padding, or say the block is not padded.
 *
 * Done by hand rather than through `setAutoPadding(true)` because a wrong key
 * produces plausible-looking bytes with invalid padding, and this is the only
 * cheap signal that the key did not fit. Node's own unpadding throws a generic
 * "bad decrypt" that cannot be told apart from a corrupt row.
 */
export function unpadPkcs7(block: Buffer): Buffer | null {
  if (block.length === 0 || block.length % 16 !== 0) return null
  const pad = block[block.length - 1]
  if (pad < 1 || pad > 16 || pad > block.length) return null
  for (let i = block.length - pad; i < block.length; i += 1) {
    if (block[i] !== pad) return null
  }
  return block.subarray(0, block.length - pad)
}

/**
 * Drop the domain binding Chrome 127+ puts in front of the value.
 *
 * Left alone when it is not there, which is what an older profile and an
 * unbound cookie both look like. Comparing the hash is also the strongest
 * evidence available that the key was right.
 */
export function stripDomainHash(plain: Buffer, hostKey: string): { value: Buffer; bound: boolean } {
  if (plain.length < 32) return { value: plain, bound: false }
  const digest = createHash('sha256').update(hostKey, 'utf8').digest()
  if (!plain.subarray(0, 32).equals(digest)) return { value: plain, bound: false }
  return { value: plain.subarray(32), bound: true }
}

export type DecryptResult =
  | { ok: true; value: string; bound: boolean }
  | { ok: false; reason: 'empty' | 'unsupported-version' | 'malformed' | 'bad-key' }

/**
 * Decrypt one `encrypted_value` blob.
 *
 * `v10` is macOS and the Linux keyring; `v11` is the Linux libsecret variant and
 * uses the same scheme with a different key. `v20` is Windows app-bound
 * encryption, which needs DPAPI and an elevated COM call — refused by name
 * rather than mangled.
 */
export function decryptCookieValue(blob: Buffer, key: Buffer, hostKey: string): DecryptResult {
  if (blob.length === 0) return { ok: false, reason: 'empty' }

  const version = blob.subarray(0, 3).toString('latin1')
  if (version !== 'v10' && version !== 'v11') return { ok: false, reason: 'unsupported-version' }

  const body = blob.subarray(3)
  if (body.length === 0 || body.length % 16 !== 0) return { ok: false, reason: 'malformed' }

  let plain: Buffer
  try {
    const decipher = createDecipheriv('aes-128-cbc', key, COOKIE_IV)
    decipher.setAutoPadding(false)
    plain = Buffer.concat([decipher.update(body), decipher.final()])
  } catch {
    return { ok: false, reason: 'bad-key' }
  }

  const unpadded = unpadPkcs7(plain)
  if (!unpadded) return { ok: false, reason: 'bad-key' }

  const stripped = stripDomainHash(unpadded, hostKey)
  return { ok: true, value: stripped.value.toString('utf8'), bound: stripped.bound }
}

/* ------------------------------------------------------------- the rows -- */

/** One row of Chromium's `cookies` table, before any of it is trusted. */
export interface CookieRow {
  host_key?: unknown
  name?: unknown
  value?: unknown
  encrypted_value?: unknown
  path?: unknown
  expires_utc?: unknown
  is_secure?: unknown
  is_httponly?: unknown
  samesite?: unknown
  is_persistent?: unknown
}

/** Chromium times are microseconds since 1601-01-01 UTC. */
const CHROME_EPOCH_OFFSET_SECONDS = 11_644_473_600

/**
 * Cookie expiry, in the seconds Electron wants.
 *
 * `chrome-import.ts` has a converter already and it is deliberately not reused:
 * it rejects anything in the future as a corrupt field, which is correct for a
 * visit time and exactly wrong for an expiry, where the future is the point.
 */
export function cookieExpiryToUnixSeconds(value: unknown): number | null {
  const micros = typeof value === 'number' ? value : typeof value === 'string' ? Number(value) : NaN
  if (!Number.isFinite(micros) || micros <= 0) return null
  const seconds = Math.round(micros / 1_000_000) - CHROME_EPOCH_OFFSET_SECONDS
  return seconds > 0 ? seconds : null
}

export type SameSite = 'unspecified' | 'no_restriction' | 'lax' | 'strict'

/**
 * Chromium stores SameSite as -1 unspecified, 0 none, 1 lax, 2 strict.
 *
 * `None` is downgraded when the cookie is not Secure, because Chromium refuses
 * that combination on the way back in — the whole `cookies.set` rejects, and a
 * row that Chrome itself would never have accepted is not worth failing over.
 */
export function toSameSite(raw: unknown, secure: boolean): SameSite {
  switch (raw) {
    case 0:
      return secure ? 'no_restriction' : 'unspecified'
    case 1:
      return 'lax'
    case 2:
      return 'strict'
    default:
      return 'unspecified'
  }
}

/** What `cookies.set` is handed. Mirrors Electron's `CookiesSetDetails`. */
export interface CookieSetDetails {
  url: string
  name: string
  value: string
  domain?: string
  path: string
  secure: boolean
  httpOnly: boolean
  expirationDate?: number
  sameSite: SameSite
}

/**
 * Build the `cookies.set` payload for one decrypted row, or say why not.
 *
 * Two details decide whether the cookie behaves the same in the new browser as
 * in the old one. A `host_key` with a leading dot is a *domain* cookie and the
 * dot has to be passed through; one without is host-only, and passing a domain
 * at all would silently widen it to every subdomain — which is how a
 * `__Host-`-prefixed cookie ends up rejected. And a Secure cookie has to be set
 * through an https URL or Chromium drops it without a word.
 */
export function toCookieSetDetails(
  row: CookieRow,
  value: string,
  now: number,
): { ok: true; details: CookieSetDetails } | { ok: false; reason: 'invalid' | 'expired' } {
  const hostKey = typeof row.host_key === 'string' ? row.host_key.trim() : ''
  const name = typeof row.name === 'string' ? row.name : ''
  if (hostKey === '' || name === '') return { ok: false, reason: 'invalid' }

  const isDomainCookie = hostKey.startsWith('.')
  const host = isDomainCookie ? hostKey.slice(1) : hostKey
  if (host === '' || /[\s/]/.test(host)) return { ok: false, reason: 'invalid' }

  const secure = row.is_secure === 1 || row.is_secure === true
  const rawPath = typeof row.path === 'string' && row.path !== '' ? row.path : '/'
  const path = rawPath.startsWith('/') ? rawPath : `/${rawPath}`

  let url: string
  try {
    url = new URL(`${secure ? 'https' : 'http'}://${host}${path}`).toString()
  } catch {
    return { ok: false, reason: 'invalid' }
  }

  const persistent = row.is_persistent === 1 || row.is_persistent === true
  const expiresAt = persistent ? cookieExpiryToUnixSeconds(row.expires_utc) : null
  if (expiresAt !== null && expiresAt * 1000 <= now) return { ok: false, reason: 'expired' }

  const details: CookieSetDetails = {
    url,
    name,
    value,
    path,
    secure,
    httpOnly: row.is_httponly === 1 || row.is_httponly === true,
    sameSite: toSameSite(row.samesite, secure),
  }
  if (isDomainCookie) details.domain = hostKey
  if (expiresAt !== null) details.expirationDate = expiresAt

  return { ok: true, details }
}

/* ------------------------------------------------------------ the source -- */

/**
 * Where a profile keeps its cookies.
 *
 * `Network/Cookies` first because that is where current Chromium documents it,
 * then the flat path — which is where Chrome 151 actually has it on this
 * machine. Probing both costs one `stat` and avoids reporting a profile with
 * thousands of cookies as having none.
 */
export function cookiesFileFor(
  profilePath: string,
  exists: (path: string) => boolean = existsSync,
): string | null {
  const candidates = [join(profilePath, 'Network', 'Cookies'), join(profilePath, 'Cookies')]
  for (const candidate of candidates) {
    try {
      if (exists(candidate)) return candidate
    } catch {
      // A protected parent reports as absent, which is the same answer.
    }
  }
  return null
}

/**
 * Every profile this machine has a cookie database for.
 *
 * `detectBrowsers()` already knows where the profiles are and whether macOS is
 * letting anything be read; this only adds "and there is a cookie file in it".
 */
export function listCookieSources(
  browsers = detectBrowsers(),
  exists: (path: string) => boolean = existsSync,
): CookieSource[] {
  const out: CookieSource[] = []
  for (const browser of browsers) {
    for (const profile of browser.profiles) {
      const path = cookiesFileFor(profile.path, exists)
      if (!path) continue
      out.push({
        browserId: browser.id,
        browserName: browser.name,
        profileId: profile.id,
        profileName: profile.name,
        path,
        keychainItem: SAFE_STORAGE_ITEMS[browser.id] !== undefined,
      })
    }
  }
  return out
}

/**
 * `better-sqlite3`, loaded on demand.
 *
 * Same shape and same reason as `chrome-import.ts`: the binding is built for
 * Electron's ABI and cannot load in the Node that runs the tests, so a static
 * import would make this file unimportable from a test of its pure half.
 */
async function openCookieDatabase(file: string): Promise<ReadonlyDatabase> {
  const mod: unknown = await import('better-sqlite3')
  const candidate = (mod as { default?: unknown }).default ?? mod
  const Database = candidate as new (
    path: string,
    options?: { readonly?: boolean; fileMustExist?: boolean },
  ) => ReadonlyDatabase
  return new Database(file, { readonly: true, fileMustExist: true })
}

/**
 * A cap, not a page. A profile with more cookies than this has years of
 * tracking in it and the tail is not what anyone is signing in with.
 */
const MAX_ROWS = 20_000

/** `SELECT *` on purpose: the column set has changed across schema versions. */
const COOKIE_SQL = `SELECT * FROM cookies LIMIT ${MAX_ROWS}`

export async function readCookieRows(
  file: string,
  open: DatabaseOpener = openCookieDatabase,
): Promise<CookieRow[]> {
  const snapshot = snapshotDatabase(file)
  try {
    const db = await open(snapshot.file)
    try {
      return db.prepare(COOKIE_SQL).all() as CookieRow[]
    } finally {
      db.close()
    }
  } finally {
    // The copy is a verbatim slice of the user's session tokens. It does not
    // outlive the read, whatever happens during it.
    snapshot.dispose()
  }
}

/* --------------------------------------------------------------- ledger -- */

const LEDGER_FILE = 'browser-imported-cookies.json'

export function emptyLedger(): CookieLedger {
  return { version: 1, importedAt: null, source: '', entries: [] }
}

/** Parse a ledger off disk. A file someone edited by hand is data, not truth. */
export function parseLedger(raw: unknown): CookieLedger {
  if (typeof raw !== 'object' || raw === null) return emptyLedger()
  const record = raw as Record<string, unknown>
  const entries = Array.isArray(record.entries) ? record.entries : []
  return {
    version: 1,
    importedAt: typeof record.importedAt === 'number' ? record.importedAt : null,
    source: typeof record.source === 'string' ? record.source : '',
    entries: entries.flatMap((entry): ImportedCookieRef[] => {
      if (typeof entry !== 'object' || entry === null) return []
      const item = entry as Record<string, unknown>
      if (typeof item.name !== 'string' || typeof item.domain !== 'string') return []
      return [
        {
          name: item.name,
          domain: item.domain,
          path: typeof item.path === 'string' && item.path !== '' ? item.path : '/',
          secure: item.secure === true,
        },
      ]
    }),
  }
}

/** Key an entry by everything that makes a cookie a distinct cookie. */
export function refKey(ref: ImportedCookieRef): string {
  // NUL, not a space: a cookie path may legally contain almost anything,
  // and a separator that can appear inside a field makes two different
  // cookies share a key.
  return [ref.domain, ref.path, ref.name].join('\u0000')
}

/** Merge a fresh import into what is already recorded, without duplicates. */
export function mergeLedger(
  current: CookieLedger,
  added: readonly ImportedCookieRef[],
  source: string,
  at: number,
): CookieLedger {
  const byKey = new Map(current.entries.map((entry) => [refKey(entry), entry]))
  for (const entry of added) byKey.set(refKey(entry), entry)
  return { version: 1, importedAt: at, source, entries: [...byKey.values()] }
}

function ledgerPath(): string {
  return join(app.getPath('userData'), LEDGER_FILE)
}

function loadLedger(): CookieLedger {
  try {
    return parseLedger(JSON.parse(readFileSync(ledgerPath(), 'utf8')) as unknown)
  } catch {
    // Absent on a fresh install, and unreadable is the same answer here.
    return emptyLedger()
  }
}

function saveLedger(ledger: CookieLedger): void {
  try {
    writeFileSync(ledgerPath(), `${JSON.stringify(ledger, null, 2)}\n`, 'utf8')
  } catch {
    // Losing the ledger costs the count and the targeted clear, not the import.
    // The blanket "Clear stored browsing data" still removes everything.
  }
}

/* --------------------------------------------------------------- import -- */

export interface ImportRequest {
  browserId?: BrowserId
  profileId?: string
  /** Restrict to these hosts and their subdomains. Empty means everything. */
  domains?: string[]
}

function matchesDomain(hostKey: string, wanted: readonly string[]): boolean {
  if (wanted.length === 0) return true
  const host = hostKey.replace(/^\./, '').toLowerCase()
  return wanted.some((domain) => host === domain || host.endsWith(`.${domain}`))
}

export function normaliseDomains(raw: unknown): string[] {
  if (!Array.isArray(raw)) return []
  return raw.flatMap((entry) => {
    if (typeof entry !== 'string') return []
    const trimmed = entry.trim().replace(/^\./, '').toLowerCase()
    return trimmed === '' ? [] : [trimmed]
  })
}

/** The counts an import produced, before they become a sentence. */
export interface ImportTally {
  imported: number
  skipped: number
  failed: number
  /** How many decrypted values carried the domain binding — the key fit. */
  bound: number
  domains: Set<string>
  entries: ImportedCookieRef[]
  /** Ready for `cookies.set`, in the order they were read. */
  details: CookieSetDetails[]
}

/**
 * Turn rows into cookies to set. Pure, so the interesting half is testable
 * against fixtures rather than against the user's real profile.
 */
export function planImport(
  rows: readonly CookieRow[],
  key: Buffer,
  wanted: readonly string[],
  now: number,
): ImportTally {
  const tally: ImportTally = {
    imported: 0,
    skipped: 0,
    failed: 0,
    bound: 0,
    domains: new Set<string>(),
    entries: [],
    details: [],
  }

  for (const row of rows) {
    const hostKey = typeof row.host_key === 'string' ? row.host_key : ''
    if (hostKey === '' || !matchesDomain(hostKey, wanted)) {
      tally.skipped += 1
      continue
    }

    const blob = row.encrypted_value
    let value: string
    if (Buffer.isBuffer(blob) && blob.length > 0) {
      const decrypted = decryptCookieValue(blob, key, hostKey)
      if (!decrypted.ok) {
        tally.failed += 1
        continue
      }
      value = decrypted.value
      if (decrypted.bound) tally.bound += 1
    } else if (typeof row.value === 'string') {
      // Chromium leaves a value in the clear when encryption was unavailable at
      // write time. Rare, but it is a real row and it still signs you in.
      value = row.value
    } else {
      tally.failed += 1
      continue
    }

    const built = toCookieSetDetails(row, value, now)
    if (!built.ok) {
      if (built.reason === 'expired') tally.skipped += 1
      else tally.failed += 1
      continue
    }

    tally.details.push(built.details)
    tally.entries.push({
      name: built.details.name,
      domain: built.details.domain ?? hostKey,
      path: built.details.path,
      secure: built.details.secure,
    })
    tally.domains.add(hostKey.replace(/^\./, ''))
    tally.imported += 1
  }

  return tally
}

/** The sentence a finished import shows. Counts only — never a name or a value. */
export function importMessage(tally: ImportTally, source: string): string {
  // Checked before the "did not fit" line below, because by the time this runs
  // the set loop has already moved every rejected cookie from `imported` to
  // `failed` — so a run that decrypted perfectly and was then refused by
  // Chromium is indistinguishable from a wrong key by the counts alone.
  // `details` is what planImport produced and is never emptied, so it is the
  // one witness that decryption worked. Blaming the keychain there would send
  // someone hunting a key that was right.
  if (tally.imported === 0 && tally.details.length > 0) {
    return `Everything in ${source} decrypted, but the browser refused all ${tally.details.length} of the cookies, so nothing was carried over.`
  }
  if (tally.imported === 0 && tally.failed > 0) {
    return `Nothing could be decrypted from ${source}. The keychain key did not fit its cookie database — that happens when the profile was copied from another Mac.`
  }
  if (tally.imported === 0) {
    return `${source} had no cookies worth carrying over — everything in it had already expired.`
  }
  const parts = [
    `Imported ${tally.imported} cookie${tally.imported === 1 ? '' : 's'} across ${tally.domains.size} site${tally.domains.size === 1 ? '' : 's'} from ${source}.`,
  ]
  if (tally.failed > 0) {
    parts.push(`${tally.failed} could not be read and were left behind.`)
  }
  parts.push('Tabs set to Isolated do not see them.')
  return parts.join(' ')
}

function sourceLabel(source: CookieSource): string {
  return source.profileId === 'Default'
    ? source.browserName
    : `${source.browserName} — ${source.profileName}`
}

function pickSource(request: ImportRequest, sources: readonly CookieSource[]): CookieSource | null {
  const wanted = sources.filter(
    (source) =>
      (!request.browserId || source.browserId === request.browserId) &&
      (!request.profileId || source.profileId === request.profileId),
  )
  // Default before the numbered profiles, which is the order detectBrowsers
  // already sorted them into — so the first match is the one a user who picked
  // only a browser meant.
  return wanted[0] ?? null
}

/**
 * What to say when no profile could be picked at all.
 *
 * Two different situations reach this and only one of them is a permission:
 * a machine with no Chromium browser installed, and a machine where every
 * installed browser's data is refused. The old sentence merged them — *"No
 * installed browser with a readable cookie database was found. macOS protects
 * those files until this app has Full Disk Access."* — which reads as an
 * accusation on a machine that simply has no Chrome, and offers nothing to
 * press on the machine where the permission really is the problem.
 *
 * `browserDataAccess` already knows which it is, because `detectBrowsers` keeps
 * a blocked browser in its list precisely so this question can be answered.
 */
function noSourceMessage(platform: Platform): { message: string; pane: PrivacyPane | null } {
  const access = browserDataAccess(detectBrowsers(), platform)
  if (access.problem) return { message: access.problem.message, pane: access.problem.pane }
  return {
    message: 'No installed Chromium browser was found on this machine, so there is nothing to import from.',
    pane: null,
  }
}

function failure(
  source: CookieSource | null,
  keychain: KeychainFailure | 'ok' | null,
  message: string,
  settings: PrivacyPane | null = null,
): CookieImportReport {
  return {
    ok: false,
    browserId: source?.browserId ?? '',
    browserName: source?.browserName ?? '',
    profileId: source?.profileId ?? '',
    imported: 0,
    skipped: 0,
    failed: 0,
    domains: 0,
    keychain,
    message,
    settings,
  }
}

/**
 * Read one profile's cookies and write them into the app's browser session.
 *
 * Never throws for an expected outcome — a denied keychain, an absent profile
 * and a database that will not open all come back as a report with `ok: false`
 * and a sentence, because each one is something the user can do something about
 * and none of them is a bug.
 */
/**
 * The three machine-shaped facts an import depends on, injectable.
 *
 * Added for one assertion that cannot be made any other way: **the keychain is
 * not asked for when the file cannot be read.** That is the whole of the fix
 * below, it is invisible in a return value — a run that stops on the file and a
 * run that stops after a refused keychain both come back `ok: false` — and the
 * difference the user sees is whether macOS put a password dialog on their
 * screen. Only a spy can see that, so only a seam can test it.
 *
 * Every one of them defaults to the real thing, so production has no idea this
 * exists.
 */
export interface ImportDeps {
  /** The candidate profiles. A test needs no installed browser. */
  sources?: readonly CookieSource[]
  /** The keychain read — the prompt. A test proves it was never reached. */
  keychain?: (browserId: BrowserId, browserName: string) => Promise<KeychainResult>
  /** Whether the cookie database can be opened. See {@link canRead}. */
  readable?: (path: string) => boolean
  /**
   * Which operating system this run should answer as. Defaults to the real one.
   *
   * Here for the reason `platform/host.ts` gives at length, and it was added
   * after a real Windows CI run failed on it. A blocked import does not say the
   * same thing on every platform and must not: on macOS the refusal is a TCC
   * grant the user can give, so the sentence names Full Disk Access and carries
   * the System Settings pane that has the ＋ button in it. On Windows and Linux
   * there is no such gate — a profile directory this app cannot open there is
   * locked or owned by somebody else — so `describeAccessFailure` deliberately
   * says only that the machine refused, with no pane, because sending a Windows
   * user to a macOS security pane is an instruction for an operating system
   * they are not running.
   *
   * Without this seam the platform was read inside `describeAccessFailure` from
   * `process.platform`, so a test could only ever see the branch belonging to
   * the machine it ran on: the macOS sentence was asserted unconditionally, it
   * passed here forever, and it failed the first time the suite ran on Windows.
   * With the platform passed in, both sentences are pinned side by side on this
   * Mac and neither is a fact only a Windows runner ever checks.
   *
   * It is threaded all the way through rather than used for the message alone.
   * The keychain lives in the macOS login keychain and the key derivation uses a
   * different iteration count off macOS, so a run pinned to `win32` that still
   * asked the *real* `security` binary would be answering as two machines at
   * once.
   */
  platform?: Platform
}

export async function importCookies(
  request: ImportRequest,
  target: Session = guestSession(),
  now: number = Date.now(),
  deps: ImportDeps = {},
): Promise<CookieImportReport> {
  const platform = deps.platform ?? currentPlatform()
  const readable = deps.readable ?? canRead
  const keychainOf =
    deps.keychain ??
    ((browserId: BrowserId, browserName: string) =>
      readSafeStorageKey(browserId, browserName, platform))
  const source = pickSource(request, deps.sources ?? listCookieSources())
  if (!source) {
    const reason = noSourceMessage(platform)
    return failure(
      null,
      null,
      reason.message,
      reason.pane,
    )
  }

  const label = sourceLabel(source)

  /*
   * The file first, the keychain second. This order is the fix for the fault
   * Asad reported: *"it is not asking if it needs full access — let it ask full
   * access in that case rather than asking only this much, so it can
   * successfully import."*
   *
   * An import needs two separate permissions and they are not interchangeable.
   * The keychain one is asked by macOS with a dialog naming this app and the
   * browser's Safe Storage item; full disk access is what lets the cookie file
   * be opened at all. The run used to ask for the *keychain* first — so on a
   * machine without full disk access the user was shown a real, alarming
   * security prompt about their stored passwords, granted it, and the import
   * then died on a file it had never even tried to open. The prompt they
   * answered could not have made it succeed. That is a prompt asking for too
   * little, exactly as reported.
   *
   * `listCookieSources` cannot catch this earlier, and deliberately so: it
   * finds the database with `existsSync`, which is a `stat`, and `stat`
   * succeeds on a protected path where every read raises EPERM (measured — see
   * `chrome-import.ts`). Being able to *see* the file is not being able to read
   * it, so the check has to be a real open, and `canRead` is one.
   *
   * The keychain is still not asked for a moment earlier than it is needed,
   * which is the other half of the same principle: this asks for what the
   * operation actually requires, when it requires it, and never for more.
   */
  if (!readable(source.path)) {
    const denied = describeAccessFailure({ code: 'EPERM' }, `${label}’s cookies`, platform)
    return failure(source, null, denied.message, denied.pane)
  }

  const keychain = await keychainOf(source.browserId, source.browserName)
  if (!keychain.ok) return failure(source, keychain.reason, keychain.detail)

  const key = deriveCookieKey(keychain.secret, platform)

  let rows: CookieRow[]
  try {
    rows = await readCookieRows(source.path)
  } catch (err) {
    // Still handled, because `canRead` above proves the file could be opened a
    // moment ago and not that it can be read through to the end — a lock, a
    // revoked grant or a disk error can all land here.
    const denied = describeAccessFailure(err, `${label}’s cookie database`, platform)
    return failure(source, 'ok', denied.message, denied.pane)
  }

  const tally = planImport(rows, key, normaliseDomains(request.domains), now)
  // The derived key has done its job. Overwriting is best-effort — V8 may have
  // copied it — but leaving it intact for the life of the process is worse.
  key.fill(0)

  const written: ImportedCookieRef[] = []
  for (let i = 0; i < tally.details.length; i += 1) {
    try {
      await target.cookies.set(tally.details[i])
      written.push(tally.entries[i])
    } catch {
      // A cookie Chromium will not take back — a stale `__Host-` prefix, a
      // domain it no longer considers valid. One row, not the import.
      tally.imported -= 1
      tally.failed += 1
    }
  }
  await target.cookies.flushStore()

  // Only when something actually landed. Merging an empty list still stamps
  // `importedAt`, and a ledger that records nothing but claims a time reads in
  // the panel as "No cookies have been imported. Last imported just now." —
  // two sentences that contradict each other over one run that did nothing.
  if (written.length > 0) saveLedger(mergeLedger(loadLedger(), written, label, now))

  return {
    ok: tally.imported > 0,
    browserId: source.browserId,
    browserName: source.browserName,
    profileId: source.profileId,
    imported: tally.imported,
    skipped: tally.skipped,
    failed: tally.failed,
    domains: tally.domains.size,
    keychain: 'ok',
    message: importMessage(tally, label),
    // Nothing was blocked, so there is nothing to send anybody to.
    settings: null,
  }
}

/* ---------------------------------------------------------------- status -- */

async function statusOf(
  target: Session,
  platform: Platform = currentPlatform(),
): Promise<CookieImportStatus> {
  const ledger = loadLedger()
  const live = new Set<string>()
  try {
    for (const cookie of await target.cookies.get({})) {
      live.add(
        refKey({
          name: cookie.name,
          domain: cookie.domain ?? '',
          path: cookie.path ?? '/',
          secure: cookie.secure === true,
        }),
      )
    }
  } catch {
    // A session that cannot be read yet is not a reason to show nothing at all.
  }
  return {
    present: ledger.entries.filter((entry) => live.has(refKey(entry))).length,
    recorded: ledger.entries.length,
    importedAt: ledger.importedAt,
    source: ledger.source,
    // Through the seam, not through `process.platform` inline. Same reason as
    // everywhere else in this file: a branch written inline is a branch only
    // the machine it was written on can ever exercise. And through the shared
    // predicate rather than a fourth copy of the comparison — the settings pane
    // and the keychain read have to agree with each other or a Windows user is
    // told two different things two inches apart, which is what was happening.
    supported: cookieImportSupported(platform),
  }
}

/**
 * Remove exactly what was imported, and nothing else.
 *
 * The ledger is what makes this different from the blanket clear next to it: a
 * user who signed into a dev app *inside* this browser keeps that session, and
 * only the cookies carried in from Chrome go away.
 */
async function clearImported(target: Session): Promise<{ removed: number }> {
  const ledger = loadLedger()
  let removed = 0
  for (const entry of ledger.entries) {
    try {
      await target.cookies.remove(
        cookieRemovalUrl({
          name: entry.name,
          domain: entry.domain,
          path: entry.path,
          secure: entry.secure,
          httpOnly: false,
          session: false,
          expiresAt: null,
          valueBytes: 0,
        }),
        entry.name,
      )
      removed += 1
    } catch {
      // Already gone, or a domain that will not reconstruct into a URL.
    }
  }
  await target.cookies.flushStore()
  saveLedger(emptyLedger())
  return { removed }
}

/* -------------------------------------------------------------------- ipc -- */

/**
 * Wire the channels into the main process:
 *
 *     import { registerCookieImportIpc } from './cookie-import'
 *     registerCookieImportIpc(ipcMain)
 *
 * Channels:
 * - `cookie-import:sources` (invoke)          → {@link CookieSource}[]
 * - `cookie-import:status`  (invoke)          → {@link CookieImportStatus}
 * - `cookie-import:run`     (invoke, request) → {@link CookieImportReport}
 * - `cookie-import:clear`   (invoke)          → { removed: number }
 *
 * Nothing here returns a cookie value or the keychain key.
 */
export function registerCookieImportIpc(ipcMain: IpcMain): void {
  ipcMain.handle('cookie-import:sources', (): CookieSource[] => listCookieSources())

  ipcMain.handle('cookie-import:status', (): Promise<CookieImportStatus> => statusOf(guestSession()))

  ipcMain.handle('cookie-import:run', (_event, request: unknown): Promise<CookieImportReport> => {
    const asked = (typeof request === 'object' && request !== null ? request : {}) as Record<
      string,
      unknown
    >
    return importCookies({
      browserId: typeof asked.browserId === 'string' ? (asked.browserId as BrowserId) : undefined,
      profileId: typeof asked.profileId === 'string' ? asked.profileId : undefined,
      domains: normaliseDomains(asked.domains),
    })
  })

  ipcMain.handle('cookie-import:clear', (): Promise<{ removed: number }> =>
    clearImported(guestSession()),
  )
}
