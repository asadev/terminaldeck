import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { StoreBody, type StoreBodyProps } from './McpStore'
import type { McpStoreRow as Row, McpStoreView } from './mcp-store-bridge'
import { NO_FILTER, withFacet } from '../store/storefront'

/**
 * The MCP store's one screen, rendered.
 *
 * There is no DOM in this project's test setup, so this renders `StoreBody`
 * through `react-dom/server` — the panel around it loads through an effect,
 * which SSR never runs, and asserting on the panel would be the *"proof by a
 * function nothing calls"* this store was already audited for once.
 *
 * What is being asserted is that the store browses. It used to group nineteen
 * rows into four bins named after their state — Installed, Ready to install, A
 * server already has this name, Cannot run on this machine — which answers one
 * question, and not the one anybody arrives with.
 */

function row(over: Partial<Row> = {}): Row {
  return {
    id: 'filesystem',
    name: 'filesystem',
    summary: 'Reads, writes and searches files, under directories you name.',
    category: 'files',
    tags: ['files', 'folder', 'disk'],
    homepage: 'https://github.com/modelcontextprotocol/servers',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-filesystem',
    licence: 'MIT',
    version: '2026.7.10',
    runtime: 'node',
    runtimeBinary: 'npx',
    origin: 'reference',
    cost: 'free',
    costNote: '',
    command: 'npx -y @modelcontextprotocol/server-filesystem ${ROOT}',
    inputs: [],
    state: 'available',
    scope: '',
    custom: false,
    transport: 'stdio',
    envKeys: [],
    runsWords: '',
    runtimeMissing: false,
    taken: '',
    blocked: '',
    logo: 'modelcontextprotocol',
    caveat: '',
    ...over,
  }
}

const POSTGRES = row({
  id: 'postgres',
  name: 'postgres',
  summary: 'Runs read-only SQL against a Postgres database.',
  category: 'data',
  tags: ['sql', 'database'],
  origin: 'reference-archived',
  caveat: 'This one now lives in modelcontextprotocol/servers-archived.',
})

const GITHUB = row({
  id: 'github',
  name: 'github',
  summary: 'Issues, pull requests, code search.',
  category: 'code',
  tags: ['pull requests', 'issues'],
  homepage: 'https://github.com/github/github-mcp-server',
  runtime: 'docker',
  runtimeBinary: 'docker',
  origin: 'third-party',
  state: 'unavailable',
  // Both, because `buildStoreView` sets both for a catalogue row whose runtime
  // is missing. The compat filter reads `runtimeMissing` rather than the state,
  // so that a server somebody added — which stays `installed`, because it is in
  // the configuration — can also say its runtime has gone.
  runtimeMissing: true,
  blocked: 'docker is not on this machine. It needs Docker, and it has to be running.',
})

const VIEW: McpStoreView = {
  rows: [row(), POSTGRES, GITHUB],
  runtimes: [
    { id: 'node', binary: 'npx', found: true, path: '/usr/bin/npx', needs: 'Node.js.' },
    { id: 'python', binary: 'uvx', found: true, path: '/usr/bin/uvx', needs: 'uv.' },
    { id: 'docker', binary: 'docker', found: false, path: '', needs: 'Docker.' },
  ],
  writer: { found: true, path: '/usr/bin/claude' },
  environmentSource: 'login-shell',
  projectPath: '',
}

function render(over: Partial<StoreBodyProps> = {}): string {
  const noop = (): void => {}
  return renderToStaticMarkup(
    <StoreBody
      view={VIEW}
      busy=""
      values={{}}
      said={{}}
      saidOwn=""
      arming=""
      asking=""
      filter={NO_FILTER}
      onFilter={noop}
      onValue={noop}
      onAct={noop}
      onArm={noop}
      onAsk={noop}
      onAddOwn={noop}
      onImport={noop}
      onEdit={noop}
      onExport={noop}
      {...over}
    />,
  )
}

describe('the shelves', () => {
  it('groups by what a server does, not by whether it can be installed', () => {
    const markup = render()
    expect(markup).toContain('Files on this machine')
    expect(markup).toContain('Databases')
    expect(markup).toContain('Code and repositories')
    // The bins the shelves replaced.
    expect(markup).not.toContain('Ready to install')
    expect(markup).not.toContain('Cannot run on this machine')
  })

  it('draws no heading for a shelf with nothing on it', () => {
    expect(render()).not.toContain('Chat and messaging')
  })

  it('keeps a row that cannot run, on its own shelf, with a chip saying which', () => {
    /*
     * The row is not hidden and not moved to a bin at the bottom. Somebody
     * looking under *Code and repositories* for the GitHub server has to find
     * it there — "it is not in the list" and "your machine has no Docker" are
     * different answers and only one of them is true.
     */
    const markup = render()
    expect(markup).toContain('Cannot run here')
    expect(markup).toContain('docker is not on this machine')
  })
})

