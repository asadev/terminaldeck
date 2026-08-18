import { existsSync } from 'node:fs'
import { app, type Cookie, type IpcMain, type Session } from 'electron'
import { activeProfile, activeProfileSession } from './browser-profiles'

/**
 * The embedded browser's session: the thing that makes a login survive a
 * restart, and the controls for throwing it away again.
 *
 * ## Persistence is the whole point, and it was verified
 *
 * `persist:` partitions write to `<userData>/Partitions/<name>` and outlive the
 * process. That is a claim worth checking rather than repeating, so it was:
 * on Electron 41.10.5, a cookie and a `localStorage` entry written by one app
 * process were both still there for a second, freshly launched process reading
 * the same partition — `isPersistent()` true, storage path
 * `<userData>/Partitions/terminaldeck-browser`. The per-origin zoom factor persisted
 * too, which is why zoom is not restored by hand anywhere in this feature.
 *
 * One thing that check also settled: cookies can still be in memory when a
 * process ends, so anything that *writes* a cookie flushes the store. Reads do
 * not need to.
 *
 * ## Cookie values never leave this module
 *
 * The panel needs to show what a site has stored and let the user throw it
 * away. It does not need the values, and those values are session tokens — the
 * literal credentials that keep the user logged in. Sending them to the
 * renderer would put them in a React tree, in devtools, and in any future crash
 * report. {@link summarizeCookie} exists to make that a rule rather than a habit.
 *
 * The partition name is duplicated from `browser-tab.ts`, which creates the
 * views. `session.fromPartition` returns the same object for the same string,
 * so both modules hold the same session — but the two constants have to stay
 * equal, and there is a test in this repo's spirit for exactly that in
 * `browser-session.test.ts`.
 */

/** Must equal `GUEST_PARTITION` in `browser-tab.ts`. */
export const GUEST_PARTITION = 'persist:terminaldeck-browser'

/* ------------------------------------------------------------------ types -- */

/** A cookie as the UI is allowed to see it. Note the absence of `value`. */
export interface CookieSummary {
  name: string
  domain: string
  path: string
  secure: boolean
  httpOnly: boolean
  /** True when it dies with the browser, false when it is written to disk. */
  session: boolean
  /** Seconds since the epoch, or null for a session cookie. */
  expiresAt: number | null
  /** How many bytes the value takes, so "big" is visible without showing it. */
  valueBytes: number
}

export interface CookieDomain {
  domain: string
  cookies: CookieSummary[]
  /** How many of them survive a restart. */
  persistent: number
}

export interface BrowserSessionInfo {
  partition: string
  persistent: boolean
  /** Where on disk the partition lives, or '' when Electron reports none. */
  storagePath: string
  /** False until the first page has actually been loaded in this partition. */
  storageExists: boolean
  cookieCount: number
  domainCount: number
  cacheBytes: number
}

/* -------------------------------------------------------------- the session -- */

/**
 * The guest session — now *the profile that is switched on*, not a fixed one.
 *
 * The signature did not change and neither did anything about the callers, and
 * that is the point: everything in this file, plus `cookie-import.ts` and the
 * `isGuest` check in `browser-view.ts`, asks this question and now gets an
 * answer that follows the profile. Without that the cookie panel would keep
 * showing the default profile's cookies while the person browsed in another one
 * — a panel confidently reporting somebody else's logins.
 *
 * `browser-profiles.ts` mints and hardens the session; `session.fromPartition`
 * returns the same object for the same string, so this is still one session per
 * partition and not a new one per call.
 */
export function guestSession(): Session {
  return activeProfileSession(app.getPath('userData'))
}

/** Which profile the panel is talking about, so a screen can name it. */
export function guestProfileName(): string {
  return activeProfile(app.getPath('userData')).name
}

/**
 * Make sure the active profile's session exists and is hardened before any page
 * loads.
 *
 * This used to write and register the flow recorder's preload itself. That work
 * moved into `browser-profiles.ts`, because a preload registered on one session
 * is not registered on the others — so a second profile would have looked like
 * it was recording and captured nothing, which is the exact trap
 * `browser-isolation.ts` documents for isolated tabs. Registering it in the one
 * place that mints sessions is the only arrangement where that cannot happen
 * again.
 *
 * The call stays, and is still made before the first window is created, because
 * hardening has to be in place before a page can ask for a camera.
 */
