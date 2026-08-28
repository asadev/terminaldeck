import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { NO_FILTER, withFacet, type StoreFilter } from '../store/storefront'
import { CommunityBody, type CommunityBodyProps } from './CommunityDepartment'
import { NO_COMMUNITY, type CommunityItem, type CommunityView } from './bridge'

/**
 * The Community department's one screen, actually rendered.
 *
 * `CommunityBody` is the whole department as a pure function of the loaded
 * catalogue — the container above it only adds the effects SSR cannot run — so
 * rendering it here is rendering what a person sees rather than a helper nothing
 * calls. That split is the same one `StoreBody` and `StorePageFrame` have, and
 * for the same reason: this project has no DOM in its test setup, deliberately.
 */

function item(over: Partial<CommunityItem> = {}): CommunityItem {
  return {
    id: 'acme/pr-review',
    publisher: 'acme',
    handle: 'acme',
    profileUrl: 'https://terminaldeck.dev/@acme',
    kind: 'skill',
    name: 'Pull request review',
    summary: 'Reads a diff and writes the review.',
    version: '1.2.0',
    licence: 'MIT',
    tags: [],
    agents: ['claude', 'codex', 'gemini'],
    tier: 2,
    needs: [],
    missing: [],
    cost: 'free',
    costNote: '',
    delivery: 'repo',
    offsiteUrl: '',
    repo: 'https://github.com/acme/pr-review',
    commit: 'a'.repeat(40),
    artifactUrl: 'https://codeload.github.com/acme/pr-review/zip/aaa',
    sha256: 'b'.repeat(64),
    bytes: 4096,
    network: [],
    updatedAt: '2026-08-26T00:00:00.000Z',
    stars: 1204,
    openIssues: 12,
    ratingScore: 0,
    ratingCount: 0,
    state: 'available',
    installedVersion: '',
    message: '',
    reason: '',
    lands: ['/Users/x/.claude/skills/acme.pr-review'],
    command: '',
    variables: [],
    trigger: '',
    reach: [],
    logo: '',
    ...over,
  }
}

const SERVER = item({
  id: 'lumen/postgres',
  publisher: 'lumen',
  handle: 'lumen',
  kind: 'mcp',
  name: 'Postgres',
  summary: 'Queries a database.',
  tier: 3,
  needs: ['node'],
  command: 'npx -y @lumen/postgres',
  artifactUrl: '',
  sha256: '',
})

/** A paid listing we do not host: a classified advertisement and nothing more. */
const OFFSITE = item({
  id: 'northwind/desk',
  publisher: 'northwind',
  handle: 'northwind',
  kind: 'tool',
  name: 'Desk',
  summary: 'A program you install yourself.',
  cost: 'paid',
  costNote: 'Their price is $9 a month.',
  delivery: 'off-site',
  offsiteUrl: 'https://www.northwind.example/desk',
  artifactUrl: '',
  sha256: '',
  commit: '',
  ratingScore: 4.9,
  ratingCount: 40,
})

function view(over: Partial<CommunityView> = {}): CommunityView {
  return {
    ...NO_COMMUNITY,
    at: '2026-08-29T09:00:00.000Z',
    items: [item(), SERVER, OFFSITE],
    folder: '/Users/x/Library/Application Support/deck/community',
    agents: [
      { id: 'claude', name: 'Claude Code', found: true, note: '' },
      { id: 'codex', name: 'Codex CLI', found: false, note: '' },
      { id: 'gemini', name: 'Gemini CLI', found: true, note: '' },
    ],
    ...over,
  }
}

function render(over: Partial<CommunityBodyProps> = {}): string {
  return renderToStaticMarkup(
    <CommunityBody
      view={view()}
      filter={NO_FILTER}
      busy=""
      said={{}}
      onFilter={() => {}}
      onRefresh={() => {}}
      onInstall={() => {}}
      onRemove={() => {}}
      {...over}
    />,
  )
}

describe('the shelves', () => {
  it('groups by kind, and heads each shelf with the kind’s own name', () => {
    // Somebody browsing a community store is looking for *skills*. The kind is
    // what they shop by, so the kind is the shelf.
    const markup = render()
    expect(markup).toContain('Skill')
    expect(markup).toContain('MCP server')
    expect(markup).toContain('Open-source tool')
  })

  it('draws no shelf for a kind nothing is on', () => {
    // The same rule a chip obeys and the rail obeys: a heading over nothing is
    // furniture.
    const markup = render({ view: view({ items: [item()] }) })
    expect(markup).not.toContain('Hooks')
    expect(markup).not.toContain('Browser extension')
  })

  it('says what is missing rather than nothing when a filter empties it', () => {
    const filter: StoreFilter = withFacet(NO_FILTER, 'cost', 'metered')
    expect(render({ filter })).toContain('Nothing here matches that')
  })
})