describe('search and filters', () => {
  it('finds a row by a tag that is in neither its name nor its summary', () => {
    const markup = render({ filter: { ...NO_FILTER, query: 'sql' } })
    expect(markup).toContain('postgres')
    expect(markup).not.toContain('Files on this machine')
  })

  it('says so when a search matches nothing, rather than looking like an empty store', () => {
    const markup = render({ filter: { ...NO_FILTER, query: 'wombat' } })
    expect(markup).toContain('Nothing in the catalogue matches that')
  })

  it('keeps the archived distinction filterable', () => {
    /*
     * The one maintenance fact this catalogue actually checked, on a dated day,
     * against GitHub's own `archived: true`. A store that folded those rows in
     * with the maintained reference servers would be throwing it away.
     */
    const markup = render({ filter: withFacet(NO_FILTER, 'source', 'reference-archived') })
    expect(markup).toContain('postgres')
    expect(markup).not.toContain('Files on this machine')
  })

  it('offers the source chips with the archived one named as unmaintained', () => {
    const markup = render()
    expect(markup).toContain('Archived — unmaintained')
    expect(markup).toContain('Official reference')
    expect(markup).toContain('Community')
  })

  it('draws no runtime chip when every row’s runtime is present', () => {
    // Absent rather than disabled. With nothing missing there is one live option
    // and the group is not drawn at all.
    const allFine = { ...VIEW, rows: [row(), POSTGRES] }
    expect(render({ view: allFine })).not.toContain('Runtime missing')
    expect(render()).toContain('Runtime missing')
  })
})

describe('installed', () => {
  it('is its own section above the shelves, so "do I have this" is answered by order', () => {
    /*
     * Matched on the headings rather than on the words, because the words are
     * now in the filter chips as well — *Installed* and *Databases* both appear
     * in the bar above everything, which is where the control that governs the
     * whole screen belongs.
     */
    const view = { ...VIEW, rows: [row({ state: 'installed', scope: 'user' }), POSTGRES] }
    const markup = render({ view })
    const heading = (text: string) => markup.indexOf(`mcp-store-heading">${text}<`)
    expect(heading('Installed')).toBeGreaterThan(-1)
    expect(heading('Installed')).toBeLessThan(heading('Databases'))
  })

  it('puts the filters above everything they govern', () => {
    // Including the Installed section: choosing "Not configured" has to be able
    // to empty it, and a control that filters what is above it reads as broken.
    const view = { ...VIEW, rows: [row({ state: 'installed', scope: 'user' }), POSTGRES] }
    const markup = render({ view })
    expect(markup.indexOf('storefront-facet')).toBeGreaterThan(-1)
    expect(markup.indexOf('storefront-facet')).toBeLessThan(
      markup.indexOf('mcp-store-heading">Installed<'),
    )
  })

  it('draws no search box of its own, because the page above carries one', () => {
    /*
     * This body is one **department** of the store page now, and the page has a
     * single box that searches both it and the browser's extensions. A second
     * box under this heading would search half a store while looking like it
     * searched all of it — see `store/StorePage.tsx`.
     */
    expect(render()).not.toContain('storefront-search')
  })

  it('says everything is configured rather than showing an empty browse area', () => {
    const view = { ...VIEW, rows: [row({ state: 'installed', scope: 'user' })] }
    expect(render({ view })).toContain('Everything in the catalogue is already in your configuration')
  })

  it('does not say nothing matched when what matched is installed and shown above', () => {
    /*
     * Rendering this and looking at it is what caught the sentence this
     * replaces. Filtering to *Files on this machine* — whose one row is
     * installed — drew "Nothing in the catalogue matches that" directly under
     * the row that had just matched. The browsing area was empty; the catalogue
     * was not, and those are different claims.
     */
    const view = { ...VIEW, rows: [row({ state: 'installed', scope: 'user' }), POSTGRES] }
    const markup = render({ view, filter: withFacet(NO_FILTER, 'category', 'files') })
    expect(markup).not.toContain('Nothing in the catalogue matches that')
    expect(markup).toContain('already in your configuration — it is above')
  })
})

