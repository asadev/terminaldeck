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
 * The renderer's half of the MCP store.
 *
 * Optional, every method, for the reason `browser/store-bridge.ts` gives about
 * its own: `McpInspector`'s `resolveBridge` refuses to resolve at all when one
 * of `BRIDGE_METHODS` is missing, which is right for the methods the page
 * cannot draw a pixel without and catastrophic for a new one. A preload older
 * than this feature must cost the page its **Store tab**, never the whole MCP
 * page — so the store's methods are looked up separately and their absence is a
 * missing tab rather than an empty window.
 *
 * The types are mirrors rather than imports, again for the reason the rest of
 * this folder gives: the renderer's tsconfig does not include `src/main`. Every
 * value that arrives is narrowed below rather than trusted, because a main
 * process one version behind sends a shape these types only promise.
 */

/** Mirrors `McpRuntime` in `src/main/mcp-catalogue.ts`. */
export type McpRuntime = 'node' | 'python' | 'docker'

/** Mirrors `McpInputKind`. */
export type McpInputKind = 'secret' | 'path' | 'text'

/** Mirrors `McpAddTransport` in `src/main/mcp-add.ts`. */
export type McpAddTransport = 'stdio' | 'http' | 'sse'

/** Mirrors `McpOrigin`. */
export type McpOrigin = 'reference' | 'reference-archived' | 'vendor' | 'hosted' | 'third-party'

/**
 * Mirrors `McpStoreCost` in `src/main/mcp-store.ts`.
 *
 * A catalogue row's price is one of four things and never a guess. The fifth is
 * the answer only a row nobody catalogued can give — *this app has not measured
 * what your server costs* — and it belongs to the servers somebody added
 * themselves. The browser store has carried it since its own catalogue stopped
 * being all open source; both halves now can be it, for the same one row.
 */
export type McpCost = 'free' | 'account' | 'metered' | 'paid' | 'unknown'

/** Mirrors `McpCategory` in `src/main/mcp-catalogue.ts`. */
export type McpCategory =
  | 'files'
  | 'code'
  | 'work'
  | 'data'
  | 'cloud'
  | 'web'
  | 'browser'
  | 'knowledge'
  | 'design'
  | 'business'
  | 'thinking'
  | 'messaging'
  | 'utility'

/**
 * The shelves, and the name each wears. Mirrors `MCP_CATEGORIES`.
 *
 * Written out here rather than sent down the wire with the rows, for the reason
 * `browser/extensions-bridge.ts` gives about its own copy: a heading is a label
 * on a screen, and sending it would let a build of the panel draw a heading that
 * no longer matched what the panel does with it. A *measurement* — which runtime
 * was found, and where — travels, because it belongs to the module that took it.
 */
/**
 * The shelf a row can sit on. Mirrors `McpStoreCategory` in `src/main`.
 *
 * `your-own` is the one shelf the catalogue can never fill: it holds the servers
 * somebody typed themselves. The browser store spells its equivalent the same
 * way, which is deliberate — the two stores are meant to read as one product,
 * and *Added by you* means the same thing on both.
 */
export type McpStoreCategory = McpCategory | 'your-own'

export const MCP_CATEGORY_NAMES: Readonly<Record<McpStoreCategory, string>> = {
  files: 'Files on this machine',
  code: 'Code and repositories',
  work: 'Issues, projects and tickets',
  data: 'Databases',
  cloud: 'Hosting, cloud and what is running',
  web: 'Searching and reading the web',
  browser: 'Driving a browser',
  knowledge: 'Notes and documentation',
  design: 'Design',
  business: 'Payments and customers',
  thinking: 'What the agent remembers',
  messaging: 'Mail, chat and calendars',
  utility: 'Time, testing and odds and ends',
  'your-own': 'Added by you',
}

