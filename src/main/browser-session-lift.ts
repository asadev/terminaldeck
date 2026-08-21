import { randomUUID } from 'node:crypto'
import type { Cookie, Session, WebContents } from 'electron'
import type { CookieSetDetails, SameSite } from './cookie-import'

/**
 * Lifting one signed-in session into every worker profile.
 *
 * ## The problem this is the only answer to
 *
 * Many sites permit exactly **one** login at a time, and his do. Seven of his
 * profiles carried a byte-identical session token, and signing in separately on
 * each would have invalidated the six before it — so "one profile per worker"
 * and "log in per profile" are mutually exclusive on the very targets a worker
 * pool exists for.
 *
 * The way out is the one Electron hands over directly: the person signs in
 * **once**, in a window they are watching, and that session is copied into the
 * worker jars. `session.fromPartition(x).cookies.get` on the one, `.set` on the
 * others. Where the site keeps its token in `localStorage` rather than in a
 * cookie there is no jar API at all, and it has to be reached through a page —
 * see {@link STORAGE_READ_SCRIPT} and `browser-seed-preload.ts`.
 *
 * ## This is a security boundary, and here is where the line is
 *
 * A tool that copies a logged-in session between profiles is also a tool that
 * exfiltrates a login. The rule this file is built around, stated so that
 * anybody widening it has to argue with the reason rather than with the code:
 *
 *  - **Lifting is human-initiated.** {@link liftFromPage} is reachable from one
 *    place — an `ipcMain` handler behind a button in the browser panel, on the
 *    page the person is looking at. `deck-control` has no tool that reaches it,
 *    and `session-tools.ts` states in its own comment why no such tool is on
 *    the session allow-list. An agent that needs a login **asks**, through the
 *    handover banner that already exists (`browser.handover`), and the ask is a
 *    sentence on the person's screen. There is no code path from a model's
 *    string to this function.
 *  - **Injecting is automatic, once the lift has happened.** The scope was
 *    decided at the moment the person pressed the button — this host, this
 *    profile, these workers — so copying it onwards is bookkeeping rather than
 *    a second decision. Asking again per worker would be the confirmation
 *    fatigue `consent.ts` refuses to build.
 *
 * ## Values never leave the main process
 *
 * `browser-session.ts` established the rule for the cookie panel and its words
 * are the ones that apply here: *"those values are session tokens, the literal
 * credentials"*. So a {@link Lift} lives in a module-level map in **memory
 * only** — never a file, never `settings.json`, never an IPC reply — and
 * everything that crosses to the renderer, to a log line or to a tool goes
 * through {@link summariseLift}, which carries counts and cookie *names* and no
 * value of any kind. Names are already what the cookie panel shows.
 *
 * A lift also expires ({@link LIFT_TTL_MS}). A live credential held in a
 * process that runs for weeks is a worse thing to hold than one held for an
 * hour, and the injection it exists for happens in the seconds after the press.
 */

/* ------------------------------------------------------------------ shape -- */

/** One page's web storage, as read out of it. Values included — see the header. */
export interface StorageBundle {
  entries: [string, string][]
  /** True when the read stopped at a cap rather than at the end. */
  truncated: boolean
}

export interface LiftedStorage {
  origin: string
  local: StorageBundle
  session: StorageBundle
}

/** A lifted session. **Never serialised, never sent anywhere.** */
export interface Lift {
  id: string
  takenAt: number
  expiresAt: number
  /** The profile the person was signed in on. */
  sourceProfileId: string
  sourceProfileName: string
  /** The host they were on, which is the scope of everything below. */
  host: string
  origin: string
  cookies: CookieSetDetails[]
  storage: LiftedStorage | null
}

