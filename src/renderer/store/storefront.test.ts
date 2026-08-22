import { describe, expect, it } from 'vitest'
import {
  ANY,
  facetControl,
  facetControls,
  filtering,
  matchesFilter,
  matchesQuery,
  NEEDS_NOTHING,
  NO_FILTER,
  shelve,
  withFacet,
  type FacetVocabulary,
  type StoreFacet,
  type StoreFacets,
} from './storefront'

/**
 * The one storefront model.
 *
 * Everything here is a decision both stores make, which is the whole reason the
 * file exists — so every test is about one of two failure shapes: a search that
 * answers with the wrong rows, or a control that is drawn when pressing it would
 * leave nothing on screen.
 */

/* ---------------------------------------------------------------- fixture -- */

function row(over: Partial<StoreFacets> = {}): StoreFacets {
  return {
    id: 'ublock-origin',
    name: 'uBlock Origin',
    summary: 'The wide-spectrum content blocker.',
    category: 'blocking',
    categoryName: 'Blocking ads and trackers',
    tags: ['ads', 'adblock', 'trackers'],
    compat: 'works',
    installed: false,
    source: 'release',
    needs: [],
    ...over,
  }
}

const DARK = row({
  id: 'dark-reader',
  name: 'Dark Reader',
  summary: 'Turns every site dark.',
  category: 'appearance',
  categoryName: 'How pages look',
  tags: ['dark mode', 'night'],
})

const VIMIUM = row({
  id: 'vimium',
  name: 'Vimium',
  summary: 'Drives the browser from the keyboard.',
  category: 'scripting',
  categoryName: 'Scripting and the keyboard',
  tags: ['vim', 'keyboard'],
  compat: 'unknown',
  source: 'web-store',
})

const BITWARDEN = row({
  id: 'bitwarden',
  name: 'Bitwarden',
  summary: 'The open-source password manager.',
  category: 'passwords',
  categoryName: 'Passwords',
  tags: ['vault', 'logins'],
  compat: 'cannot',
  needs: ['account'],
})

const ALL = [row(), DARK, VIMIUM, BITWARDEN]

/* --------------------------------------------------------------- searching -- */

describe('search', () => {
  it('is case-insensitive, which is the whole of "forgiving" most of the time', () => {
    expect(matchesQuery(DARK, 'DARK')).toBe(true)
    expect(matchesQuery(DARK, 'dArK rEaDeR')).toBe(true)
  })

  it('matches part of a word, so a store answers while somebody is still typing', () => {
    // A search that only answers on the last keystroke reads as broken for every
    // keystroke before it.
    for (const partial of ['u', 'ub', 'ubl', 'ublo']) {
      expect(matchesQuery(row(), partial)).toBe(true)
    }
  })

  it('finds a row by a tag that appears in neither its name nor its summary', () => {
    /*
     * The reason tags exist. uBlock Origin's summary is "The wide-spectrum
     * content blocker" — four words containing neither *ad* nor *block* as
     * anybody would type them — so the single most likely thing to type into an
     * extension store matched nothing at all before this.
     */
    expect(row().name.toLowerCase()).not.toContain('adblock')
    expect(row().summary.toLowerCase()).not.toContain('adblock')
    expect(matchesQuery(row(), 'adblock')).toBe(true)
  })

  it('finds a row by its category name', () => {
    expect(matchesQuery(BITWARDEN, 'passwords')).toBe(true)
  })

  it('ignores punctuation on both sides of the comparison', () => {
    // `sequential-thinking` is the MCP catalogue's name for it and
    // `sequentialthinking` is what the reference repository calls the directory.
    // Neither spelling may be the only one that works.
    const server = row({
      name: 'sequential-thinking',
      summary: 'Numbered steps it can revise.',
      tags: [],
    })
    expect(matchesQuery(server, 'sequentialthinking')).toBe(true)
    expect(matchesQuery(server, 'sequential thinking')).toBe(true)
    expect(matchesQuery(server, 'SEQUENTIAL-THINKING')).toBe(true)
  })

  it('narrows on a second word rather than widening', () => {
    // Every word has to appear. Narrowing is what a second word is for.
    expect(matchesQuery(DARK, 'dark reader')).toBe(true)
    expect(matchesQuery(DARK, 'dark wombat')).toBe(false)
  })

  it('keeps everything when nothing has been typed', () => {
    expect(ALL.every((one) => matchesQuery(one, '   '))).toBe(true)
  })
})