/**
 * The shelves the store browses by, in order, with *Added by you* last.
 *
 * It is on this list, and that is a change of mind worth writing down. When the
 * custom rows were first built, both departments still drew their own row of
 * category chips, and rendering it showed `Added by you 2` twice, two rows
 * apart — once as a category and once in *Where it comes from* — so the
 * category was dropped as the one filed under the wrong question.
 *
 * The store page took the chips away. Shelves now live in exactly one place, the
 * page's left rail, and the browser department has listed **Added by you** there
 * since the catalogue was widened. Leaving the MCP half off it would mean one
 * department offering a way to your own things in the rail and the other not,
 * which is the drift `store/storefront.ts` exists to stop.
 *
 * Nothing draws twice as a result: a custom row is always installed, so it never
 * reaches the browsing list `shelve` groups, and the *Added by you* section is
 * the only place one is rendered.
 */
export const MCP_CATEGORY_ORDER: readonly McpStoreCategory[] = [
  'files',
  'code',
  'work',
  'data',
  'cloud',
  'web',
  'browser',
  'knowledge',
  'design',
  'business',
  'thinking',
  'messaging',
  'utility',
  'your-own',
]

/** Mirrors `McpStoreState` in `src/main/mcp-store.ts`. */
export type McpStoreState = 'available' | 'installed' | 'taken' | 'unavailable'

export type McpEnvironmentSource = 'login-shell' | 'process' | 'unavailable'

export interface McpStoreInput {
  key: string
  label: string
  hint: string
  kind: McpInputKind
  into: 'env' | 'arg'
  required: boolean
  inEnvironment: boolean
}

export interface McpStoreRow {
  id: string
  name: string
  summary: string
  /** Which shelf it sits on. */
  category: McpStoreCategory
  /** Words to search on that are in neither the name nor the summary. */
  tags: string[]
  homepage: string
  registry: string
  licence: string
  version: string
  runtime: McpRuntime
  runtimeBinary: string
  origin: McpOrigin
  /** What using it costs. See `McpCost`. */
  cost: McpCost
  /** The price reality in a sentence, or `''`. */
  costNote: string
  command: string
  inputs: McpStoreInput[]
  state: McpStoreState
  scope: '' | 'user' | 'project' | 'local'
  /** True for a server somebody added themselves — see `src/main/mcp-custom.ts`. */
  custom: boolean
  transport: McpAddTransport
  /** The names of the environment variables it carries. Never the values. */
  envKeys: string[]
  /** How it runs, when the three-runtime vocabulary cannot say it. `''` otherwise. */
  runsWords: string
  /** The binary it needs was looked for on this machine and was not there. */
  runtimeMissing: boolean
  taken: string
  blocked: string
  caveat: string
  /** Which mark to draw, as a key into `store/logo-data.ts`. `''` for none. */
  logo: string
}

export interface McpRuntimeReport {
  id: McpRuntime
  binary: string
  found: boolean
  path: string
  needs: string
}

export interface McpStoreView {
  rows: McpStoreRow[]
  runtimes: McpRuntimeReport[]
  writer: { found: boolean; path: string }
  environmentSource: McpEnvironmentSource
  projectPath: string
}

export interface McpStoreResult {
  ok: boolean
  message: string
}

export interface McpStoreApi {
  mcpStore?(projectPath?: string | null): Promise<unknown>
  mcpStoreInstall?(request: unknown): Promise<unknown>
  /**
   * The removal, which is the page's own — see the note in `src/preload`. It is
   * named here because the store's rows carry a Remove and a bridge that could
   * list and install but not remove would be the half a control panel the MCP
   * page was already criticised for being.
   */
  removeMcpServer?(request: unknown): Promise<unknown>
  /**
   * The whole-server write, which is what “Add your own” goes through.
   *
   * Not `mcpStoreInstall`: that channel installs a *catalogue row by id* and
   * would refuse a hand-written command, which is the half of this store Asad
   * called the point — *"they can just click and attach their own things"*. One
   * write path per kind of thing being written, and both are named here so the
   * tab is only offered when both exist.
   */
  addMcpServer?(request: unknown): Promise<unknown>
  /**
   * Changing a server you added.
   *
   * Deliberately **not** in {@link METHODS}. The four below it are what a store
   * cannot be without — list, install, remove, add your own — and a build whose
   * preload predates this one should lose the *Edit* button on custom rows, not
   * the whole Store tab. Absent rather than disabled, the standing rule.
   */
  editMcpServer?(request: unknown): Promise<unknown>
  /** Writing one out as a file, and reading one back in. Same rule as above. */
  exportMcpServer?(name: string, scope: string, projectPath?: string | null): Promise<unknown>
  importMcpServer?(): Promise<unknown>
}