/** Everything about a lift that is safe to show, log or hand to a tool. */
export interface LiftSummary {
  id: string
  takenAt: number
  expiresAt: number
  sourceProfileId: string
  sourceProfileName: string
  host: string
  origin: string
  cookieCount: number
  /**
   * The names, in order, and no values.
   *
   * Shown rather than withheld because the person pressing this button needs to
   * see that `sessionid` and `cf_clearance` are in the set and that nothing
   * else is — the difference between "it copied the login" and "it copied a
   * consent banner's preference cookie" is exactly this list. Capped so a site
   * with two hundred cookies does not turn a dialog into a wall.
   */
  cookieNames: string[]
  cookieNamesTruncated: boolean
  /** How many `localStorage` / `sessionStorage` keys came with it. */
  localKeys: number
  sessionKeys: number
  storageTruncated: boolean
}

export const MAX_SHOWN_COOKIE_NAMES = 24

/**
 * How long a lifted session is held before it is dropped.
 *
 * Fifteen minutes. The injection it exists for happens in the seconds after the
 * press; the rest of the window is for a person who mints another worker and
 * wants it to get the same session without signing in again. Anything longer is
 * a live credential sitting in a long-lived process for no purpose that was
 * asked for.
 */
export const LIFT_TTL_MS = 15 * 60_000

/**
 * How long a queued storage seed waits for a page to exist.
 *
 * Longer than the lift, deliberately, and the asymmetry is the argument. A lift
 * is a *whole* session sitting in memory able to be injected anywhere; a seed
 * is one partition, one origin, one-shot, already decided. What it has to
 * survive is a person pressing Inject and then going to open a tab in each
 * worker — which is a few minutes of clicking, and fifteen is uncomfortably
 * close to it.
 *
 * An hour, and it is visible the whole time: {@link pendingSeeds} is what the
 * Workers panel prints as *"waiting for …"*, so a seed that lapses is a row
 * that stops saying it rather than a key that quietly never arrives.
 */
export const SEED_TTL_MS = 60 * 60_000

/* --------------------------------------------------------------- the scope -- */

export type ScopeAnswer =
  | { ok: true; host: string; origin: string }
  | { ok: false; reason: string }

/**
 * What a lift is *about*, taken from the page's own address.
 *
 * The host is not a parameter anywhere in this feature, and that is a
 * deliberate narrowing: the person is looking at a page, and the scope of what
 * they are agreeing to copy is that page's site. A free-text host field would
 * let a lift be aimed at a site nobody was looking at, which is the same
 * capability wearing a friendlier shape.
 */
export function scopeFromUrl(url: unknown): ScopeAnswer {
  if (typeof url !== 'string' || url.trim() === '') {
    return { ok: false, reason: 'there is no page open to take a session from' }
  }
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return { ok: false, reason: 'that page’s address could not be read' }
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    return { ok: false, reason: 'only a page on http or https has a session to take' }
  }
  const host = parsed.hostname.toLowerCase()
  if (host === '') return { ok: false, reason: 'that page has no site to take a session from' }
  return { ok: true, host, origin: parsed.origin }
}

/* -------------------------------------------------------------- the cookies -- */

/**
 * Would this cookie be sent to that host?
 *
 * Chromium's own rule, in the two shapes a jar stores: a **host-only** cookie
 * matches its host exactly, and a **domain** cookie matches that domain and
 * everything under it. Getting this wrong in the tight direction loses the
 * login (`.example.com` cookies dropped for `app.example.com`); getting it
 * wrong in the loose direction copies cookies for sites the person was not
 * looking at, which is the whole thing this feature has to be careful about.
 *
 * Electron reports `hostOnly` on a read cookie, and the leading-dot convention
 * is the fallback for a shape that does not — the two disagree only on cookies
 * neither Chromium nor this code would produce.
 */
export function cookieAppliesTo(cookie: Pick<Cookie, 'domain' | 'hostOnly'>, host: string): boolean {
  const raw = (cookie.domain ?? '').trim().toLowerCase()
  if (raw === '' || host === '') return false
  const hostOnly = cookie.hostOnly === true || (cookie.hostOnly === undefined && !raw.startsWith('.'))
  const bare = raw.startsWith('.') ? raw.slice(1) : raw
  if (bare === '') return false
  if (hostOnly) return bare === host
  return host === bare || host.endsWith(`.${bare}`)
}

