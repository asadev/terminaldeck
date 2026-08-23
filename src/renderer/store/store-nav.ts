import {
  ANY,
  matchesFilter,
  withFacet,
  type StoreFacets,
  type StoreFilter,
} from './storefront'

/**
 * The store page's own model: which department you are in, which shelf, and how
 * many things are behind every word in the rail.
 *
 * ## Why this is a second model beside `storefront.ts`
 *
 * `storefront.ts` decides everything *inside one catalogue* — what a search
 * matches, which chips are worth drawing, what a shelf holds. It is deliberately
 * blind to there being two catalogues, and it should stay that way: the whole
 * argument in its header is that the two stores must not be forced to share a
 * vocabulary they did not both measure.
 *
 * What it cannot answer is the question a **page** asks and a dialog never had
 * to: *where am I in this store, and what is down each of the other roads?*
 * Twenty-four extensions and eighteen servers is not a list. It is a shop with
 * two departments and sixteen shelves between them, and the thing that makes it
 * navigable is a rail that says how many are on each shelf before you press it.
 *
 * ## The counts follow one rule, and it is the same rule the chips follow
 *
 * A count is taken with **the search applied and the shelf ignored**. That is
 * the cross-filter arrangement `facetControl` already argues for: counting a
 * shelf over the fully-filtered set would zero every shelf but the one you are
 * standing on, and the rail would collapse to a single row the moment you used
 * it. Typing `github` and watching *Code and repositories 2* appear beside
 * *Saving and research 1* is the rail doing its job.
 *
 * A department's own count is taken the same way, over its own rows only. It is
 * therefore never a sum of its shelves plus a remainder — a row belongs to
 * exactly one shelf and every shelf is listed, so the two agree by construction.
 *
 * ## Nothing here knows what a row *is*
 *
 * Every function below takes {@link StoreFacets} and nothing else, so this file
 * has no idea that one department installs `.crx` files and the other writes
 * command lines into a configuration. That is what lets both departments hang
 * off one rail without either one's words leaking into the other's.
 */

/** Which half of the store. */
export type StoreDepartmentId = 'extensions' | 'servers'

/**
 * One department, as the rail needs to see it.
 *
 * `wired` is not a styling hint. A build whose preload predates a half, or one
 * where the feature that owns it is uninstalled, has that department **absent**
 * — not greyed, not empty-with-an-apology — which is this app's standing rule
 * for a control that cannot do anything. An unwired department is dropped from
 * the rail entirely by {@link storeNav}, so nothing can navigate to it.
 *
 * ## Each department brings its own filter, and that is not an oversight
 *
 * The page has **one search box** and it searches the whole store. It does not
 * have one set of chips, and the first version of this file assumed it did —
 * one `StoreFilter` shared by both halves — which was wrong in a way a
 * screenshot found immediately. `storefront.ts` says outright that a facet's
 * *id* is shared and the sentence it wears is not, because the two catalogues
 * genuinely know different things: an extension's source is `release` or
 * `your-own`, a server's is `reference` or `third-party`, and the two lists do
 * not intersect. Pressing **The project's own releases** under Browser
 * extensions therefore set `source: 'release'` on a value the MCP department was
 * also reading, and emptied it — one department's chip silently blanking the
 * other.
 *
 * So the chips stay where their vocabulary is. What is shared is the query,
 * which means the same thing everywhere, and the shelf, which is applied by
 * {@link filterFor} to the one department that owns it.
 */
export interface StoreDepartmentInput {
  id: StoreDepartmentId
  /** The heading, in the rail and above the rows. One name, both places. */
  name: string
  wired: boolean
  /** The shelves in the order this department draws them, with their words. */
  shelves: readonly { id: string; name: string }[]
  /** Every row it holds, filtered or not — the counts are taken from this. */
  rows: readonly StoreFacets[]
  /**
   * What this department is filtered by: the page's query and its own chips.
   *
   * Its `category` is ignored here — the shelf lives in the {@link StorePlace}
   * and is applied by {@link filterFor}, so a department can never be handed a
   * shelf id belonging to the other one.
   */
  filter: StoreFilter
}

export interface StoreNavShelf {
  id: string
  name: string
  count: number
}