/** The optional half — a missing one costs a button, never the tab. */
const EXTRA_METHODS = [
  'editMcpServer',
  'exportMcpServer',
  'importMcpServer',
] as const satisfies readonly (keyof McpStoreApi)[]

const METHODS = [
  'mcpStore',
  'mcpStoreInstall',
  'removeMcpServer',
  'addMcpServer',
] as const satisfies readonly (keyof McpStoreApi)[]

export function resolveMcpStoreApi(host?: unknown): McpStoreApi {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  for (const name of [...METHODS, ...EXTRA_METHODS]) {
    const value = record[name]
    if (typeof value === 'function') api[name] = (value as (...args: never[]) => unknown).bind(source)
  }
  return api as McpStoreApi
}

/**
 * Is the store wired in this build?
 *
 * All four, the same bar `storeAvailable` sets next door and for the same
 * reason: a store with a list and no Install is a catalogue of things you cannot
 * have, one with an Install and no Remove is a one-way door, and one that cannot
 * take a server you typed yourself is a walled garden. Any of those is worse
 * than the tab not being there.
 */
export function mcpStoreAvailable(api: McpStoreApi): boolean {
  return METHODS.every((name) => typeof api[name] === 'function')
}

/* --------------------------------------------------------------- reading -- */

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function flag(value: unknown): boolean {
  return value === true
}

const KINDS: readonly McpInputKind[] = ['secret', 'path', 'text']
const STATES: readonly McpStoreState[] = ['available', 'installed', 'taken', 'unavailable']
const ORIGINS: readonly McpOrigin[] = [
  'reference',
  'reference-archived',
  'vendor',
  'hosted',
  'third-party',
]
const COSTS: readonly McpCost[] = ['free', 'account', 'metered', 'paid', 'unknown']
const RUNTIMES: readonly McpRuntime[] = ['node', 'python', 'docker']
const SOURCES: readonly McpEnvironmentSource[] = ['login-shell', 'process', 'unavailable']
const TRANSPORTS: readonly McpAddTransport[] = ['stdio', 'http', 'sse']

function oneOf<T extends string>(value: unknown, allowed: readonly T[], fallback: T): T {
  return allowed.find((candidate) => candidate === value) ?? fallback
}

function readInput(raw: unknown): McpStoreInput | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const key = text(record.key)
  if (key === '') return null
  const into = record.into === 'arg' ? 'arg' : 'env'
  return {
    key,
    label: text(record.label) || key,
    hint: text(record.hint),
    kind: oneOf(record.kind, KINDS, 'text'),
    into,
    required: flag(record.required),
    // Belt and braces on top of the main process's own rule: an `arg` can never
    // be inherited, so a build that sent `true` for one would be offering a
    // choice that does nothing.
    inEnvironment: into === 'env' && flag(record.inEnvironment),
  }
}

