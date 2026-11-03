/**
 * The renderer's half of profiles, saved logins and the sign-in handover.
 *
 * Optional, every method of it, and that is the point. `bridge.ts` refuses to
 * resolve at all when any of `BRIDGE_METHODS` is missing — which is right for
 * the methods the panel cannot draw a single pixel without, and catastrophic for
 * a new one: adding a name to that list blanks the whole browser panel on every
 * build whose preload predates it. `draw-bridge.ts` and `drive-bridge.ts` both
 * carry that note, and this is the third feature to take the same shape.
 *
 * The types are mirrors rather than imports, for the reason `bridge.ts` states:
 * the renderer's tsconfig does not include `src/main`, and this repo lets
 * feature types cross as `unknown` rather than duplicating them into
 * `shared/types.ts` where the two sides drift quietly instead of disagreeing
 * loudly. Each one names the module it mirrors.
 *
 * **There is no method here that returns a password**, and there is not meant to
 * be. `browserPasswordCopy` names a row and is told whether a copy happened; the
 * secret goes from the main process to the clipboard without passing through
 * this side. See `browser-passwords.ts` for why that rule exists.
 */

/** Mirrors `BrowserProfile` in `src/main/browser-profiles.ts`. */
export interface BrowserProfile {
  id: string
  name: string
  partition: string
  createdAt: number
  isDefault: boolean
  /** One character for the badge, or `''` for the name's initial. */
  avatar: string
}

/** Mirrors `ProfileState` in `src/main/browser-profiles.ts`. */
export interface ProfileState {
  profiles: BrowserProfile[]
  activeId: string
}

/** Mirrors `SavedLoginSummary` in `src/main/browser-passwords.ts`. Note: no password. */
export interface SavedLoginSummary {
  profileId: string
  origin: string
  username: string
  updatedAt: number
}

/** Mirrors `Visit` in `src/main/browser-history.ts`. */
export interface HistoryVisit {
  profileId: string
  url: string
  title: string
  visitedAt: number
  visits: number
}

/** Mirrors `SaveOutcome` in `src/main/browser-passwords.ts`. */
export interface SaveOutcome {
  ok: boolean
  message: string
}

/** Mirrors `SignInTrouble` in `src/main/browser-signin.ts`. */
export interface SignInTrouble {
  kind: 'refused' | 'restricted'
  headline: string
  detail: string
  domains: string[]
}

/** Mirrors `Handover` in `src/main/browser-signin.ts`. */
export interface Handover {
  url: string
  domains: string[]
}

/** Mirrors `AgentCliVersion` in `src/main/browser-signin.ts`. */
export interface AgentCliVersion {
  command: string
  version: string | null
  stale: boolean
  advice: string
}

export interface AccountsApi {
  browserProfiles?(): Promise<unknown>
  browserProfileCreate?(name: string): Promise<unknown>
  browserProfileRename?(id: string, name: string): Promise<unknown>
  browserProfileActivate?(id: string): Promise<unknown>
  browserProfileDelete?(id: string): Promise<unknown>

  browserProfileAvatar?(id: string, avatar: string): Promise<unknown>

  /**
   * Where this browser has been, per profile — `browser-history.ts`.
   *
   * There is no method here that *writes* a visit, and there is not meant to be.
   * The store is fed by committed navigations in the main process, so nothing on
   * this side can put a page into somebody's history that they never opened.
   */
  browserHistory?(profileId: string, query?: string): Promise<unknown>
  browserHistorySuggest?(profileId: string, typed: string): Promise<unknown>
  browserHistoryForget?(profileId: string, url: string): Promise<unknown>
  browserHistoryClear?(profileId: string): Promise<unknown>

  browserPasswordsAvailable?(): Promise<unknown>
  /** Whether saving works, where the file is, and whether it verified. */
  browserPasswordState?(): Promise<unknown>
  /**
   * Show that file in Finder or Explorer. Not the password — the file.
   *
   * Named `ShowFile` rather than `Reveal` deliberately: "reveal" on this bridge
   * means the one thing that must never exist here, and the test in
   * `BrowserSection.test.tsx` bans the spelling outright.
   */
  browserPasswordShowFile?(): Promise<unknown>
  browserPasswords?(profileId: string): Promise<unknown>
  browserPasswordForget?(profileId: string, origin: string, username: string): Promise<unknown>
  browserPasswordForgetAll?(): Promise<unknown>
  browserPasswordCopy?(profileId: string, origin: string, username: string): Promise<unknown>
  browserPasswordAnswer?(keep: boolean): Promise<unknown>
  onBrowserPasswordOffer?(cb: (id: string, origin: string, username: string) => void): () => void
  /**
   * A page with a sign-in form, and whether the saved login went in by itself.
   *
   * `filled: false` is not a failure. `browser-fill-gate.ts` withholds the
   * automatic fill on any page an agent navigated to or is holding, and `note`
   * is the sentence that says so — the offer is still there, one press away.
   */
  onBrowserLoginAvailable?(
    cb: (id: string, origin: string, usernames: string[], filled: boolean, note: string) => void,
  ): () => void
  /**
   * Type a saved login into the page in this tab. **A person's press only.**
   *
   * The one method in this family that causes a password to be typed anywhere,
   * and the reason it is safe to have is where it lives: an `ipcMain` channel
   * on the window's own bridge, which no agent and no guest page can reach. See
   * the note in `src/preload/index.ts` and the argument in
   * `browser-fill-gate.ts`.
   */
  browserPasswordFill?(id: string, username: string): Promise<unknown>

