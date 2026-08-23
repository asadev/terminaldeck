/**
 * The store page, in a real browser, over the real catalogues.
 *
 * The lane's instruction was to render it and look at it, and nothing about this
 * page can be looked at through `renderToStaticMarkup`: the rail's counts, the
 * cross-filtering, the shelf you are standing on and the detail view are all
 * functions of state that only exists after something has been typed or pressed.
 *
 * Both departments are driven by `BROWSER_EXTENSION_CATALOGUE` and
 * `MCP_CATALOGUE` — twenty-four extensions across eight shelves and eighteen
 * servers across nine — because a store's rail is only worth judging over the
 * number of rows it actually has. Three fixtures would have shown a rail with
 * nothing to count.
 *
 * `?q=` pre-fills the search, `?shelf=<department>:<id>` stands the page on a
 * shelf, and `?row=<key>` opens one row on its own — so a screenshot of any of
 * the four states is one URL rather than a sequence of clicks.
 */
import './stub'
import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
/* The empty state is `components/PageEmpty.tsx`, whose rules live in the
   shell's sheet — which `App.tsx` imports and nothing else does. Without it
   this harness draws a left-aligned, full-width blank that the app never
   shows, and a screenshot of it would be a screenshot of the harness. */
import '../src/renderer/shell/shell.css'
import '../src/renderer/browser/BrowserWorkspace.css'
import '../src/renderer/components/McpInspector.css'
import {
  StoreBody as BrowserStoreBody,
  BROWSER_SHELVES,
  BUILT_IN_SHELF,
} from '../src/renderer/browser/StorePanel'
import { StoreBody as McpStoreBody } from '../src/renderer/components/McpStore'
import { StorePageFrame } from '../src/renderer/store/StorePage'
import { StoreDetail } from '../src/renderer/store/StoreDetail'
import { ExtensionRow } from '../src/renderer/browser/ExtensionRow'
import { McpStoreRow as McpRow } from '../src/renderer/components/McpStoreRow'
import {
  EVERYTHING,
  filterFor,
  type StoreDepartmentInput,
  type StorePlace,
} from '../src/renderer/store/store-nav'
import { NO_FILTER, type StoreFilter } from '../src/renderer/store/storefront'
import {
  CATEGORY_NAMES,
  extensionFacets,
  type ExtensionsView,
  type StoreExtension,
} from '../src/renderer/browser/extensions-bridge'
import type { StoreView } from '../src/renderer/browser/store-bridge'
import {
  MCP_CATEGORY_NAMES,
  MCP_CATEGORY_ORDER,
  mcpFacets,
  type McpStoreRow,
  type McpStoreView,
} from '../src/renderer/components/mcp-store-bridge'
import { BROWSER_EXTENSION_CATALOGUE } from '../src/main/browser-extension-catalogue'
import { MCP_CATALOGUE, RUNTIME_BINARY, RUNTIME_NEEDS } from '../src/main/mcp-catalogue'

/* --------------------------------------------------- the browser store's rows -- */

function extensionRows(): StoreExtension[] {
  return BROWSER_EXTENSION_CATALOGUE.map((entry) => ({
    id: entry.id,
    name: entry.name,
    summary: entry.summary,
    homepage: entry.homepage,
    licence: entry.licence,
    version: entry.works === 'unmeasured' ? '' : entry.version,
    works: entry.works,
    category: entry.category,
    tags: [...entry.tags],
    needs: [...(entry.needs ?? [])],
    /* This fixture predated the price field and drew *What it costs* with
       nothing after it — the empty-fact this store is written against, in the
       one place it is looked at. */
    cost: entry.cost,
    costNote: entry.costNote,
    logo: entry.logo ?? '',
    measured: entry.measured,
    noRelease: entry.noRelease ?? '',
    url: entry.source?.url ?? '',
    sha256: entry.source?.sha256 ?? '',
    bytes: entry.source?.bytes ?? 0,
    state:
      entry.works === 'unmeasured'
        ? ('not-offered' as const)
        : entry.source === null
          ? ('unavailable' as const)
          : ('available' as const),
    installedVersion: '',
    installedAt: 0,
    enabled: false,
    reach: [...entry.reach],
    mayAsk: [...(entry.mayAskToReach ?? [])],
    everywhere: entry.reach.some((one) => one === '<all_urls>' || one === '*://*/*'),
    missing: [],
    provides: [],
    inert: [],
    rulesetsSwitchedOn: 0,
    popup: '',
    optionsPage: '',
    sideloaded: false,
    origin: '',
    crxId: '',
    staticRulesets: false,
    message: '',
  })).map((one) =>
    one.id === 'dark-reader'
      ? {
          ...one,
          state: 'installed' as const,
          enabled: true,
          installedVersion: one.version,
          installedAt: Date.now(),
          popup: 'ui/popup/index.html',
        }
      : one,
  )
}