function readRow(raw: unknown): McpStoreRow | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const id = text(record.id)
  if (id === '') return null
  const scope = record.scope
  return {
    id,
    name: text(record.name) || id,
    summary: text(record.summary),
    category: oneOf(record.category, MCP_CATEGORY_ORDER, 'utility'),
    tags: Array.isArray(record.tags)
      ? record.tags.filter((one): one is string => typeof one === 'string').slice(0, 16)
      : [],
    homepage: text(record.homepage),
    registry: text(record.registry),
    licence: text(record.licence),
    version: text(record.version),
    runtime: oneOf(record.runtime, RUNTIMES, 'node'),
    runtimeBinary: text(record.runtimeBinary),
    origin: oneOf(record.origin, ORIGINS, 'third-party'),
    /*
     * A main process one version behind sends no price at all, and the fallback
     * is `account` rather than `free`. Both are guesses; only one of them can
     * cost somebody money, and a row that quietly reads *Free* because a field
     * was missing is exactly the failure this field was added to prevent.
     */
    cost: oneOf(record.cost, COSTS, 'account'),
    costNote: text(record.costNote),
    command: text(record.command),
    inputs: Array.isArray(record.inputs)
      ? record.inputs.map(readInput).filter((one): one is McpStoreInput => one !== null)
      : [],
    state: oneOf(record.state, STATES, 'available'),
    scope: scope === 'user' || scope === 'project' || scope === 'local' ? scope : '',
    custom: flag(record.custom),
    transport: oneOf(record.transport, TRANSPORTS, 'stdio'),
    envKeys: Array.isArray(record.envKeys)
      ? record.envKeys.filter((one): one is string => typeof one === 'string').slice(0, 32)
      : [],
    runsWords: text(record.runsWords),
    runtimeMissing: flag(record.runtimeMissing),
    taken: text(record.taken),
    blocked: text(record.blocked),
    caveat: text(record.caveat),
    logo: text(record.logo),
  }
}

function readRuntime(raw: unknown): McpRuntimeReport | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const id = RUNTIMES.find((candidate) => candidate === record.id)
  if (id === undefined) return null
  return {
    id,
    binary: text(record.binary),
    found: flag(record.found),
    path: text(record.path),
    needs: text(record.needs),
  }
}

export const EMPTY_STORE_VIEW: McpStoreView = {
  rows: [],
  runtimes: [],
  writer: { found: false, path: '' },
  environmentSource: 'unavailable',
  projectPath: '',
}

export function readMcpStoreView(raw: unknown): McpStoreView {
  if (typeof raw !== 'object' || raw === null) return EMPTY_STORE_VIEW
  const record = raw as Record<string, unknown>
  const writer =
    typeof record.writer === 'object' && record.writer !== null
      ? (record.writer as Record<string, unknown>)
      : {}
  return {
    rows: Array.isArray(record.rows)
      ? record.rows.map(readRow).filter((one): one is McpStoreRow => one !== null)
      : [],
    runtimes: Array.isArray(record.runtimes)
      ? record.runtimes.map(readRuntime).filter((one): one is McpRuntimeReport => one !== null)
      : [],
    writer: { found: flag(writer.found), path: text(writer.path) },
    environmentSource: oneOf(record.environmentSource, SOURCES, 'unavailable'),
    projectPath: text(record.projectPath),
  }
}

/**
 * A result, narrowed.
 *
 * A shape that is not a result is a failure with the honest sentence, never a
 * silent success: `ok` defaulting to true would turn a main process that threw
 * into a green message over a thing that did not happen.
 */
export function readMcpStoreResult(raw: unknown): McpStoreResult {
  if (typeof raw !== 'object' || raw === null) return { ok: false, message: 'That did not work.' }
  const record = raw as Record<string, unknown>
  const message = text(record.message)
  const ok = record.ok === true
  return { ok, message: message === '' ? (ok ? 'Done.' : 'That did not work.') : message }
}

/**
 * What an import answered with: a sentence, and the draft it read.
 *
 * The draft is the whole reason this is not just an {@link McpStoreResult}: an
 * import **writes nothing**. It fills in the add form and the person presses the
 * button, which is the same shape as installing a catalogue row that needs a
 * token — a definition somebody mailed you is not more trusted than one in the
 * catalogue. See `src/main/mcp-share.ts`.
 */
export interface McpImportedDraft {
  name: string
  transport: McpAddTransport
  command: string
  url: string
  /** Variable names, to be drawn as empty fields. The file carries no values. */
  env: string[]
}

export interface McpImportResult extends McpStoreResult {
  draft: McpImportedDraft | null
}