/**
 * A read cookie, turned back into something `cookies.set` will accept.
 *
 * Three details decide whether the cookie behaves in the worker exactly as it
 * did in the window, and all three are the ones `cookie-import.ts` learned the
 * hard way importing from Chrome:
 *
 *  - a **domain** cookie has to be passed as a domain or it silently narrows to
 *    one host; a **host-only** one must not be given a domain at all, or it
 *    widens to every subdomain and a `__Host-`-prefixed cookie is rejected
 *    outright;
 *  - a **Secure** cookie has to be set through an `https` URL or Chromium drops
 *    it without a word;
 *  - `SameSite=None` on a cookie that is not Secure is a combination Chromium
 *    refuses, and the refusal fails the whole `set` rather than the field.
 *
 * A **session** cookie — no `expirationDate` — is copied as a session cookie,
 * which is the case that matters most here: that is what a "logged in until you
 * close the browser" site gives you, and it is exactly the one an importer that
 * only handled persistent cookies would drop on the floor.
 */
export function toSetDetails(cookie: Cookie, now: number): CookieSetDetails | null {
  const name = typeof cookie.name === 'string' ? cookie.name : ''
  const raw = (cookie.domain ?? '').trim().toLowerCase()
  if (name === '' || raw === '') return null

  const isDomainCookie = raw.startsWith('.') || cookie.hostOnly === false
  const bare = raw.startsWith('.') ? raw.slice(1) : raw
  if (bare === '' || /[\s/]/.test(bare)) return null

  const secure = cookie.secure === true
  const rawPath = typeof cookie.path === 'string' && cookie.path !== '' ? cookie.path : '/'
  const path = rawPath.startsWith('/') ? rawPath : `/${rawPath}`

  let url: string
  try {
    url = new URL(`${secure ? 'https' : 'http'}://${bare}${path}`).toString()
  } catch {
    return null
  }

  const expiresAt =
    typeof cookie.expirationDate === 'number' && Number.isFinite(cookie.expirationDate)
      ? cookie.expirationDate
      : null
  // An expired cookie is not a login, and setting one is a no-op that would
  // still be counted as "copied" in the report. Dropped, and counted as dropped.
  if (expiresAt !== null && expiresAt * 1000 <= now) return null

  const details: CookieSetDetails = {
    url,
    name,
    value: typeof cookie.value === 'string' ? cookie.value : '',
    path,
    secure,
    httpOnly: cookie.httpOnly === true,
    sameSite: normaliseSameSite(cookie.sameSite, secure),
  }
  if (isDomainCookie) details.domain = raw.startsWith('.') ? raw : `.${bare}`
  if (expiresAt !== null) details.expirationDate = expiresAt
  return details
}

function normaliseSameSite(raw: unknown, secure: boolean): SameSite {
  switch (raw) {
    case 'no_restriction':
      return secure ? 'no_restriction' : 'unspecified'
    case 'lax':
      return 'lax'
    case 'strict':
      return 'strict'
    default:
      return 'unspecified'
  }
}

/* -------------------------------------------------------------- the storage -- */

/**
 * How much web storage one lift will carry.
 *
 * A session token is a few hundred bytes. A site that has cached its whole
 * catalogue in `localStorage` is not something to copy into eight profiles, and
 * a cap that is hit is **reported** rather than silently applied — a "session"
 * that is 40% of a session is the shape of failure this whole round is about:
 * 58% of every image was discarded by a resize nobody was told about.
 */
export const MAX_STORAGE_KEYS = 200
export const MAX_STORAGE_BYTES = 256 * 1024

/**
 * A world of its own, not the driver's.
 *
 * `browser-driver.ts` uses 31017 and its scripts leave things in it. Sharing a
 * world would mean this read could see, and be seen by, a drive that was in
 * progress on the same page — which is not a security hole (both are this
 * repository's own code) but is exactly the sort of coupling that makes a
 * failure in one look like a bug in the other.
 */
export const LIFT_WORLD = 31_019

