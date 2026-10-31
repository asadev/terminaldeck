import { existsSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import type { IpcMain } from 'electron'
import { writeFileAtomic } from './atomic-write'

/**
 * Where this browser has been — one list per profile, on disk, clickable.
 *
 * ## Why there was none
 *
 * There was no history store, no history UI and no `browser-history:*` channel
 * in any build before this one. `history` in this subsystem only ever meant
 * `webContents.navigationHistory` — the Back and Forward buttons, which are
 * per-tab and die with the tab. Asad read Chrome's ⋮ menu out loud with ours
 * open beside it:
 *
 *   > *"I need most of them, and passwords history also."*
 *   > *"Then I need proper downloads folder and all of this stuff, history,
 *   > save passwords and all of this."*
 *
 * ## Why it is not in `settings.json`
 *
 * That store is the wrong shape and the wrong place, both. Wrong shape:
 * `settings-extra.ts` takes **primitives only**, capped at `MAX_KEYS = 500` and
 * `MAX_STRING_LENGTH = 4096`, and it says why — a settings file is a list of
 * small choices, not a document store. Wrong place: `settings.read` is a
 * copilot tool (`deck-control/catalogue.ts`), so an agent holding it can read
 * that whole bag. Where somebody has been is not a preference and it is not an
 * agent's business, so it lives in its own file beside `browser-profiles.json`,
 * which is where the thing it belongs to lives.
 *
 * ## Why a profile owns its history
 *
 * A profile here is a real Chromium partition — its own cookie jar, storage and
 * cache (`browser-profiles.ts`). Two profiles exist so two people, or two
 * personas, can use the same window without seeing each other's session, and a
 * shared history would hand back exactly what the partition keeps apart. So
 * every row carries the `profileId` it was recorded under and every read takes
 * one, the same discipline `browser-passwords.ts` applies to logins.
 *
 * **An Isolated tab records nothing.** Its partition is in memory and dies with
 * the tab (`browser-isolation.ts`), and its `profileId` is the empty string —
 * the same marker that stops a saved login ever being offered to it. A tab that
 * throws its cookies away and keeps a permanent record of where it went would be
 * a private mode that is not one.
 *
 * ## One row per address, not one per visit
 *
 * Chrome keeps every visit and groups them by day. This keeps the **last** visit
 * to each address in a profile, with a count. The store is a flat file read into
 * memory at first use, so the honest limit is the size of that file rather than
 * the size of a database, and one row per address makes {@link MAX_ENTRIES} a
 * number of *places* rather than a number of *reloads* — a page refreshed forty
 * times would otherwise push forty other sites out. Both facts are kept because
 * the address bar ranks on both: see {@link suggestFor}.
 */

/* ------------------------------------------------------------------ shape -- */

/** One address, in one profile, as it was last seen. */
export interface Visit {
  /** The profile whose partition the page was loaded in. Never `''`. */
  profileId: string
  url: string
  /** The page's own title, or `''` when it never announced one. */
  title: string
  /** Milliseconds since the epoch, of the most recent visit. */
  visitedAt: number
  /** How many times this address has been landed on. At least 1. */
  visits: number
}

/**
 * How many addresses a profile keeps.
 *
 * A number of places rather than a number of days: an expiry in days throws away
 * the site somebody visits once a year and keeps a thousand rows of a dev server
 * from this morning, and it is the first kind that is hard to find again. 3000
 * rows is around 300 kB of JSON, which is a file this module can read whole at
 * first use without anybody noticing.
 */
export const MAX_ENTRIES = 3000

/** Longer than this is a `data:` URL somebody pasted, not a page. */
export const MAX_URL = 2048

/** Longer than this is a document, not a title. */
export const MAX_TITLE = 300

/**
 * The address a visit is filed under, or null when it is not one to remember.
 *
 * http and https only — the same boundary `browser-passwords.ts` draws, and for
 * a related reason: `about:blank`, `data:` and the app's own start page are not
 * places, and a history whose first three rows are `about:blank` is a list
 * nobody reads twice. Plain http stays, because localhost is plain http and a
 * dev server is the most common page this browser will ever see.
 */
export function visitableUrl(url: unknown): string | null {
  if (typeof url !== 'string' || url.trim() === '' || url.length > MAX_URL) return null
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null
    if (parsed.hostname === '') return null
    return parsed.href
  } catch {
    return null
  }
}

