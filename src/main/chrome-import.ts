/**
 * Chrome import — find the local dev URLs already sitting in a Chromium
 * browser's profile, so they can be opened in a Deck browser tab instead of
 * being retyped.
 *
 * Strictly read-only. Nothing here ever writes into another application's
 * profile, and every SQLite file is copied to a temp directory before it is
 * opened, because Chrome holds a lock on the live one and reading it in place
 * can leave the browser's own database in a state it did not ask for.
 *
 * Everything below was checked against the real Chrome installation on this
 * machine, and three findings changed the design:
 *
 * 1. **`stat` works where `readdir` and `read` do not.** macOS protects
 *    `~/Library/Application Support/Google/Chrome`, so `readdirSync` and
 *    `readFileSync` both fail with EPERM until the app is granted Full Disk
 *    Access — while `statSync` on a path inside it still succeeds. Discovery
 *    therefore falls back to probing known profile names by `stat`, and a
 *    profile that is found but unreadable is reported as `blocked` with an
 *    actionable note rather than silently omitted. "No profiles found" would
 *    be a lie the user could not act on.
 * 2. **Profile numbering has gaps.** This machine has `Default`, `Profile 2`
 *    and `Profile 3` — and no `Profile 1`. Any loop that stops at the first
 *    miss finds one profile out of three. It also has `Guest Profile` and
 *    `System Profile`, which are not the user's and are excluded.
 * 3. **History is a rollback-journal database, not WAL.** The real file has a
 *    `History-journal` beside it and no `-wal`, and a fresh SQLite database
 *    confirms `journal_mode = delete`. The copy takes whichever sidecars exist
 *    so the snapshot is coherent either way.
 *
 * `better-sqlite3` is loaded lazily and through an injectable opener. Its
 * native binding is compiled for Electron's ABI (145 here) and cannot be
 * loaded by the system Node that runs the tests (147), so a top-level import
 * would take down every test that so much as imported this file.
 */

import {
  closeSync,
  copyFileSync,
  mkdtempSync,
  openSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
} from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join, posix, win32 } from 'node:path'
import { currentPlatform, type Env, type Platform } from './platform/host'

/* ------------------------------------------------------------------ types -- */

export type BrowserId = 'chrome' | 'chrome-canary' | 'arc' | 'edge' | 'brave' | 'vivaldi' | 'chromium'

/** Whether we can actually read a thing we can see. */
export type AccessState = 'ok' | 'blocked' | 'missing'

export type CandidateSource = 'bookmark' | 'history' | 'session'

export type LocalReason = 'loopback' | 'local-tld' | 'private-lan' | 'named-host-port'

export interface BrowserProfile {
  browserId: BrowserId
  browserName: string
  /** Directory name — 'Default', 'Profile 3'. Stable; the display name is not. */
  id: string
  name: string
  path: string
  access: AccessState
}

export interface DetectedBrowser {
  id: BrowserId
  name: string
  userDataDir: string
  access: AccessState
  /** Set when `access` is not 'ok', in words the user can act on. */
  note?: string
  profiles: BrowserProfile[]
}

export interface DevUrl {
  url: string
  host: string
  /** Explicit port only; null when the scheme's default was used. */
  port: number | null
  title: string | null
  source: CandidateSource
  reason: LocalReason
  /** Bookmark folder path, or the visit count, depending on the source. */
  detail: string | null
  /** Unix ms. Null when the source does not carry a time. */
  lastSeen: number | null
  /**
   * Recovered by scanning a binary session file rather than parsed from a
   * documented format — present, but not something to state as fact.
   */
  approximate?: boolean
  browserId: BrowserId
  profileId: string
}

export interface ScanProblem {
  browserId: BrowserId
  profileId: string | null
  source: CandidateSource | 'profile'
  message: string
}

export interface ScanResult {
  urls: DevUrl[]
  problems: ScanProblem[]
}

export interface ScanRequest {
  /** Restrict to one browser. Omit to scan every readable one. */
  browserId?: BrowserId
  /** Restrict to one profile directory. */
  profileId?: string
  /** Defaults to all three. */
  sources?: readonly CandidateSource[]
  /** Cap on returned URLs. Defaults to 200. */
  limit?: number
}

/* -------------------------------------------------------------- browsers -- */

interface BrowserDef {
  id: BrowserId
  name: string
  /** Relative to the home directory. */
  darwin: string
  /**
   * The application bundle's name on macOS, for asking whether it is installed.
   *
   * This exists because a user-data directory is not evidence that a browser is
   * on the machine. Measured here: `/Applications` holds Google Chrome and no
   * other browser at all, `mdfind` finds no Edge, Brave, Vivaldi, Arc or
   * Chromium bundle anywhere — and yet
   * `~/Library/Application Support/Microsoft Edge` and
   * `.../BraveSoftware/Brave-Browser` both exist, left behind by installs that
   * are long gone, and both are protected by macOS so they read as EPERM rather
   * than as empty. The Browser pane consequently printed three identical Full
   * Disk Access warnings, two of them about software that is not here.
   *
   * See {@link isInstalled} for why the answer is only used to suppress a
   * warning and never to hide a browser we can actually read.
   */
  darwinApp: string
  /** Relative to the home directory. Unverified on this machine. */
  linux?: string
  /** Relative to %LOCALAPPDATA%. Unverified on this machine. */
  win32?: string
}

/**
 * Where each browser keeps its user data.
 *
 * The macOS paths are the ones confirmed present here. Arc keeps its profiles
 * under a `User Data` subdirectory, unlike the others — on this machine that
 * directory holds only `NativeMessagingHosts`, which is why a directory
 * existing is never taken as proof that a profile does.
 */
