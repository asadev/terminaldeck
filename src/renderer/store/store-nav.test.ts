import { describe, expect, it } from 'vitest'
import {
  EVERYTHING,
  filterFor,
  navTotal,
  showsDepartment,
  storeEmpty,
  storeNav,
  storeShown,
  type StoreDepartmentInput,
} from './store-nav'
import { ANY, NO_FILTER, type StoreFacets, type StoreFilter } from './storefront'

/**
 * The store page's rail, as a model.
 *
 * What is worth pinning here is the pair of things a *page* can get wrong that
 * the two dialogs it replaces could not: a count that collapses the moment
 * somebody uses the rail, and an empty screen that says "nothing matches" while
 * the thing is sitting on the next shelf down.
 */

function row(over: Partial<StoreFacets> = {}): StoreFacets {
  return {
    id: 'ublock',
    name: 'uBlock Origin',
    summary: 'Blocks ads and trackers.',
    cost: 'free',
    category: 'blocking',
    categoryName: 'Blocking ads and trackers',
    tags: ['adblock'],
    compat: 'works',
    installed: false,
    source: 'release',
    needs: [],
    ...over,
  }
}

const EXTENSIONS: StoreDepartmentInput = {
  id: 'extensions',
  name: 'Browser extensions',
  wired: true,
  filter: NO_FILTER,
  shelves: [
    { id: 'blocking', name: 'Blocking ads and trackers' },
    { id: 'passwords', name: 'Passwords' },
  ],
  rows: [
    row(),
    row({ id: 'adguard', name: 'AdGuard', tags: ['adblock'] }),
    row({
      id: 'bitwarden',
      name: 'Bitwarden',
      summary: 'A password manager.',
      category: 'passwords',
      categoryName: 'Passwords',
      tags: [],
    }),
  ],
}

const SERVERS: StoreDepartmentInput = {
  id: 'servers',
  name: 'MCP servers',
  wired: true,
  filter: NO_FILTER,
  shelves: [
    { id: 'files', name: 'Files on this machine' },
    { id: 'code', name: 'Code and repositories' },
  ],
  rows: [
    row({
      id: 'filesystem',
      name: 'filesystem',
      summary: 'Reads and writes files.',
      category: 'files',
      categoryName: 'Files on this machine',
      tags: [],
      compat: 'unknown',
      source: 'reference',
    }),
    row({
      id: 'github',
      name: 'github',
      summary: 'Pull requests and issues.',
      category: 'code',
      categoryName: 'Code and repositories',
      tags: [],
      compat: 'unknown',
      source: 'reference',
    }),
  ],
}

/**
 * The third department, which is the check on whether this is a model or a pair.
 *
 * Its shelves are the seven kinds and its rows are strangers' work. Nothing in
 * `store-nav.ts` learned anything to accommodate it — which is the property
 * being asserted below rather than a coincidence worth mentioning once.
 */
const COMMUNITY: StoreDepartmentInput = {
  id: 'community',
  name: 'Community',
  wired: true,
  filter: NO_FILTER,
  shelves: [
    { id: 'skill', name: 'Skill' },
    { id: 'mcp', name: 'MCP server' },
    { id: 'hooks', name: 'Hooks' },
  ],
  rows: [
    row({
      id: 'acme/pr-review',
      name: 'Pull request review',
      summary: 'Reads a diff and writes the review.',
      category: 'skill',
      categoryName: 'Skill',
      tags: [],
      compat: 'unknown',
      source: 'community',
    }),
    row({
      id: 'lumen/postgres',
      name: 'Postgres',
      summary: 'Queries a database.',
      category: 'mcp',
      categoryName: 'MCP server',
      tags: [],
      cost: 'paid',
      compat: 'unknown',
      source: 'community',
    }),
  ],
}

const BOTH = [EXTENSIONS, SERVERS]
const ALL = [EXTENSIONS, SERVERS, COMMUNITY]

/** Both departments handed the same query, which is what the page's one box does. */
const asking = (query: string): StoreDepartmentInput[] =>
  BOTH.map((one) => ({ ...one, filter: { ...one.filter, query } }))

