// Relative, not '@shared/store-manifest'. Vitest runs without the electron-vite
// resolver, so the alias is not there — importing through it takes down the
// whole test file of anything that touches this module. `renderer/accounts.ts`
// carries the same note for the same reason.
import {
  KIND_NAMES,
  STORE_KINDS,
  TIER_WORDS,
  type ManifestAgent,
  type StoreKind,
  type StoreTier,
} from '../../shared/store-manifest'
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
 * The renderer's half of the Community store.
 *
 * ## Optional, every method of it
 *
 * The same rule `browser/store-bridge.ts` states in its own header: `bridge.ts`
 * refuses to resolve at all when one of `BRIDGE_METHODS` is missing, which is
 * right for the methods a window cannot draw a pixel without and catastrophic
 * for a new one. A preload older than this feature must cost the store its third
 * department, never the whole window.
 *
 * ## The types are mirrors, and here that is not a preference
 *
 * `src/main/store-index.ts` already declares `StoreRow` — the row of the signed
 * catalogue — and this file cannot import it: `tsconfig.web.json` includes
 * `src/renderer`, `src/shared` and nothing else, deliberately, so that a screen
 * can never reach into the main process's graph. What it *can* import is
 * `@shared/store-manifest`, which is where the closed vocabularies live — the
 * seven kinds, the three tiers and the words each wears — so the two halves
 * agree on the words that matter without the renderer learning what a sha256
 * check is.
 *
 * Everything below narrows. Nothing that arrives over the wire is trusted to be
 * the shape it claims, and nothing here throws: a catalogue with one malformed
 * row draws the rest of the shop.
 *
 * ## What this deliberately does not do
 *
 * Decide anything. Where the catalogue is fetched from, whether its signature
 * checked out, what the tier recomputed to over the bytes that actually
 * arrived — all of that is settled in the main process before a byte of it
 * reaches here, and the view carries the *answers*. A renderer that re-derived
 * any of it would be a second opinion with less evidence.
 */

/* ------------------------------------------------------------- the shapes -- */

/**
 * What state an installed community item is in.
 *
 * The first four mirror `ToolState` in `src/main/browser-store.ts`. `withdrawn`
 * is the fifth and it is this store's own: an item pulled from the catalogue
 * after somebody installed it. It is drawn in red with the reason beside a
 * Remove, and **it never disappears and never deletes itself** — taking a
 * stranger's files off somebody's disk because a web form was filled in is not a
 * capability a catalogue should have.
 */
export type CommunityState = 'available' | 'installed' | 'outdated' | 'damaged' | 'withdrawn'

const STATES: readonly CommunityState[] = [
  'available',
  'installed',
  'outdated',
  'damaged',
  'withdrawn',
]

/** How an item's bytes reach this machine. Mirrors `StoreDelivery`. */
export type CommunityDelivery = 'repo' | 'off-site'

/**
 * One agent, as the install sheet has to draw it.
 *
 * All three are always in this list, whatever is on the machine, because
 * `found` is the thing being reported and a missing row would report it by
 * absence — which is the one shape house rule 4 forbids. `note` is a short line
 * the main process supplies for the two answers that are genuinely unusual; it
 * is never composed here, so the sentence lives once, beside the code that
 * makes it true.
 */
export interface CommunityAgent {
  id: ManifestAgent
  /** What this agent is called on screen, from the shared catalogue. */
  name: string
  /** Whether its binary was found on this machine. */
  found: boolean
  /** One short line, or `''`. Never a paragraph — see `InstallSheet.tsx`. */
  note: string
}

