/**
 * The one storefront model, shared by both stores.
 *
 * ## Why this file exists
 *
 * Two stores were built in the same release and they are meant to read as one
 * product. Asad, re-scanning them:
 *
 *   > *"make a proper search page and everything proper filters and search and
 *   > separation of the categories … so they can categorize and choose which
 *   > specific tool they want."*
 *
 * The browser's store had a search box and a row of category chips. The MCP
 * store had neither, and it grouped by *state* — Installed, Ready, Cannot run —
 * which is a list of nineteen things in four bins rather than something a person
 * browses. Adding a second search box next to the first would have produced two
 * stores that behave *almost* the same, and the almost is where they drift: one
 * lower-cases and the other does not, one searches tags and the other forgets,
 * one hides an empty chip and the other draws a dead one.
 *
 * So the deciding is here, once, as pure functions over one shape, and each
 * store's job is reduced to translating its own rows into {@link StoreFacets}.
 * `browser/extensions-bridge.ts` and `components/mcp-store-bridge.ts` each hold
 * exactly one such translator, and they are the only per-store code involved in
 * searching or filtering anything.
 *
 * ## What is deliberately *not* shared
 *
 * The words. A facet's **id** is shared; the sentence it wears on screen is
 * supplied by the store that drew it, because the two catalogues genuinely know
 * different things. The browser store measured its rows running in this app's
 * own Electron and can say *works here*; the MCP catalogue says outright that
 * *"nothing here was watched working"*, and the most it can claim is that the
 * runtime a row needs is on this machine. Forcing one vocabulary onto both would
 * mean one of them saying something it did not measure — which is the failure
 * both stores were written against.
 *
 * ## The one rule every control here obeys
 *
 * A filter option is drawn only if choosing it would leave something on screen.
 * `StorePanel.tsx` already argued this for its category chips — *"a chip that
 * filtered down to 'nothing matches that' would be a control that does nothing,
 * which is the thing this app keeps being about"* — and {@link facetOptions}
 * makes it structural rather than a habit each store has to remember.
 */

/** The value that means "do not filter on this facet". */
export const ANY = 'all'

/**
 * How much this app knows about whether a row works where it is being offered.
 *
 * Three values, and the middle one is the important one. `unknown` is not a
 * softer `cannot`: it is *nothing was measured*, which the browser catalogue
 * spends a paragraph distinguishing from *it was run here and watched failing*,
 * and which is the only honest answer an MCP row can ever give about itself.
 */
export type StoreCompat = 'works' | 'unknown' | 'cannot'

/**
 * What it costs to actually use the thing, once it is installed.
 *
 * ## Why this is a field and not a sentence somebody wrote in a summary
 *
 * Asad, widening both catalogues:
 *
 *   > *"maybe some other tools paid ones too not just open source"*
 *
 * The moment a store holds more than open source, the most important fact about
 * a row stops being its licence. `tavily-mcp` is MIT and `firecrawl-mcp` is MIT
 * and neither does anything at all without a key you buy — a row that printed
 * *MIT* and stopped there would be telling the truth in a way that leaves
 * somebody worse informed than saying nothing. So price is its own field, on
 * every row of both catalogues, and it is filterable.
 *
 * ## Four values, because three of them are different kinds of free
 *
 *  - `free` — nothing to pay and nobody to sign up with. `filesystem`, `time`,
 *    Google Translate.
 *  - `account` — free to use, and it does nothing until you sign in somewhere.
 *    The account itself costs nothing. Notion, Figma, Stripe's test keys.
 *  - `metered` — free to a limit, then you pay. Tavily's free tier is a monthly
 *    allowance; Google Maps bills past its credit; Loom's free plan caps how
 *    long a recording may be. The distinction from `paid` is not pedantry: one
 *    of these you can try today and one you cannot.
 *  - `paid` — money before it does its job at all. Perplexity's API has no free
 *    tier; 1Password has no free plan. A row like this that read *free* because
 *    its extension is a free download would be the exact lie this field exists
 *    to prevent.
 *
 * A fifth value, `unknown`, exists for the one row neither catalogue can answer
 * for: something a person added themselves. This app has never seen it, does not
 * know who wrote it, and is not going to guess what it costs.
 */
export type StoreCost = 'free' | 'account' | 'metered' | 'paid' | 'unknown'