describe('the rail', () => {
  it('counts every department and every shelf it has something on', () => {
    const nav = storeNav(BOTH)
    expect(nav.map((one) => [one.id, one.count])).toEqual([
      ['extensions', 3],
      ['servers', 2],
    ])
    expect(nav[0].shelves.map((shelf) => [shelf.id, shelf.count])).toEqual([
      ['blocking', 2],
      ['passwords', 1],
    ])
    expect(navTotal(nav)).toBe(5)
  })

  it('does not draw a shelf with nothing on it', () => {
    // The same rule a chip obeys and a section heading obeys. A rail full of
    // zeroes is a rail of controls that do nothing.
    const nav = storeNav(asking('password'))
    expect(nav[0].shelves.map((shelf) => shelf.id)).toEqual(['passwords'])
  })

  it('keeps the shelf you are standing on even when the search empties it', () => {
    // Otherwise the row that put the page in this state disappears out of the
    // rail, and the filter is left in force with nothing on screen able to
    // turn it off.
    const place = { kind: 'shelf', department: 'extensions', shelf: 'blocking' } as const
    const nav = storeNav(asking('password'), place)
    const shelves = nav[0].shelves.map((shelf) => [shelf.id, shelf.count])
    expect(shelves).toContainEqual(['blocking', 0])
  })

  it('does not collapse the other shelves when one is chosen', () => {
    /*
     * The failure this is written against: counting over the fully-filtered set
     * zeroes every shelf but the one being stood on, so a person who pressed
     * Passwords would watch every other shelf vanish and have no way back.
     */
    const place = { kind: 'shelf', department: 'extensions', shelf: 'passwords' } as const
    const nav = storeNav(BOTH, place)
    expect(nav[0].shelves.map((shelf) => [shelf.id, shelf.count])).toEqual([
      ['blocking', 2],
      ['passwords', 1],
    ])
  })

  it('drops a department the build cannot draw, rather than greying it', () => {
    const nav = storeNav([{ ...EXTENSIONS, wired: false }, SERVERS])
    expect(nav.map((one) => one.id)).toEqual(['servers'])
  })

  it('counts a third department the same way, having learned nothing new', () => {
    /*
     * The Community department's shelves are the seven kinds and its rows are
     * other people's work, and none of that reached this file. If a third
     * department had needed a line here, the model would have been two things
     * with a shared word rather than a model.
     */
    const nav = storeNav(ALL)
    expect(nav.map((one) => [one.id, one.count])).toEqual([
      ['extensions', 3],
      ['servers', 2],
      ['community', 2],
    ])
    expect(nav[2].shelves.map((shelf) => [shelf.id, shelf.count])).toEqual([
      ['skill', 1],
      ['mcp', 1],
    ])
    expect(navTotal(nav)).toBe(7)
  })

  it('lets the community chips alone empty only the community', () => {
    // `paid` is a word the other two catalogues have and the community one uses
    // differently; one shared filter is the bug this whole arrangement exists to
    // stop, and a third department is one more chance to reintroduce it.
    const nav = storeNav([
      EXTENSIONS,
      SERVERS,
      { ...COMMUNITY, filter: { ...NO_FILTER, cost: 'paid' } },
    ])
    expect(nav.map((one) => [one.id, one.count])).toEqual([
      ['extensions', 3],
      ['servers', 2],
      ['community', 1],
    ])
  })
})

describe('where the page is pointed', () => {
  it('hands a shelf only to the department that owns it', () => {
    /*
     * The two catalogues' shelf ids are different alphabets — `blocking` means
     * nothing to the MCP catalogue. A shared category in the filter would empty
     * whichever department did not own the word.
     */
    const place = { kind: 'shelf', department: 'extensions', shelf: 'blocking' } as const
    expect(filterFor(place, EXTENSIONS).category).toBe('blocking')
    expect(filterFor(place, SERVERS).category).toBe(ANY)
  })

  it('draws both departments at the front door and one anywhere else', () => {
    expect(showsDepartment(EVERYTHING, 'extensions')).toBe(true)
    expect(showsDepartment(EVERYTHING, 'servers')).toBe(true)
    const place = { kind: 'department', department: 'servers' } as const
    expect(showsDepartment(place, 'extensions')).toBe(false)
    expect(showsDepartment(place, 'servers')).toBe(true)
  })

  it('keeps the search and the department’s own chips when the shelf changes', () => {
    const filter: StoreFilter = { ...NO_FILTER, query: 'ad', installed: 'no' }
    const place = { kind: 'shelf', department: 'extensions', shelf: 'blocking' } as const
    expect(filterFor(place, { ...EXTENSIONS, filter })).toEqual({
      ...filter,
      category: 'blocking',
    })
  })

  it('lets one department’s chips alone empty only that department', () => {
    /*
     * The bug a screenshot found. The two catalogues' `source` ids do not
     * intersect — `release` and `web-store` against `reference` and
     * `third-party` — so one shared filter meant pressing **The project's own
     * releases** under Browser extensions blanked MCP servers, which had nothing
     * that could ever match the word.
     */
    const nav = storeNav([
      { ...EXTENSIONS, filter: { ...NO_FILTER, source: 'release' } },
      SERVERS,
    ])
    expect(nav.map((one) => [one.id, one.count])).toEqual([
      ['extensions', 3],
      ['servers', 2],
    ])
  })
})

