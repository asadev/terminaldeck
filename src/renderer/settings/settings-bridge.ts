/**
 * The slice of the preload bridge the settings window uses, and the narrowing
 * that turns its `unknown` answers into something a control can render.
 *
 * Two constraints shape this file.
 *
 * Everything crosses the bridge as `unknown` — the main-process modules own
 * their types and duplicating them in `shared/types.ts` lets the two drift — so
 * each shape is mirrored here and parsed on arrival, the way `BrowserTab.tsx`
 * mirrors the browser types.
 *
 * And every method is optional. The preload is wired by the orchestrator after
 * these files land, and several sections depend on channels that may not exist
 * yet in a given build. A section that finds its method missing says so in one
 * sentence; the alternative is a dialog that throws on open.
 */

import type { SettingValues } from './settings-schema'

/* -------------------------------------------------------------- sections -- */

/** What every section is handed. Uniform so the shell can render them in a map. */
export interface SectionProps {
  values: SettingValues
  /** Optimistic — the shell applies the patch locally, then persists it. */
  save(patch: Record<string, unknown>): void
  bridge: SettingsBridge
  /** True until the stored values have arrived; controls stay disabled. */
  loading: boolean
  /** Jump to another section — for the places where one setting lives in two. */
  goTo(section: string): void
  /** Re-read both stores from disk. For anything that writes behind `save`. */
  reload(): void
}

/* ------------------------------------------------------------ mirrored -- */

export interface StoredSettingsPayload {
  version: number
  values: Record<string, unknown>
}

/** Mirrors `ConfigPath` in `src/main/settings-extra.ts`. */
export interface ConfigPath {
  key: string
  label: string
  purpose: string
  path: string
  kind: 'file' | 'folder'
  exists: boolean
}

export interface OpenPathResult {
  opened: boolean
  path: string | null
  message: string
}

export interface UpdateChannel {
  packaged: boolean
  feedPresent: boolean
  checkable: boolean
  detail: string
}

/** Mirrors `AboutInfo` in `src/main/settings-extra.ts`. */
export interface AboutInfo {
  name: string
  tagline: string
  version: string
  electron: string
  chromium: string
  node: string
  platform: string
  arch: string
  license: string | null
  repository: string | null
  homepage: string | null
  updates: UpdateChannel | null
}

/** Mirrors `ToolStatus` in `src/main/prerequisites.ts`. */
export interface ToolStatus {
  id: string
  label: string
  state: 'ready' | 'installed-not-authed' | 'missing' | 'unknown'
  version?: string
  purpose: string
  remedy?: string
  url?: string
  required: boolean
}

export interface Prerequisites {
  tools: ToolStatus[]
  canRunSessions: boolean
  needsLogin: boolean
}

/** Mirrors `Profile` in `src/main/profiles.ts`. */
export interface ProfileSummary {
  id: string
  name: string
  configDir: string
  system: boolean
  /** A custom property name from tokens.css — the UI wraps it in `var()`. */
  color: string
  createdAt: number
  lastUsedAt: number | null
}

export interface ProfilesSnapshot {
  profiles: ProfileSummary[]
  defaultProfileId: string | null
}

/** Mirrors `DetectedBrowser` in `src/main/chrome-import.ts`. */
export interface BrowserProfileSummary {
  id: string
  name: string
  access: 'ok' | 'blocked' | 'missing'
}

export interface DetectedBrowser {
  id: string
  name: string
  userDataDir: string
  access: 'ok' | 'blocked' | 'missing'
  note?: string
  profiles: BrowserProfileSummary[]
}

export interface DevUrl {
  url: string
  host: string
  title: string | null
  source: 'bookmark' | 'history' | 'session'
  detail: string | null
  approximate?: boolean
}

export interface ScanResult {
  urls: DevUrl[]
  problems: Array<{ message: string }>
}

export interface ClearResult {
  cleared: boolean
  message: string
}

/** Mirrors `CookieSource` in `src/main/cookie-import.ts`. */
export interface CookieSource {
  browserId: string
  browserName: string
  profileId: string
  profileName: string
  /** False when nothing on this machine holds that browser's encryption key. */
  keychainItem: boolean
}

/** Mirrors `CookieImportStatus` in `src/main/cookie-import.ts`. */
export interface CookieImportStatus {
  present: number
  recorded: number
  importedAt: number | null
  source: string
  supported: boolean
}

/**
 * Mirrors `CookieImportReport` in `src/main/cookie-import.ts`.
 *
 * `keychain` is the field that separates "nothing to import" from "you said no
 * to the keychain", which are the same number of cookies and completely
 * different situations.
 */