/**
 * What each price wears on screen, shared by both stores.
 *
 * The one place this file's *"the words are deliberately not shared"* rule is
 * suspended, and deliberately. The rule exists because the two catalogues know
 * different things — one measured its rows running in this app's Electron, the
 * other says outright it never will — so forcing one vocabulary would make one
 * of them claim something it did not measure. Money is not like that. A monthly
 * bill is the same fact in both stores, and calling it *Free to start, then
 * paid* in one and something else in the other would be the drift this file was
 * written to stop.
 */
export const COST_WORDS: Readonly<Record<StoreCost, string>> = {
  free: 'Free',
  account: 'Free, needs an account',
  metered: 'Free to a limit, then paid',
  paid: 'Paid',
  unknown: 'Not known',
}

/** The order a price control draws its chips in: cheapest certainty first. */
export const COST_ORDER: readonly StoreCost[] = ['free', 'account', 'metered', 'paid', 'unknown']

/** Which of the six facets a control is filtering on. */
export type StoreFacet = 'category' | 'cost' | 'compat' | 'installed' | 'source' | 'needs'

/**
 * One row of either store, reduced to the things that can be searched, filtered
 * and grouped.
 *
 * A projection rather than a base class: `StoreExtension` and `McpStoreRow` have
 * almost nothing in common below this line — one carries a sha256 and a set of
 * host patterns, the other a command line and a list of environment variables —
 * and a shared supertype would have dragged one store's vocabulary into the
 * other's rows. What they *do* share is how somebody looks for a thing.
 */
export interface StoreFacets {
  /** The row's own id, so a caller can join back to it. */
  id: string
  name: string
  summary: string
  /** The shelf id. Its display name is the store's to supply. */
  category: string
  /** The shelf's name, included so search covers it without a lookup table. */
  categoryName: string
  /**
   * Words somebody might type that are not in the name or the summary.
   *
   * *ads* for a blocker, *vim* for a keyboard driver, *postgres* for the SQL
   * one. Search over name and summary alone answers "where is the ad blocker"
   * with nothing, because no summary in either catalogue contains the word
   * `adblock`.
   */
  tags: readonly string[]
  /**
   * What using it costs. See {@link StoreCost}.
   *
   * A string rather than the union, for the same reason `category` and `source`
   * are: {@link matchesFacet} compares facet values as ids, and a projection
   * that narrowed here would make one store's vocabulary the shared model's
   * business.
   */
  cost: string
  compat: StoreCompat
  installed: boolean
  /** Where the row comes from. A store-specific id; see this file's header. */
  source: string
  /**
   * What a person has to bring before the row can work — a set, not one value.
   *
   * A set because a Docker row that also wants an API key needs both, and a
   * single winner would have hidden one of them from whichever filter was
   * chosen. Empty means nothing: press it and it goes.
   */
  needs: readonly string[]
}

/** What is currently being filtered by. Every field is a facet value or {@link ANY}. */
export interface StoreFilter {
  query: string
  category: string
  /** A {@link StoreCost} id, or {@link ANY}. */
  cost: string
  compat: StoreCompat | typeof ANY
  /** `'yes'` / `'no'` / {@link ANY}. A tri-state, because "not installed" is a real ask. */
  installed: 'yes' | 'no' | typeof ANY
  source: string
  needs: string
}

/** Nothing filtered. The state every store opens in. */
export const NO_FILTER: StoreFilter = {
  query: '',
  category: ANY,
  cost: ANY,
  compat: ANY,
  installed: ANY,
  source: ANY,
  needs: ANY,
}

/** The id used for "needs nothing at all", which is the absence of every other need. */
export const NEEDS_NOTHING = 'nothing'

/* --------------------------------------------------------------- searching -- */

/**
 * Everything a query is matched against, lower-cased and joined.
 *
 * Category name included, so typing *passwords* finds the shelf's contents even
 * though no row's summary says the word.
 */
function haystack(facets: StoreFacets): string {
  return [facets.name, facets.summary, facets.categoryName, ...facets.tags].join(' ').toLowerCase()
}

/**
 * The same text with everything that is not a letter or a digit removed.
 *
 * This is what makes the search forgiving of how a name is punctuated, and it is
 * not a hypothetical: the MCP catalogue holds `sequential-thinking`, and
 * somebody typing `sequentialthinking` — which is what the reference repository
 * calls the directory — matched nothing at all before this. Likewise `uBlock
 * Origin` for `ublockorigin`, and `ClearURLs` for `clear urls`.
 */