describe('the controls it draws and the ones it does not', () => {
  it('has no second search box', () => {
    // One box on the page searches the whole store. A second under this heading
    // would search a third of it while looking like it searched all of it.
    expect(render()).not.toContain('type="search"')
  })

  it('draws no "where it comes from" chips, because every row answers the same', () => {
    expect(render()).not.toContain('Where it comes from')
  })

  it('draws a price control only because the shop holds more than one price', () => {
    // A chip is drawn only if choosing it would leave something on screen, so
    // this is `facetControl`'s rule visible on the surface it protects.
    expect(render()).toContain('What it costs')
    expect(render({ view: view({ items: [item()] }) })).not.toContain('What it costs')
  })

  it('never draws a chip with a count of zero', () => {
    expect(render()).not.toMatch(/storefront-chip-count">0</)
  })
})

describe('what a row is allowed to offer', () => {
  it('gives an off-site listing one way out and no Install anywhere on it', () => {
    /*
     * A paid item we do not host is a classified advertisement: the publisher's
     * own price, and a button to their own domain. Never a disabled Install —
     * the law `facetControl` encodes by returning null below two options applies
     * to buttons too.
     */
    const markup = render({ view: view({ items: [OFFSITE] }) })
    expect(markup).toContain('Get it from northwind.example')
    expect(markup).not.toContain('>Install<')
    expect(markup).not.toContain('disabled')
  })

  it('prints a price sentence above the button rather than after it', () => {
    // A cost read after pressing Install arrived too late.
    expect(render({ view: view({ items: [OFFSITE] }) })).toContain('Their price is $9 a month.')
  })

  it('gives an installed row a Remove and no Install', () => {
    const markup = render({
      view: view({ items: [item({ state: 'installed', installedVersion: '1.2.0' })] }),
    })
    expect(markup).toContain('Remove')
    expect(markup).not.toContain('>Install<')
  })

  it('offers an update rather than a second install for an outdated row', () => {
    const markup = render({
      view: view({ items: [item({ state: 'outdated', installedVersion: '1.0.0' })] }),
    })
    expect(markup).toContain('Update')
    expect(markup).toContain('Remove')
  })

  it('says a row is installing on the row that is installing', () => {
    const markup = render({ busy: 'acme/pr-review', view: view({ items: [item()] }) })
    expect(markup).toContain('Installing…')
  })

  it('prints the real reason an install failed, in its own words', () => {
    // Never "That did not work" over a sentence the app actually has.
    const markup = render({
      said: { 'acme/pr-review': 'the download did not match its fingerprint' },
      view: view({ items: [item()] }),
    })
    expect(markup).toContain('the download did not match its fingerprint')
  })

  it('keeps a withdrawn item on screen with its reason and a Remove', () => {
    /*
     * The app never uninstalls anything on its own. Deleting a stranger's files
     * off somebody's disk because a web form was filled in is not a capability
     * anybody should hand a website — revocation stops distribution and tells
     * the truth on the row; removal stays a human act.
     */
    const markup = render({
      view: view({
        items: [
          item({ state: 'withdrawn', installedVersion: '1.2.0', reason: 'it shipped a key' }),
        ],
      }),
    })
    expect(markup).toContain('Withdrawn: it shipped a key')
    expect(markup).toContain('Pull request review')
    expect(markup).toContain('Remove')
  })
})

describe('the disclosure stays on the shelf', () => {
  it('shows the commit, the download and the fingerprint on this screen', () => {
    /*
     * `StorePanel.test.tsx` carries a test of exactly this name, and it exists
     * because it was got wrong once: moving the awkward facts behind navigation
     * tidies the shelf and quietly stops the disclosure being disclosure.
     */
    const markup = render({ view: view({ items: [item()] }) })
    expect(markup).toContain('a'.repeat(40))
    expect(markup).toContain('b'.repeat(64))
    expect(markup).toContain('https://codeload.github.com/acme/pr-review/zip/aaa')
  })

  it('folds it behind a label that names what is inside, never "More"', () => {
    const markup = render()
    expect(markup).toContain('Publisher, repository, the exact commit, download and fingerprint')
  })

  it('says on the row what the item can reach on this machine', () => {
    // The one fact that decides whether the button below is worth pressing.
    const markup = render({ view: view({ items: [SERVER]}) })
    expect(markup).toContain('Runs a program on this machine')
  })

  it('names the publisher on every row', () => {
    expect(render()).toContain('@acme')
  })
})

describe('what it says when the catalogue is old or absent', () => {
  it('draws the list it kept, and says the date on it', () => {
    // Offline is not a reason to hide a shop somebody already has; it is a
    // reason to say how old the list is.
    const markup = render({
      view: view({ from: 'kept', because: 'the store could not be reached' }),
    })
    expect(markup).toContain('Catalogue from 29 August')
    expect(markup).toContain('the store could not be reached')
    expect(markup).toContain('Pull request review')
  })

  it('says nothing about a date when the list came off the store just now', () => {
    expect(render()).not.toContain('Catalogue from')
  })

  it('draws a real screen, not an empty grid, when there is nothing kept either', () => {
    const markup = render({
      view: view({ items: [], problem: 'the store could not be reached, and nothing was kept' }),
    })
    expect(markup).toContain('Nothing has been fetched yet')
    expect(markup).toContain('the store could not be reached, and nothing was kept')
    expect(markup).toContain('Try again')
  })

  it('says where the files are, because Remove promises to delete them', () => {
    expect(render()).toContain('/Users/x/Library/Application Support/deck/community')
  })

  it('says whose the things on these shelves are, in one line', () => {
    expect(render()).toContain('it does not review, endorse or sell them')
  })
})
