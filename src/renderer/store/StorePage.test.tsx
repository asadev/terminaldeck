import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { departmentOfRow, StorePageFrame, type StorePageFrameProps } from './StorePage'
import { EVERYTHING, type StoreDepartmentInput, type StorePlace } from './store-nav'
import { NO_FILTER, type StoreFacets, type StoreFilter } from './storefront'

/**
 * The store page's own surface, rendered.
 *
 * There is no DOM in this project's test setup, so this renders the **frame**
 * through `react-dom/server` — the container above it loads two catalogues
 * through effects, which SSR never runs, and asserting on it would be the
 * *"proof by a function nothing calls"* this store has already been audited for
 * once. The frame is what a person reads: the search box, the rail, the
 * departments and what the page says when there is nothing to show.
 *
 * What each department draws is not this file's business — that is
 * `browser/StorePanel.test.tsx` and `components/McpStore.test.tsx`, which render
 * the same two bodies this page mounts. Here they are a marker, so what is being
 * asserted is the page and not the shop's stock.
 */

function row(over: Partial<StoreFacets> = {}): StoreFacets {
  return {
    id: 'ublock',
    name: 'uBlock Origin',
    summary: 'Blocks ads and trackers.',
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
  rows: [row(), row({ id: 'bitwarden', name: 'Bitwarden', category: 'passwords', categoryName: 'Passwords', tags: [] })],
}

const SERVERS: StoreDepartmentInput = {
  id: 'servers',
  name: 'MCP servers',
  wired: true,
  filter: NO_FILTER,
  shelves: [{ id: 'code', name: 'Code and repositories' }],
  rows: [
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

function render(over: Partial<StorePageFrameProps> = {}): string {
  return renderToStaticMarkup(
    <StorePageFrame
      departments={[EXTENSIONS, SERVERS]}
      place={EVERYTHING}
      detail=""
      onQuery={() => {}}
      onPlace={() => {}}
      onClear={() => {}}
      department={(id) => <p>rows of {id}</p>}
      {...over}
    />,
  )
}

/** Both departments asked the same thing, which is what one search box does. */
function asking(query: string): StoreDepartmentInput[] {
  return [EXTENSIONS, SERVERS].map((one) => ({ ...one, filter: { ...one.filter, query } }))
}

/**
 * Is a department on screen?
 *
 * Not `markup.includes` — that is the trap this page's design sets. A department
 * is **hidden and still mounted**, deliberately: unmounting it would re-read its
 * catalogue on the way back and, worse, take the counts it reports out of the
 * rail. So its rows are always in the document, and the question a test has to
 * ask is whether the `<section>` around them carries `hidden`.
 */
function shows(markup: string, id: 'extensions' | 'servers'): boolean {
  const at = markup.indexOf(`rows of ${id}`)
  if (at === -1) return false
  const opened = markup.lastIndexOf('<section', at)
  return !markup.slice(opened, at).includes('hidden')
}

describe('one store, two departments', () => {
  it('draws both halves under one search box', () => {
    const markup = render()
    expect(markup).toContain('Browser extensions')
    expect(markup).toContain('MCP servers')
    // One box. Two would mean whichever half somebody typed into decided what
    // they concluded the store contained.
    expect(markup.match(/type="search"/g)).toHaveLength(1)
  })

  it('puts every shelf of both departments in the rail, with a count on each', () => {
    const markup = render()
    expect(markup).toContain('Blocking ads and trackers')
    expect(markup).toContain('Passwords')
    expect(markup).toContain('Code and repositories')
    expect(markup).toContain('store-rail-count">3<')
  })

  it('draws no department the build cannot answer for', () => {
    /*
     * Absent, not greyed. A half whose preload is too old, or whose feature is
     * uninstalled, cannot list anything or install anything — and the store is
     * still a store with the other one.
     */
    const markup = render({ departments: [{ ...EXTENSIONS, wired: false }, SERVERS] })
    expect(markup).not.toContain('Browser extensions')
    expect(markup).toContain('MCP servers')
  })

  it('says nothing about counts before anybody has narrowed anything', () => {
    // "44 of 44" over an untouched store is noise, and a Clear with nothing to
    // clear is a control that does nothing.
    expect(render()).not.toContain('Show everything')
  })

  it('counts what is on screen rather than what the search matched', () => {
    const place: StorePlace = { kind: 'shelf', department: 'extensions', shelf: 'passwords' }
    const markup = render({ place })
    expect(markup).toContain('1 of 3')
  })
})

describe('what it says when there is nothing to show', () => {
  it('points at the rest of the store rather than claiming the store is empty', () => {
    /*
     * The lie a page can tell that neither dialog could: "nothing matches",
     * printed over a shelf, while the row that does match sits one rail entry
     * away. The sentence names the number and the button goes and gets it.
     */
    const markup = render({
      departments: asking('github'),
      place: { kind: 'shelf', department: 'extensions', shelf: 'passwords' },
    })
    expect(markup).toContain('Nothing here matches that')
    expect(markup).toContain('1 thing elsewhere in the store does')
    expect(markup).toContain('Look in the whole store')
  })

  it('offers no way out when there is genuinely nowhere else to look', () => {
    const markup = render({ departments: asking('kubernetes') })
    expect(markup).toContain('Nothing in the store matches that')
    expect(markup).not.toContain('Look in the whole store')
  })

  it('takes the departments off the screen rather than drawing empty ones under it', () => {
    // Both halves stay mounted — nothing is re-fetched when the search clears —
    // but neither is drawn over the page's own answer.
    const markup = render({ departments: asking('kubernetes') })
    expect(shows(markup, 'extensions')).toBe(false)
    expect(shows(markup, 'servers')).toBe(false)
    // Still mounted, so clearing the search costs nothing and the rail keeps
    // the numbers both halves reported.
    expect(markup).toContain('rows of extensions')
  })

  it('drops a department the search emptied, instead of leaving its furniture', () => {
    /*
     * Seen in a screenshot: searching `github` drew *Browser extensions 0*
     * followed by its limits note, its "Add your own" and two folder paths,
     * above the one row that actually matched.
     */
    const markup = render({ departments: asking('github') })
    expect(shows(markup, 'extensions')).toBe(false)
    expect(shows(markup, 'servers')).toBe(true)
  })
})

describe('reading one row on its own', () => {
  it('puts the other department away entirely', () => {
    /*
     * Found by looking: opening an extension drew its detail view with every MCP
     * server still browsing underneath it, which is a page showing one thing and
     * everything else at the same time.
     */
    const markup = render({ detail: 'e:ublock' })
    expect(shows(markup, 'extensions')).toBe(true)
    expect(shows(markup, 'servers')).toBe(false)
  })

  it('knows which department owns each kind of key', () => {
    // Three kinds of row are numbered independently, so a bare id could name two
    // of them. The prefix is what tells the page which half to ask.
    expect(departmentOfRow('e:ublock')).toBe('extensions')
    expect(departmentOfRow('t:page-images')).toBe('extensions')
    expect(departmentOfRow('m:github')).toBe('servers')
    expect(departmentOfRow('')).toBeNull()
  })
})

describe('the chips belong to their own department', () => {
  it('does not let one half’s filter empty the other', () => {
    /*
     * `release` is a word only the extension catalogue has; the MCP catalogue's
     * sources are `reference` and `third-party`. One shared filter meant
     * pressing a chip under one heading blanked the department under the other.
     */
    const chosen: StoreFilter = { ...NO_FILTER, source: 'release' }
    const markup = render({ departments: [{ ...EXTENSIONS, filter: chosen }, SERVERS] })
    expect(shows(markup, 'servers')).toBe(true)
    expect(shows(markup, 'extensions')).toBe(true)
  })
})
