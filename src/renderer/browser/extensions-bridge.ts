/**
 * The renderer's half of the browser extension store.
 *
 * Optional, every method of it, for the reason `store-bridge.ts` states about
 * its own: `bridge.ts` refuses to resolve at all when one of `BRIDGE_METHODS` is
 * missing, which is right for the methods the panel cannot draw a pixel without
 * and catastrophic for a new one. *"A preload older than this feature must cost
 * the browser its store, never the whole browser."*
 *
 * The types are mirrors rather than imports, again for the reason `bridge.ts`
 * gives: the renderer's tsconfig does not include `src/main`. Every value that
 * arrives is narrowed below rather than trusted.
 */

/** Mirrors `ExtensionVerdict` in `src/main/browser-extensions.ts`. */
export type ExtensionVerdict = 'works' | 'partly' | 'no' | 'unmeasured'

/** Mirrors `ExtensionState`. */
export type ExtensionState =
  | 'available'
  | 'installed'
  | 'damaged'
  | 'unavailable'
  | 'not-offered'

/** Mirrors `ExtensionCategory`. */
export type ExtensionCategory =
  | 'blocking'
  | 'privacy'
  | 'appearance'
  | 'media'
  | 'passwords'
  | 'research'
  | 'scripting'
  | 'your-own'

/**
 * The shelves, and the name each wears. Mirrors `EXTENSION_CATEGORIES`.
 *
 * Written out here rather than sent down the wire with the list, unlike the
 * limits next to it, and the difference is what each one is: a limit is a
 * **measurement** and belongs to the module that took it, so a limit that stops
 * being true is deleted where it was measured. A section heading is a label on a
 * screen. Sending it would mean a build of the panel could draw a heading that
 * no longer matched what the panel does with it.
 */
export const CATEGORY_NAMES: Readonly<Record<ExtensionCategory, string>> = {
  blocking: 'Blocking ads and trackers',
  privacy: 'Privacy and cleaning up',
  appearance: 'How pages look',
  media: 'Video and audio',
  passwords: 'Passwords',
  research: 'Saving and research',
  scripting: 'Scripting and the keyboard',
  'your-own': 'Added by you',
}

/** The order the store draws them in. */
export const CATEGORY_ORDER: readonly ExtensionCategory[] = [
  'blocking',
  'privacy',
  'appearance',
  'media',
  'passwords',
  'research',
  'scripting',
  'your-own',
]

/** Mirrors `StoreExtension`. */
export interface StoreExtension {
  id: string
  name: string
  summary: string
  homepage: string
  licence: string
  version: string
  works: ExtensionVerdict
  category: ExtensionCategory
  measured: string
  /** Why nothing was measured and nothing is offered, or `''`. */
  noRelease: string
  url: string
  sha256: string
  bytes: number
  state: ExtensionState
  installedVersion: string
  installedAt: number
  enabled: boolean
  reach: string[]
  /** What it may ask to reach later, and can never be granted here. */
  mayAsk: string[]
  everywhere: boolean
  missing: string[]
  /** `chrome.*` this app fills in so the extension can start. */
  provides: string[]
  /** What stays inert even with that layer, in the words a row shows. */
  inert: string[]
  /** How many of its manifest declarativeNetRequest rulesets this app switched on. */
  rulesetsSwitchedOn: number
  popup: string
  /** Its own settings page, or `''`. */
  optionsPage: string
  /** True for one a person added themselves. */
  sideloaded: boolean
  /** The folder or `.crx` a sideloaded one came from. */
  origin: string
  /** The id a `.crx`'s own signature yields, or `''`. */
  crxId: string
  staticRulesets: boolean
  message: string
}

export interface ExtensionProfile {
  id: string
  name: string
}

export interface ExtensionsView {
  profileId: string
  profileName: string
  extensions: StoreExtension[]
  folder: string
  /** Folders under the profile's root this build no longer has a row for. */
  orphans: string[]
  profiles: ExtensionProfile[]
  /** What this browser cannot do, measured in the main process. Said once. */
  limits: string[]
}

/** Mirrors `ExtensionResult`. */
export interface ExtensionResult {
  ok: boolean
  message: string
}

export interface ExtensionsApi {
  browserExtensions?(profileId: string): Promise<unknown>
  browserExtensionInstall?(profileId: string, id: string): Promise<unknown>
  browserExtensionRemove?(profileId: string, id: string): Promise<unknown>
  browserExtensionEnable?(profileId: string, id: string, on: boolean): Promise<unknown>
  browserExtensionPopup?(profileId: string, id: string): Promise<unknown>
  browserExtensionOptions?(profileId: string, id: string): Promise<unknown>
  browserExtensionAddFolder?(profileId: string): Promise<unknown>
  browserExtensionAddCrx?(profileId: string): Promise<unknown>
}

