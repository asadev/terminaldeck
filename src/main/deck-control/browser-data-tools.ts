import type { BrowserId, DetectedBrowser, ScanRequest, ScanResult } from '../chrome-import'
import type {
  CookieImportReport,
  CookieImportStatus,
  CookieSource,
} from '../cookie-import'
import type { BrowserSessionInfo, CookieDomain } from '../browser-session'
import type { ProfileState } from '../browser-profiles'
import {
  actionOf,
  escalateBy,
  notASession,
  optInt,
  optStr,
  profileIdOf,
} from './browser-area-kit'
import { mayDrive } from './browser-tools'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused, type Tier } from './surface'

/**
 * `browser.data` and `browser.import` — what the browser keeps for each site,
 * and what can be brought in from Chrome.
 *
 * ## Cookies: the names, never the values
 *
 * A cookie's value is a session token: holding it is being signed in.
 * `browser-session.ts` refuses to send one even to the app's own renderer —
 * *"sending them to the renderer would put them in a React tree, in devtools,
 * and in any future crash report"* — and a tool result is a strictly worse place
 * than any of those, because it is text in another company's model's context.
 * So this tool lists cookies the way the panel does, from `CookieSummary`, which
 * has no field for a value: the site, the name, its flags, when it expires and
 * how many bytes it is. That is enough to answer "am I signed in to this site
 * here?" and "is that the cookie the login uses?", and nothing more.
 *
 * ## Clearing is `alter`, every kind of it
 *
 * Clearing cookies signs somebody out of sites; clearing site storage throws
 * away what pages saved; clearing the cache is the gentlest of the three and
 * still forgets. All three go through the gate — the house rule for anything
 * that forgets — and the one that matters most has a rule of its own carried
 * over from the panel: naming a site that is not a site is refused, never read
 * as "every site", because that misreading signs somebody out of everything.
 *
 * ## The Chrome import reads another program's logins
 *
 * `browser.import`'s `run` copies cookies out of Chrome (or Arc, Brave, Edge…)
 * into this browser's profile, which means asking the Mac's Keychain for that
 * browser's key and decrypting its cookie database. On this Mac a Keychain
 * dialog appears and a person answers it; the tool is `alter` besides, so they
 * are asked here first as well. What comes back is counts and a sentence —
 * `CookieImportReport` carries no value and no key, by construction.
 *
 * `scan` is the other half of the import panel and it is a read: it finds the
 * *local* development addresses — localhost, `.local`, a LAN address — in
 * Chrome's bookmarks, history and open tabs, so they can be opened here instead
 * of retyped. It never reports a public address, by `classifyLocalUrl`'s rule,
 * and it never writes into Chrome's profile.
 *
 * ## Who may call either
 *
 * Both are about logins, so both pass {@link mayDrive} — the person at this
 * machine, attended — and refuse an ordinary session. A paired phone asking
 * which sites this Mac is signed in to is the same question as a phone asking to
 * drive the browser, and it gets the same answer.
 */

/* --------------------------------------------------------------- the deps -- */

export interface DataToolDeps {
  profiles(): ProfileState
  info(profileId: string): Promise<BrowserSessionInfo>
  cookies(profileId: string): Promise<CookieDomain[]>
  clearCookies(site: string | null, profileId: string): Promise<{ removed: number }>
  clearStorage(site: string | null, profileId: string): Promise<{ origins: string[] }>
  clearCache(profileId: string): Promise<void>
}

export interface ImportToolDeps {
  browsers(): DetectedBrowser[]
  sources(): CookieSource[]
  status(): Promise<CookieImportStatus>
  run(request: { browserId?: BrowserId; profileId?: string; domains: string[] }): Promise<CookieImportReport>
  clear(): Promise<{ removed: number }>
  scan(request: ScanRequest): Promise<ScanResult>
}

function gate(context: ToolContext, tool: string): void {
  notASession(context, tool)
  mayDrive(context, tool)
}

/* ------------------------------------------------------------------ data -- */

const DATA_ACTIONS = ['info', 'cookies', 'clearcookies', 'clearstorage', 'clearcache'] as const
type DataAction = (typeof DATA_ACTIONS)[number]