export function readMcpImport(raw: unknown): McpImportResult {
  const result = readMcpStoreResult(raw)
  if (typeof raw !== 'object' || raw === null) return { ...result, draft: null }
  const record = (raw as Record<string, unknown>).draft
  if (typeof record !== 'object' || record === null) return { ...result, draft: null }
  const draft = record as Record<string, unknown>
  const name = text(draft.name)
  if (name === '') return { ...result, draft: null }
  return {
    ...result,
    draft: {
      name,
      transport: oneOf(draft.transport, TRANSPORTS, 'stdio'),
      command: text(draft.command),
      url: text(draft.url),
      env: Array.isArray(draft.env)
        ? draft.env.filter((one): one is string => typeof one === 'string').slice(0, 32)
        : [],
    },
  }
}

/* ---------------------------------------------------------------- words -- */

/** What each origin means, in a phrase, on the row. */
export const ORIGIN_WORDS: Readonly<Record<McpOrigin, string>> = {
  reference: 'Reference server',
  'reference-archived': 'Archived reference server',
  vendor: 'From the vendor',
  hosted: 'Runs on the vendor’s servers',
  'third-party': 'Third party',
}

/** The id every custom row wears in the *source* facet. */
export const CUSTOM_SOURCE = 'custom'

/**
 * The phrase the chip in a row's head wears.
 *
 * `origin` is what the *catalogue* established about a project, and a server
 * this app has never heard of has no such fact — so a custom row says the only
 * true thing there is to say about where it came from. See `McpStoreRow.custom`
 * for why this is a separate field rather than a sixth `McpOrigin`.
 */
export function sourceWords(row: McpStoreRow): string {
  return row.custom ? 'Added by you' : ORIGIN_WORDS[row.origin]
}

/**
 * How a custom row's command runs, or the catalogue's phrase for a runtime.
 *
 * One function so the row has one line to draw and cannot end up printing "npx —
 * fetched from npm the first time it runs" under `/usr/local/bin/serve`, which
 * is what it would have done with `RUNTIME_WORDS` alone.
 */
export function runsWords(row: McpStoreRow): string {
  return row.runsWords === '' ? RUNTIME_WORDS[row.runtime] : row.runsWords
}

/**
 * What a price wears on the row.
 *
 * Taken from `store/storefront.ts` rather than spelled again here, which is the
 * one exception to this file's *"the words are the store's own"* rule and is
 * argued there: a monthly bill is the same fact in both stores, and two names
 * for it would be the drift the shared model exists to stop.
 *
 * All five, `unknown` included. It was once left out on the grounds that *"every
 * row of this catalogue is one this file wrote"* — which stopped being the whole
 * story when the store started carrying the servers somebody typed themselves.
 * Nobody wrote a catalogue entry for one of those, so nobody read its pricing
 * page, and *Not known* is the only honest chip it can wear.
 */
export const COST_LABELS: Readonly<Record<McpCost, string>> = {
  free: COST_WORDS.free,
  account: COST_WORDS.account,
  metered: COST_WORDS.metered,
  paid: COST_WORDS.paid,
  unknown: COST_WORDS.unknown,
}

/** How each runtime fetches and starts the server, on the row. */
export const RUNTIME_WORDS: Readonly<Record<McpRuntime, string>> = {
  node: 'npx — fetched from npm the first time it runs',
  python: 'uvx — fetched from PyPI the first time it runs',
  docker: 'docker — pulled as a container image',
}

/**
 * What a row needs, in one phrase, before anything is pressed.
 *
 * Pure and exported because it is the sentence the section list is sorted and
 * filtered by, and *"a row that cannot work without one says so BEFORE install
 * rather than failing after"* is the whole requirement. Deriving it in JSX would
 * put that promise in a place no test can reach.
 */
export function needsWords(row: McpStoreRow): string {
  const required = row.inputs.filter((input) => input.required)
  if (required.length === 0) return row.inputs.length === 0 ? 'Nothing' : 'Nothing required'
  // The labels' own case, not lowered. This phrase and the "Needs …" line under
  // the button name the same fields, and two spellings of one field on one row
  // reads as two different things.
  return required.map((input) => input.label).join(', ')
}