/** One row of the signed catalogue, as a screen needs to see it. */
export interface CommunityItem {
  /** `<publisher>/<id>`, which is what every other list joins on. */
  id: string
  publisher: string
  /** The publisher's handle, without the at-sign. */
  handle: string
  /** Their page on the site, or `''`. A non-http value draws no link at all. */
  profileUrl: string
  kind: StoreKind
  name: string
  summary: string
  version: string
  licence: string
  tags: string[]
  /** Which agents the publisher states they tested it against. */
  agents: ManifestAgent[]
  /** Recomputed from the received bytes by the main process, never claimed here. */
  tier: StoreTier
  needs: string[]
  /** Of those needs, the ones this machine does not have. */
  missing: string[]
  cost: StoreCost
  costNote: string
  delivery: CommunityDelivery
  /** Where an off-site listing sends somebody. `''` for anything we install. */
  offsiteUrl: string
  repo: string
  /** 40 hex characters. Never a tag: a tag moves and the pin is the whole story. */
  commit: string
  artifactUrl: string
  sha256: string
  bytes: number
  /** Hosts the item declares it talks to. */
  network: string[]
  updatedAt: string
  /** GitHub's own numbers, labelled as theirs. `-1` means we do not have one. */
  stars: number
  openIssues: number
  /** A rating is drawn only from five people up — see {@link ratingChip}. */
  ratingScore: number
  ratingCount: number
  state: CommunityState
  /** The version on this disk, or `''`. This is what "installed" actually means. */
  installedVersion: string
  /** The real reason a row is damaged or an install refused. Never a summary. */
  message: string
  /** Why it was withdrawn, when it was. */
  reason: string
  /** Every absolute path installing it writes. Computed by the installer itself. */
  lands: string[]
  /** For an `mcp` item: the command this app's own code composes. */
  command: string
  /** For an `mcp` item: the variable NAMES it wants. Never values. */
  variables: string[]
  /** For a `routine`: what it would be triggered by. It arrives disarmed. */
  trigger: string
  /** For an `extension`: the hosts it may reach. */
  reach: string[]
  /** The key into `store/logo-data.ts`, or `''` for a monogram. */
  logo: string
}

/** Everything `community:list` answers, narrowed. */
export interface CommunityView {
  /** Whether this list came off the network or out of the kept copy. */
  from: 'store' | 'kept'
  /** When it was fetched, ISO. What the offline line prints the date of. */
  at: string
  /** A sentence about the list's age, or `''`. */
  stale: string
  /** Why the store could not be reached, when a kept list is being shown. */
  because: string
  /** Why there is nothing at all to show. `''` when there is. */
  problem: string
  items: CommunityItem[]
  /** Where installed items are kept, so Remove's promise can be checked. */
  folder: string
  agents: CommunityAgent[]
}

/** What an install or a remove answered. */
export interface CommunityResult {
  ok: boolean
  message: string
}

export interface CommunityApi {
  community?(): Promise<unknown>
  communityInstall?(id: string, agents: readonly string[]): Promise<unknown>
  communityRemove?(id: string): Promise<unknown>
  communityRefresh?(): Promise<unknown>
}

const METHODS = [
  'community',
  'communityInstall',
  'communityRemove',
  'communityRefresh',
] as const satisfies readonly (keyof CommunityApi)[]