const DATA_TIERS: Readonly<Record<DataAction, Tier>> = {
  info: 'read',
  cookies: 'read',
  clearcookies: 'alter',
  clearstorage: 'alter',
  clearcache: 'alter',
}

const DATA_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...DATA_ACTIONS], description: 'Default info.' },
    profile: { type: 'string', description: 'A profile name or id. Omit for the one switched on.' },
    site: {
      type: 'string',
      description: 'For cookies, clearcookies and clearstorage: one site, like example.com. Omit for every site.',
    },
  },
  additionalProperties: false,
}

/** A site name a person would type, or null. Refuses anything that is plainly not one. */
function siteOf(args: Record<string, unknown>): string | null {
  const site = optStr(args, 'site')
  if (site === null) return null
  const bare = site.trim().replace(/^https?:\/\//i, '').replace(/\/.*$/, '').replace(/^\./, '')
  if (!/^[a-z0-9.-]+(:\d+)?$/i.test(bare) || (!bare.includes('.') && bare !== 'localhost')) {
    throw new Refused(
      'not-permitted',
      `${site} is not a site name. Name one like example.com, or leave site out to mean every site.`,
    )
  }
  return bare.toLowerCase()
}

export function dataTools(deps: DataToolDeps): ToolSpec[] {
  const profileFrom = (args: Record<string, unknown>): { id: string; name: string } => {
    const state = deps.profiles()
    const id = profileIdOf(optStr(args, 'profile'), state.profiles, state.activeId)
    return { id, name: state.profiles.find((one) => one.id === id)?.name ?? id }
  }
  return [
    {
      id: 'browser.data',
      wire: 'browser_data',
      tier: 'read',
      title: 'What the browser keeps for each site',
      description:
        'The cookies, site storage and cache the in-app browser keeps for a profile (profile: a name or ' +
        'id; omit for the one switched on). "info" (the default) gives counts: cookies, sites, cache size ' +
        'and where it is on disk. "cookies" lists cookies by site with their names, flags, expiry and size ' +
        '— never their values (site narrows it). "clearcookies" signs the profile out of one site (site) ' +
        'or every site; "clearstorage" removes what pages saved, for one site or all; "clearcache" empties ' +
        'the cache. The three clears ask the person first.',
      index:
        'Cookies (names, never values), site storage and cache per profile: counts, list, clear.',
      inputSchema: DATA_SCHEMA,
      escalate: escalateBy(DATA_TIERS, 'info'),
      precheck: (args, context) => {
        gate(context, 'browser.data')
        actionOf(args, DATA_ACTIONS, 'info')
        profileFrom(args)
        siteOf(args)
      },
      summary: (args) => {
        const action = typeof args.action === 'string' ? args.action : 'info'
        const site = typeof args.site === 'string' && args.site !== '' ? args.site : null
        const where = typeof args.profile === 'string' && args.profile !== '' ? ` in profile ${args.profile}` : ''
        switch (action) {
          case 'clearcookies':
            return site === null
              ? `Clear every cookie${where} — this signs the browser out of every site`
              : `Clear the cookies for ${site}${where} — this signs the browser out of it`
          case 'clearstorage':
            return site === null ? `Clear every site's stored data${where}` : `Clear what ${site} stored${where}`
          case 'clearcache':
            return `Empty the browser cache${where}`
          case 'cookies':
            return `List the cookie names${site === null ? '' : ` for ${site}`}${where}`
          default:
            return `Read what the browser keeps${where}`
        }
      },
      run: async (args): Promise<ToolOutput> => {
        const action = actionOf(args, DATA_ACTIONS, 'info')
        const profile = profileFrom(args)
        const site = siteOf(args)
        switch (action) {
          case 'info': {
            const info = await deps.info(profile.id)
            return {
              value: {
                profile: profile.name,
                cookies: info.cookieCount,
                sites: info.domainCount,
                cacheBytes: info.cacheBytes,
                keptOnDisk: info.persistent,
                folder: info.storagePath,
              },
              summary: { profile: profile.id, cookies: info.cookieCount },
            }
          }
          case 'cookies': {
            const all = await deps.cookies(profile.id)
            const matches = (domain: string): boolean => {
              if (site === null) return true
              const bare = domain.replace(/^\./, '').toLowerCase()
              return bare === site || bare.endsWith(`.${site}`)
            }
            const sites = all
              .filter((group) => matches(group.domain))
              .map((group) => ({
                site: group.domain,
                persistent: group.persistent,
                // `CookieSummary` has no value field; this is every field it has.
                cookies: group.cookies.map((cookie) => ({
                  name: cookie.name,
                  path: cookie.path,
                  secure: cookie.secure,
                  httpOnly: cookie.httpOnly,
                  session: cookie.session,
                  expiresAt: cookie.expiresAt,
                  valueBytes: cookie.valueBytes,
                })),
              }))
            return {
              value: { profile: profile.name, sites },
              summary: { profile: profile.id, sites: sites.length },
            }
          }
          case 'clearcookies': {
            const done = await deps.clearCookies(site, profile.id)
            return { value: { profile: profile.name, site: site ?? 'every site', ...done }, summary: { profile: profile.id, ...done } }
          }
          case 'clearstorage': {
            const done = await deps.clearStorage(site, profile.id)
            return {
              value: { profile: profile.name, site: site ?? 'every site', cleared: done.origins.length === 0 ? 'everything' : done.origins },
              summary: { profile: profile.id },
            }
          }
          case 'clearcache': {
            await deps.clearCache(profile.id)
            return { value: { profile: profile.name, cleared: true }, summary: { profile: profile.id } }
          }
        }
        throw new Refused('not-permitted', `action must be one of: ${DATA_ACTIONS.join(', ')}`)
      },
    },
  ]
}

/* ---------------------------------------------------------------- import -- */

const IMPORT_ACTIONS = ['sources', 'status', 'run', 'clear', 'scan'] as const
type ImportAction = (typeof IMPORT_ACTIONS)[number]

const IMPORT_TIERS: Readonly<Record<ImportAction, Tier>> = {
  sources: 'read',
  status: 'read',
  run: 'alter',
  clear: 'alter',
  scan: 'read',
}

const BROWSER_IDS: readonly BrowserId[] = ['chrome', 'chrome-canary', 'arc', 'edge', 'brave', 'vivaldi', 'chromium']

const IMPORT_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...IMPORT_ACTIONS], description: 'Default sources.' },
    browser: { type: 'string', enum: [...BROWSER_IDS], description: 'For run and scan: which browser. Omit for the first found.' },
    browserProfile: { type: 'string', description: 'For run and scan: that browser’s profile folder, like Default.' },
    sites: {
      type: 'array',
      items: { type: 'string' },
      description: 'For run: only these sites’ cookies. Omit for all of them.',
    },
    limit: { type: 'integer', description: 'For scan: most addresses to return. Default 200.' },
  },
  additionalProperties: false,
}