export const BROWSERS: readonly BrowserDef[] = [
  {
    id: 'chrome',
    name: 'Chrome',
    darwin: 'Library/Application Support/Google/Chrome',
    darwinApp: 'Google Chrome.app',
    linux: '.config/google-chrome',
    win32: 'Google/Chrome/User Data',
  },
  {
    id: 'chrome-canary',
    name: 'Chrome Canary',
    darwin: 'Library/Application Support/Google/Chrome Canary',
    darwinApp: 'Google Chrome Canary.app',
  },
  { id: 'arc', name: 'Arc', darwin: 'Library/Application Support/Arc/User Data', darwinApp: 'Arc.app' },
  {
    id: 'edge',
    name: 'Edge',
    darwin: 'Library/Application Support/Microsoft Edge',
    darwinApp: 'Microsoft Edge.app',
    linux: '.config/microsoft-edge',
    win32: 'Microsoft/Edge/User Data',
  },
  {
    id: 'brave',
    name: 'Brave',
    darwin: 'Library/Application Support/BraveSoftware/Brave-Browser',
    darwinApp: 'Brave Browser.app',
    linux: '.config/BraveSoftware/Brave-Browser',
    win32: 'BraveSoftware/Brave-Browser/User Data',
  },
  {
    id: 'vivaldi',
    name: 'Vivaldi',
    darwin: 'Library/Application Support/Vivaldi',
    darwinApp: 'Vivaldi.app',
    linux: '.config/vivaldi',
    win32: 'Vivaldi/User Data',
  },
  {
    id: 'chromium',
    name: 'Chromium',
    darwin: 'Library/Application Support/Chromium',
    darwinApp: 'Chromium.app',
    linux: '.config/chromium',
    win32: 'Chromium/User Data',
  },
]

/** Not the user's profiles, and both exist on a normal install. */
const EXCLUDED_PROFILE_DIRS = new Set(['System Profile', 'Guest Profile'])

/**
 * Names to probe when the directory cannot be listed. `Default` plus a run of
 * numbered profiles — the gap on this machine (no `Profile 1`, but `Profile 2`
 * and `Profile 3`) is why this probes the whole range instead of stopping at
 * the first miss.
 */
function candidateProfileDirs(): string[] {
  const names = ['Default']
  // Up to 40 because this machine's highest is `Profile 18` — the numbers
  // track how many profiles have ever been created, not how many exist.
  for (let i = 1; i <= 40; i += 1) names.push(`Profile ${i}`)
  return names
}

/** 'Profile 2' before 'Profile 13'; a plain string sort gets that backwards. */
function compareProfileIds(a: string, b: string): number {
  if (a === 'Default') return -1
  if (b === 'Default') return 1
  return a.localeCompare(b, undefined, { numeric: true })
}

/**
 * Where a browser keeps its user data on a given platform, or null when it
 * keeps none there.
 *
 * Two things are passed in rather than read, and both are the same lesson
 * `platform/host.ts` writes down at length: a decision that reads the host can
 * only ever be exercised on the host.
 *
 * - **`platform` picks the path flavour too.** Joining with the bare `join`
 *   used the *running* machine's separator, so asking for the darwin answer on
 *   Windows produced `\Users\asad\Library\Application Support\…` — a string
 *   that is neither a macOS path nor a Windows one (observed on Windows 11).
 *   Production never noticed, because there the platform asked about is the
 *   platform running; a test pinning the other one did.
 * - **The environment is an argument, not a default.** `localAppData` used to
 *   default to `process.env.LOCALAPPDATA`, and a defaulted parameter cannot be
 *   overridden with `undefined` — passing it explicitly re-triggers the
 *   default. So "LOCALAPPDATA is not set" was unpinnable on a machine that
 *   sets it, and the case returned a real directory on Windows instead of null.
 */
export function userDataDirFor(
  def: BrowserDef,
  platform: Platform = currentPlatform(),
  home: string = homedir(),
  env: Env = process.env,
): string | null {
  if (platform === 'darwin') return posix.join(home, def.darwin)
  if (platform === 'win32') {
    const localAppData = env.LOCALAPPDATA
    return def.win32 && localAppData ? win32.join(localAppData, def.win32) : null
  }
  return def.linux ? posix.join(home, def.linux) : null
}

/* ----------------------------------------------------------- url matching -- */

const LOCAL_TLDS = ['.local', '.localhost', '.test', '.internal', '.lan']

function isLoopback(host: string): boolean {
  if (host === 'localhost' || host === '::1' || host === '0.0.0.0') return true
  return /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host)
}

function isPrivateLan(host: string): boolean {
  const parts = host.split('.')
  if (parts.length !== 4 || !parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255)) return false
  const [a, b] = parts.map(Number)
  if (a === 10) return true
  if (a === 172 && b >= 16 && b <= 31) return true
  if (a === 192 && b === 168) return true
  // Link-local. Rare in a browser, but it is unambiguously not the internet.
  return a === 169 && b === 254
}

function isIpish(host: string): boolean {
  return /^[\d.]+$/.test(host) || host.includes(':')
}

/**
 * WHATWG `URL.hostname` keeps the brackets on an IPv6 literal — `[::1]`, not
 * `::1` — so every comparison against a bare address misses without this.
 * Confirmed against Node's own URL parser rather than assumed.
 */
function bareHost(hostname: string): string {
  const host = hostname.toLowerCase()
  return host.startsWith('[') && host.endsWith(']') ? host.slice(1, -1) : host
}

export interface LocalUrl {
  url: string
  host: string
  port: number | null
  reason: LocalReason
}