export interface CookieImportReport {
  ok: boolean
  browserName: string
  imported: number
  skipped: number
  failed: number
  domains: number
  keychain: string | null
  message: string
}

/* -------------------------------------------------------------- bridge -- */

export interface SettingsBridgeMethods {
  getPreferences(): Promise<unknown>
  setPreferences(patch: Record<string, unknown>): Promise<unknown>

  getSettings(): Promise<unknown>
  setSettings(patch: Record<string, unknown>): Promise<unknown>
  resetSettings(): Promise<unknown>
  settingsPaths(): Promise<unknown>
  openSettingsPath(key: string): Promise<unknown>
  appAbout(): Promise<unknown>
  clearBrowserData(): Promise<unknown>

  getBrand(): Promise<unknown>
  checkPrerequisites(): Promise<unknown>
  detectProviders(): Promise<unknown>

  listProfiles(): Promise<unknown>
  createProfile(name: string): Promise<unknown>
  renameProfile(id: string, name: string): Promise<unknown>
  deleteProfile(id: string): Promise<unknown>
  setDefaultProfile(id: string): Promise<unknown>

  listBrowsers(): Promise<unknown>
  scanBrowserTabs(request?: unknown): Promise<unknown>

  /**
   * Cookie import. `importBrowserCookies` is the one call in this bridge that
   * can put a system dialog on screen — macOS asks before handing over the
   * keychain key — so nothing calls it except a button the user pressed.
   */
  browserCookieSources(): Promise<unknown>
  browserCookieImportStatus(): Promise<unknown>
  importBrowserCookies(request?: unknown): Promise<unknown>
  clearImportedCookies(): Promise<unknown>

  /**
   * Setup: one read of what is installed and what our hooks look like, and the
   * two writes that change the second half of that. The names are the preload's
   * — `installHooks`, not `hooksInstall` — because the contract test matches
   * these strings against it and a near-miss renders a panel that looks
   * unimplemented rather than one that fails.
   */
  setupStatus(): Promise<unknown>
  installHooks(providerId: string): Promise<unknown>
  removeHooks(providerId: string): Promise<unknown>
}

export type SettingsBridge = Partial<SettingsBridgeMethods>

const BRIDGE_METHODS: ReadonlyArray<keyof SettingsBridgeMethods> = [
  'getPreferences',
  'setPreferences',
  'getSettings',
  'setSettings',
  'resetSettings',
  'settingsPaths',
  'openSettingsPath',
  'appAbout',
  'clearBrowserData',
  'getBrand',
  'checkPrerequisites',
  'detectProviders',
  'listProfiles',
  'createProfile',
  'renameProfile',
  'deleteProfile',
  'setDefaultProfile',
  'listBrowsers',
  'scanBrowserTabs',
  'browserCookieSources',
  'browserCookieImportStatus',
  'importBrowserCookies',
  'clearImportedCookies',
  'setupStatus',
  'installHooks',
  'removeHooks',
]

/**
 * Pick the methods that actually exist on the bridge, each one called through
 * the host object rather than detached.
 *
 * Detaching matters: a preload that exposes plain functions survives being
 * torn off its object, one with methods on a prototype throws on `this` the
 * first time a button is pressed. Cheap to avoid, impossible to debug later.
 */
export function resolveSettingsBridge(host?: unknown): SettingsBridge {
  const source =
    host ??
    (typeof window === 'undefined'
      ? undefined
      : (window as unknown as { deck?: unknown }).deck)

  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}

  for (const name of BRIDGE_METHODS) {
    if (typeof record[name] !== 'function') continue
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }

  return bridge as SettingsBridge
}

/* ------------------------------------------------------------ narrowing -- */

export function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function asString(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}

function asOptionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}

function asBoolean(value: unknown, fallback = false): boolean {
  return typeof value === 'boolean' ? value : fallback
}