/**
 * A title as it can be drawn on one row.
 *
 * Control characters are stripped rather than escaped, for the reason
 * `cleanProfileName` gives: a newline in the middle of a row is a rendering bug
 * whose cause is invisible to the person looking at it.
 */
export function cleanTitle(raw: unknown): string {
  if (typeof raw !== 'string') return ''
  const flat = raw.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim()
  return flat.length > MAX_TITLE ? flat.slice(0, MAX_TITLE) : flat
}

/**
 * Read a stored file into a list, dropping anything that is not a visit.
 *
 * Defensive even though this app wrote the file, the same discipline `readLogins`
 * and `readProfileState` apply: a row with no URL cannot be clicked, and a row
 * with no profile would appear in every profile's list — the one thing this
 * store exists to never do.
 */
export function readVisits(raw: unknown): Visit[] {
  if (typeof raw !== 'object' || raw === null) return []
  const value = raw as Record<string, unknown>
  const list = Array.isArray(value.entries) ? value.entries : []
  const out: Visit[] = []
  for (const entry of list) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    const url = visitableUrl(record.url)
    const profileId = typeof record.profileId === 'string' ? record.profileId : ''
    if (url === null || profileId === '') continue
    out.push({
      profileId,
      url,
      title: cleanTitle(record.title),
      visitedAt: typeof record.visitedAt === 'number' ? record.visitedAt : 0,
      visits: typeof record.visits === 'number' && record.visits > 0 ? Math.floor(record.visits) : 1,
    })
  }
  return out
}

/**
 * Put a visit in, or move the row it already has.
 *
 * A title that arrives empty does **not** wipe the one already stored. Titles
 * arrive after the navigation that carries them — `did-navigate` fires with the
 * URL and `page-title-updated` some milliseconds later — so the first record of
 * any page has no title, and a redirect back onto a page would otherwise blank a
 * row that had a good one.
 *
 * Trimming happens here rather than at save time, so the list in memory and the
 * file on disk are never two different lengths.
 */
export function noteVisit(
  list: readonly Visit[],
  entry: { profileId: string; url: string; title: string; visitedAt: number },
  limit = MAX_ENTRIES,
): Visit[] {
  const existing = list.find((item) => item.profileId === entry.profileId && item.url === entry.url)
  const rest = existing ? list.filter((item) => item !== existing) : [...list]
  const next: Visit = {
    profileId: entry.profileId,
    url: entry.url,
    title: entry.title === '' && existing ? existing.title : entry.title,
    visitedAt: entry.visitedAt,
    visits: existing ? existing.visits + 1 : 1,
  }
  const all = [next, ...rest]
  if (all.length <= limit) return all
  // Oldest out of the door first, whatever profile it belongs to. A cap per
  // profile would let a profile nobody opens hold rows that a profile in daily
  // use has just lost.
  return [...all].sort((a, b) => b.visitedAt - a.visitedAt).slice(0, limit)
}

/** Everything matching `query` in one profile, newest first. */
export function historyFor(
  list: readonly Visit[],
  profileId: string,
  query = '',
  limit = 500,
): Visit[] {
  const needle = query.trim().toLowerCase()
  return list
    .filter((item) => item.profileId === profileId)
    .filter(
      (item) =>
        needle === '' ||
        item.url.toLowerCase().includes(needle) ||
        item.title.toLowerCase().includes(needle),
    )
    .sort((a, b) => b.visitedAt - a.visitedAt)
    .slice(0, limit)
}

/* ----------------------------------------------------------- the omnibox -- */