function browserOf(args: Record<string, unknown>): BrowserId | undefined {
  const raw = optStr(args, 'browser')
  if (raw === null) return undefined
  if (!BROWSER_IDS.includes(raw as BrowserId)) {
    throw new Refused('not-permitted', `browser must be one of: ${BROWSER_IDS.join(', ')}`)
  }
  return raw as BrowserId
}

function sitesOf(args: Record<string, unknown>): string[] {
  const raw = args.sites
  if (raw === undefined || raw === null) return []
  if (!Array.isArray(raw) || raw.some((entry) => typeof entry !== 'string')) {
    throw new Refused('not-permitted', 'sites must be a list of site names')
  }
  return raw as string[]
}

export function importTools(deps: ImportToolDeps): ToolSpec[] {
  return [
    {
      id: 'browser.import',
      wire: 'browser_import',
      tier: 'read',
      title: 'Bring logins and dev pages in from Chrome',
      description:
        'The browser’s import from Chrome and other Chromium browsers on this Mac (Arc, Brave, Edge, ' +
        'Vivaldi, Chromium). "sources" (the default) lists the browsers and profiles found and which can be ' +
        'read. "run" copies that browser’s cookies into this browser’s profile that is switched on, so its ' +
        'sign-ins work here (browser, browserProfile, sites to narrow it) — the person is asked first and ' +
        'the Mac’s Keychain asks too; it answers with counts, never a value. "status" says what the last ' +
        'import left here; "clear" removes exactly the imported cookies. "scan" finds the local development ' +
        'addresses — localhost, .local, LAN — in that browser’s bookmarks, history and open tabs.',
      index:
        'Import from Chrome and other browsers: copy cookies in (asks), undo, find local dev addresses.',
      inputSchema: IMPORT_SCHEMA,
      escalate: escalateBy(IMPORT_TIERS, 'sources'),
      precheck: (args, context) => {
        gate(context, 'browser.import')
        actionOf(args, IMPORT_ACTIONS, 'sources')
        browserOf(args)
        sitesOf(args)
      },
      summary: (args) => {
        const action = typeof args.action === 'string' ? args.action : 'sources'
        const which = typeof args.browser === 'string' ? args.browser : 'Chrome'
        switch (action) {
          case 'run': {
            const sites = Array.isArray(args.sites) ? args.sites.filter((one) => typeof one === 'string') : []
            return `Copy ${sites.length === 0 ? 'every' : sites.join(', ')} cookie${sites.length === 1 ? '' : 's'} from ${which} into this browser, signing it in where ${which} is`
          }
          case 'clear':
            return `Remove the cookies imported from another browser`
          case 'scan':
            return `Look for local development addresses in ${which}`
          case 'status':
            return 'Check what the last cookie import left here'
          default:
            return 'List the browsers this one can import from'
        }
      },
      run: async (args): Promise<ToolOutput> => {
        const action = actionOf(args, IMPORT_ACTIONS, 'sources')
        switch (action) {
          case 'sources': {
            const browsers = deps.browsers().map((browser) => ({
              browser: browser.id,
              name: browser.name,
              readable: browser.access,
              ...(browser.note ? { note: browser.note } : {}),
              profiles: browser.profiles.map((profile) => ({
                browserProfile: profile.id,
                name: profile.name,
                readable: profile.access,
              })),
            }))
            const cookieSources = deps.sources().map((source) => ({
              browser: source.browserId,
              browserProfile: source.profileId,
              name: `${source.browserName} — ${source.profileName}`,
              hasKey: source.keychainItem,
            }))
            return {
              value: { browsers, cookieSources },
              summary: { browsers: browsers.length, cookieSources: cookieSources.length },
            }
          }
          case 'status': {
            const status = await deps.status()
            return { value: status, summary: { present: status.present } }
          }
          case 'run': {
            const browserId = browserOf(args)
            const profileId = optStr(args, 'browserProfile') ?? undefined
            const report = await deps.run({
              ...(browserId === undefined ? {} : { browserId }),
              ...(profileId === undefined ? {} : { profileId }),
              domains: sitesOf(args),
            })
            if (!report.ok) throw new Refused('not-permitted', report.message)
            return {
              value: {
                browser: report.browserName,
                imported: report.imported,
                skipped: report.skipped,
                failed: report.failed,
                sites: report.domains,
                message: report.message,
              },
              summary: { imported: report.imported, failed: report.failed },
            }
          }
          case 'clear': {
            const done = await deps.clear()
            return { value: done, summary: done }
          }
          case 'scan': {
            const browserId = browserOf(args)
            const profileId = optStr(args, 'browserProfile') ?? undefined
            const result = await deps.scan({
              ...(browserId === undefined ? {} : { browserId }),
              ...(profileId === undefined ? {} : { profileId }),
              limit: optInt(args, 'limit', 200, 1, 500),
            })
            return {
              value: {
                addresses: result.urls.map((url) => ({
                  url: url.url,
                  title: url.title,
                  from: url.source,
                  why: url.reason,
                  lastSeen: url.lastSeen,
                  ...(url.approximate ? { approximate: true } : {}),
                })),
                problems: result.problems.map((problem) => problem.message),
              },
              summary: { addresses: result.urls.length, problems: result.problems.length },
            }
          }
        }
        throw new Refused('not-permitted', `action must be one of: ${IMPORT_ACTIONS.join(', ')}`)
      },
    },
  ]
}