describe('the store’s one standing sentence', () => {
  it('says nothing ships inside the app, and what a row with no Install carries instead', () => {
    const markup = render()
    expect(markup).toContain('Nothing here ships inside this app')
    expect(markup).toContain('Get it')
  })

  it('keeps the Get it explanation reachable rather than printed above every shelf', () => {
    /*
     * Four lines above the first shelf, of which two were about rows a person
     * may never meet. Measured at 1440x900 with the filter bar and the *Added by
     * you* card: **533px before the first row**, on a page whose rows are 137px
     * next door in the extensions department.
     *
     * Behind the dot, not deleted — `HoverNote` keeps its paragraph in the
     * document whether or not anything is hovering, which is why this can be
     * asserted at all. The row itself still carries the chip, the main process's
     * own sentence and the Get it link; this paragraph was the third telling.
     */
    const markup = render()
    expect(markup).toContain('hovernote-text')
    expect(markup).toContain('the runtime it needs is not on this machine')
    expect(markup).not.toContain(
      '<p class="mcp-store-note">A row with no Install says which of two things',
    )
  })
})

describe('the shelf for what you added yourself', () => {
  const MINE = row({
    id: 'own:user:my-notes',
    name: 'my-notes',
    summary: 'You added this one.',
    category: 'your-own',
    tags: [],
    homepage: '',
    registry: '',
    licence: '',
    version: '',
    origin: 'third-party',
    command: 'npx -y @me/notes /Users/me/Notes',
    state: 'installed',
    scope: 'user',
    custom: true,
    envKeys: ['API_KEY'],
    runsWords: 'npx on this machine — /opt/homebrew/bin/npx',
  })

  it('draws the door whether or not anything has come through it', () => {
    /*
     * The shelf is the way *in*, not a result, so it is there on a machine with
     * nothing hand-written. The button used to live in the bar above the store —
     * and what it added did not appear in the store at all, which is the defect
     * this shelf exists to close.
     */
    const markup = render()
    expect(markup).toContain('Added by you')
    expect(markup).toContain('Add your own tool…')
  })

  it('is a control on one line now, with its paragraph still reachable behind it', () => {
    /*
     * It was a bordered card carrying a four-line paragraph, 208px of it, above
     * a store whose first row was already below the fold at 1440x900. The
     * paragraph is worth reading once, by somebody about to press the button,
     * and was being printed on every visit to a page that is mostly a catalogue
     * of rows nobody typed.
     */
    const markup = render()
    expect(markup).toContain('mcp-store-own-bar')
    expect(markup).toContain('Any MCP server at all')
    expect(markup).not.toContain('<p class="mcp-store-note">Any MCP server at all')
  })

  it('puts a server you added on it, with what is actually configured on the row', () => {
    const markup = render({ view: { ...VIEW, rows: [row(), MINE] } })
    expect(markup).toContain('my-notes')
    expect(markup).toContain('npx -y @me/notes /Users/me/Notes')
    // The variables it carries, by name. A value could only be here if something
    // above put one on the wire, and `configuredForStore` sends names.
    expect(markup).toContain('API_KEY')
    expect(markup).toContain('its value is in your configuration and is not shown here')
  })

  it('draws no empty link where a catalogue row would have a project page', () => {
    /*
     * Nobody published it, so `homepage` and `registry` are `''` — and an empty
     * `<a href="">` is a link to the page you are already on, which is the dead
     * control this store is not allowed to have.
     */
    expect(render({ view: { ...VIEW, rows: [MINE] } })).not.toContain('href=""')
  })

  it('offers Edit and Share only when this build can do them', () => {
    // Absent rather than disabled, the standing rule for a control that cannot
    // do anything — here because the preload predates the channel.
    const view = { ...VIEW, rows: [MINE] }
    const without = render({ view })
    expect(without).not.toContain('>Edit<')
    expect(without).not.toContain('>Share<')
    const with_ = render({ view, canEdit: true, canExport: true })
    expect(with_).toContain('>Edit<')
    expect(with_).toContain('>Share<')
  })

  it('keeps a server you added out of the catalogue’s Installed section', () => {
    // Otherwise it sits between two catalogue rows, which is where it was
    // invisible in the first place.
    const view = { ...VIEW, rows: [row({ state: 'installed', scope: 'user' }), MINE] }
    const markup = render({ view })
    const own = markup.indexOf('Added by you')
    const installed = markup.indexOf('>Installed<')
    expect(own).toBeGreaterThan(-1)
    expect(installed).toBeGreaterThan(own)
    expect(markup.indexOf('my-notes')).toBeLessThan(installed)
  })

  it('says which of yours the filter is hiding, rather than nothing at all', () => {
    // Silence under the heading would read as "you have added nothing", which
    // would be false.
    const view = { ...VIEW, rows: [row(), MINE] }
    const markup = render({ view, filter: withFacet(NO_FILTER, 'category', 'files') })
    expect(markup).toContain('The one you added does not match that')
  })
})