/**
 * Decide whether a URL points at something running on this machine or this
 * network, and say why.
 *
 * An explicit port is a signal but never on its own — `https://example.com:8443`
 * is somebody's production site, and importing it as a "dev URL" would be
 * noise at best. A port only qualifies a host with no dots in it, which is a
 * machine name on the local network (`http://devbox:5173`) rather than a
 * domain. Returns null for anything else, including non-http schemes.
 */
export function classifyLocalUrl(raw: string): LocalUrl | null {
  if (typeof raw !== 'string' || raw.length === 0) return null

  let parsed: URL
  try {
    parsed = new URL(raw)
  } catch {
    return null
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null

  const host = bareHost(parsed.hostname)
  if (!host) return null
  const port = parsed.port ? Number(parsed.port) : null

  // Credentials embedded in a URL are real credentials. History and bookmarks
  // both keep them, and everything downstream of here is displayed, logged and
  // sent across IPC — so they are dropped before the URL leaves this function.
  // The address still opens; the password just does not travel with it.
  parsed.username = ''
  parsed.password = ''

  const reason: LocalReason | null = isLoopback(host)
    ? 'loopback'
    : LOCAL_TLDS.some((tld) => host.endsWith(tld))
      ? 'local-tld'
      : isPrivateLan(host)
        ? 'private-lan'
        : port !== null && !host.includes('.') && !isIpish(host)
          ? 'named-host-port'
          : null

  if (!reason) return null
  return { url: parsed.toString(), host, port, reason }
}

/* -------------------------------------------------------------- discovery -- */

function errorCode(err: unknown): string {
  return (err as NodeJS.ErrnoException)?.code ?? 'UNKNOWN'
}

function isBlocked(err: unknown): boolean {
  const code = errorCode(err)
  return code === 'EPERM' || code === 'EACCES'
}

function exists(path: string): boolean {
  try {
    statSync(path)
    return true
  } catch {
    // EPERM from `stat` would mean the parent is unreadable too, in which case
    // there is nothing useful to say about this path either.
    return false
  }
}

/**
 * Profile display names, keyed by directory, out of `Local State`.
 * Unreadable on a machine without Full Disk Access, so the caller falls back
 * to the directory name — which is stable anyway, unlike the display name.
 */
export function parseProfileNames(raw: unknown): Record<string, string> {
  const out: Record<string, string> = {}
  if (typeof raw !== 'object' || raw === null) return out
  const profile = (raw as Record<string, unknown>).profile
  if (typeof profile !== 'object' || profile === null) return out
  const cache = (profile as Record<string, unknown>).info_cache
  if (typeof cache !== 'object' || cache === null) return out

  for (const [dir, value] of Object.entries(cache as Record<string, unknown>)) {
    if (!dir || dir === '__proto__') continue
    if (typeof value !== 'object' || value === null) continue
    const name = (value as Record<string, unknown>).name
    if (typeof name === 'string' && name.trim()) out[dir] = name.trim()
  }
  return out
}

/**
 * A directory is a profile when it contains a `Preferences` file. Checked with
 * `stat`, which keeps working under macOS's protection when reading does not —
 * so profiles are still found on a machine where nothing can be read yet, and
 * can be reported as blocked instead of missing.
 */
function looksLikeProfile(dir: string): boolean {
  return exists(join(dir, 'Preferences'))
}

/**
 * Is the browser itself on this machine, as opposed to its leftovers?
 *
 * macOS only, and non-committal by design: it answers `true` for "yes" and for
 * "cannot tell", and `false` only when the bundle is genuinely nowhere the
 * standard locations reach. A browser installed somewhere unusual must not
 * disappear from this pane because of a lookup, so the caller uses a `false`
 * *only* to stop warning about something it also cannot read — never to hide a
 * browser whose profiles it can actually see.
 *
 * `/Applications` and `~/Applications` are the two places macOS installers use.
 * A Spotlight query would find a bundle dragged elsewhere, but it means spawning
 * `mdfind` on every call from a settings pane, and it answers nothing on a
 * machine with indexing off — a slower way to be unsure.
 */
export function isInstalled(
  def: BrowserDef,
  platform: Platform = currentPlatform(),
  home: string = homedir(),
): boolean {
  if (platform !== 'darwin') return true
  return exists(join('/Applications', def.darwinApp)) || exists(join(home, 'Applications', def.darwinApp))
}

/** Every browser this machine has, with what can be reached inside it. */
export function detectBrowsers(): DetectedBrowser[] {
  const out: DetectedBrowser[] = []

  for (const def of BROWSERS) {
    const userDataDir = userDataDirFor(def)
    if (!userDataDir || !exists(userDataDir)) continue

    let names: Record<string, string> = {}
    let access: AccessState = 'ok'
    let note: string | undefined

    try {
      names = parseProfileNames(JSON.parse(readFileSync(join(userDataDir, 'Local State'), 'utf8')))
    } catch (err) {
      if (isBlocked(err)) access = 'blocked'
      else if (errorCode(err) !== 'ENOENT') note = `Could not read Local State (${errorCode(err)}).`
    }

    // Listing is the good path; probing is what still works under EPERM.
    let dirs: string[]
    try {
      dirs = readdirSync(userDataDir, { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => entry.name)
    } catch (err) {
      if (isBlocked(err)) access = 'blocked'
      dirs = candidateProfileDirs()
    }

    // Set once, after both attempts. Which of the two trips the block varies —
    // on this machine Chrome's Local State read raises EPERM while Edge's
    // reports the file as simply absent — so hanging the explanation off
    // either one alone leaves a browser marked blocked with nothing said.
    if (access === 'blocked') {
      note = describeAccessFailure({ code: 'EPERM' }, `${def.name}’s data`).message
    }

    const profiles: BrowserProfile[] = []
    for (const dir of dirs) {
      if (EXCLUDED_PROFILE_DIRS.has(dir)) continue
      const path = join(userDataDir, dir)
      if (!looksLikeProfile(path)) continue
      profiles.push({
        browserId: def.id,
        browserName: def.name,
        id: dir,
        name: names[dir] ?? dir,
        path,
        access,
      })
    }

    // `Default` first, then the numbered profiles in numeric order.
    profiles.sort((a, b) => compareProfileIds(a.id, b.id))

    // A user-data directory with no profiles in it is not a browser the user
    // has ever run — Arc leaves one behind holding only NativeMessagingHosts.
    // A blocked one is still listed, because "nothing here" would be a lie
    // when the truth is "not allowed to look".
    if (profiles.length === 0 && access !== 'blocked') continue

    /*
     * A blocked directory belonging to a browser that is not installed is a
     * leftover, and warning about it is noise the user cannot act on.
     *
     * This is the "ask what is installed before warning about it" rule, and it
     * is narrow on purpose. It only fires when *both* are true: the app is not
     * on the machine, and we could not read the directory anyway — so there is
     * nothing to lose by dropping the row, because there was nothing in it. A
     * browser whose profiles we can see stays listed no matter where its bundle
     * lives, which is what keeps an unusual install from vanishing.
     *
     * Measured here: `/Applications` holds Google Chrome and nothing else, but
     * `~/Library/Application Support/Microsoft Edge` and the Brave directory
     * both survive and both read EPERM — so this pane printed three identical
     * Full Disk Access warnings, and two of them named software that has been
     * uninstalled.
     */
    if (access === 'blocked' && !isInstalled(def)) continue

    out.push({
      id: def.id,
      name: def.name,
      userDataDir,
      access: profiles.length === 0 && access === 'ok' ? 'missing' : access,
      note,
      profiles,
    })
  }

  return out
}

/* -------------------------------------------------------------- bookmarks -- */

interface BookmarkNode {
  type?: unknown
  name?: unknown
  url?: unknown
  date_added?: unknown
  children?: unknown
}

/** Chrome stores times as microseconds since 1601-01-01 UTC. */
const CHROME_EPOCH_OFFSET_MS = 11_644_473_600_000

/** Verified against a round-trip through a real SQLite database. */
export function chromeTimeToUnixMs(value: unknown): number | null {
  const micros = typeof value === 'string' ? Number(value) : typeof value === 'number' ? value : NaN
  if (!Number.isFinite(micros) || micros <= 0) return null
  const ms = Math.round(micros / 1000) - CHROME_EPOCH_OFFSET_MS
  // Anything before Chrome existed, or far in the future, is a corrupt field.
  return ms > 0 && ms < Date.now() + 86_400_000 ? ms : null
}

export interface BookmarkHit extends LocalUrl {
  title: string | null
  /** Human-readable folder path, e.g. 'Bookmarks bar/Work'. */
  folder: string
  addedAt: number | null
}

/**
 * Walk a `Bookmarks` file and keep the local dev URLs.
 *
 * Iterative, with an explicit stack and a visit cap: the file is a tree of
 * unbounded depth written by another program, and a recursive walk over a
 * pathological one takes the main process down with a stack overflow.
 */
export function collectBookmarkUrls(raw: unknown, maxNodes = 50_000): BookmarkHit[] {
  const found: BookmarkHit[] = []
  if (typeof raw !== 'object' || raw === null) return found

  const roots = (raw as Record<string, unknown>).roots
  if (typeof roots !== 'object' || roots === null) return found

  interface Frame {
    node: BookmarkNode
    folder: string
    /** The root's own `name` is the label we already have — don't repeat it. */
    isRoot: boolean
  }

  const stack: Frame[] = []
  for (const [key, value] of Object.entries(roots as Record<string, unknown>)) {
    if (typeof value === 'object' && value !== null) {
      stack.push({ node: value as BookmarkNode, folder: prettyRoot(key), isRoot: true })
    }
  }

  let visited = 0
  while (stack.length > 0 && visited < maxNodes) {
    const { node, folder, isRoot } = stack.pop() as Frame
    visited += 1

    if (typeof node.url === 'string') {
      const local = classifyLocalUrl(node.url)
      if (local) {
        found.push({
          ...local,
          title: typeof node.name === 'string' && node.name.trim() ? node.name.trim() : null,
          folder,
          addedAt: chromeTimeToUnixMs(node.date_added),
        })
      }
      continue
    }

    if (Array.isArray(node.children)) {
      const name = !isRoot && typeof node.name === 'string' && node.name ? node.name : null
      const next = name ? `${folder}/${name}` : folder
      for (const child of node.children) {
        if (typeof child === 'object' && child !== null) {
          stack.push({ node: child as BookmarkNode, folder: next, isRoot: false })
        }
      }
    }
  }

  return found
}

function prettyRoot(key: string): string {
  const named: Record<string, string> = {
    bookmark_bar: 'Bookmarks bar',
    other: 'Other bookmarks',
    synced: 'Mobile bookmarks',
  }
  return named[key] ?? key
}

/* ---------------------------------------------------------------- history -- */

/** The slice of better-sqlite3 this module uses, so tests can supply their own. */
export interface HistoryRow {
  url: unknown
  title: unknown
  last_visit_time: unknown
  visit_count: unknown
}

export interface ReadonlyDatabase {
  prepare(sql: string): { all(): unknown[] }
  close(): void
}

export type DatabaseOpener = (file: string) => Promise<ReadonlyDatabase> | ReadonlyDatabase

type DatabaseConstructor = new (
  path: string,
  options?: { readonly?: boolean; fileMustExist?: boolean },
) => ReadonlyDatabase

/**
 * Load better-sqlite3 on demand, through a dynamic import.
 *
 * Never at module scope. The binding in this repo is compiled for Electron's
 * ABI (NODE_MODULE_VERSION 145) and the tests run on the system Node (147),
 * where constructing a Database throws ERR_DLOPEN_FAILED — a static import
 * would make this file unimportable from a test even to check a pure function.
 * `import()` also survives the main bundle being emitted as either CJS or ESM,
 * which a `require` call would not.
 */
async function defaultOpener(file: string): Promise<ReadonlyDatabase> {
  const mod: unknown = await import('better-sqlite3')
  const candidate = (mod as { default?: unknown }).default ?? mod
  const Database = candidate as DatabaseConstructor
  return new Database(file, { readonly: true, fileMustExist: true })
}

const HISTORY_SQL =
  'SELECT url, title, last_visit_time, visit_count FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT 4000'

/** Sidecars SQLite may need for a coherent snapshot; whichever exist are taken. */
const DB_SIDECARS = ['-journal', '-wal', '-shm']

/**
 * Copy a SQLite database and its sidecars to a private temp directory and hand
 * back the copy's path plus a disposer.
 *
 * The copy is the whole point: Chrome keeps `History` open, and opening the
 * live file — even read-only — is how another process ends up interfering with
 * a database the browser is mid-transaction on.
 */
export function snapshotDatabase(source: string): { file: string; dispose(): void } {
  const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-browser-'))
  const file = join(dir, 'db.sqlite')
  const dispose = () => rmSync(dir, { recursive: true, force: true })

  try {
    copyFileSync(source, file)
    for (const suffix of DB_SIDECARS) {
      const sidecar = `${source}${suffix}`
      if (exists(sidecar)) copyFileSync(sidecar, `${file}${suffix}`)
    }
  } catch (err) {
    dispose()
    throw err
  }

  return { file, dispose }
}

export async function readHistoryRows(
  file: string,
  open: DatabaseOpener = defaultOpener,
): Promise<HistoryRow[]> {
  const snapshot = snapshotDatabase(file)
  try {
    const db = await open(snapshot.file)
    try {
      return db.prepare(HISTORY_SQL).all() as HistoryRow[]
    } finally {
      db.close()
    }
  } finally {
    // The copy is deleted whatever happens — it is a verbatim slice of the
    // user's browsing history and has no business outliving the read.
    snapshot.dispose()
  }
}

/* --------------------------------------------------------------- sessions -- */

/**
 * URL-shaped runs of bytes in a Chrome session file.
 *
 * This is a scan, not a parser, and it is labelled `approximate` everywhere it
 * surfaces. Chrome's session files are SNSS: a header, then length-prefixed
 * pickled commands. Nothing here claims to understand that format — it looks
 * for `http://` and `https://` followed by characters RFC 3986 permits in a
 * URL, which stops naturally at the first byte that cannot be part of one.
 *
 * Titles are deliberately not extracted: they are pickled as UTF-16, so a
 * byte scan would produce mangled text, and a wrong title is worse than none.
 */
export function scanSessionBlob(buffer: Buffer, limit = 500): string[] {
  // latin1 maps every byte to one character, so offsets stay meaningful and no
  // byte sequence is silently replaced by U+FFFD the way utf8 would.
  const text = buffer.toString('latin1')
  const pattern = /https?:\/\/[A-Za-z0-9\-._~:/?#[\]@!$&'()*+,;=%]{1,2000}/g

  const seen = new Set<string>()
  const out: string[] = []
  for (const match of text.matchAll(pattern)) {
    // Trailing punctuation is far more often the next field's first byte than
    // part of the URL.
    const url = match[0].replace(/[.,;:'!]+$/, '')
    if (url.length < 12 || seen.has(url)) continue
    seen.add(url)
    out.push(url)
    if (out.length >= limit) break
  }
  return out
}

/**
 * The trailing timestamp of a session file name, kept as digits.
 *
 * Chrome's stamps are ~1.3e16, comfortably past `Number.MAX_SAFE_INTEGER`, so
 * `Number()` rounds neighbouring files to the same value. Comparing the digit
 * strings by length and then lexically is exact.
 */
function sessionStamp(name: string): string {
  const digits = /_(\d+)$/.exec(name)?.[1] ?? ''
  return digits.replace(/^0+(?=\d)/, '')
}

function compareStamps(a: string, b: string): number {
  if (a.length !== b.length) return a.length - b.length
  return a < b ? -1 : a > b ? 1 : 0
}

/**
 * Session files, newest first. Chrome suffixes them with a timestamp.
 *
 * Ordered by that timestamp, not by the file name: a plain descending string
 * sort puts every `Tabs_…` ahead of every `Session_…` because 'T' sorts after
 * 'S', so on a profile with four or more `Tabs_` files the `Session_` files —
 * the ones holding the open tabs — never made it past the cap.
 */
export function listSessionFiles(profilePath: string): string[] {
  const dir = join(profilePath, 'Sessions')
  let entries: string[]
  try {
    entries = readdirSync(dir)
  } catch {
    return []
  }
  return entries
    .filter((name) => name.startsWith('Session_') || name.startsWith('Tabs_'))
    .sort(
      (a, b) =>
        compareStamps(sessionStamp(b), sessionStamp(a)) ||
        b.localeCompare(a, undefined, { numeric: true }),
    )
    .slice(0, 4)
    .map((name) => join(dir, name))
}

/* ------------------------------------------------------------------- scan -- */

const DEFAULT_SOURCES: readonly CandidateSource[] = ['bookmark', 'history', 'session']
const DEFAULT_LIMIT = 200
/** A session file is a few MB at most; anything larger is not one. */
const MAX_SESSION_BYTES = 32 * 1024 * 1024

export interface ScanOptions {
  /** Injected in tests; production uses better-sqlite3. */
  openDatabase?: DatabaseOpener
  /** Injected in tests. */
  browsers?: readonly DetectedBrowser[]
}

function problem(
  browserId: BrowserId,
  profileId: string | null,
  source: CandidateSource | 'profile',
  err: unknown,
): ScanProblem {
  const code = errorCode(err)
  // Routed through the one describer so the "grant it here" wording is written
  // once. It used to say "Grant Full Disk Access to import from this browser"
  // and stop there, which named a permission without naming where it lives or
  // offering any way to get to it.
  const message = isBlocked(err)
    ? describeAccessFailure(err, 'this browser’s data').message
    : code === 'ENOENT'
      ? 'Nothing to read here.'
      : `${code}: ${err instanceof Error ? err.message : String(err)}`
  return { browserId, profileId, source, message }
}

/**
 * Whatever a caller supplied, reduced to sources this module understands.
 *
 * Both entry points are reachable from an IPC handler, so the argument is
 * renderer input: `sources` arriving as a string or a number turned
 * `sources.includes(…)` into a TypeError and rejected the whole scan, from
 * functions that both document that they never throw. A malformed request
 * falls back to the defaults; an explicitly empty one still means "nothing".
 */
function normaliseSources(value: unknown): readonly CandidateSource[] {
  if (!Array.isArray(value)) return DEFAULT_SOURCES
  return value.filter((item): item is CandidateSource =>
    DEFAULT_SOURCES.includes(item as CandidateSource),
  )
}

/** Scan one profile. Never throws — every failure lands in `problems`. */
export async function scanProfile(
  profile: BrowserProfile,
  requested: readonly CandidateSource[] = DEFAULT_SOURCES,
  options: ScanOptions = {},
): Promise<ScanResult> {
  const sources = normaliseSources(requested)
  const urls: DevUrl[] = []
  const problems: ScanProblem[] = []
  const base = { browserId: profile.browserId, profileId: profile.id }

  if (sources.includes('bookmark')) {
    try {
      const raw = JSON.parse(readFileSync(join(profile.path, 'Bookmarks'), 'utf8')) as unknown
      for (const hit of collectBookmarkUrls(raw)) {
        urls.push({
          ...base,
          url: hit.url,
          host: hit.host,
          port: hit.port,
          title: hit.title,
          source: 'bookmark',
          reason: hit.reason,
          detail: hit.folder,
          lastSeen: hit.addedAt,
        })
      }
    } catch (err) {
      if (errorCode(err) !== 'ENOENT') problems.push(problem(profile.browserId, profile.id, 'bookmark', err))
    }
  }

  if (sources.includes('history')) {
    try {
      for (const row of await readHistoryRows(join(profile.path, 'History'), options.openDatabase)) {
        if (typeof row.url !== 'string') continue
        const local = classifyLocalUrl(row.url)
        if (!local) continue
        const visits = typeof row.visit_count === 'number' ? row.visit_count : null
        urls.push({
          ...base,
          url: local.url,
          host: local.host,
          port: local.port,
          title: typeof row.title === 'string' && row.title.trim() ? row.title.trim() : null,
          source: 'history',
          reason: local.reason,
          detail: visits === null ? null : `${visits} visit${visits === 1 ? '' : 's'}`,
          lastSeen: chromeTimeToUnixMs(row.last_visit_time),
        })
      }
    } catch (err) {
      if (errorCode(err) !== 'ENOENT') problems.push(problem(profile.browserId, profile.id, 'history', err))
    }
  }

  if (sources.includes('session')) {
    for (const file of listSessionFiles(profile.path)) {
      try {
        if (statSync(file).size > MAX_SESSION_BYTES) continue
        for (const raw of scanSessionBlob(readFileSync(file))) {
          const local = classifyLocalUrl(raw)
          if (!local) continue
          urls.push({
            ...base,
            url: local.url,
            host: local.host,
            port: local.port,
            title: null,
            source: 'session',
            reason: local.reason,
            detail: 'Open tab',
            lastSeen: null,
            approximate: true,
          })
        }
      } catch (err) {
        // Chrome rotates these files constantly, so one listed a moment ago is
        // routinely gone by the time it is read. That is not a problem worth
        // showing anyone, and it is filtered here for the same reason the
        // other two sources filter it.
        if (errorCode(err) !== 'ENOENT') {
          problems.push(problem(profile.browserId, profile.id, 'session', err))
        }
      }
    }
  }

  return { urls, problems }
}

/**
 * De-duplicate by URL, keeping the most useful copy.
 *
 * The same address usually turns up in several places, and they are not
 * equally good: a bookmark carries a name the user chose, history carries a
 * timestamp, a session hit carries neither and is only a guess. Preferring the
 * richer record — and folding a title or a time in from the losers — is what
 * stops the list showing one URL three times with a different half of the
 * information each time.
 */
export function dedupeUrls(urls: readonly DevUrl[]): DevUrl[] {
  const rank: Record<CandidateSource, number> = { bookmark: 3, history: 2, session: 1 }
  const best = new Map<string, DevUrl>()

  for (const candidate of urls) {
    const key = candidate.url
    const current = best.get(key)
    if (!current) {
      best.set(key, { ...candidate })
      continue
    }
    // `winner` is always a fresh object, so it can never be reference-equal to
    // `current` — deriving the loser from that comparison silently made the
    // fold a no-op whenever the incumbent won, which is the common case: a
    // profile is scanned bookmarks-first, so the bookmark is already in the map
    // by the time history arrives with the only timestamp anyone has.
    const candidateWins = rank[candidate.source] > rank[current.source]
    const winner: DevUrl = { ...(candidateWins ? candidate : current) }
    const loser = candidateWins ? current : candidate
    winner.title = winner.title ?? loser.title
    winner.lastSeen = winner.lastSeen ?? loser.lastSeen
    // Only still a guess if every sighting was one.
    if (!candidate.approximate || !current.approximate) delete winner.approximate
    best.set(key, winner)
  }

  return [...best.values()].sort((a, b) => {
    if (a.source !== b.source) return rank[b.source] - rank[a.source]
    if (a.lastSeen !== b.lastSeen) return (b.lastSeen ?? 0) - (a.lastSeen ?? 0)
    return a.url.localeCompare(b.url)
  })
}

/** Scan every matching profile. Never throws. */
export async function scanForDevUrls(
  request: ScanRequest = {},
  options: ScanOptions = {},
): Promise<ScanResult> {
  // `request` crosses an IPC boundary, so it is whatever the renderer sent —
  // including null, which a default parameter does not cover.
  const asked: ScanRequest = typeof request === 'object' && request !== null ? request : {}
  const browsers = options.browsers ?? detectBrowsers()
  const sources = normaliseSources(asked.sources)
  // `Math.min(NaN, 2000)` is NaN and `slice(0, NaN)` is empty, so a limit that
  // is not a number used to return zero URLs rather than the default page.
  const wanted = Number(asked.limit)
  const limit = Number.isFinite(wanted)
    ? Math.max(1, Math.min(Math.floor(wanted), 2000))
    : DEFAULT_LIMIT

  const urls: DevUrl[] = []
  const problems: ScanProblem[] = []

  for (const browser of browsers) {
    if (asked.browserId && browser.id !== asked.browserId) continue
    for (const profile of browser.profiles) {
      if (asked.profileId && profile.id !== asked.profileId) continue
      // Sequential on purpose: each profile copies a database to temp, and
      // running every profile at once would multiply that disk cost for no
      // gain — the work is IO on one disk, not parallelisable compute.
      const found = await scanProfile(profile, sources, options)
      urls.push(...found.urls)
      problems.push(...found.problems)
    }
  }

  return { urls: dedupeUrls(urls).slice(0, limit), problems }
}

/* ------------------------------------------------------ the permission gate -- */

/**
 * Where macOS keeps the permission this needs, and what the pane is called.
 *
 * ## Why a URL and not a sentence
 *
 * Both modules already printed *"Grant Full Disk Access to import from it"* and
 * that is where it ended: a sentence with no way to act on it, in a list of
 * per-profile problems, after an import had already failed. Asad's note is
 * about exactly that gap — *"it is not asking if it needs full access; let it
 * ask full access in that case rather than asking only this much, so it can
 * successfully import."* An instruction a person has to carry out by hand,
 * through four levels of System Settings, is not asking.
 *
 * ## The anchor was read off this machine, not remembered
 *
 * `x-apple.systempreferences:` takes a pane bundle id and a "reveal element"
 * key, and the key is not documented anywhere Apple publishes. It is in the
 * privacy pane's own table, and on macOS 27 (26A5388g) that table says:
 *
 *     /System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex
 *       /Contents/Resources/TCCServiceList.plist
 *     …
 *     Dict {
 *         requiresAdmin = true
 *         supportsAddDeleteAction = true
 *         tcc = kTCCServiceSystemPolicyAllFiles
 *         revealElementKeyName = Privacy_AllFiles
 *         serviceName = ALL_FILES
 *     }
 *
 * So `Privacy_AllFiles` is the live name of the Full Disk Access row, and
 * `supportsAddDeleteAction` is why sending someone there is useful rather than
 * merely informative: that pane is the one with the ＋ button.
 *
 * The same binary shows `setSystemPolicyAppDataAccess` and
 * `TCCServiceSystemPolicyAllFilesView` in one file, which is macOS 27 keeping
 * the narrower *"access to data from other apps"* grants inside this same pane
 * — so this is the right destination whichever of the two the user ends up
 * granting.
 *
 * Null off macOS, and that is the honest answer rather than a gap. Windows and
 * Linux have no equivalent gate on another program's profile directory: a file
 * this app cannot read there is locked or owned by somebody else, and no
 * settings pane changes that.
 */
export interface PrivacyPane {
  url: string
  /** The pane's name, spelled the way System Settings spells it. */
  label: string
}

export function fullDiskAccessPane(platform: Platform = currentPlatform()): PrivacyPane | null {
  if (platform !== 'darwin') return null
  return {
    url: 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles',
    label: 'Privacy & Security → Full Disk Access',
  }
}

/**
 * Can this app actually open that file right now?
 *
 * `openSync` and nothing else. It is the exact syscall every read below starts
 * with, so it fails in exactly the cases they fail in, and it reads no bytes —
 * which matters because the file it is usually asked about is a cookie database
 * holding somebody's live session tokens.
 *
 * It is deliberately not `statSync`. On a protected path `stat` *succeeds*
 * while every read raises EPERM — measured on this machine, and the reason
 * `detectBrowsers` probes with `stat` in the first place — so a check built on
 * `stat` would report "fine" for precisely the machine that is about to fail.
 */
export function canRead(path: string): boolean {
  try {
    closeSync(openSync(path, 'r'))
    return true
  } catch {
    return false
  }
}

/** Why an operation on another browser's data cannot go ahead. */
export type AccessBlock =
  /** The OS refused: EPERM/EACCES. A permission, and one the user can grant. */
  | 'permission'
  /** There is nothing there. Not a permission problem and must not be dressed as one. */
  | 'missing'
  /** Something else — a lock, a corrupt file, a disk error. */
  | 'other'

export interface AccessProblem {
  block: AccessBlock
  /** One sentence for a person, naming the pane when there is one to name. */
  message: string
  /** Where to send them, or null when nothing can be opened. */
  pane: PrivacyPane | null
}

/**
 * Turn a failed read into something a screen can act on.
 *
 * The distinction that earns this function is `permission` against `missing`.
 * They look the same from the outside — no data came back — and they want
 * opposite words: one is "let me at it and it will work", the other is "there
 * is nothing here and no permission will conjure any". Saying "grant Full Disk
 * Access" for a browser that is simply not installed sends someone into a
 * security pane to fix a problem that does not exist, which is worse than
 * saying nothing.
 */
export function describeAccessFailure(
  err: unknown,
  what: string,
  platform: Platform = currentPlatform(),
): AccessProblem {
  const code = errorCode(err)
  if (code === 'ENOENT') {
    return { block: 'missing', message: `${what} is not on this machine.`, pane: null }
  }
  if (!isBlocked(err)) {
    return {
      block: 'other',
      message: `${what} could not be opened (${code}).`,
      pane: null,
    }
  }

  const pane = fullDiskAccessPane(platform)
  if (!pane) {
    // No pane to offer, so no pane is named. On Windows this is an ACL or a
    // lock, and telling somebody to grant Full Disk Access there would be an
    // instruction for an operating system they are not using.
    return {
      block: 'permission',
      message: `${what} could not be read — this machine refused access to it.`,
      pane: null,
    }
  }
  return {
    block: 'permission',
    message:
      `macOS will not let this app read ${what} until it is given full disk access. ` +
      `Open ${pane.label}, add this app, then run the import again.`,
    pane,
  }
}

/**
 * The one question worth asking before an import starts.
 *
 * Answered per browser rather than as one boolean, because macOS 27 grants
 * access to another app's data one app at a time: being able to read Chrome
 * says nothing about Edge. A caller that only wanted a yes/no can read
 * `blocked.length`, and the ones that name a browser to the user have the list
 * they need.
 */
export interface BrowserDataAccess {
  /** Installed browsers whose profile data this app can read right now. */
  readable: BrowserId[]
  /** Installed browsers that are refusing. */
  blocked: BrowserId[]
  /** Set when at least one installed browser is refusing. */
  problem: AccessProblem | null
}

export function browserDataAccess(
  browsers: readonly DetectedBrowser[] = detectBrowsers(),
  platform: Platform = currentPlatform(),
): BrowserDataAccess {
  const readable: BrowserId[] = []
  const blocked: BrowserId[] = []
  for (const browser of browsers) {
    if (browser.access === 'blocked') blocked.push(browser.id)
    else if (browser.access === 'ok') readable.push(browser.id)
  }
  if (blocked.length === 0) return { readable, blocked, problem: null }

  const names = browsers
    .filter((browser) => browser.access === 'blocked')
    .map((browser) => browser.name)
  return {
    readable,
    blocked,
    // Built through the same describer as every other failure so the wording
    // cannot drift between "before you started" and "this is why it stopped".
    problem: describeAccessFailure(
      { code: 'EPERM' },
      names.length === 1 ? `${names[0]}’s data` : `${names.join(', ')} data`,
      platform,
    ),
  }
}

/* -------------------------------------------------------------------- ipc -- */

/**
 * Opens a System Settings pane. Injected so a test never opens one.
 *
 * A function rather than a direct `shell.openExternal` because this module has
 * no Electron import and must keep it that way: its native-module comment at
 * the top is about being loadable under plain Node, and a static
 * `import { shell } from 'electron'` would take that away from every test in
 * this file.
 */
export type PaneOpener = (url: string) => Promise<void>

const openWithElectron: PaneOpener = async (url) => {
  const { shell } = await import('electron')
  await shell.openExternal(url)
}

export interface ChromeImportIpcOptions {
  openPane?: PaneOpener
  platform?: Platform
}

/**
 * Wire the channels into the main process: `registerChromeImportIpc(ipcMain)`.
 *
 * Every handler but one is a read, and the exception opens a settings pane —
 * there is deliberately still no channel that writes anywhere near another
 * browser's profile.
 */
export function registerChromeImportIpc(
  ipcMain: Electron.IpcMain,
  options: ChromeImportIpcOptions = {},
): void {
  const openPane = options.openPane ?? openWithElectron
  ipcMain.handle('chrome-import:browsers', () => detectBrowsers())
  ipcMain.handle('chrome-import:scan', (_e, request: ScanRequest = {}) => scanForDevUrls(request))
  ipcMain.handle('chrome-import:access', () => browserDataAccess(detectBrowsers(), options.platform))
  /*
   * The button that makes the sentence actionable.
   *
   * It answers with what it did rather than with nothing, because the one way
   * this can fail is the one worth telling the user about: a build on a
   * platform with no such pane. Silently doing nothing when a button is pressed
   * is the dead control the design brief forbids.
   */
  ipcMain.handle('chrome-import:open-privacy-settings', async (): Promise<{ opened: boolean }> => {
    const pane = fullDiskAccessPane(options.platform)
    if (!pane) return { opened: false }
    await openPane(pane.url)
    return { opened: true }
  })
}