/* --------------------------------------------------------------- filtering -- */

describe('filters', () => {
  it('filters on each facet independently', () => {
    const cases: Array<[StoreFacet, string, string[]]> = [
      ['category', 'appearance', ['dark-reader']],
      ['compat', 'cannot', ['bitwarden']],
      ['installed', 'no', ['ublock-origin', 'dark-reader', 'vimium', 'bitwarden']],
      ['source', 'web-store', ['vimium']],
      ['needs', 'account', ['bitwarden']],
    ]
    for (const [facet, value, expected] of cases) {
      const filter = withFacet(NO_FILTER, facet, value)
      expect(ALL.filter((one) => matchesFilter(one, filter)).map((one) => one.id)).toEqual(expected)
    }
  })

  it('"needs nothing" means the absence of every other need, not a need of its own', () => {
    const filter = withFacet(NO_FILTER, 'needs', NEEDS_NOTHING)
    expect(ALL.filter((one) => matchesFilter(one, filter)).map((one) => one.id)).toEqual([
      'ublock-origin',
      'dark-reader',
      'vimium',
    ])
  })

  it('matches a row that has more than one need from either of them', () => {
    // The GitHub MCP row wants a personal access token *and* Docker. A single
    // winner would have hidden one of those from whichever filter was chosen.
    const github = row({ id: 'github', needs: ['token', 'docker'] })
    expect(matchesFilter(github, withFacet(NO_FILTER, 'needs', 'token'))).toBe(true)
    expect(matchesFilter(github, withFacet(NO_FILTER, 'needs', 'docker'))).toBe(true)
  })

  it('combines the search with the facets', () => {
    const filter = { ...withFacet(NO_FILTER, 'category', 'blocking'), query: 'dark' }
    expect(ALL.filter((one) => matchesFilter(one, filter))).toEqual([])
  })

  it('knows whether anything is filtered at all, which decides the empty sentence', () => {
    expect(filtering(NO_FILTER)).toBe(false)
    expect(filtering({ ...NO_FILTER, query: ' ' })).toBe(false)
    expect(filtering({ ...NO_FILTER, query: 'x' })).toBe(true)
    expect(filtering(withFacet(NO_FILTER, 'source', 'release'))).toBe(true)
  })
})

/* ---------------------------------------------------------------- controls -- */

const COMPAT: FacetVocabulary = {
  label: 'In this browser',
  anyName: 'Any',
  options: [
    { id: 'works', name: 'Works here' },
    { id: 'unknown', name: 'Not measured' },
    { id: 'cannot', name: 'Cannot work here' },
  ],
}

const SOURCE: FacetVocabulary = {
  label: 'Where it comes from',
  anyName: 'Anywhere',
  options: [
    { id: 'release', name: 'Releases' },
    { id: 'web-store', name: 'A web store' },
    { id: 'your-own', name: 'Added by you' },
  ],
}