describe('what an empty store says', () => {
  it('says nothing at all when something is on screen', () => {
    expect(storeEmpty(BOTH, EVERYTHING)).toBeNull()
  })

  it('points at the rest of the store when the shelf is the only empty thing', () => {
    /*
     * The lie a page can tell that a dialog could not: "nothing matches" printed
     * over a shelf, while the two rows that do match sit one rail entry away.
     */
    const place = { kind: 'shelf', department: 'extensions', shelf: 'passwords' } as const
    const empty = storeEmpty(asking('adblock'), place)
    expect(empty?.title).toBe('Nothing here matches that')
    expect(empty?.elsewhere).toBe(2)
    expect(empty?.detail).toContain('2 things elsewhere in the store')
  })

  it('says how much it searched when the whole store comes back empty', () => {
    const empty = storeEmpty(asking('kubernetes'), EVERYTHING)
    expect(empty?.title).toBe('Nothing in the store matches that')
    expect(empty?.detail).toContain('all 5 of them')
    expect(empty?.elsewhere).toBe(0)
  })

  it('separates a build that cannot read the store from a store with nothing in it', () => {
    const none = storeEmpty(
      [
        { ...EXTENSIONS, wired: false },
        { ...SERVERS, wired: false },
      ],
      EVERYTHING,
    )
    expect(none?.title).toBe('Nothing to browse in this build')

    const empty = storeEmpty([{ ...EXTENSIONS, rows: [] }], EVERYTHING)
    expect(empty?.detail).toContain('came back empty')
  })

  it('points at the rest of the store when this department has nothing', () => {
    /*
     * "In the other one" was true of a shop with two departments and became a
     * lie the day it had three. The sentence names the number and sends somebody
     * to the rail, which is the same answer the shelf case gives.
     */
    const place = { kind: 'department', department: 'servers' } as const
    const empty = storeEmpty(asking('password'), place)
    expect(empty?.title).toBe('Nothing in this department matches that')
    expect(empty?.detail).toContain('1 thing elsewhere in the store does')
    expect(empty?.elsewhere).toBe(1)
  })

  it('counts every department it searched, not two of them', () => {
    const empty = storeEmpty(
      ALL.map((one) => ({ ...one, filter: { ...one.filter, query: 'kubernetes' } })),
      EVERYTHING,
    )
    expect(empty?.detail).toContain('all 7 of them')
    expect(empty?.detail).toContain('all 3 departments')
  })
})

describe('what the header counts', () => {
  it('answers how much is on screen, not how much the search matched', () => {
    /*
     * The failure a screenshot caught: standing on **Databases**, with two rows
     * under it, the header read *44 of 44*. That number is the rail's, and the
     * rail's counts ignore the shelf on purpose — otherwise pressing one
     * collapses every other. Two different questions, two different functions.
     */
    const place = { kind: 'shelf', department: 'servers', shelf: 'code' } as const
    expect(navTotal(storeNav(BOTH, place))).toBe(5)
    expect(storeShown(BOTH, place)).toBe(1)
  })

  it('counts both departments at the front door', () => {
    expect(storeShown(BOTH, EVERYTHING)).toBe(5)
  })

  it('counts nothing behind a department that is not drawn', () => {
    const place = { kind: 'department', department: 'servers' } as const
    expect(storeShown(BOTH, place)).toBe(2)
  })
})