/**
 * Read `localStorage` and `sessionStorage` out of a page.
 *
 * **No arguments and no interpolation.** Unlike `browser-drive-script.ts`,
 * which takes a selector, there is nothing a caller contributes to this string
 * at all — the scope is the page's own origin, read inside the page. So there
 * is no `withArgs`, no token and nothing to escape.
 *
 * It runs in an isolated world, which shares the page's storage (that is what
 * makes it work) but not the page's globals (which is what stops a site that
 * has redefined `Storage.prototype.getItem` from lying about what is in it).
 * `Object.getOwnPropertyDescriptor` is not used for that: the caps are the
 * defence, and a site that returns endless keys hits them.
 */
export const STORAGE_READ_SCRIPT = `(function () {
  var MAX_KEYS = ${MAX_STORAGE_KEYS};
  var MAX_BYTES = ${MAX_STORAGE_BYTES};
  function grab(store) {
    var out = [];
    var bytes = 0;
    try {
      var n = store.length;
      for (var i = 0; i < n; i++) {
        if (out.length >= MAX_KEYS) return { entries: out, truncated: true };
        var k = store.key(i);
        if (typeof k !== 'string') continue;
        var v = store.getItem(k);
        if (typeof v !== 'string') continue;
        bytes += k.length + v.length;
        if (bytes > MAX_BYTES) return { entries: out, truncated: true };
        out.push([k, v]);
      }
    } catch (e) {
      /* A partition with storage blocked, or a page that threw. What was read
         so far is still true; the flag says it is not everything. */
      return { entries: out, truncated: true };
    }
    return { entries: out, truncated: false };
  }
  var empty = { entries: [], truncated: false };
  try {
    return {
      origin: String(window.location.origin),
      local: grab(window.localStorage),
      session: grab(window.sessionStorage),
    };
  } catch (e) {
    return { origin: '', local: empty, session: empty };
  }
})()`

/**
 * What came back from the page, read the way every other `unknown` is read.
 *
 * The page is not a trust boundary here — the script is this repository's own
 * and runs in an isolated world — but the *value* crosses from a renderer, and
 * a malformed one must produce an empty bundle rather than throw inside a
 * button press.
 */
export function readStorageBundle(raw: unknown): StorageBundle {
  const value = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
  const list = Array.isArray(value.entries) ? value.entries : []
  const entries: [string, string][] = []
  for (const entry of list) {
    if (!Array.isArray(entry) || entry.length < 2) continue
    const [key, item] = entry
    if (typeof key !== 'string' || typeof item !== 'string' || key === '') continue
    if (entries.length >= MAX_STORAGE_KEYS) return { entries, truncated: true }
    entries.push([key, item])
  }
  return { entries, truncated: value.truncated === true }
}

/* ------------------------------------------------------------- the summary -- */

export function summariseLift(lift: Lift): LiftSummary {
  const names = lift.cookies.map((cookie) => cookie.name)
  return {
    id: lift.id,
    takenAt: lift.takenAt,
    expiresAt: lift.expiresAt,
    sourceProfileId: lift.sourceProfileId,
    sourceProfileName: lift.sourceProfileName,
    host: lift.host,
    origin: lift.origin,
    cookieCount: names.length,
    cookieNames: names.slice(0, MAX_SHOWN_COOKIE_NAMES),
    cookieNamesTruncated: names.length > MAX_SHOWN_COOKIE_NAMES,
    localKeys: lift.storage?.local.entries.length ?? 0,
    sessionKeys: lift.storage?.session.entries.length ?? 0,
    storageTruncated:
      lift.storage?.local.truncated === true || lift.storage?.session.truncated === true,
  }
}

/**
 * The one sentence a person reads before deciding.
 *
 * Written here so the dialog, the log line and the panel's status row all say
 * the same thing. It names the site, the profile it came from and what is in
 * it, because "copy your session" with no detail is a button nobody can judge.
 */
export function liftLine(summary: LiftSummary, workerCount: number): string {
  const bits = [`${summary.cookieCount} cookie${summary.cookieCount === 1 ? '' : 's'}`]
  if (summary.localKeys > 0) bits.push(`${summary.localKeys} stored key${summary.localKeys === 1 ? '' : 's'}`)
  if (summary.sessionKeys > 0) bits.push(`${summary.sessionKeys} session key${summary.sessionKeys === 1 ? '' : 's'}`)
  return `${bits.join(', ')} for ${summary.host}, from ${summary.sourceProfileName}, into ${workerCount} worker${workerCount === 1 ? '' : 's'}.`
}