export function resolveCommunityApi(host?: unknown): CommunityApi {
  const source =
    host ??
    (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  for (const name of METHODS) {
    const value = record[name]
    if (typeof value === 'function') {
      api[name] = (value as (...args: never[]) => unknown).bind(source)
    }
  }
  return api as CommunityApi
}

/**
 * Is the department wired in this build?
 *
 * All four, for the reason `storeAvailable` gives about its three: a store with
 * a list and no Install is a catalogue of things you cannot have, and one with
 * an Install and no Remove is worse than no store at all. Refresh is the fourth
 * because this catalogue arrives over a network — a department that can never
 * ask again is one whose only answer to "the list looks old" is to quit the app.
 *
 * A `false` here makes the department **absent** from the store's rail. Never
 * greyed: `store/store-nav.ts` drops an unwired department entirely, so there is
 * nothing to navigate to and nothing to press.
 */
export function communityAvailable(api: CommunityApi): boolean {
  return (
    typeof api.community === 'function' &&
    typeof api.communityInstall === 'function' &&
    typeof api.communityRemove === 'function' &&
    typeof api.communityRefresh === 'function'
  )
}

/* ---------------------------------------------------------------- reading -- */

function text(raw: unknown): string {
  return typeof raw === 'string' ? raw : ''
}

function count(raw: unknown, floor = 0): number {
  return typeof raw === 'number' && Number.isFinite(raw) ? raw : floor
}

function words(raw: unknown, limit: number): string[] {
  if (!Array.isArray(raw)) return []
  return raw.filter((entry): entry is string => typeof entry === 'string').slice(0, limit)
}

function readKind(raw: unknown): StoreKind | null {
  return STORE_KINDS.includes(raw as StoreKind) ? (raw as StoreKind) : null
}

function readTier(raw: unknown): StoreTier {
  // The highest of the three when the answer is not one of them. A row whose
  // tier did not survive the wire is not a row to describe as harmless.
  return raw === 1 || raw === 2 || raw === 3 ? raw : 3
}

function readState(raw: unknown): CommunityState {
  return STATES.includes(raw as CommunityState) ? (raw as CommunityState) : 'available'
}

function readCost(raw: unknown): StoreCost {
  return COST_ORDER.includes(raw as StoreCost) ? (raw as StoreCost) : 'unknown'
}

function readAgents(raw: unknown): ManifestAgent[] {
  if (!Array.isArray(raw)) return []
  return raw.filter(
    (one): one is ManifestAgent => one === 'claude' || one === 'codex' || one === 'gemini',
  )
}

function readItem(raw: unknown): CommunityItem | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const id = text(record.id)
  const kind = readKind(record.kind)
  /*
   * A row whose kind this build does not know is dropped rather than drawn.
   *
   * Every control on it is decided by the kind — which shelf it stands on, what
   * the sheet says installing it means, whether there is anything to install at
   * all — and there is no honest default for "something we have no idea how to
   * run". The catalogue's own parser refuses one too; this is the same refusal
   * on the far side of the wire, because a renderer that trusts the shape it was
   * handed is a renderer with no opinion of its own.
   */
  if (id === '' || kind === null) return null
  const publisher = text(record.publisher)
  return {
    id,
    publisher,
    handle: text(record.handle) || publisher,
    profileUrl: text(record.profileUrl),
    kind,
    name: text(record.name) || id,
    summary: text(record.summary),
    version: text(record.version),
    licence: text(record.licence),
    tags: words(record.tags, 16),
    agents: readAgents(record.agents),
    tier: readTier(record.tier),
    needs: words(record.needs, 12),
    missing: words(record.missing, 12),
    cost: readCost(record.cost),
    costNote: text(record.costNote),
    delivery: record.delivery === 'off-site' ? 'off-site' : 'repo',
    offsiteUrl: text(record.offsiteUrl),
    repo: text(record.repo),
    commit: text(record.commit),
    artifactUrl: text(record.artifactUrl),
    sha256: text(record.sha256),
    bytes: count(record.bytes),
    network: words(record.network, 40),
    updatedAt: text(record.updatedAt),
    stars: count(record.stars, -1),
    openIssues: count(record.openIssues, -1),
    ratingScore: count(record.ratingScore),
    ratingCount: count(record.ratingCount),
    state: readState(record.state),
    installedVersion: text(record.installedVersion),
    message: text(record.message),
    reason: text(record.reason),
    lands: words(record.lands, 24),
    command: text(record.command),
    variables: words(record.variables, 24),
    trigger: text(record.trigger),
    reach: words(record.reach, 40),
    logo: text(record.logo),
  }
}

function readAgentRow(raw: unknown): CommunityAgent | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const id = readAgents([record.id])[0]
  if (id === undefined) return null
  return { id, name: text(record.name) || id, found: record.found === true, note: text(record.note) }
}