/**
 * Which fields still have to be filled before Install can do anything.
 *
 * The button is disabled on this and the row names them, rather than the press
 * going to the main process to be refused there. Both ends check — the main
 * process must, because a bridge is not a boundary you trust — but a user
 * should never be the one to discover it.
 */
export function unfilled(row: McpStoreRow, values: Record<string, string>): string[] {
  return row.inputs
    .filter((input) => input.required)
    .filter((input) => (values[input.key] ?? '').trim() === '' && !input.inEnvironment)
    .map((input) => input.label)
}

/* ------------------------------------------------------------- storefront -- */

/**
 * What this row needs a person to bring, as ids the shared filter can match.
 *
 * Three values, and each is a different kind of obstacle:
 *
 *  - `token` — a key or an account somewhere else. Only for a `secret` input,
 *    because that is the one the catalogue verified by reading the package's own
 *    README: `NOTION_TOKEN`, `TAVILY_API_KEY` and the rest are the packages' own
 *    spellings rather than plausible ones.
 *  - `setting` — something on this machine it has to be pointed at. A directory
 *    for `filesystem`, a repository for `git`, a connection string for postgres.
 *  - `docker` — a container runtime, which is a separate install that also has
 *    to be *running*, not only present. `npx` and `uvx` are not on this list:
 *    every row needs one of those, so a filter for them would keep the whole
 *    catalogue and answer nothing.
 *
 * A set rather than one winner, because the GitHub row needs a token **and**
 * Docker, and a single value would have hidden one of those from whichever
 * filter somebody chose.
 */
export function mcpNeeds(row: McpStoreRow): string[] {
  const needs: string[] = []
  if (row.inputs.some((input) => input.required && input.kind === 'secret')) needs.push('token')
  if (row.inputs.some((input) => input.required && input.kind !== 'secret')) needs.push('setting')
  if (row.runtime === 'docker') needs.push('docker')
  return needs
}

/**
 * How much this app knows about the row working here.
 *
 * Never `works`, and that is not an oversight — it is `mcp-catalogue.ts`'s own
 * standing statement, kept: *"Nothing here was watched working, and no row says
 * it was."* The browser store can claim `works` because it loaded the artifact
 * into this app's own Electron and watched it; here the artifact is a process
 * fetched from a registry at spawn time and run by the agent, not by this app.
 *
 * So the two live values are `cannot` — the runtime was looked for on this
 * machine with the same `which` this app uses everywhere else, and was not there
 * — and `unknown`, which is *the runtime is here and nothing further is
 * claimed*. `facetControls` drops a group with fewer than two live options, so
 * on a machine with every runtime present this facet simply is not drawn.
 */
export function mcpCompat(row: McpStoreRow): StoreCompat {
  /*
   * `runtimeMissing` rather than `state === 'unavailable'`, and the two coincide
   * only for catalogue rows. A server somebody added whose runtime has since
   * been uninstalled is still *installed* — it is in the configuration and it
   * will fail when something tries to start it — so it never reaches that state,
   * and a filter keyed on the state would have answered "its runtime is here"
   * about a row that says on its face that the runtime is not.
   */
  return row.runtimeMissing ? 'cannot' : 'unknown'
}

/**
 * One MCP row as the shared storefront sees it.
 *
 * The whole of what `components/` contributes to searching and filtering; every
 * decision made from it lives in `store/storefront.ts`, which is what stops the
 * two stores drifting into two different ideas of what a partial word is.
 *
 * `taken` does **not** count as installed, and the line is worth drawing there
 * rather than anywhere else. A server of that name is in the configuration and
 * it is not this one — this row is a thing you do not have, sitting behind a
 * name collision — so *Installed* would answer *do I have this* with somebody
 * else's server. It stays on its shelf, with a chip and the sentence naming the
 * command line already wearing the name.
 */
export function mcpFacets(row: McpStoreRow): StoreFacets {
  return {
    id: row.id,
    name: row.name,
    summary: row.summary,
    category: row.category,
    categoryName: MCP_CATEGORY_NAMES[row.category],
    tags: row.tags,
    cost: row.cost,
    compat: mcpCompat(row),
    installed: row.state === 'installed',
    source: row.custom ? CUSTOM_SOURCE : row.origin,
    needs: mcpNeeds(row),
  }
}