const METHODS = [
  'browserExtensions',
  'browserExtensionInstall',
  'browserExtensionRemove',
  'browserExtensionEnable',
  'browserExtensionPopup',
  'browserExtensionOptions',
  'browserExtensionAddFolder',
  'browserExtensionAddCrx',
] as const satisfies readonly (keyof ExtensionsApi)[]

export function resolveExtensionsApi(host?: unknown): ExtensionsApi {
  const source =
    host ??
    (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  for (const name of METHODS) {
    const value = record[name]
    if (typeof value === 'function') api[name] = (value as (...args: never[]) => unknown).bind(source)
  }
  return api as ExtensionsApi
}

/**
 * Is the store wired in this build?
 *
 * All four of list, install, remove and the switch, and the argument is
 * `store-bridge.ts`'s verbatim: *"a store with a list and no Install is a
 * catalogue of things you cannot have, and a store with an Install and no Remove
 * is worse than no store at all."* The switch joins them because an extension
 * that can be installed and not turned off is a program somebody cannot stop
 * without deleting it.
 *
 * The popup is **not** in the bar. An extension with no `default_popup` has no
 * panel either, so the panel already has to draw that control conditionally —
 * one more condition on an existing branch, rather than a reason to hide the
 * whole store.
 */
export function extensionsAvailable(api: ExtensionsApi): boolean {
  return (
    typeof api.browserExtensions === 'function' &&
    typeof api.browserExtensionInstall === 'function' &&
    typeof api.browserExtensionRemove === 'function' &&
    typeof api.browserExtensionEnable === 'function'
  )
}

/* ---------------------------------------------------------------- reading -- */

function text(raw: unknown): string {
  return typeof raw === 'string' ? raw : ''
}

function count(raw: unknown): number {
  return typeof raw === 'number' && Number.isFinite(raw) && raw >= 0 ? raw : 0
}

function words(raw: unknown, limit: number): string[] {
  if (!Array.isArray(raw)) return []
  return raw.filter((entry): entry is string => typeof entry === 'string').slice(0, limit)
}

function readVerdict(raw: unknown): ExtensionVerdict {
  return raw === 'works' || raw === 'partly' || raw === 'unmeasured' ? raw : 'no'
}

function readState(raw: unknown): ExtensionState {
  return raw === 'installed' ||
    raw === 'damaged' ||
    raw === 'unavailable' ||
    raw === 'not-offered'
    ? raw
    : 'available'
}

function readCategory(raw: unknown): ExtensionCategory {
  return CATEGORY_ORDER.includes(raw as ExtensionCategory)
    ? (raw as ExtensionCategory)
    : 'scripting'
}

function readExtension(raw: unknown): StoreExtension | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const id = text(record.id)
  if (id === '') return null
  return {
    id,
    name: text(record.name) || id,
    summary: text(record.summary),
    homepage: text(record.homepage),
    licence: text(record.licence),
    version: text(record.version),
    works: readVerdict(record.works),
    category: readCategory(record.category),
    measured: text(record.measured),
    noRelease: text(record.noRelease),
    url: text(record.url),
    sha256: text(record.sha256),
    bytes: count(record.bytes),
    state: readState(record.state),
    installedVersion: text(record.installedVersion),
    installedAt: count(record.installedAt),
    enabled: record.enabled === true,
    reach: words(record.reach, 40),
    mayAsk: words(record.mayAsk, 12),
    everywhere: record.everywhere === true,
    missing: words(record.missing, 24),
    provides: words(record.provides, 24),
    inert: words(record.inert, 12),
    rulesetsSwitchedOn: count(record.rulesetsSwitchedOn),
    popup: text(record.popup),
    optionsPage: text(record.optionsPage),
    sideloaded: record.sideloaded === true,
    origin: text(record.origin),
    crxId: text(record.crxId),
    staticRulesets: record.staticRulesets === true,
    message: text(record.message),
  }
}