export function registerRecorderPreload(): void {
  guestSession()
}

/* ---------------------------------------------------------------- cookies -- */

/** Strip a cookie down to what may be shown. Never returns the value. */
export function summarizeCookie(cookie: Cookie): CookieSummary {
  const value = typeof cookie.value === 'string' ? cookie.value : ''
  return {
    name: cookie.name,
    domain: cookie.domain ?? '',
    path: cookie.path ?? '/',
    secure: cookie.secure === true,
    httpOnly: cookie.httpOnly === true,
    session: cookie.session === true,
    expiresAt: typeof cookie.expirationDate === 'number' ? cookie.expirationDate : null,
    valueBytes: Buffer.byteLength(value, 'utf8'),
  }
}

/**
 * The URL `cookies.remove()` wants.
 *
 * It takes a URL rather than a domain, and reconstructing one is fiddly enough
 * to get wrong quietly: a leading dot means "and every subdomain" and is not
 * part of the host, the path belongs in the URL or a `/admin`-scoped cookie is
 * missed, and the scheme has to be https for a Secure cookie or the removal
 * silently matches nothing.
 */
export function cookieRemovalUrl(cookie: CookieSummary): string {
  const host = cookie.domain.replace(/^\./, '')
  const scheme = cookie.secure ? 'https' : 'http'
  const path = cookie.path.startsWith('/') ? cookie.path : `/${cookie.path}`
  return `${scheme}://${host}${path}`
}

/** Group by domain, biggest first, so the list opens on what matters. */
export function groupCookies(cookies: CookieSummary[]): CookieDomain[] {
  const byDomain = new Map<string, CookieSummary[]>()
  for (const cookie of cookies) {
    const key = cookie.domain || '(no domain)'
    const list = byDomain.get(key)
    if (list) list.push(cookie)
    else byDomain.set(key, [cookie])
  }
  return [...byDomain.entries()]
    .map(([domain, list]) => ({
      domain,
      cookies: [...list].sort((a, b) => a.name.localeCompare(b.name)),
      persistent: list.filter((c) => !c.session).length,
    }))
    .sort((a, b) => b.cookies.length - a.cookies.length || a.domain.localeCompare(b.domain))
}

/**
 * `clearStorageData` wants `scheme://host:port`. A domain on its own is not an
 * origin, and passing one clears nothing at all — silently, which is the worst
 * way for a "clear my data" button to fail.
 */