/** Nothing loaded yet, and nothing claimed about why. */
export const NO_COMMUNITY: CommunityView = {
  from: 'store',
  at: '',
  stale: '',
  because: '',
  problem: '',
  items: [],
  folder: '',
  agents: [],
}

/** What `community:list` answered, narrowed. Never throws. */
export function readCommunityView(raw: unknown): CommunityView {
  if (typeof raw !== 'object' || raw === null) return NO_COMMUNITY
  const record = raw as Record<string, unknown>
  const items = Array.isArray(record.items)
    ? record.items.map(readItem).filter((one): one is CommunityItem => one !== null)
    : []
  return {
    from: record.from === 'kept' ? 'kept' : 'store',
    at: text(record.at),
    stale: text(record.stale),
    because: text(record.because),
    problem: text(record.problem),
    items,
    folder: text(record.folder),
    agents: Array.isArray(record.agents)
      ? record.agents.map(readAgentRow).filter((one): one is CommunityAgent => one !== null)
      : [],
  }
}

/** What an install or a remove answered, narrowed. */
export function readCommunityResult(raw: unknown): CommunityResult {
  if (typeof raw !== 'object' || raw === null) {
    return { ok: false, message: 'The app did not answer.' }
  }
  const record = raw as Record<string, unknown>
  return { ok: record.ok === true, message: text(record.message) }
}

/* ------------------------------------------------------------- the facets -- */

/** The shelves, in the order the department draws them. */
export const KIND_ORDER: readonly StoreKind[] = STORE_KINDS

/** The shelves the store page's rail is handed, with their words. */
export const COMMUNITY_SHELVES: readonly { id: string; name: string }[] = KIND_ORDER.map((id) => ({
  id,
  name: KIND_NAMES[id],
}))

/** The word every community row wears under "where it comes from". */
export const COMMUNITY_SOURCE = 'community'

/**
 * The needs that are about *this machine* rather than about an account.
 *
 * Only these can make a row `cannot`. A missing key is something a person goes
 * and gets in five minutes; a missing runtime is the row not working here, and
 * conflating the two would put a red answer on half the shop.
 */
const RUNTIME_NEEDS = new Set(['node', 'python', 'local-app', 'runs-scripts'])

/**
 * One row, as the shared storefront model sees it.
 *
 * `compat` is `unknown` unless something on this machine was actually measured
 * missing, and that is the point rather than caution: `storefront.ts` says
 * outright that `unknown` means **nothing was measured** and is never "probably
 * fine". Nothing in a community catalogue was watched running here.
 */
export function communityFacets(item: CommunityItem): StoreFacets {
  const cannot = item.missing.some((need) => RUNTIME_NEEDS.has(need))
  const compat: StoreCompat = cannot ? 'cannot' : 'unknown'
  return {
    id: item.id,
    name: item.name,
    summary: item.summary,
    category: item.kind,
    categoryName: KIND_NAMES[item.kind],
    /* The handle is searchable. "Where is the thing that person published" is a
       real question in a shop whose rows are strangers' work, and no summary in
       the catalogue contains a handle. */
    tags: [...item.tags, item.handle, item.publisher],
    cost: item.cost,
    compat,
    /* What is on this disk, which is not the same question as what state the row
       is in: an item withdrawn after somebody installed it is still installed. */
    installed: item.installedVersion !== '',
    source: COMMUNITY_SOURCE,
    needs: item.needs,
  }
}

/**
 * What this department's chips say.
 *
 * `category` is declared and then removed again by `withoutShelf` before the bar
 * is drawn — the shelves are the page's own rail, with a count on each, and a
 * second row of chips saying the same thing would be two controls for one
 * choice. It is declared anyway so this table is the whole vocabulary in one
 * place rather than most of it.
 *
 * `source` is deliberately absent. Every row here comes from the same place, so
 * a control offering one option is a control that cannot act — and
 * `facetControl` would drop it anyway, which is the rule doing the work rather
 * than a habit.
 */