  browserSignInDiagnose?(url: string): Promise<unknown>
  browserSignInHandover?(url: string): Promise<unknown>
  browserSignInAgents?(): Promise<unknown>

  /**
   * The existing cookie importer, which is what makes the handover a round trip
   * rather than a one-way door.
   *
   * It predates this feature and belongs to `cookie-import.ts`; it is listed
   * here because this is the only caller that asks for specific domains, and
   * because a handover that could not bring the session back would be exactly
   * the "appears to try and dies silently" behaviour the review is about.
   */
  importBrowserCookies?(request: unknown): Promise<unknown>
}

const METHODS = [
  'browserProfiles',
  'browserProfileCreate',
  'browserProfileRename',
  'browserProfileActivate',
  'browserProfileDelete',
  'browserProfileAvatar',
  'browserHistory',
  'browserHistorySuggest',
  'browserHistoryForget',
  'browserHistoryClear',
  'browserPasswordsAvailable',
  'browserPasswordState',
  'browserPasswordShowFile',
  'browserPasswords',
  'browserPasswordForget',
  'browserPasswordForgetAll',
  'browserPasswordCopy',
  'browserPasswordAnswer',
  'onBrowserPasswordOffer',
  'onBrowserLoginAvailable',
  'browserPasswordFill',
  'browserSignInDiagnose',
  'browserSignInHandover',
  'browserSignInAgents',
  'importBrowserCookies',
] as const satisfies readonly (keyof AccountsApi)[]

export function resolveAccountsApi(host?: unknown): AccountsApi {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  // Method by method rather than handed over whole, so a preload older than this
  // file contributes what it has and nothing else — the shape `resolveDriveApi`
  // uses, and the reason the availability answers below can each be one honest
  // check rather than five `typeof`s at every call site.
  for (const name of METHODS) {
    const value = record[name]
    if (typeof value === 'function') api[name] = (value as (...args: never[]) => unknown).bind(source)
  }
  return api as AccountsApi
}

/**
 * Are profiles wired in this build?
 *
 * All five or none. A menu that can list profiles but not switch to one is a
 * screen that cannot act, which is the single most repeated complaint in the
 * review this feature comes from — so the honest answer when the preload is
 * half-wired is to not offer the menu at all.
 */
export function profilesAvailable(api: AccountsApi): boolean {
  return (
    typeof api.browserProfiles === 'function' &&
    typeof api.browserProfileCreate === 'function' &&
    typeof api.browserProfileRename === 'function' &&
    typeof api.browserProfileActivate === 'function' &&
    typeof api.browserProfileDelete === 'function'
  )
}

/**
 * Is browsing history wired in this build?
 *
 * List, suggest and forget together, for the reason {@link profilesAvailable}
 * gives: a History page that cannot forget a row, or an address bar that lists
 * suggestions from a store nothing can open, is the half-feature this whole
 * review is about. `browserProfileAvatar` is deliberately **not** in here — a
 * preload that cannot set an avatar still has a perfectly good history, and the
 * profile section hides that one control instead of the section.
 */
export function historyAvailable(api: AccountsApi): boolean {
  return (
    typeof api.browserHistory === 'function' &&
    typeof api.browserHistorySuggest === 'function' &&
    typeof api.browserHistoryForget === 'function' &&
    typeof api.browserHistoryClear === 'function'
  )
}

/** The same bargain for saved logins: list, forget and answer, or nothing. */
export function passwordsAvailable(api: AccountsApi): boolean {
  return (
    typeof api.browserPasswordsAvailable === 'function' &&
    typeof api.browserPasswords === 'function' &&
    typeof api.browserPasswordForget === 'function' &&
    typeof api.browserPasswordAnswer === 'function'
  )
}

export function signInHelpAvailable(api: AccountsApi): boolean {
  return typeof api.browserSignInDiagnose === 'function' && typeof api.browserSignInHandover === 'function'
}

/* ---------------------------------------------------------------- reading -- */

/**
 * Everything below validates a shape that came from this app's own main
 * process, which is not a trust boundary — it is the discipline every other
 * `unknown` on this side gets, and it is what makes an older or newer main
 * process a quiet no-op rather than a crash inside an effect.
 */