/**
 * The address as somebody would have typed it: whole, without its scheme, and
 * without `www.`.
 *
 * That is the whole judgement here — a person reaching for `github.com/asadev`
 * types `git`, never `htt`. These are the forms {@link scoreVisit} matches a
 * prefix against, and the forms the renderer completes inline.
 */
export function typedForms(url: string): string[] {
  const bare = url.replace(/^https?:\/\//i, '')
  const noWww = bare.replace(/^www\./i, '')
  return noWww === bare ? [url, bare] : [url, bare, noWww]
}

/**
 * How well a stored visit answers what is being typed, or 0 for not at all.
 *
 * Ordered by how confident the match is rather than by string distance, because
 * the top row is the one that gets completed inline and a wrong guess there
 * fights the person typing:
 *
 *  4. the address, shorn of scheme and `www.`, starts with what was typed —
 *     the row Chrome fills in for you.
 *  3. the whole address starts with it, so somebody who did type `https://`
 *     gets the same treatment.
 *  2. the title starts with it.
 *  1. either contains it anywhere — which is how a search run once before comes
 *     back from a word in the middle of its title.
 */
export function scoreVisit(item: Visit, typed: string): number {
  const needle = typed.trim().toLowerCase()
  if (needle === '') return 0
  const url = item.url.toLowerCase()
  const title = item.title.toLowerCase()
  const forms = typedForms(url)
  if (forms.slice(1).some((form) => form.startsWith(needle))) return 4
  if (url.startsWith(needle)) return 3
  if (title.startsWith(needle)) return 2
  if (url.includes(needle) || title.includes(needle)) return 1
  return 0
}

/**
 * What the address bar should offer for what has been typed so far.
 *
 * Score first, then how often the place has been visited, then how recently.
 * Visits before recency deliberately: an address bar is used to *return*
 * somewhere, and the page somebody opens every day beats the one they opened
 * once an hour ago even though the second is newer.
 */
export function suggestFor(
  list: readonly Visit[],
  profileId: string,
  typed: string,
  limit = 8,
): Visit[] {
  const scored: { item: Visit; score: number }[] = []
  for (const item of list) {
    if (item.profileId !== profileId) continue
    const score = scoreVisit(item, typed)
    if (score > 0) scored.push({ item, score })
  }
  scored.sort(
    (a, b) =>
      b.score - a.score || b.item.visits - a.item.visits || b.item.visitedAt - a.item.visitedAt,
  )
  return scored.slice(0, limit).map((entry) => entry.item)
}

/* ----------------------------------------------------------- persistence -- */

export function historyPath(userData: string): string {
  return join(userData, 'browser-history.json')
}

/**
 * In memory for the life of the process, written through on a short delay.
 *
 * Every navigation and every title change is a change, and a page whose title
 * ticks — a timer, an unread count — would otherwise be a file write a second,
 * forever. The delay coalesces those; {@link flushHistory} makes quitting exact.
 * A crash loses at most {@link WRITE_DELAY} of browsing, which is the right
 * trade against rewriting 300 kB because a title changed by one digit.
 */
const WRITE_DELAY = 400

let cache: Visit[] | null = null
let cacheDir: string | null = null
let pending: ReturnType<typeof setTimeout> | null = null

/** For tests, which must not inherit each other's store. */
export function resetHistoryForTests(): void {
  if (pending) clearTimeout(pending)
  pending = null
  cache = null
  cacheDir = null
}

export function allVisits(userData: string): Visit[] {
  if (cache !== null && cacheDir === userData) return cache
  cacheDir = userData
  const path = historyPath(userData)
  if (!existsSync(path)) {
    cache = []
    return cache
  }
  try {
    cache = readVisits(JSON.parse(readFileSync(path, 'utf8')) as unknown)
  } catch {
    // A file this app cannot read is the same as no file, from here. The
    // alternative is a browser panel that will not open because a JSON file has
    // a stray comma in it — the trap `readProfileState` names.
    cache = []
  }
  return cache
}

function write(userData: string, list: readonly Visit[]): void {
  const path = historyPath(userData)
  mkdirSync(dirname(path), { recursive: true })
  writeFileAtomic(path, JSON.stringify({ version: 1, entries: list }, null, 2))
}

function schedule(userData: string): void {
  if (pending) return
  pending = setTimeout(() => {
    pending = null
    try {
      write(userData, cache ?? [])
    } catch {
      // A history that could not be written is not worth a dialog: nothing else
      // in the app is blocked by it, and the next visit tries again.
    }
  }, WRITE_DELAY)
}

/** Write anything the delay is still holding. Called on the way out of the app. */
export function flushHistory(): void {
  if (pending) {
    clearTimeout(pending)
    pending = null
  }
  if (cache === null || cacheDir === null) return
  try {
    write(cacheDir, cache)
  } catch {
    /* see `schedule` */
  }
}

/**
 * Record a page that has just been landed on.
 *
 * Answers whether it was recorded, so its one caller does not have to carry a
 * second copy of this module's rules about which pages count.
 */
export function rememberVisit(
  userData: string,
  entry: { profileId: unknown; url: unknown; title?: unknown },
  now = Date.now(),
): boolean {
  // The empty profile id is an Isolated tab. See the note at the top of the file.
  if (typeof entry.profileId !== 'string' || entry.profileId === '') return false
  const url = visitableUrl(entry.url)
  if (url === null) return false
  cache = noteVisit(allVisits(userData), {
    profileId: entry.profileId,
    url,
    title: cleanTitle(entry.title),
    visitedAt: now,
  })
  cacheDir = userData
  schedule(userData)
  return true
}

/** Drop one address from one profile's history. */
export function forgetVisit(userData: string, profileId: unknown, url: unknown): Visit[] {
  const next = allVisits(userData).filter(
    (item) => !(item.profileId === profileId && item.url === url),
  )
  cache = next
  cacheDir = userData
  schedule(userData)
  return next
}

/** Drop a whole profile's history, and nobody else's. */
export function clearHistory(userData: string, profileId: unknown): Visit[] {
  const next = allVisits(userData).filter((item) => item.profileId !== profileId)
  cache = next
  cacheDir = userData
  schedule(userData)
  return next
}

/* -------------------------------------------------------------- register -- */

/**
 * Wire browsing history. Call once from `registerIpc()`:
 *
 *     import { registerBrowserHistoryIpc } from './browser-history'
 *     registerBrowserHistoryIpc(ipcMain, () => app.getPath('userData'))
 *
 * Channels:
 * - `browser-history:list`    (invoke, profileId, query?) → {@link Visit}[]
 * - `browser-history:suggest` (invoke, profileId, typed)  → {@link Visit}[]
 * - `browser-history:forget`  (invoke, profileId, url)    → that profile's list
 * - `browser-history:clear`   (invoke, profileId)         → that profile's list
 */
export function registerBrowserHistoryIpc(ipcMain: IpcMain, userData: () => string): void {
  const asId = (value: unknown): string => (typeof value === 'string' ? value : '')

  ipcMain.handle('browser-history:list', (_event, profileId: unknown, query: unknown) =>
    historyFor(allVisits(userData()), asId(profileId), typeof query === 'string' ? query : ''),
  )

  ipcMain.handle('browser-history:suggest', (_event, profileId: unknown, typed: unknown) =>
    suggestFor(allVisits(userData()), asId(profileId), typeof typed === 'string' ? typed : ''),
  )

  ipcMain.handle('browser-history:forget', (_event, profileId: unknown, url: unknown) =>
    historyFor(forgetVisit(userData(), asId(profileId), url), asId(profileId)),
  )

  ipcMain.handle('browser-history:clear', (_event, profileId: unknown) =>
    historyFor(clearHistory(userData(), asId(profileId)), asId(profileId)),
  )
}