/* ---------------------------------------------------------------- the vault -- */

/**
 * Lifted sessions, in memory, for fifteen minutes.
 *
 * A `Map` and not a store: nothing here is written to disk at any point, and
 * there is no code in this file that could. See the header.
 */
const vault = new Map<string, Lift>()

function sweepVault(now: number): void {
  for (const [id, lift] of vault) {
    if (lift.expiresAt <= now) vault.delete(id)
  }
}

export function liftById(id: unknown, now = Date.now()): Lift | null {
  sweepVault(now)
  return typeof id === 'string' ? (vault.get(id) ?? null) : null
}

export function liftSummaries(now = Date.now()): LiftSummary[] {
  sweepVault(now)
  return [...vault.values()].map(summariseLift)
}

export function forgetLift(id: unknown): void {
  if (typeof id === 'string') vault.delete(id)
}

/** For tests, and for a sign-out that should not leave a credential behind. */
export function forgetAllLifts(): void {
  vault.clear()
}

/* ----------------------------------------------------------------- the lift -- */

export interface LiftSource {
  /** The page the person is looking at. Its URL is the scope. */
  page: Pick<WebContents, 'getURL' | 'executeJavaScriptInIsolatedWorld'>
  /** The jar behind that page. */
  jar: Pick<Session, 'cookies'>
  profileId: string
  profileName: string
}

export type LiftResult =
  | { ok: true; summary: LiftSummary }
  | { ok: false; reason: string }

/**
 * Take the session out of the page the person is looking at.
 *
 * Called from **one** place: the `ipcMain` handler behind the Workers panel's
 * button. It is not exported to `deck-control`, and the reason is in the header
 * — this is the human gesture, and a function an agent can reach is not one.
 *
 * Nothing is refused for being empty. A site with no cookies for its own host
 * is a real state (an SPA that keeps everything in `localStorage`), and so is a
 * page with no web storage, so the two are counted separately and the *sum*
 * being zero is what makes this an honest failure rather than a silent one: a
 * lift that found nothing says so and stores nothing, instead of handing back
 * an id that would inject nothing into eight profiles and report success.
 * Three of his scripts reported success while doing nothing; this is the same
 * failure, and it is refused by hand.
 */
export async function liftFromPage(source: LiftSource, now = Date.now()): Promise<LiftResult> {
  const scope = scopeFromUrl(safeUrl(source.page))
  if (!scope.ok) return { ok: false, reason: scope.reason }

  let all: Cookie[]
  try {
    all = await source.jar.cookies.get({})
  } catch {
    return { ok: false, reason: 'that profile’s cookies could not be read' }
  }

  const cookies: CookieSetDetails[] = []
  for (const cookie of all) {
    if (!cookieAppliesTo(cookie, scope.host)) continue
    const details = toSetDetails(cookie, now)
    if (details !== null) cookies.push(details)
  }

  let storage: LiftedStorage | null = null
  try {
    const raw = (await source.page.executeJavaScriptInIsolatedWorld(LIFT_WORLD, [
      { code: STORAGE_READ_SCRIPT },
    ])) as unknown
    const value = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
    const local = readStorageBundle(value.local)
    const session = readStorageBundle(value.session)
    if (local.entries.length > 0 || session.entries.length > 0) {
      storage = { origin: scope.origin, local, session }
    }
  } catch {
    /*
     * A page that would not run the script — a Chromium error document, a
     * frame that navigated underneath us. The cookies are still real, so this
     * is not a failure of the lift; it is one half of it being absent, which is
     * what the summary's `localKeys: 0` says.
     */
  }

  if (cookies.length === 0 && storage === null) {
    return {
      ok: false,
      reason: `nothing was signed in for ${scope.host} in this profile — no cookies and no stored keys. Sign in on this page first, then lift.`,
    }
  }

  const lift: Lift = {
    id: randomUUID(),
    takenAt: now,
    expiresAt: now + LIFT_TTL_MS,
    sourceProfileId: source.profileId,
    sourceProfileName: source.profileName,
    host: scope.host,
    origin: scope.origin,
    cookies,
    storage,
  }
  vault.set(lift.id, lift)
  return { ok: true, summary: summariseLift(lift) }
}