export function readProfileState(raw: unknown): ProfileState | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  if (!Array.isArray(value.profiles)) return null
  const profiles: BrowserProfile[] = []
  for (const entry of value.profiles) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.id !== 'string' || typeof record.name !== 'string') continue
    profiles.push({
      id: record.id,
      name: record.name,
      partition: typeof record.partition === 'string' ? record.partition : '',
      createdAt: typeof record.createdAt === 'number' ? record.createdAt : 0,
      isDefault: record.isDefault === true,
      avatar: typeof record.avatar === 'string' ? record.avatar : '',
    })
  }
  if (profiles.length === 0) return null
  const activeId =
    typeof value.activeId === 'string' && profiles.some((p) => p.id === value.activeId)
      ? value.activeId
      : profiles[0].id
  return { profiles, activeId }
}

export function readLoginList(raw: unknown): SavedLoginSummary[] {
  if (!Array.isArray(raw)) return []
  const out: SavedLoginSummary[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.origin !== 'string' || record.origin === '') continue
    out.push({
      profileId: typeof record.profileId === 'string' ? record.profileId : '',
      origin: record.origin,
      username: typeof record.username === 'string' ? record.username : '',
      updatedAt: typeof record.updatedAt === 'number' ? record.updatedAt : 0,
    })
  }
  return out
}

/**
 * Is this address still on the origin a saved-login offer was made for?
 *
 * The renderer's half of the exact-origin rule `browser-passwords.ts` argues
 * for: scheme, host and port, compared as a triple, with no registrable-domain
 * grouping and no guessing. It is used to *stop drawing* an offer rather than
 * to decide anything about a credential — the main process checks the same
 * thing again before it fills, against what Chromium actually committed — so
 * the failure direction here costs at worst a bar that is not shown.
 *
 * An address that will not parse matches nothing. A page with no address yet is
 * a page with no sign-in form on it either.
 */
export function sameOrigin(origin: string, url: string): boolean {
  if (origin === '' || url === '') return false
  try {
    return new URL(url).origin === origin
  } catch {
    return false
  }
}

/** Mirrors `StoreState` in `src/main/browser-passwords.ts`. No password on it. */
export interface PasswordStoreState {
  available: boolean
  /** The file. Named on screen so nobody has to be told to go and find it. */
  path: string
  exists: boolean
  fault: 'none' | 'tampered' | 'unreadable'
  /** The main process's own sentence for the fault. Empty when there is none. */
  message: string
}

/**
 * Read it, and default to the *cautious* answer for every missing field.
 *
 * `available: false` from an older preload means the manager says saving is not
 * possible rather than offering something that will not work — which is the
 * right way round, because the store itself refuses in exactly that case and
 * two screens disagreeing about one machine is worse than one saying no.
 */
export function readPasswordStoreState(raw: unknown): PasswordStoreState | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  return {
    available: record.available === true,
    path: typeof record.path === 'string' ? record.path : '',
    exists: record.exists === true,
    fault:
      record.fault === 'tampered' ? 'tampered' : record.fault === 'unreadable' ? 'unreadable' : 'none',
    message: typeof record.message === 'string' ? record.message : '',
  }
}

/**
 * A history list, read the way every other `unknown` on this side is read.
 *
 * A row with no URL is dropped rather than drawn: it is the one thing on the
 * page that cannot be clicked, and a row that does nothing when pressed is the
 * complaint this whole review is made of.
 */
export function readVisitList(raw: unknown): HistoryVisit[] {
  if (!Array.isArray(raw)) return []
  const out: HistoryVisit[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.url !== 'string' || record.url === '') continue
    out.push({
      profileId: typeof record.profileId === 'string' ? record.profileId : '',
      url: record.url,
      title: typeof record.title === 'string' ? record.title : '',
      visitedAt: typeof record.visitedAt === 'number' ? record.visitedAt : 0,
      visits: typeof record.visits === 'number' ? record.visits : 1,
    })
  }
  return out
}

export function readSignInTrouble(raw: unknown): SignInTrouble | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  if (value.kind !== 'refused' && value.kind !== 'restricted') return null
  if (typeof value.headline !== 'string' || typeof value.detail !== 'string') return null
  return {
    kind: value.kind,
    headline: value.headline,
    detail: value.detail,
    domains: Array.isArray(value.domains) ? value.domains.filter((d): d is string => typeof d === 'string') : [],
  }
}

export function readStaleAgents(raw: unknown): AgentCliVersion[] {
  if (!Array.isArray(raw)) return []
  const out: AgentCliVersion[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.command !== 'string' || record.stale !== true) continue
    out.push({
      command: record.command,
      version: typeof record.version === 'string' ? record.version : null,
      stale: true,
      advice: typeof record.advice === 'string' ? record.advice : '',
    })
  }
  return out
}

/**
 * A saved login shown as one line.
 *
 * The scheme is dropped for https and kept for http, which is the whole reason
 * this is a function rather than a template literal at the call site: plain http
 * means the password travels in the clear, and that is worth seeing on the row
 * rather than being tidied away for symmetry.
 */
export function loginLabel(entry: SavedLoginSummary): string {
  const site = entry.origin.replace(/^https:\/\//, '')
  return entry.username === '' ? site : `${site} — ${entry.username}`
}