/**
 * What the MCP store's filter chips say.
 *
 * The `source` group is where the requirement *"the archived distinction must
 * survive"* lands, and it survives with the fact behind it intact: the catalogue
 * established on a dated day that `modelcontextprotocol/servers-archived` is a
 * repository GitHub reports as `archived: true`, and six rows are in it. A
 * filter that quietly folded those into *reference* would be throwing away the
 * one maintenance fact this catalogue actually checked.
 */
export const MCP_FACETS: Partial<Record<StoreFacet, FacetVocabulary>> = {
  category: {
    label: 'Category',
    anyName: 'Everything',
    options: MCP_CATEGORY_ORDER.map((id) => ({ id, name: MCP_CATEGORY_NAMES[id] })),
  },
  cost: {
    label: 'What it costs',
    anyName: 'Any price',
    /*
     * Drawn straight from the shared order, so the browser store's price chips
     * and these are the same words in the same sequence — `unknown` included.
     *
     * It used to be filtered out here on the grounds that no MCP row could be
     * one. That is still true of every *catalogue* row and no longer true of the
     * store: a server somebody typed is priced `unknown`, because this app has
     * never opened it. `facetControls` drops an option no row would match, so on
     * a machine with nothing hand-written the chip is simply not drawn — which
     * is what filtering it out here was really trying to achieve.
     */
    options: COST_ORDER.map((id: StoreCost) => ({ id, name: COST_WORDS[id] })),
  },
  compat: {
    label: 'On this machine',
    anyName: 'Any',
    options: [
      { id: 'unknown', name: 'Its runtime is here' },
      { id: 'cannot', name: 'Runtime missing' },
    ],
  },
  installed: {
    label: 'Installed',
    anyName: 'Any',
    options: [
      { id: 'yes', name: 'In your configuration' },
      { id: 'no', name: 'Not configured' },
    ],
  },
  source: {
    label: 'Where it comes from',
    anyName: 'Anywhere',
    options: [
      /*
       * First, because it is the answer a person is most often looking *for*
       * rather than browsing past — "where is the one I added". `facetControls`
       * drops an option no row would match, so on a machine with nothing
       * hand-written this chip is simply not drawn.
       */
      { id: CUSTOM_SOURCE, name: 'Added by you' },
      { id: 'reference', name: 'Official reference' },
      { id: 'vendor', name: 'From the vendor' },
      { id: 'hosted', name: 'Runs on the vendor’s servers' },
      { id: 'third-party', name: 'Community' },
      { id: 'reference-archived', name: 'Archived — unmaintained' },
    ],
  },
  needs: {
    label: 'What it needs',
    anyName: 'Any',
    options: [
      { id: NEEDS_NOTHING, name: 'Nothing' },
      { id: 'token', name: 'A key or token' },
      { id: 'setting', name: 'A path or setting' },
      { id: 'docker', name: 'Docker' },
    ],
  },
}

/**
 * The project page a row with no Install sends somebody to, or `''`.
 *
 * The same third answer the browser store now gives, for the same reason: a row
 * whose runtime is missing, or whose name is already taken by somebody else's
 * server, correctly gets no Install and used to get no control at all. The
 * project page is on the row already; making it a button costs nothing and turns
 * a dead end into a way onward.
 *
 * Never on a row that has an Install, and never on an installed one. Two
 * controls on one row where one of them quietly does something else is exactly
 * what this store refuses elsewhere.
 */
export function mcpLinkOut(row: McpStoreRow): string {
  if (row.state === 'installed' || row.blocked === '') return ''
  // A custom row has no project page — nobody published it — and `homepage` is
  // `''` on every one of them, so this is belt and braces rather than a branch
  // that changes an outcome.
  if (row.custom) return ''
  return /^https?:\/\//i.test(row.homepage) ? row.homepage : ''
}