function safeUrl(page: Pick<WebContents, 'getURL'>): string {
  try {
    return page.getURL()
  } catch {
    return ''
  }
}

/* ------------------------------------------------------------ the injection -- */

/** One worker, as the injection needs it. */
export interface InjectTarget {
  profileId: string
  name: string
  partition: string
  jar: Pick<Session, 'cookies'>
}

/** What happened to one worker. Counts, never values. */
export interface InjectReport {
  profileId: string
  name: string
  cookiesSet: number
  cookiesRefused: number
  /** Keys queued for the next time that worker opens the origin. See below. */
  storageQueued: number
  /** The one sentence a row prints. Empty when everything landed. */
  note: string
}

/**
 * Web storage that is waiting for a page to exist.
 *
 * ## Why this is queued rather than written
 *
 * `localStorage` is per-origin storage inside a renderer. Electron exposes no
 * API to write it from the main process — `session.clearStorageData` can empty
 * it and nothing can fill it — so the only way in is *through a page on that
 * origin*, and a worker profile has no page open at the moment somebody presses
 * a button.
 *
 * The obvious answer is a hidden window, and it is refused. A hidden window is
 * the beginning of headless, and headless is the single thing every target this
 * feature exists for answers with a 403; a path that quietly creates one would
 * be a capability regression wearing the shape of a convenience. So the seed
 * waits, and `browser-seed-preload.ts` applies it in the frame the person's own
 * next page load creates.
 *
 * ## And why the panel says "queued" rather than "done"
 *
 * Because it is queued. A worker that never visits the origin never gets the
 * keys, and the row keeps saying so until it does. A cookie is copied
 * immediately and a stored key is not, and reporting them as one number would
 * be a screen that claims a thing that has not happened yet — the exact fault
 * of a resume ledger that skipped 48,473 assets and exited reporting success.
 */
interface Seed {
  partition: string
  origin: string
  local: [string, string][]
  session: [string, string][]
  expiresAt: number
}

/** `<partition> <origin>` → seed. Memory only, like the vault. */
const seeds = new Map<string, Seed>()

function seedKey(partition: string, origin: string): string {
  return `${partition} ${origin}`
}

/**
 * The seed for one partition and origin, taken **once**.
 *
 * Removed as it is handed over rather than after the page confirms, and that is
 * the safer of the two orders: a confirmation that never arrives — the frame
 * navigated away, the renderer died — would otherwise leave a live credential
 * in this map until its TTL, ready to be handed to the next frame on that
 * origin. Losing a seed costs one re-lift; keeping one costs a credential
 * sitting in memory nobody is waiting for.
 */
export function takeSeed(partition: string, origin: string, now = Date.now()): Seed | null {
  for (const [key, seed] of seeds) {
    if (seed.expiresAt <= now) seeds.delete(key)
  }
  const key = seedKey(partition, origin)
  const seed = seeds.get(key)
  if (!seed) return null
  seeds.delete(key)
  return seed
}

/** What is still waiting, for a panel that has to say "queued" honestly. */
export function pendingSeeds(now = Date.now()): { partition: string; origin: string; keys: number }[] {
  const out: { partition: string; origin: string; keys: number }[] = []
  for (const [key, seed] of seeds) {
    if (seed.expiresAt <= now) {
      seeds.delete(key)
      continue
    }
    out.push({
      partition: seed.partition,
      origin: seed.origin,
      keys: seed.local.length + seed.session.length,
    })
  }
  return out
}

export function forgetAllSeeds(): void {
  seeds.clear()
}

/* ---------------------------------------------------------- what went where -- */