export interface StoreNavDepartment {
  id: StoreDepartmentId
  name: string
  /** How many of its rows survive the search. Shelf choice deliberately ignored. */
  count: number
  /** Only the shelves with something on them. An empty shelf is not a place. */
  shelves: StoreNavShelf[]
}

/**
 * Where in the store the page is pointed.
 *
 * Three kinds rather than a nullable pair, because the three are genuinely
 * different screens and a `{ department: null, shelf: 'files' }` is not a state
 * anything should be able to represent.
 */
export type StorePlace =
  | { kind: 'all' }
  | { kind: 'department'; department: StoreDepartmentId }
  | { kind: 'shelf'; department: StoreDepartmentId; shelf: string }

/** The front door. Both departments, every shelf, nothing chosen. */
export const EVERYTHING: StorePlace = { kind: 'all' }

/** Which department a place belongs to, or `null` for the front door. */
export function placeDepartment(place: StorePlace): StoreDepartmentId | null {
  return place.kind === 'all' ? null : place.department
}

/** Is this department drawn at all, standing where we are standing? */
export function showsDepartment(place: StorePlace, id: StoreDepartmentId): boolean {
  return place.kind === 'all' || place.department === id
}

/**
 * The filter one department should be handed.
 *
 * The page keeps **one** filter — one search box, searching the whole store, is
 * the thing a page can do that two dialogs could not — and the shelf lives in
 * the rail rather than in that filter, because the two departments' shelf ids
 * are different alphabets. `blocking` means nothing to the MCP catalogue and
 * `files` means nothing to the extension one, so a shared `filter.category`
 * would silently empty whichever department did not own the chosen word.
 *
 * So the shelf is applied **here**, to the one department it belongs to, and
 * every other department is not drawn at all when a shelf is chosen. What each
 * department receives is therefore always a filter whose category is either its
 * own shelf or nothing.
 */
export function filterFor(place: StorePlace, department: StoreDepartmentInput): StoreFilter {
  const category =
    place.kind === 'shelf' && place.department === department.id ? place.shelf : ANY
  return withFacet(department.filter, 'category', category)
}

/** The filter a count is taken under: this department's own, without the shelf. */
function counting(department: StoreDepartmentInput): StoreFilter {
  return withFacet(department.filter, 'category', ANY)
}

/**
 * The rail: every wired department, with the shelves that have something on
 * them, and a count on every word.
 *
 * Empty shelves are dropped rather than drawn as a zero, which is the same rule
 * `facetControl` applies to a chip and `shelve` applies to a section heading: a
 * control that would leave nothing on screen is not a control. The one exception
 * is the shelf you are **standing on** — it is kept even at zero, because a
 * chosen row that vanished out of the rail would leave the page filtered with
 * nothing on screen able to unfilter it.
 */
export function storeNav(
  departments: readonly StoreDepartmentInput[],
  place: StorePlace = EVERYTHING,
): StoreNavDepartment[] {
  return departments
    .filter((department) => department.wired)
    .map((department) => {
      const kept = department.rows.filter((row) => matchesFilter(row, counting(department)))
      const standing =
        place.kind === 'shelf' && place.department === department.id ? place.shelf : ''
      return {
        id: department.id,
        name: department.name,
        count: kept.length,
        shelves: department.shelves
          .map((shelf) => ({
            id: shelf.id,
            name: shelf.name,
            count: kept.filter((row) => row.category === shelf.id).length,
          }))
          .filter((shelf) => shelf.count > 0 || shelf.id === standing),
      }
    })
}

/** How many rows the whole store has under the current search. */
export function navTotal(nav: readonly StoreNavDepartment[]): number {
  return nav.reduce((sum, department) => sum + department.count, 0)
}

/**
 * How many rows are actually **on screen**, shelf and all.
 *
 * Different from {@link navTotal} on purpose, and the difference is the header's
 * whole job. The rail's counts deliberately ignore the shelf you are standing on
 * — otherwise pressing one collapses every other — so summing them answers *how
 * much of the store your search matches*, which is not what a person standing on
 * **Databases** reading *44 of 44* is asking. This answers *how much am I
 * looking at*, which is 2.
 */
export function storeShown(
  departments: readonly StoreDepartmentInput[],
  place: StorePlace,
): number {
  return departments
    .filter((department) => department.wired && showsDepartment(place, department.id))
    .reduce(
      (sum, department) =>
        sum + department.rows.filter((row) => matchesFilter(row, filterFor(place, department))).length,
      0,
    )
}