describe('the controls a facet draws', () => {
  it('never offers an option that would leave nothing on screen', () => {
    // The rule the whole bar rests on, and the one `StorePanel.tsx` used to
    // apply by hand to its category chips: a chip that filtered down to "nothing
    // matches that" is a control that does nothing.
    const control = facetControl(ALL, NO_FILTER, 'source', SOURCE)
    expect(control?.options.map((one) => one.id)).toEqual(['release', 'web-store'])
    expect(control?.options.every((one) => one.count > 0)).toBe(true)
  })

  it('is not drawn at all when fewer than two options survive', () => {
    /*
     * Absent rather than disabled. This is also what lets both stores share one
     * bar honestly: the MCP catalogue says outright that nothing in it was
     * watched working, so no MCP row is ever `works`, and on a machine with
     * every runtime present that facet has one live option and simply is not
     * drawn — without the MCP store having to know it is being left out.
     */
    const allWork = [row(), DARK, row({ id: 'stylus', name: 'Stylus' })]
    expect(facetControl(allWork, NO_FILTER, 'compat', COMPAT)).toBeNull()
  })

  it('counts each option over the other facets but not its own', () => {
    /*
     * The cross-filter arrangement. Counting over the fully-filtered set would
     * zero every unchosen option in a group the moment one was picked, so
     * somebody who chose Blocking would watch every other shelf disappear with
     * no way back except a Clear button.
     */
    const chosen = withFacet(NO_FILTER, 'compat', 'works')
    const control = facetControl(ALL, chosen, 'compat', COMPAT)
    expect(control?.value).toBe('works')
    expect(control?.options.find((one) => one.id === 'cannot')?.count).toBe(1)
    expect(control?.total).toBe(ALL.length)
  })

  it('keeps a chosen option whose count has reached zero, so it can be turned off', () => {
    // A chosen chip that vanished would leave a filter in force with nothing on
    // screen able to release it.
    const filter = { ...withFacet(NO_FILTER, 'source', 'your-own'), query: 'dark' }
    const control = facetControl(ALL, filter, 'source', SOURCE)
    expect(control?.options.map((one) => one.id)).toContain('your-own')
    expect(control?.options.find((one) => one.id === 'your-own')?.count).toBe(0)
  })

  it('ignores an option the vocabulary does not name', () => {
    const narrow: FacetVocabulary = { ...SOURCE, options: [{ id: 'release', name: 'Releases' }] }
    expect(facetControl(ALL, NO_FILTER, 'source', narrow)).toBeNull()
  })

  it('draws only the facets a store gave words to', () => {
    const controls = facetControls(ALL, NO_FILTER, { compat: COMPAT, source: SOURCE })
    expect(controls.map((one) => one.facet)).toEqual(['compat', 'source'])
  })

  it('the ANY value is never one of the counted options', () => {
    // The bar draws that chip itself, with the pool's own size on it, so a
    // vocabulary that named it would produce two of them.
    const withAny: FacetVocabulary = {
      ...SOURCE,
      options: [{ id: ANY, name: 'Anywhere' }, ...SOURCE.options],
    }
    const control = facetControl(ALL, NO_FILTER, 'source', withAny)
    expect(control?.options.map((one) => one.id)).not.toContain(ANY)
  })
})

/* ----------------------------------------------------------------- shelves -- */

describe('shelves', () => {
  const ORDER = [
    { id: 'blocking', name: 'Blocking ads and trackers' },
    { id: 'appearance', name: 'How pages look' },
    { id: 'passwords', name: 'Passwords' },
    { id: 'scripting', name: 'Scripting and the keyboard' },
  ]

  it('groups in the store’s own order and drops the empty ones', () => {
    const shelves = shelve(
      [BITWARDEN, DARK],
      ORDER,
      (one) => one,
      () => 0,
    )
    expect(shelves.map((one) => one.id)).toEqual(['appearance', 'passwords'])
  })

  it('orders within a shelf by the rank the store supplies', () => {
    // The browser store puts what can be installed above what was measured
    // failing above what was never measured, and the MCP store puts a name
    // collision above a missing runtime. Both are the store's own judgement.
    const cannot = row({ id: 'ghostery', name: 'Ghostery', compat: 'cannot' })
    const shelves = shelve(
      [cannot, row()],
      ORDER,
      (one) => one,
      (one) => (one.compat === 'cannot' ? 1 : 0),
    )
    expect(shelves[0]?.rows.map((one) => one.id)).toEqual(['ublock-origin', 'ghostery'])
  })
})