function asNumber(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

export function toStoredSettings(raw: unknown): Record<string, unknown> {
  const record = asRecord(raw)
  if (!record) return {}
  const values = asRecord(record.values)
  // Both shapes: the envelope, and a bare map from a build that predates it.
  return values ?? record
}

export function toConfigPaths(raw: unknown): ConfigPath[] {
  return asArray(raw).flatMap((entry) => {
    const record = asRecord(entry)
    if (!record || typeof record.key !== 'string' || typeof record.path !== 'string') return []
    return [
      {
        key: record.key,
        label: asString(record.label, record.key),
        purpose: asString(record.purpose),
        path: record.path,
        kind: record.kind === 'folder' ? 'folder' : 'file',
        exists: asBoolean(record.exists),
      },
    ]
  })
}

export function toOpenPathResult(raw: unknown): OpenPathResult {
  const record = asRecord(raw)
  return {
    opened: asBoolean(record?.opened),
    path: typeof record?.path === 'string' ? record.path : null,
    message: asString(record?.message, 'Nothing happened.'),
  }
}

export function toAbout(raw: unknown): AboutInfo | null {
  const record = asRecord(raw)
  if (!record || typeof record.name !== 'string') return null
  const updates = asRecord(record.updates)
  return {
    name: record.name,
    tagline: asString(record.tagline),
    version: asString(record.version),
    electron: asString(record.electron),
    chromium: asString(record.chromium),
    node: asString(record.node),
    platform: asString(record.platform),
    arch: asString(record.arch),
    license: typeof record.license === 'string' ? record.license : null,
    repository: typeof record.repository === 'string' ? record.repository : null,
    homepage: typeof record.homepage === 'string' ? record.homepage : null,
    updates: updates
      ? {
          packaged: asBoolean(updates.packaged),
          feedPresent: asBoolean(updates.feedPresent),
          checkable: asBoolean(updates.checkable),
          detail: asString(updates.detail),
        }
      : null,
  }
}

const TOOL_STATES = new Set(['ready', 'installed-not-authed', 'missing', 'unknown'])

export function toPrerequisites(raw: unknown): Prerequisites | null {
  const record = asRecord(raw)
  if (!record || !Array.isArray(record.tools)) return null
  const tools = record.tools.flatMap((entry): ToolStatus[] => {
    const tool = asRecord(entry)
    if (!tool || typeof tool.id !== 'string') return []
    return [
      {
        id: tool.id,
        label: asString(tool.label, tool.id),
        state: TOOL_STATES.has(asString(tool.state))
          ? (tool.state as ToolStatus['state'])
          : 'unknown',
        version: asOptionalString(tool.version),
        purpose: asString(tool.purpose),
        remedy: asOptionalString(tool.remedy),
        url: asOptionalString(tool.url),
        required: asBoolean(tool.required),
      },
    ]
  })
  return {
    tools,
    canRunSessions: asBoolean(record.canRunSessions),
    needsLogin: asBoolean(record.needsLogin),
  }
}

/**
 * A profile's colour is a custom property *name*, which the list wraps in
 * `var()` and hands to an inline style. Anything that is not one is replaced
 * rather than passed through: `profiles.json` is a file a person can edit, and
 * `var(whatever they typed)` is at best a dot that does not appear.
 */
const CUSTOM_PROPERTY = /^--[A-Za-z0-9-]{1,64}$/

export function toProfiles(raw: unknown): ProfilesSnapshot | null {
  const record = asRecord(raw)
  if (!record || !Array.isArray(record.profiles)) return null
  const profiles = record.profiles.flatMap((entry): ProfileSummary[] => {
    const profile = asRecord(entry)
    if (!profile || typeof profile.id !== 'string') return []
    return [
      {
        id: profile.id,
        name: asString(profile.name, profile.id),
        configDir: asString(profile.configDir),
        system: asBoolean(profile.system),
        color: CUSTOM_PROPERTY.test(asString(profile.color)) ? (profile.color as string) : '--accent',
        createdAt: asNumber(profile.createdAt),
        lastUsedAt: typeof profile.lastUsedAt === 'number' ? profile.lastUsedAt : null,
      },
    ]
  })
  return {
    profiles,
    defaultProfileId:
      typeof record.defaultProfileId === 'string' ? record.defaultProfileId : null,
  }
}

const ACCESS_STATES = new Set(['ok', 'blocked', 'missing'])

function toAccess(value: unknown): DetectedBrowser['access'] {
  return ACCESS_STATES.has(asString(value)) ? (value as DetectedBrowser['access']) : 'missing'
}

export function toBrowsers(raw: unknown): DetectedBrowser[] {
  return asArray(raw).flatMap((entry): DetectedBrowser[] => {
    const browser = asRecord(entry)
    if (!browser || typeof browser.id !== 'string') return []
    return [
      {
        id: browser.id,
        name: asString(browser.name, browser.id),
        userDataDir: asString(browser.userDataDir),
        access: toAccess(browser.access),
        note: asOptionalString(browser.note),
        profiles: asArray(browser.profiles).flatMap((raw2): BrowserProfileSummary[] => {
          const profile = asRecord(raw2)
          if (!profile || typeof profile.id !== 'string') return []
          return [
            {
              id: profile.id,
              name: asString(profile.name, profile.id),
              access: toAccess(profile.access),
            },
          ]
        }),
      },
    ]
  })
}

const URL_SOURCES = new Set(['bookmark', 'history', 'session'])

/**
 * Both lists are deduplicated here rather than trusted.
 *
 * `chrome-import` folds repeated addresses together, but it reports one problem
 * per browser *profile*, so a machine with three Chrome profiles behind Full
 * Disk Access sends the same sentence three times — rendered as three identical
 * warnings under three identical React keys. Deduplicating on arrival fixes the
 * duplicate keys and the duplicate warnings in one place, and makes the panel
 * safe against a scan that ever stops folding its URLs.
 */
export function toScanResult(raw: unknown): ScanResult {
  const record = asRecord(raw)
  const seenUrls = new Set<string>()
  const urls = asArray(record?.urls).flatMap((entry): DevUrl[] => {
    const hit = asRecord(entry)
    if (!hit || typeof hit.url !== 'string') return []
    if (seenUrls.has(hit.url)) return []
    seenUrls.add(hit.url)
    return [
      {
        url: hit.url,
        host: asString(hit.host),
        title: typeof hit.title === 'string' ? hit.title : null,
        source: URL_SOURCES.has(asString(hit.source)) ? (hit.source as DevUrl['source']) : 'history',
        detail: typeof hit.detail === 'string' ? hit.detail : null,
        approximate: hit.approximate === true,
      },
    ]
  })
  const seenProblems = new Set<string>()
  const problems = asArray(record?.problems).flatMap((entry) => {
    const problem = asRecord(entry)
    const message = asString(problem?.message)
    if (message === '' || seenProblems.has(message)) return []
    seenProblems.add(message)
    return [{ message }]
  })
  return { urls, problems }
}

export function toCookieSources(raw: unknown): CookieSource[] {
  return asArray(raw).flatMap((entry): CookieSource[] => {
    const source = asRecord(entry)
    if (!source || typeof source.browserId !== 'string' || typeof source.profileId !== 'string') {
      return []
    }
    return [
      {
        browserId: source.browserId,
        browserName: asString(source.browserName, source.browserId),
        profileId: source.profileId,
        profileName: asString(source.profileName, source.profileId),
        keychainItem: asBoolean(source.keychainItem),
      },
    ]
  })
}

export function toCookieImportStatus(raw: unknown): CookieImportStatus {
  const record = asRecord(raw)
  return {
    present: asNumber(record?.present),
    recorded: asNumber(record?.recorded),
    importedAt: typeof record?.importedAt === 'number' ? record.importedAt : null,
    source: asString(record?.source),
    // Defaults to false: claiming an import will work and then failing at the
    // keychain is worse than saying up front that it will not.
    supported: asBoolean(record?.supported),
  }
}

export function toCookieImportReport(raw: unknown): CookieImportReport {
  const record = asRecord(raw)
  return {
    ok: asBoolean(record?.ok),
    browserName: asString(record?.browserName),
    imported: asNumber(record?.imported),
    skipped: asNumber(record?.skipped),
    failed: asNumber(record?.failed),
    domains: asNumber(record?.domains),
    keychain: typeof record?.keychain === 'string' ? record.keychain : null,
    message: asString(record?.message, 'The import finished without saying what happened.'),
  }
}

export function toClearResult(raw: unknown): ClearResult {
  const record = asRecord(raw)
  return {
    cleared: asBoolean(record?.cleared),
    message: asString(record?.message, 'Nothing to report.'),
  }
}

/** The message to show when a channel the preload has not wired yet is called. */
export function missingChannelNote(what: string): string {
  return `${what} is not available in this build yet.`
}

/**
 * An error from an IPC rejection, reduced to one line a person can read.
 *
 * Never the empty string. Every caller renders this conditionally, so returning
 * '' would show no message at all — and the two ways that happened were both
 * real: an Error whose message is exactly `Error:` (the frame with nothing
 * after it), and a rejection that is not an Error at all.
 */
export function errorText(error: unknown, fallback: string): string {
  const message =
    error instanceof Error
      ? error.message
      : typeof error === 'string'
        ? error
        : ''
  if (message.trim() === '') return fallback

  // Electron prefixes a rejected invoke with the channel and handler frame; the
  // sentence the main process actually wrote is after the last one.
  const parts = message.split(/Error:\s*/)
  const tail = (parts[parts.length - 1] ?? '').trim()
  return tail !== '' ? tail : message.trim()
}