function squash(text: string): string {
  return text.replace(/[^a-z0-9]+/g, '')
}

/**
 * Does this row match what has been typed?
 *
 * Every whitespace-separated word must appear, as a substring, in either the
 * plain haystack or the squashed one. Substring rather than whole word because
 * *block* has to find *Blocking ads and trackers* and *pass* has to find
 * *Passwords* while somebody is still typing — a search that only answers on the
 * last keystroke reads as broken for every keystroke before it.
 *
 * Every word rather than any word, because narrowing is what a second word is
 * for. Typing *youtube dislike* over a catalogue where six rows say *youtube*
 * should leave one.
 */
export function matchesQuery(facets: StoreFacets, query: string): boolean {
  const needle = query.trim().toLowerCase()
  if (needle === '') return true
  const plain = haystack(facets)
  const tight = squash(plain)
  return needle
    .split(/\s+/)
    .every((word) => plain.includes(word) || (squash(word) !== '' && tight.includes(squash(word))))
}

/* -------------------------------------------------------------- filtering -- */

/** Does this row survive one facet of the filter? Exported for {@link facetOptions}. */
export function matchesFacet(facets: StoreFacets, filter: StoreFilter, facet: StoreFacet): boolean {
  switch (facet) {
    case 'category':
      return filter.category === ANY || facets.category === filter.category
    case 'cost':
      return filter.cost === ANY || facets.cost === filter.cost
    case 'compat':
      return filter.compat === ANY || facets.compat === filter.compat
    case 'installed':
      return filter.installed === ANY || facets.installed === (filter.installed === 'yes')
    case 'source':
      return filter.source === ANY || facets.source === filter.source
    case 'needs':
      if (filter.needs === ANY) return true
      return filter.needs === NEEDS_NOTHING
        ? facets.needs.length === 0
        : facets.needs.includes(filter.needs)
  }
}

/**
 * The facets, in the order a store draws their controls.
 *
 * `cost` sits second, straight after the shelf. It is the question a person asks
 * before *does it run here* and long before *who publishes it* — and a price
 * control at the end of a row of six would be the one nobody scrolls to.
 */
const FACETS: readonly StoreFacet[] = [
  'category',
  'cost',
  'compat',
  'installed',
  'source',
  'needs',
]

/** Does this row survive the whole filter, search included? */
export function matchesFilter(facets: StoreFacets, filter: StoreFilter): boolean {
  return matchesQuery(facets, filter.query) && FACETS.every((f) => matchesFacet(facets, filter, f))
}

/** Is anything being filtered at all? Decides which empty-state sentence is true. */
export function filtering(filter: StoreFilter): boolean {
  return (
    filter.query.trim() !== '' ||
    FACETS.some((facet) => valueOf(filter, facet) !== ANY)
  )
}

/** One facet's current value, as a string. */
export function valueOf(filter: StoreFilter, facet: StoreFacet): string {
  switch (facet) {
    case 'category':
      return filter.category
    case 'cost':
      return filter.cost
    case 'compat':
      return filter.compat
    case 'installed':
      return filter.installed
    case 'source':
      return filter.source
    case 'needs':
      return filter.needs
  }
}

/** The same filter with one facet set. Written here so no store re-implements it. */
export function withFacet(filter: StoreFilter, facet: StoreFacet, value: string): StoreFilter {
  switch (facet) {
    case 'category':
      return { ...filter, category: value }
    case 'cost':
      return { ...filter, cost: value }
    case 'compat':
      return { ...filter, compat: value as StoreCompat | typeof ANY }
    case 'installed':
      return { ...filter, installed: value as 'yes' | 'no' | typeof ANY }
    case 'source':
      return { ...filter, source: value }
    case 'needs':
      return { ...filter, needs: value }
  }
}

/* ------------------------------------------------------------ the controls -- */

/** One choice a facet offers, with how many rows it would leave. */
export interface StoreOption {
  id: string
  name: string
  count: number
}

/** How a store names its own facet values. Ids it does not name are dropped. */
export interface FacetVocabulary {
  /** The heading above the chips. */
  label: string
  /** The word the "no filter" chip wears — "Everything", "Any shelf". */
  anyName: string
  /** The ids, in the order they are drawn, each with the words it wears. */
  options: readonly { id: string; name: string }[]
}

