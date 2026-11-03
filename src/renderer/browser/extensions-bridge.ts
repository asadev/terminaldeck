import {
  COST_ORDER,
  COST_WORDS,
  NEEDS_NOTHING,
  type FacetVocabulary,
  type StoreCompat,
  type StoreCost,
  type StoreFacet,
  type StoreFacets,
} from '../store/storefront'

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
export type ExtensionState = 'available' | 'installed' | 'damaged'

/** Mirrors `ExtensionNeed`. */
export type ExtensionNeed = 'account' | 'companion-app'

/** Mirrors `ExtensionCost`. */
export type ExtensionCost = 'free' | 'account' | 'metered' | 'paid' | 'unknown'

/** Mirrors `ExtensionCategory`. */
export type ExtensionCategory =
  | 'blocking'
  | 'privacy'
  | 'appearance'
  | 'media'
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
  scripting: 'Scripting and the keyboard',
  'your-own': 'Added by you',
}

/** The order the store draws them in. */
export const CATEGORY_ORDER: readonly ExtensionCategory[] = [
  'blocking',
  'privacy',
  'appearance',
  'media',
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
  /** Words to search on that are in neither the name nor the summary. */
  tags: string[]
  /** What a person has to bring before it can do its job. Usually empty. */
  needs: ExtensionNeed[]
  /** What using it costs. See `ExtensionCost`. */
  cost: ExtensionCost
  /** The price reality in a sentence, or `''`. */
  costNote: string
  measured: string
  /** Which mark to draw, as a key into `store/logo-data.ts`. `''` for none. */
  logo: string
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
  /** A packed file — a `.crx` or a zip. The main process decides which from the bytes. */
  browserExtensionAddCrx?(profileId: string): Promise<unknown>
  /**
   * Copy one you added in again from where it came from, and restart it.
   *
   * The developer loop: rebuild, press Reload. Absent in a preload older than
   * this feature, and its absence costs that one button on rows somebody added —
   * absent rather than disabled, the standing rule for this whole menu.
   */
  browserExtensionReload?(profileId: string, id: string): Promise<unknown>
  /** Rename one you added. The only part of somebody else's program this app wrote. */
  browserExtensionRename?(profileId: string, id: string, name: string): Promise<unknown>
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
  'browserExtensionReload',
  'browserExtensionRename',
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
  return raw === 'installed' || raw === 'damaged' ? raw : 'available'
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
    tags: words(record.tags, 16),
    needs: words(record.needs, 4).filter((one): one is ExtensionNeed =>
      NEEDS.some((known) => known === one),
    ),
    cost: readCost(record.cost),
    costNote: text(record.costNote),
    measured: text(record.measured),
    logo: text(record.logo),
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

/*
 * `canAct`, `linkOut`, `linkOutLabel` and `hasReach` used to live here, and all
 * four answered the same question: what a row does when it cannot be installed.
 * `canAct` was false for a row watched failing, `linkOut` handed such a row the
 * project's own page, `linkOutLabel` chose between **Get it** and **Open
 * project**, and `hasReach` hid a `Reaches` line on a row with no manifest
 * behind it.
 *
 * Asad, on what that added up to: *"They click Get and it takes them to the
 * Chrome store … we should not offer tools that don't work with our
 * architecture."* The catalogue cannot hold such a row any more — see
 * `CatalogueEntry` in `src/main/browser-extensions.ts` — so all four had exactly
 * one answer left, and four functions that can only answer one way are four
 * places for a screen to disagree with itself. Every row here now installs, has
 * a manifest, and states its reach.
 */

/* ------------------------------------------------------------- storefront -- */

/** The `ExtensionNeed`s this build knows, for narrowing what arrives. */
const NEEDS: readonly ExtensionNeed[] = ['account', 'companion-app']

/** The `ExtensionCost`s this build knows. */
const COSTS: readonly ExtensionCost[] = ['free', 'account', 'metered', 'paid', 'unknown']

/**
 * What arrived, or `unknown`.
 *
 * The fallback is not `free`, and that is the whole point of writing this out
 * rather than defaulting. A main process one version behind sends no price at
 * all; a row that read *Free* because a field was missing would be the one lie
 * this field exists to stop. `unknown` is a real value here — a sideloaded
 * extension is genuinely unpriceable by this app — so it costs nothing to land
 * on it.
 */
function readCost(raw: unknown): ExtensionCost {
  return COSTS.includes(raw as ExtensionCost) ? (raw as ExtensionCost) : 'unknown'
}

/**
 * Where this row comes from, as the store's *source* facet.
 *
 * Derived, never a new catalogue field, because both answers are already facts
 * on the row: a sideloaded row came off this machine, and everything else came
 * from a project's own release, fetched at a byte count and a fingerprint this
 * app has written down.
 *
 * There used to be a third answer — `web-store`, for a row whose project
 * publishes through the Chrome Web Store and nowhere this app can fetch from.
 * It is gone with those rows. A catalogue that cannot hold one no longer needs a
 * chip that would filter to nothing, and `facetControls` would have refused to
 * draw it anyway.
 *
 * The MCP store's three answers are *official / community / archived*, and they
 * are not these. That distinction is real over there — GitHub reports
 * `modelcontextprotocol/servers-archived` archived, and the catalogue checked it
 * on a dated day — and there is nothing measured that would put an extension in
 * any of those three bins. Copying the words across would have been a filter
 * that sorted rows by a fact nobody established, so this facet answers the
 * question this catalogue can actually answer.
 */
export type ExtensionSourceKind = 'release' | 'your-own'

export function extensionSource(extension: StoreExtension): ExtensionSourceKind {
  return extension.sideloaded ? 'your-own' : 'release'
}

/**
 * How much this app knows about the row working *here*.
 *
 * `partly` lands on `unknown` rather than `works`, and that is the honest
 * reading of what the catalogue says about those rows: *"Loads. Its background
 * page runs with no uncaught error. It was not watched applying a style, so this
 * app does not claim it does."* A filter called "Works here" that returned it
 * would be making the claim the row refuses to.
 */
export function extensionCompat(extension: StoreExtension): StoreCompat {
  if (extension.works === 'works') return 'works'
  return extension.works === 'no' ? 'cannot' : 'unknown'
}

/**
 * One extension as the shared storefront sees it.
 *
 * The whole of what `browser/` contributes to searching and filtering. Every
 * decision above this line is `store/storefront.ts`'s, so the two stores cannot
 * end up with two different ideas of what a partial word is.
 */
export function extensionFacets(extension: StoreExtension): StoreFacets {
  return {
    id: extension.id,
    name: extension.name,
    summary: extension.summary,
    category: extension.category,
    categoryName: CATEGORY_NAMES[extension.category],
    /*
     * Name, summary, category and tags — and deliberately **not** the measured
     * sentence. Those paragraphs mention `chrome.tabs`, `ads.doubleclick.net`
     * and every namespace this browser lacks, so searching them would make a
     * search for "cookies" return the ad blockers and a search for "tabs" return
     * most of the catalogue. A search that answers with almost everything is the
     * same as one that answers with nothing, and slower to disbelieve.
     */
    tags: extension.tags,
    cost: extension.cost,
    compat: extensionCompat(extension),
    installed: extension.state === 'installed' || extension.state === 'damaged',
    source: extensionSource(extension),
    needs: extension.needs,
  }
}

/**
 * What the browser store's filter chips say.
 *
 * Its own words, not the MCP store's, because this catalogue measured its rows
 * running inside this app's own Electron and can say *works here* — a sentence
 * the MCP catalogue states outright that it will never say about anything.
 * `facetControls` drops any group that would be left with fewer than two live
 * options, so a profile with nothing of its own added simply stops drawing the
 * *Where it comes from* control rather than offering one answer.
 */
export const EXTENSION_FACETS: Partial<Record<StoreFacet, FacetVocabulary>> = {
  category: {
    label: 'Category',
    anyName: 'Everything',
    options: CATEGORY_ORDER.map((id) => ({ id, name: CATEGORY_NAMES[id] })),
  },
  cost: {
    label: 'What it costs',
    anyName: 'Any price',
    /*
     * The shared order and the shared words, so a price chip reads the same in
     * both stores. `unknown` stays in this one — unlike the MCP store's, where
     * no row can be it — because a sideloaded extension genuinely is one, and
     * `facetControls` drops the option on any profile that has none.
     */
    options: COST_ORDER.map((id: StoreCost) => ({ id, name: COST_WORDS[id] })),
  },
  compat: {
    label: 'In this browser',
    anyName: 'Any',
    options: [
      { id: 'works', name: 'Works here' },
      { id: 'unknown', name: 'Not measured' },
      { id: 'cannot', name: 'Cannot work here' },
    ],
  },
  installed: {
    label: 'Installed',
    anyName: 'Any',
    options: [
      { id: 'yes', name: 'Installed' },
      { id: 'no', name: 'Not installed' },
    ],
  },
  source: {
    label: 'Where it comes from',
    anyName: 'Anywhere',
    options: [
      { id: 'release', name: 'The project’s own releases' },
      { id: 'your-own', name: 'Added by you' },
    ],
  },
  needs: {
    label: 'What it needs',
    anyName: 'Any',
    options: [
      { id: NEEDS_NOTHING, name: 'Nothing' },
      { id: 'account', name: 'An account' },
      { id: 'companion-app', name: 'Another app running here' },
    ],
  },
}
