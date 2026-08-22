/**
 * Both stores, side by side, in a real browser.
 *
 * The lane's own instruction was *"render both and look at them"*, and neither
 * store can be looked at through `renderToStaticMarkup`: the chips' counts, the
 * cross-filtering and the empty states are all functions of state that only
 * exists once something has been typed or pressed. A static render shows the
 * opening frame of a surface whose whole point is what happens after that.
 *
 * Both halves are driven by the **real catalogues** — `MCP_CATALOGUE` and
 * `BROWSER_EXTENSION_CATALOGUE` — because a store's shelves are only worth
 * looking at over the number of rows it actually has. Twenty-four extensions
 * across seven shelves and eighteen servers across nine is the thing being
 * judged; three fixtures would have shown a bar with no work to do.
 *
 * `?store=browser|mcp` draws one; the default stacks both.
 *
 * Since 2026-08-23 these two are **departments of the store page** rather than a
 * dialog and a tab, so neither draws a search box of its own any more — the page
 * carries one, over both of them, and `.harness/storepage.tsx` is where that is
 * looked at. This file is still the way to judge one department's shelves and
 * chips on their own, at full width, without the rail beside them.
 */
import './stub'
import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/browser/BrowserWorkspace.css'
import '../src/renderer/components/McpInspector.css'
import { StoreBody as BrowserStoreBody } from '../src/renderer/browser/StorePanel'
import { StoreBody as McpStoreBody } from '../src/renderer/components/McpStore'
import { NO_FILTER, type StoreFilter } from '../src/renderer/store/storefront'
import type {
  ExtensionsView,
  StoreExtension,
} from '../src/renderer/browser/extensions-bridge'
import type { StoreView } from '../src/renderer/browser/store-bridge'
import type { McpStoreRow, McpStoreView } from '../src/renderer/components/mcp-store-bridge'
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
    measured: entry.measured,
    noRelease: entry.noRelease ?? '',
    logo: entry.logo ?? '',
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
  }))
}

/** One installed row, because the Installed section is part of what is judged. */
function withOneInstalled(rows: StoreExtension[]): StoreExtension[] {
  return rows.map((one) =>
    one.id === 'dark-reader'
      ? { ...one, state: 'installed' as const, enabled: true, installedVersion: one.version,
          installedAt: Date.now(), popup: 'ui/popup/index.html' }
      : one,
  )
}

/**
 * One row nobody's catalogue has ever seen, because the mark is only half the
 * feature.
 *
 * A folder somebody dropped in has no logo and never will, and the store draws
 * `StoreLogo`'s generated monogram for it — a letter on one of this app's own
 * `--bind-*` fills. That is the half of the picture that cannot be judged from
 * a catalogue full of vendors' marks, so the harness carries one.
 */
function withOneAdded(rows: StoreExtension[]): StoreExtension[] {
  return [
    ...rows,
    {
      ...rows[0],
      id: 'my-own-thing',
      name: 'My own thing',
      summary: 'A folder this app was pointed at. Nothing about it was measured.',
      homepage: '',
      licence: '',
      version: '0.4.0',
      works: 'unmeasured',
      category: 'your-own',
      tags: [],
      measured: '',
      logo: '',
      url: '',
      sha256: '',
      bytes: 0,
      state: 'installed',
      installedVersion: '0.4.0',
      installedAt: Date.now(),
      enabled: true,
      reach: [],
      /* Inherited from the row this is spread from otherwise, which would have
         the fixture claiming a reach nobody read off a manifest. */
      everywhere: false,
      popup: '',
      sideloaded: true,
      origin: '/Users/apple/Downloads/my-own-thing',
    },
  ]
}

const EXT: ExtensionsView = {
  profileId: 'default',
  profileName: 'Default',
  extensions: withOneAdded(withOneInstalled(extensionRows())),
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
      command: installed
        ? 'npx -y @modelcontextprotocol/server-filesystem /Users/apple/Projects'
        : entry.command,
      inputs: entry.inputs.map((input) => ({ ...input, inEnvironment: false })),
      state: installed ? 'installed' : found ? 'available' : 'unavailable',
      scope: installed ? 'user' : '',
      taken: '',
      blocked: found
        ? ''
        : `${RUNTIME_BINARY[entry.runtime]} is not on this machine. It needs ${RUNTIME_NEEDS[entry.runtime]}`,
      caveat: entry.caveat ?? '',
      logo: entry.logo ?? '',
    }
  })
}

const MCP: McpStoreView = {
  rows: mcpRows(),
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

function BrowserStore() {
  const [filter, setFilter] = useState<StoreFilter>(NO_FILTER)
  return (
    <div className="bw-modal-body" style={{ padding: '16px 20px', maxWidth: 940 }}>
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
        filter={filter}
        onShowProfile={noop}
        onFilter={setFilter}
        onTool={noop}
        onExtension={noop}
        onEnable={noop}
        onOpenPopup={noop}
        onOpenOptions={noop}
        onAddOwn={noop}
      />
    </div>
  )
}

function McpStore() {
  const [filter, setFilter] = useState<StoreFilter>(NO_FILTER)
  return (
    <div className="mcp-store" style={{ padding: '16px 20px', maxWidth: 940 }}>
      <McpStoreBody
        view={MCP}
        busy=""
        values={{}}
        said={{}}
        arming=""
        filter={filter}
        onFilter={setFilter}
        onValue={noop}
        onAct={noop}
        onArm={noop}
      />
    </div>
  )
}

const which = new URLSearchParams(location.search).get('store')

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <div style={{ display: 'flex', gap: 24, alignItems: 'flex-start', padding: 16 }}>
      {which !== 'mcp' && (
        <section id="browser-store" style={{ flex: 1, minWidth: 0 }}>
          <h2 style={{ font: 'inherit', fontSize: 18, margin: '0 0 8px' }}>
            Browser extensions store
          </h2>
          <BrowserStore />
        </section>
      )}
      {which !== 'browser' && (
        <section id="mcp-store" style={{ flex: 1, minWidth: 0 }}>
          <h2 style={{ font: 'inherit', fontSize: 18, margin: '0 0 8px' }}>MCP store</h2>
          <McpStore />
        </section>
      )}
    </div>
  </StrictMode>,
)