const EXT: ExtensionsView = {
  profileId: 'default',
  profileName: 'Default',
  extensions: extensionRows(),
  folder: '/Users/apple/Library/Application Support/Terminal Deck/browser-extensions/default',
  orphans: [],
  profiles: [{ id: 'default', name: 'Default' }],
  limits: [
    'There is no Chrome Web Store here, so nothing installs from one.',
    'Toolbar buttons and badges are not drawn.',
    'Keyboard shortcuts declared by an extension are not bound.',
  ],
}

const TOOLS: StoreView = {
  tools: [
    {
      id: 'page-images',
      name: 'Full-size images',
      summary: 'Every image URL a page offers, at its largest.',
      homepage: 'https://terminaldeck.dev',
      licence: 'Public domain',
      version: '1.0.0',
      grants: ['page-read'],
      origins: ['*'],
      url: '',
      fetched: false,
      sha256: 'b'.repeat(64),
      state: 'available',
      installedVersion: '',
      installedAt: 0,
      message: '',
      reads: [],
    },
    {
      id: 'page-text',
      name: 'Readable text',
      summary: 'The article on a page, without the furniture around it.',
      homepage: 'https://terminaldeck.dev',
      licence: 'Public domain',
      version: '1.0.0',
      grants: ['page-read'],
      origins: ['*'],
      url: '',
      fetched: false,
      sha256: 'c'.repeat(64),
      state: 'installed',
      installedVersion: '1.0.0',
      installedAt: Date.now(),
      message: '',
      reads: [],
    },
  ],
  folder: '/Users/apple/Library/Application Support/Terminal Deck/browser-tools',
  orphans: [],
}

/* ------------------------------------------------------- the MCP store's rows -- */

/** Docker absent, npx and uvx present — the machine this app is being read on. */
const HAS: Record<string, boolean> = { node: true, python: true, docker: false }

function mcpRows(): McpStoreRow[] {
  return MCP_CATALOGUE.map((entry): McpStoreRow => {
    const found = HAS[entry.runtime] ?? false
    const installed = entry.id === 'filesystem'
    return {
      id: entry.id,
      name: entry.name,
      summary: entry.summary,
      category: entry.category,
      tags: [...entry.tags],
      homepage: entry.homepage,
      registry: entry.registry,
      licence: entry.licence,
      version: entry.version,
      runtime: entry.runtime,
      runtimeBinary: RUNTIME_BINARY[entry.runtime],
      origin: entry.origin,
      cost: entry.cost,
      costNote: entry.costNote,
      logo: entry.logo ?? '',
      command: installed
        ? 'npx -y @modelcontextprotocol/server-filesystem /Users/apple/Projects'
        : entry.command,
      inputs: entry.inputs.map((input) => ({ ...input, inEnvironment: false })),
      state: installed ? 'installed' : found ? 'available' : 'unavailable',
      scope: installed ? 'user' : '',
      custom: false,
      transport: 'stdio',
      envKeys: [],
      runsWords: '',
      runtimeMissing: !found,
      taken: '',
      blocked: found
        ? ''
        : `${RUNTIME_BINARY[entry.runtime]} is not on this machine. It needs ${RUNTIME_NEEDS[entry.runtime]}`,
      caveat: entry.caveat ?? '',
    }
  })
}