/**
 * What a store with nothing on screen should say, or `null` when something is.
 *
 * Three genuinely different situations, and the difference matters enough that
 * the browser store had already been caught telling the wrong one of them — its
 * shelves said *"Nothing in the store matches that"* directly above a row that
 * plainly matched and was sitting under **Installed**.
 *
 * A page can be wrong in one more way a dialog could not, and this is the one
 * this function exists for: **you are standing on a shelf, and what you typed is
 * in the store but not on this shelf.** Saying "nothing matches" there is a lie
 * of exactly the kind the store is written against — the thing is right there,
 * two rows up the rail. So the sentence names the number and the page draws the
 * way back to it.
 */
export interface StoreEmpty {
  /** The heading. Short, and never a claim about anything but what was searched. */
  title: string
  /** The sentence under it. Always says what *is* true, not only what is not. */
  detail: string
  /** How many rows are elsewhere in the store — 0 when the store itself is empty. */
  elsewhere: number
}

export function storeEmpty(
  departments: readonly StoreDepartmentInput[],
  place: StorePlace,
): StoreEmpty | null {
  const wired = departments.filter((department) => department.wired)

  // Nothing is wired at all: an old preload, or both halves uninstalled. The
  // page says which, because "the store is empty" and "this build cannot read
  // the store" are opposite problems and only one of them is fixable from here.
  if (wired.length === 0) {
    return {
      title: 'Nothing to browse in this build',
      detail:
        'Neither half of the store is available here — the browser pane and MCP servers are ' +
        'what stock it, and this window has neither.',
      elsewhere: 0,
    }
  }

  if (storeShown(wired, place) > 0) return null

  const everywhere = wired.reduce(
    (sum, department) =>
      sum + department.rows.filter((row) => matchesFilter(row, counting(department))).length,
    0,
  )
  const stock = wired.reduce((sum, department) => sum + department.rows.length, 0)
  /* Every department is handed the same query, so any of them can answer for
     it — the chips are what differ, and no sentence below quotes one. */
  const query = (wired[0]?.filter.query ?? '').trim()

  // On a shelf, with matches elsewhere. The one a page can get wrong and a
  // dialog could not.
  if (place.kind === 'shelf' && everywhere > 0) {
    return {
      title: query === '' ? 'Nothing on this shelf' : 'Nothing here matches that',
      detail:
        `${everywhere} ${everywhere === 1 ? 'thing' : 'things'} elsewhere in the store ` +
        `${everywhere === 1 ? 'does' : 'do'}. The rail on the left says where.`,
      elsewhere: everywhere,
    }
  }

  if (place.kind === 'department' && everywhere > 0) {
    return {
      title: 'Nothing in this department matches that',
      detail:
        `${everywhere} ${everywhere === 1 ? 'thing' : 'things'} in the other one ` +
        `${everywhere === 1 ? 'does' : 'do'}.`,
      elsewhere: everywhere,
    }
  }

  // Nothing anywhere. Say what was searched over, so the answer reads as a
  // result rather than as a store that failed to load.
  return {
    title: query === '' ? 'Nothing in the store' : 'Nothing in the store matches that',
    detail:
      stock === 0
        ? 'The catalogues came back empty, which is not something you can fix from here.'
        : `Searched all ${stock} of them, across ${wired.length === 1 ? 'one department' : 'both departments'}.`,
    elsewhere: 0,
  }
}

/**
 * A store's facet vocabularies with the shelf taken out.
 *
 * Both departments call this before drawing their chips. The shelves are the
 * page's left rail — with a count on every one, across the whole store — and a
 * second row of chips saying the same thing under a heading would be two
 * controls for one choice.
 *
 * It removes the **chips**, not the filter. `filter.category` is still set by
 * the rail and still applied by `matchesFilter`, and every remaining chip still
 * cross-filters against it, so the counts a person reads are the counts they
 * would get. Written here rather than spelled out twice so the two departments
 * cannot come to two different ideas of which controls the page owns.
 */
export function withoutShelf<T extends { category?: unknown }>(vocabularies: T): Omit<T, 'category'> {
  const { category: _shelf, ...rest } = vocabularies
  void _shelf
  return rest
}