export const COMMUNITY_FACETS: Partial<Record<StoreFacet, FacetVocabulary>> = {
  category: {
    label: 'Kind',
    anyName: 'Everything',
    options: COMMUNITY_SHELVES.map((shelf) => ({ id: shelf.id, name: shelf.name })),
  },
  cost: {
    label: 'What it costs',
    anyName: 'Any price',
    /* Straight from the shared order, so a price is the same word in all three
       departments. `facetControls` drops any option no row would match, so a
       shop of free things draws no price control at all. */
    options: COST_ORDER.map((id: StoreCost) => ({ id, name: COST_WORDS[id] })),
  },
  compat: {
    label: 'On this machine',
    anyName: 'Any',
    options: [
      { id: 'unknown', name: 'Nothing missing' },
      { id: 'cannot', name: 'Needs something you do not have' },
    ],
  },
  installed: {
    label: 'Installed',
    anyName: 'Any',
    options: [
      { id: 'yes', name: 'On this machine' },
      { id: 'no', name: 'Not installed' },
    ],
  },
  needs: {
    label: 'What it needs',
    anyName: 'Any',
    options: [
      { id: NEEDS_NOTHING, name: 'Nothing' },
      { id: 'runs-scripts', name: 'To run scripts' },
      { id: 'node', name: 'Node' },
      { id: 'python', name: 'Python' },
      { id: 'api-key', name: 'A key or token' },
      { id: 'account', name: 'An account somewhere' },
      { id: 'local-app', name: 'Another program' },
    ],
  },
}

/* ------------------------------------------------------------- small words -- */

/**
 * The host of a URL, for the one outbound button an off-site listing carries.
 *
 * Pure and exported because it is the whole of what that button promises — *Get
 * it from acme.com* is a claim about where pressing it lands, and a claim built
 * by slicing a string is a claim that can be wrong. `www.` is dropped because
 * nobody says it.
 */
export function domainOf(url: string): string {
  try {
    const host = new URL(url).hostname
    return host.startsWith('www.') ? host.slice(4) : host
  } catch {
    return ''
  }
}

/**
 * The date a kept catalogue was fetched, in the words the offline line uses.
 *
 * `en-GB` explicitly rather than the machine's locale: this is compared against
 * in tests, and a line that reads differently on two machines is a line nobody
 * can pin. The app is English everywhere else for the same reason.
 */
export function catalogueDate(iso: string): string {
  const at = new Date(iso)
  if (Number.isNaN(at.getTime())) return ''
  return at.toLocaleDateString('en-GB', { day: 'numeric', month: 'long' })
}

/**
 * The rating chip's text, or `''` for a row that has not earned one.
 *
 * Two rules, and both are about not printing a number that means nothing. Under
 * five ratings there is no chip at all — *5.0* from one vote is the most
 * confident-looking lie a store can tell. And a paid row never carries one,
 * because we cannot see a purchase: a rating we cannot tie to anybody who
 * actually paid is a number about a different population than the one reading
 * it.
 */
export function ratingChip(item: CommunityItem): string {
  if (item.cost === 'paid' || item.ratingCount < 5) return ''
  /* The word `Rated` rather than a bare pair of numbers. On the row this chip
     sits two along from `★ 1,204`, and rendering it showed `4.6 · 21` reading as
     one more of GitHub's counts — which is the one thing it is not. */
  return `Rated ${item.ratingScore.toFixed(1)} · ${item.ratingCount}`
}

/** The tier sentence a row and its sheet both wear. One spelling, one place. */
export function tierWord(item: CommunityItem): string {
  return TIER_WORDS[item.tier]
}

/**
 * Whether this row has an Install at all.
 *
 * An off-site listing does not, and it does not get a disabled one either: it is
 * a classified advertisement — the publisher's own price and a way to go and
 * look at it. *Never a disabled Install* is the same law `facetControl` encodes
 * structurally by returning null below two options.
 */
export function installable(item: CommunityItem): boolean {
  return item.delivery === 'repo'
}