/**
 * Two servers somebody typed, so the page's *Added by you* shelf has something
 * on it and the rail has a count to draw.
 *
 * One that runs and one whose runtime is missing, which is the case worth
 * looking at: it stays **installed**, keeps its Remove, and says the problem in
 * a sentence, rather than becoming the buttonless row a catalogue entry in the
 * same position gets. See `src/main/mcp-custom.ts`.
 */
function customRows(): McpStoreRow[] {
  const base = {
    category: 'your-own' as const,
    tags: [],
    homepage: '',
    registry: '',
    licence: '',
    version: '',
    origin: 'third-party' as const,
    cost: 'unknown' as const,
    costNote: '',
    logo: '',
    inputs: [],
    state: 'installed' as const,
    scope: 'user' as const,
    custom: true,
    transport: 'stdio' as const,
    taken: '',
    blocked: '',
    summary:
      'You added this one. It is not in this app’s catalogue, nothing here was measured about ' +
      'what it does, and no fingerprint was checked against it — it is configured because you ' +
      'said so.',
  }
  return [
    {
      ...base,
      id: 'own:user:my-notes',
      name: 'my-notes',
      runtime: 'node' as const,
      runtimeBinary: 'npx',
      command: 'npx -y @me/notes-mcp /Users/apple/Notes',
      envKeys: ['NOTES_API_KEY'],
      runsWords: 'npx on this machine — /opt/homebrew/bin/npx',
      runtimeMissing: false,
      caveat: '',
    },
    {
      ...base,
      id: 'own:user:team-index',
      name: 'team-index',
      runtime: 'docker' as const,
      runtimeBinary: 'docker',
      command: 'docker run --rm -i ghcr.io/acme/team-index:2',
      envKeys: [],
      runsWords: 'docker on this machine, and it is not there.',
      runtimeMissing: true,
      caveat:
        'docker is not on this machine, so this server cannot start here. It is still in your ' +
        'configuration — nothing was removed — and whatever runs it will fail until that binary ' +
        'is installed or the command is changed.',
    },
  ]
}

const MCP: McpStoreView = {
  rows: [...mcpRows(), ...customRows()],
  runtimes: (['node', 'python', 'docker'] as const).map((id) => ({
    id,
    binary: RUNTIME_BINARY[id],
    found: HAS[id] ?? false,
    path: HAS[id] ? `/opt/homebrew/bin/${RUNTIME_BINARY[id]}` : '',
    needs: RUNTIME_NEEDS[id],
  })),
  writer: { found: true, path: '/Users/apple/.local/bin/claude' },
  environmentSource: 'login-shell',
  projectPath: '/Users/apple/Projects/terminaldeck',
}

/* ------------------------------------------------------------------- the page -- */

const noop = (): void => {}

const DEPARTMENTS = (chips: Record<'extensions' | 'servers', StoreFilter>, query: string): StoreDepartmentInput[] => [
  {
    id: 'extensions',
    name: 'Browser extensions',
    wired: true,
    filter: { ...chips.extensions, query },
    shelves: BROWSER_SHELVES,
    rows: [
      ...EXT.extensions.map(extensionFacets),
      ...TOOLS.tools.map((tool) => ({
        id: tool.id,
        name: tool.name,
        summary: tool.summary,
        category: BUILT_IN_SHELF,
        categoryName: 'Built into this app',
        tags: [] as string[],
        compat: 'works' as const,
        installed: tool.state === 'installed',
        source: BUILT_IN_SHELF,
        needs: [] as string[],
      })),
    ],
  },
  {
    id: 'servers',
    name: 'MCP servers',
    wired: true,
    filter: { ...chips.servers, query },
    shelves: MCP_CATEGORY_ORDER.map((id) => ({ id, name: MCP_CATEGORY_NAMES[id] })),
    rows: MCP.rows.map(mcpFacets),
  },
]