/** What `browser-extension:list` answered, narrowed. Never throws. */
export function readExtensionsView(raw: unknown): ExtensionsView {
  const empty: ExtensionsView = {
    profileId: '',
    profileName: '',
    extensions: [],
    folder: '',
    orphans: [],
    profiles: [],
    limits: [],
  }
  if (typeof raw !== 'object' || raw === null) return empty
  const record = raw as Record<string, unknown>
  const view =
    typeof record.view === 'object' && record.view !== null
      ? (record.view as Record<string, unknown>)
      : {}
  const extensions = Array.isArray(view.extensions)
    ? view.extensions
        .map(readExtension)
        .filter((entry): entry is StoreExtension => entry !== null)
    : []
  const profiles = Array.isArray(record.profiles)
    ? record.profiles
        .map((entry) => {
          if (typeof entry !== 'object' || entry === null) return null
          const one = entry as Record<string, unknown>
          const id = text(one.id)
          return id === '' ? null : { id, name: text(one.name) || id }
        })
        .filter((entry): entry is ExtensionProfile => entry !== null)
    : []
  return {
    profileId: text(view.profileId),
    profileName: text(view.profileName),
    extensions,
    folder: text(view.folder),
    orphans: words(record.orphans, 40),
    profiles,
    limits: words(record.limits, 12),
  }
}

/** What an install, a remove, a switch or a popup answered, narrowed. */
export function readExtensionResult(raw: unknown): ExtensionResult {
  if (typeof raw !== 'object' || raw === null) {
    return { ok: false, message: 'The app did not answer.' }
  }
  const record = raw as Record<string, unknown>
  return { ok: record.ok === true, message: text(record.message) }
}

/**
 * The sentence under "Reaches", mirroring `reachOf` in the main process.
 *
 * One place turns patterns into words, for the reason `originWords` gives next
 * door: *"two spellings of one rule is how one of them ends up wrong."* The
 * everywhere case is spelled out rather than printed as `<all_urls>`, because
 * that string means nothing to somebody deciding whether to install a program.
 */
export function reachWords(reach: readonly string[], onEveryPage: boolean): string {
  if (onEveryPage) return 'every page you open in this profile'
  if (reach.length === 0) return 'no pages of its own'
  return reach.join(', ')
}

/**
 * What one press will do, in the one word the button wears.
 *
 * Pure and exported for the reason `actionLabel` next door is: *"a button whose
 * label disagrees with its handler is the defect this app names outright."*
 * `damaged` says Remove rather than Reinstall — the files on disk are not the
 * ones that were installed, and the honest first move is to delete them.
 */
export function extensionActionLabel(extension: StoreExtension, busy: boolean): string {
  if (busy) return 'Working…'
  if (extension.state === 'installed' || extension.state === 'damaged') return 'Remove'
  return 'Install'
}

/** Which verb that press sends. The other half of {@link extensionActionLabel}. */
export function extensionActionVerb(extension: StoreExtension): 'install' | 'remove' {
  return extension.state === 'installed' || extension.state === 'damaged' ? 'remove' : 'install'
}

/**
 * Which extensions get a button at all.
 *
 * An `unavailable` row is one this app measured failing in this browser. It has
 * no download pinned, so an Install could only ever refuse — and a button that
 * can only refuse is the control this whole round exists to remove. The row is
 * still drawn, with what was measured, because *"where is uBlock Origin"* has a
 * true answer and it is not silence.
 */
export function canAct(extension: StoreExtension): boolean {
  return extension.state !== 'unavailable' && extension.state !== 'not-offered'
}

/**
 * Does this row's `Reaches` line mean anything yet?
 *
 * False for a row nothing was measured on. There is no release, so there is no
 * manifest, so there is no reach — and `reachWords` answering *no pages of its
 * own* about Privacy Badger would be this app inventing a fact about a program
 * it has never seen, which is the exact failure the row exists to avoid.
 */
export function hasReach(extension: StoreExtension): boolean {
  return extension.state !== 'not-offered'
}

/**
 * Which rows a typed word keeps.
 *
 * Name, summary and category, and deliberately **not** the measured sentence:
 * those paragraphs mention `chrome.tabs`, `ads.doubleclick.net` and every
 * namespace this browser lacks, so searching them would make a search for
 * "cookies" return the ad blockers and a search for "tabs" return most of the
 * catalogue. A search that answers with almost everything is the same as one
 * that answers with nothing, and slower to disbelieve.
 */
export function matchesSearch(extension: StoreExtension, query: string): boolean {
  const needle = query.trim().toLowerCase()
  if (needle === '') return true
  const haystack = [
    extension.name,
    extension.summary,
    CATEGORY_NAMES[extension.category],
  ]
    .join(' ')
    .toLowerCase()
  return needle.split(/\s+/).every((word) => haystack.includes(word))
}