export function storageOrigin(domain: unknown): string | null {
  if (typeof domain !== 'string') return null
  const trimmed = domain.trim().replace(/^\./, '')
  if (!trimmed) return null
  try {
    const url = new URL(/^https?:\/\//.test(trimmed) ? trimmed : `https://${trimmed}`)
    return url.origin
  } catch {
    return null
  }
}

/**
 * Every origin a domain could have stored data under.
 *
 * `storageOrigin` has to guess a scheme, and it guesses https — which is right
 * for the URL it returns and wrong for the button that uses it. `clearStorageData`
 * matches an origin *exactly*: `https://example.com` and `http://example.com` are
 * two separate stores, and clearing one leaves the other untouched. A cookie
 * domain carries no scheme, so a per-site Clear driven off the cookie list would
 * wipe the https half of a site and silently keep the http half — including on
 * a plain-http dev server, which is most of what this panel ever sees.
 *
 * So both are cleared, unless the caller named a scheme itself and meant it.
 * The port has the same problem and no fix from here: cookie domains do not
 * carry one, so data stored by `http://localhost:3000` is only reachable when
 * the caller passes that origin in full.
 */
export function storageOrigins(domain: unknown): string[] {
  if (typeof domain !== 'string') return []
  const trimmed = domain.trim().replace(/^\./, '')
  if (!trimmed) return []
  const explicit = /^https?:\/\//.test(trimmed)
  try {
    const secure = new URL(explicit ? trimmed : `https://${trimmed}`).origin
    if (explicit) return [secure]
    const plain = new URL(`http://${trimmed}`).origin
    return plain === secure ? [secure] : [secure, plain]
  } catch {
    return []
  }
}

/* --------------------------------------------------------------- register -- */

/** Everything `clearStorageData` knows about, so "clear storage" means it. */
const ALL_STORAGES = [
  'cookies',
  'filesystem',
  'indexdb',
  'localstorage',
  'shadercache',
  'websql',
  'serviceworkers',
  'cachestorage',
] as const

/**
 * Wire the guest session's controls. Call once from `registerIpc()`:
 *
 *     import { registerBrowserSessionIpc } from './browser-session'
 *     registerBrowserSessionIpc(ipcMain)
 *
 * Channels:
 * - `browser-session:info`          (invoke)                 → {@link BrowserSessionInfo}
 * - `browser-session:cookies`       (invoke)                 → {@link CookieDomain}[]
 * - `browser-session:clear-cookies` (invoke, domain?)        → { removed: number }
 * - `browser-session:clear-storage` (invoke, domain?)        → { origins: string[] }
 * - `browser-session:clear-cache`   (invoke)                 → void
 */
export function registerBrowserSessionIpc(ipcMain: IpcMain): void {
  registerRecorderPreload()

  ipcMain.handle('browser-session:info', async (): Promise<BrowserSessionInfo> => {
    const ses = guestSession()
    const cookies = await ses.cookies.get({})
    const storagePath = ses.getStoragePath() ?? ''
    return {
      partition: GUEST_PARTITION,
      persistent: ses.isPersistent(),
      storagePath,
      // A partition directory is created on first use, so "not there yet" is
      // the honest answer for a fresh install rather than an error.
      storageExists: storagePath !== '' && existsSync(storagePath),
      cookieCount: cookies.length,
      domainCount: new Set(cookies.map((c) => c.domain ?? '')).size,
      cacheBytes: await ses.getCacheSize(),
    }
  })

  ipcMain.handle('browser-session:cookies', async (): Promise<CookieDomain[]> => {
    const cookies = await guestSession().cookies.get({})
    return groupCookies(cookies.map(summarizeCookie))
  })

  ipcMain.handle('browser-session:clear-cookies', async (_event, domain: unknown) => {
    const ses = guestSession()
    const wanted = typeof domain === 'string' && domain.trim() !== '' ? domain.trim() : null
    // `cookies.get({ domain })` also matches subdomains, which is what a user
    // clearing "example.com" means, so the filter is left to Electron.
    const cookies = await ses.cookies.get(wanted ? { domain: wanted } : {})

    let removed = 0
    for (const cookie of cookies) {
      const summary = summarizeCookie(cookie)
      try {
        await ses.cookies.remove(cookieRemovalUrl(summary), summary.name)
        removed++
      } catch {
        // A cookie can be gone already, or carry a domain that will not
        // reconstruct into a URL. Neither is worth failing the whole clear.
      }
    }
    // Removals live in memory until flushed, and this one has to survive a
    // crash: a "cleared" that comes back after a restart is worse than an error.
    await ses.cookies.flushStore()
    return { removed }
  })

  ipcMain.handle('browser-session:clear-storage', async (_event, domain: unknown) => {
    const ses = guestSession()
    const origins = storageOrigins(domain)
    // Only a *missing* argument means "everything". Anything else that failed to
    // become an origin — an empty string, a number, an object the bridge did not
    // expect — is a caller that meant one site and would otherwise have every
    // site on the machine signed out on its behalf, silently and irreversibly.
    if (domain !== undefined && domain !== null && origins.length === 0) {
      throw new Error('browser-session: that is not a site this can clear')
    }
    if (origins.length === 0) {
      await ses.clearStorageData({ storages: [...ALL_STORAGES] })
    } else {
      for (const origin of origins) {
        await ses.clearStorageData({ origin, storages: [...ALL_STORAGES] })
      }
    }
    await ses.cookies.flushStore()
    return { origins }
  })

  ipcMain.handle('browser-session:clear-cache', async () => {
    await guestSession().clearCache()
  })
}