const params = new URLSearchParams(location.search)
const startShelf = params.get('shelf') ?? ''
const startPlace: StorePlace = startShelf.includes(':')
  ? {
      kind: 'shelf',
      department: startShelf.split(':')[0] as 'extensions' | 'servers',
      shelf: startShelf.split(':')[1],
    }
  : EVERYTHING

function Page() {
  const [query, setQuery] = useState(params.get('q') ?? '')
  const [chips, setChips] = useState<Record<'extensions' | 'servers', StoreFilter>>({
    extensions: NO_FILTER,
    servers: NO_FILTER,
  })
  const [place, setPlace] = useState<StorePlace>(startPlace)
  const [detail, setDetail] = useState(params.get('row') ?? '')

  const departments = DEPARTMENTS(chips, query)
  const extension = EXT.extensions.find((one) => `e:${one.id}` === detail)
  const server = MCP.rows.find((one) => `m:${one.id}` === detail)
  const chipsFor = (id: 'extensions' | 'servers') => (next: StoreFilter) => {
    setQuery(next.query)
    setChips((was) => ({ ...was, [id]: next }))
  }

  return (
    <StorePageFrame
      departments={departments}
      place={place}
      detail={detail}
      onQuery={(next) => {
        setDetail('')
        setQuery(next)
      }}
      onPlace={(next) => {
        setDetail('')
        setPlace(next)
      }}
      onClear={() => {
        setDetail('')
        setQuery('')
        setChips({ extensions: NO_FILTER, servers: NO_FILTER })
        setPlace(EVERYTHING)
      }}
      department={(id) =>
        id === 'extensions' ? (
          extension ? (
            <StoreDetail
              backTo={CATEGORY_NAMES[extension.category] ?? 'the store'}
              onBack={() => setDetail('')}
            >
              <ul className="bw-store-list">
                <ExtensionRow
                  extension={extension}
                  busy={false}
                  said=""
                  canOpenPopup
                  canOpenOptions
                  onAct={noop}
                  onEnable={noop}
                  onOpenPopup={noop}
                  onOpenOptions={noop}
                />
              </ul>
            </StoreDetail>
          ) : (
            <BrowserStoreBody
              toolsWired
              extensionsWired
              tools={TOOLS}
              toolsProblem=""
              ext={EXT}
              extProblem=""
              showing="default"
              busy=""
              said={{}}
              canOpenPopup
              canOpenOptions
              canAddFolder
              canAddCrx
              filter={filterFor(place, departments[0])}
              onShowProfile={noop}
              onFilter={chipsFor('extensions')}
              onOpenRow={setDetail}
              onTool={noop}
              onExtension={noop}
              onEnable={noop}
              onOpenPopup={noop}
              onOpenOptions={noop}
              onAddOwn={noop}
            />
          )
        ) : server ? (
          <StoreDetail
            backTo={MCP_CATEGORY_NAMES[server.category] ?? 'the store'}
            onBack={() => setDetail('')}
          >
            <ul className="mcp-store-list">
              <McpRow
                row={server}
                busy={false}
                values={{}}
                said=""
                arming={false}
                onValue={noop}
                onAct={noop}
                onArm={noop}
              />
            </ul>
          </StoreDetail>
        ) : (
          <div className="mcp-store">
            <McpStoreBody
              view={MCP}
              busy=""
              values={{}}
              said={{}}
              saidOwn=""
              arming=""
              /* Every optional door on, because the harness is where the
                 shipped row is judged. Their absence is the *older preload*
                 case, and `McpStoreRow.test.tsx` is what pins that. */
              canEdit
              canExport
              canImport
              filter={filterFor(place, departments[1])}
              onFilter={chipsFor('servers')}
              onOpenRow={(id) => setDetail(`m:${id}`)}
              onValue={noop}
              onAct={noop}
              onArm={noop}
              onAddOwn={noop}
              onImport={noop}
              onEdit={noop}
              onExport={noop}
            />
          </div>
        )
      }
    />
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Page />
  </StrictMode>,
)