/**
 * Which hosts have been injected into which partition, **this run only**.
 *
 * Deliberately not persisted, and the direction of the error is the reason. A
 * persistent cookie survives a restart and a session cookie does not, so a
 * record written to disk would come back claiming a worker is signed in when
 * half of what signed it in has evaporated. Held in memory, the record simply
 * goes quiet after a restart: the panel and the tools say nothing rather than
 * saying something that may be false, and the person re-lifts. Under-claiming
 * costs one press. Over-claiming costs an agent an hour on a worker that is
 * signed out and looks identical to one that is not.
 *
 * No values here either — a host and a time.
 */
const injected = new Map<string, Map<string, number>>()

function noteInjection(partition: string, host: string, at: number): void {
  const forPartition = injected.get(partition) ?? new Map<string, number>()
  forPartition.set(host, at)
  injected.set(partition, forPartition)
}

/** The hosts a worker has been signed into this run, newest first. */
export function injectionsFor(partition: string): { host: string; at: number }[] {
  const forPartition = injected.get(partition)
  if (!forPartition) return []
  return [...forPartition.entries()]
    .map(([host, at]) => ({ host, at }))
    .sort((a, b) => b.at - a.at)
}

export function forgetAllInjections(): void {
  injected.clear()
}

/**
 * Copy a lift into every worker it names.
 *
 * Cookies go in immediately, one `set` at a time, and a refusal is **counted**
 * rather than thrown: Chromium rejects individual cookies for reasons that are
 * per-cookie (a `__Host-` prefix with a domain, a `None` that is not Secure),
 * and one of those must not abandon the other forty. A worker that got 39 of 40
 * cookies is a fact the report carries; a worker that got an exception is one
 * that silently has none.
 *
 * `register` is called once per target that has web storage to seed, and it is
 * how the preload gets attached to that partition. It is a parameter rather
 * than an import so this function can be driven in a test with no Electron —
 * and so that a build where the preload could not be written injects cookies
 * anyway and says the storage did not go, rather than failing the whole lift.
 */
export async function injectLift(input: {
  lift: Lift
  targets: readonly InjectTarget[]
  register?: (partition: string) => boolean
  now?: number
}): Promise<InjectReport[]> {
  const now = input.now ?? Date.now()
  const reports: InjectReport[] = []

  for (const target of input.targets) {
    let set = 0
    let refused = 0
    for (const details of input.lift.cookies) {
      try {
        await target.jar.cookies.set(details)
        set += 1
      } catch {
        refused += 1
      }
    }

    let queued = 0
    const notes: string[] = []
    const storage = input.lift.storage
    if (storage !== null) {
      const seeded = input.register?.(target.partition) ?? false
      if (seeded) {
        seeds.set(seedKey(target.partition, storage.origin), {
          partition: target.partition,
          origin: storage.origin,
          local: storage.local.entries,
          session: storage.session.entries,
          expiresAt: now + SEED_TTL_MS,
        })
        queued = storage.local.entries.length + storage.session.entries.length
        notes.push(`${queued} stored key${queued === 1 ? '' : 's'} will be written the next time this worker opens ${storage.origin}`)
      } else {
        // Never silent. A build that cannot seed storage has copied the cookies
        // and nothing else, and a site that keeps its token in `localStorage`
        // will simply not be signed in — which the person has to be told, or
        // they will spend an hour on a worker that looks identical to one that
        // worked.
        notes.push('stored keys could not be queued in this build, so a site that keeps its token in localStorage will not be signed in here')
      }
    }
    if (refused > 0) notes.push(`${refused} cookie${refused === 1 ? '' : 's'} refused by Chromium`)

    /*
     * Recorded only when something actually landed.
     *
     * A worker where every cookie was refused and no key could be queued has
     * not been signed into anything, and writing it down as though it had is
     * the shape of the failure that shipped 7% of a dataset as complete.
     */
    if (set > 0 || queued > 0) noteInjection(target.partition, input.lift.host, now)

    reports.push({
      profileId: target.profileId,
      name: target.name,
      cookiesSet: set,
      cookiesRefused: refused,
      storageQueued: queued,
      note: notes.join('; '),
    })
  }

  return reports
}