/** One facet, ready to draw: its chips, its counts, and what is chosen. */
export interface FacetControl {
  facet: StoreFacet
  label: string
  anyName: string
  /** How many rows the "no filter" chip would leave — the pool's own size. */
  total: number
  /** The real options, in the store's order. Never fewer than two. */
  options: StoreOption[]
  /** Which id is chosen, {@link ANY} included. */
  value: string
}

/**
 * Which rows a facet's counts are taken over.
 *
 * Every *other* facet applies, and this one does not — the cross-filter
 * arrangement every faceted search uses, and the only one that behaves. Counting
 * over the fully-filtered set would zero every unchosen option in the group the
 * moment one was picked, so a person who chose *Blocking* would watch every
 * other shelf disappear and have no way back except a Clear button.
 */
function pool(rows: readonly StoreFacets[], filter: StoreFilter, facet: StoreFacet): StoreFacets[] {
  return rows.filter(
    (row) =>
      matchesQuery(row, filter.query) &&
      FACETS.every((other) => other === facet || matchesFacet(row, filter, other)),
  )
}

/**
 * What one facet should draw, counts and all, or `null` for one that should not
 * be drawn at all.
 *
 * `null` when fewer than two of its options survive, and that is the point
 * rather than a tidy-up: a *Where it comes from* control on a catalogue where
 * every row has the same answer is a control whose every setting shows the same
 * list. It is not drawn — absent rather than disabled, which is this app's
 * standing rule for a thing that cannot do anything, and the rule
 * `StorePanel.tsx` already applied by hand to its category chips.
 *
 * This is also what lets both stores share one bar honestly. The MCP catalogue
 * says outright that *"nothing here was watched working"*, so no MCP row is ever
 * `works`; that facet therefore comes back with one option and is not drawn
 * there, without the MCP store having to know it is being left out.
 *
 * The currently-chosen option is kept even when its count reaches zero, because
 * a chosen chip that vanished would leave a filter in force with nothing on
 * screen able to turn it off.
 */
export function facetControl(
  rows: readonly StoreFacets[],
  filter: StoreFilter,
  facet: StoreFacet,
  vocabulary: FacetVocabulary,
): FacetControl | null {
  const visible = pool(rows, filter, facet)
  const chosen = valueOf(filter, facet)
  const counted = vocabulary.options
    .filter((option) => option.id !== ANY)
    .map((option) => ({
      id: option.id,
      name: option.name,
      count: visible.filter((row) => matchesFacet(row, withFacet(filter, facet, option.id), facet))
        .length,
    }))
  const options = counted.filter((option) => option.count > 0 || option.id === chosen)
  if (options.length < 2) return null
  return {
    facet,
    label: vocabulary.label,
    anyName: vocabulary.anyName,
    total: visible.length,
    options,
    value: chosen,
  }
}

/** Every facet that is worth drawing, in the order given. */
export function facetControls(
  rows: readonly StoreFacets[],
  filter: StoreFilter,
  vocabularies: Partial<Record<StoreFacet, FacetVocabulary>>,
): FacetControl[] {
  const drawn: FacetControl[] = []
  for (const facet of FACETS) {
    const vocabulary = vocabularies[facet]
    if (vocabulary === undefined) continue
    const control = facetControl(rows, filter, facet, vocabulary)
    if (control !== null) drawn.push(control)
  }
  return drawn
}

/* ---------------------------------------------------------------- shelves -- */

/** One category's worth of rows, ready to draw as a section. */
export interface StoreShelf<Row> {
  id: string
  name: string
  rows: Row[]
}

/**
 * Group what survived the filter into shelves, in the store's own order.
 *
 * Empty shelves are dropped. `rank` decides the order *within* a shelf and is
 * the store's own: the browser store puts what can be installed above what was
 * measured failing above what was never measured, and keeps the two kinds of
 * buttonless row apart rather than sweeping them into one bin at the bottom that
 * reads as *the broken ones*.
 */
export function shelve<Row>(
  rows: readonly Row[],
  order: readonly { id: string; name: string }[],
  facetsOf: (row: Row) => StoreFacets,
  rank: (row: Row) => number,
): StoreShelf<Row>[] {
  return order
    .map((shelf) => ({
      id: shelf.id,
      name: shelf.name,
      rows: rows
        .filter((row) => facetsOf(row).category === shelf.id)
        .sort((a, b) => rank(a) - rank(b)),
    }))
    .filter((shelf) => shelf.rows.length > 0)
}
