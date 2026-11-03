import { describe, expect, it } from 'vitest'
import type { StoreTool, StoreView } from '../../browser-store'
import type { McpStoreRow, McpStoreView } from '../../mcp-store'
import { storePanel, type StorePanelDeps } from './store'

/**
 * The store panel, and one test in here is a regression rather than a feature.
 *
 * The screen this replaces said **"This machine could not answer that panel."**
 * on Asad's phone against his own headless server, and the whole of it was
 * `store().read()` — a method `Store` does not have — throwing into the catch at
 * the bottom of `panelFor`. So *a dependency that throws is a note, not a
 * throw* is pinned by name below, and it is the assertion to look at first if
 * that sentence ever comes back.
 *
 * Everything here drives the panel through {@link StorePanelDeps} with plain
 * objects. No Electron, no child process, no disk — which is the other half of
 * the fix: the panel could not previously be exercised at all without the shell
 * that owns the store.
 */

/* ------------------------------------------------------------- fixtures -- */

function serverRow(over: Partial<McpStoreRow> & Pick<McpStoreRow, 'id' | 'name'>): McpStoreRow {
  return {
    summary: 'A server.',
    category: 'utility',
    tags: [],
    homepage: '',
    registry: '',
    licence: 'MIT',
    version: '1.0.0',
    runtime: 'node',
    runtimeBinary: 'npx',
    origin: 'reference',
    cost: 'free',
    costNote: '',
    command: 'npx -y a-server',
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
    caveat: '',
    logo: '',
    ...over,
  }
}

function tool(over: Partial<StoreTool> & Pick<StoreTool, 'id' | 'name'>): StoreTool {
  return {
    summary: 'A tool.',
    homepage: '',
    licence: 'MIT',
    version: '1.0.0',
    grants: [],
    origins: [],
    url: '',
    fetched: false,
    sha256: 'a'.repeat(64),
    state: 'available',
    installedVersion: '',
    installedAt: 0,
    message: '',
    reads: [],
    ...over,
  }
}

/**
 * A catalogue of three servers and two browser tools, with the configuration
 * held in a set so an install is visible on the next read.
 *
 * `install` and `remove` write to that set and nothing else, which is enough for
 * every assertion here: what this file is testing is the panel's own contract —
 * that an action answers with the panel, that a row's buttons follow its state —
 * and `mcp-store.test.ts` and `browser-store.test.ts` own what the writes
 * themselves do.
 */
function catalogue(): { deps: Required<StorePanelDeps>; configured: Set<string> } {
  const configured = new Set<string>()
  const removed: string[] = []

  const rows = (): McpStoreRow[] => [
    serverRow({
      id: 'filesystem',
      name: 'filesystem',
      summary: 'Reads and writes files under one directory.',
      category: 'files',
      tags: ['disk'],
      ...(configured.has('filesystem') ? { state: 'installed' as const, scope: 'user' as const } : {}),
    }),
    serverRow({
      id: 'tavily',
      name: 'tavily',
      summary: 'Searches the web and reads the results.',
      category: 'web',
      cost: 'metered',
      inputs: [
        {
          key: 'TAVILY_API_KEY',
          label: 'API key',
          hint: 'From tavily.com',
          kind: 'secret',
          into: 'env',
          required: true,
          inEnvironment: false,
        },
      ],
      ...(configured.has('tavily') ? { state: 'installed' as const, scope: 'user' as const } : {}),
    }),
    serverRow({
      id: 'sqlite',
      name: 'sqlite',
      summary: 'Queries a SQLite database.',
      category: 'data',
      runtime: 'docker',
      runtimeBinary: 'docker',
      runtimeMissing: true,
      state: 'unavailable',
      blocked: 'docker is not on this machine. It needs Docker Desktop',
    }),
  ]

  const tools = (): StoreView => ({
    folder: '/tmp/tools',
    tools: [
      tool({
        id: 'page-images',
        name: 'Images',
        summary: 'Every image on the page.',
        ...(configured.has('page-images') ? { state: 'installed' as const } : {}),
      }),
      tool({ id: 'page-tables', name: 'Tables', summary: 'Every table on the page.' }),
    ],
  })

  const view = (projectPath: string | null): McpStoreView => ({
    rows: rows(),
    runtimes: [],
    writer: { found: true, path: '/usr/local/bin/claude' },
    environmentSource: 'login-shell',
    projectPath: projectPath ?? '',
  })

  return {
    configured,
    deps: {
      tools: {
        read: async () => tools(),
        install: async (id) => {
          configured.add(id)
          return { ok: true, message: `${id} is installed.` }
        },
        remove: async (id) => {
          configured.delete(id)
          return { ok: true, message: `${id} is removed.` }
        },
      },
      servers: {
        read: async (projectPath) => view(projectPath),
        install: async (request) => {
          configured.add(request.id)
          return { ok: true, message: `${request.id} was added at ${request.scope} scope.` }
        },
        remove: async (request) => {
          configured.delete(request.name)
          removed.push(`${request.scope}:${request.name}`)
          return { ok: true, message: `${request.name} was removed from ${request.scope}.` }
        },
      },
    },
  }
}

const HERE = '/Users/asad/Projects/thing'

function titles(rows: readonly { title: string }[]): string[] {
  return rows.map((row) => row.title)
}

function actionsOf(payload: { rows: readonly { id?: string; actions?: { id: string }[] }[] }, id: string): string[] {
  return (payload.rows.find((row) => row.id === id)?.actions ?? []).map((action) => action.id)
}

/* ------------------------------------------------------------ the listing -- */

describe('reading the store', () => {
  it('lists both departments, browser tools first, as the desktop store orders them', async () => {
    const panel = storePanel(catalogue().deps)
    const payload = await panel.read({ path: HERE })
    expect(titles(payload.rows)).toEqual(['Images', 'Tables', 'filesystem', 'tavily', 'sqlite'])
    expect(payload.path).toBe(HERE)
    expect(payload.note).toBeUndefined()
  })

  it('names each row by a department-prefixed id, so no action can reach the wrong half', async () => {
    const panel = storePanel(catalogue().deps)
    const payload = await panel.read({ path: HERE })
    expect(payload.rows.map((row) => row.id)).toEqual([
      'tool:page-images',
      'tool:page-tables',
      'server:filesystem',
      'server:tavily',
      'server:sqlite',
    ])
  })

  it('says what a row costs, and what it says instead once it is installed', async () => {
    const { deps, configured } = catalogue()
    const panel = storePanel(deps)
    const before = await panel.read({ path: HERE })
    expect(before.rows.find((row) => row.id === 'server:tavily')?.value).toBe(
      'Free to a limit, then paid',
    )
    configured.add('tavily')
    const after = await panel.read({ path: HERE })
    expect(after.rows.find((row) => row.id === 'server:tavily')?.value).toBe('Installed')
  })

  it('warns on a row that cannot run here, and prints why instead of its summary', async () => {
    const panel = storePanel(catalogue().deps)
    const payload = await panel.read({ path: HERE })
    const row = payload.rows.find((one) => one.id === 'server:sqlite')
    expect(row?.status).toBe('warn')
    expect(row?.detail).toContain('docker is not on this machine')
    expect(row?.actions).toBeUndefined()
  })
})

/* -------------------------------------------------------------- the search -- */

describe('the search box', () => {
  it('narrows the list across both departments at once', async () => {
    const panel = storePanel(catalogue().deps)
    expect(titles((await panel.read({ path: HERE, query: 'web' })).rows)).toEqual(['tavily'])
    expect(titles((await panel.read({ path: HERE, query: 'table' })).rows)).toEqual(['Tables'])
  })

  it('searches the shelf name too, so a word in no summary still finds the shelf', async () => {
    const panel = storePanel(catalogue().deps)
    // "Databases" is the shelf `data` wears in `MCP_CATEGORIES`; no row says it.
    expect(titles((await panel.read({ path: HERE, query: 'databases' })).rows)).toEqual(['sqlite'])
  })

  it('explains an empty list rather than showing a blank screen', async () => {
    const panel = storePanel(catalogue().deps)
    const payload = await panel.read({ path: HERE, query: 'nothing at all like this' })
    expect(payload.rows).toEqual([])
    expect(payload.note).toContain('Nothing in the store matches')
  })
})

/* --------------------------------------------------------------- the chips -- */

describe('the filter chips', () => {
  it('filters to what is installed, and marks the chip that is on', async () => {
    const { deps, configured } = catalogue()
    configured.add('filesystem')
    const panel = storePanel(deps)
    const payload = await panel.read({ path: HERE, scope: 'installed' })
    expect(titles(payload.rows)).toEqual(['filesystem'])
    expect(payload.scopes?.find((scope) => scope.on)?.id).toBe('installed')
  })

  it('leaves out a row that cannot be installed from the “can be added” chip', async () => {
    const panel = storePanel(catalogue().deps)
    const payload = await panel.read({ path: HERE, scope: 'addable' })
    // sqlite has no runtime here, so it is not something that can be added.
    expect(titles(payload.rows)).toEqual(['Images', 'Tables', 'filesystem', 'tavily'])
  })

  it('does not draw a chip that would leave nothing on screen', async () => {
    const panel = storePanel(catalogue().deps)
    // Nothing in this catalogue is installed, so the Installed chip is not drawn.
    const payload = await panel.read({ path: HERE })
    expect(payload.scopes?.map((scope) => scope.id)).toEqual(['all', 'addable', 'free'])
  })
})

/* ------------------------------------------------------------- the actions -- */

describe('installing and removing', () => {
  it('offers Install on an available row, with the folder in view as a second scope', async () => {
    const panel = storePanel(catalogue().deps)
    const payload = await panel.read({ path: HERE })
    expect(actionsOf(payload, 'server:filesystem')).toEqual(['install', 'install.here'])
    expect(actionsOf(payload, 'tool:page-tables')).toEqual(['install'])
  })

  it('asks for the key a row needs before it fires, and never prefills it', async () => {
    const panel = storePanel(catalogue().deps)
    const payload = await panel.read({ path: HERE })
    const install = payload.rows
      .find((row) => row.id === 'server:tavily')
      ?.actions?.find((action) => action.id === 'install')
    expect(install?.fields).toEqual([
      {
        id: 'TAVILY_API_KEY',
        label: 'API key',
        placeholder: 'From tavily.com',
        required: true,
      },
    ])
  })

  it('installs, answers with the panel, and the row comes back installed', async () => {
    const panel = storePanel(catalogue().deps)
    const payload = await panel.act?.({
      path: HERE,
      action: 'install',
      id: 'server:filesystem',
      fields: {},
    })
    expect(payload?.notice).toBe('filesystem was added at user scope.')
    const row = payload?.rows.find((one) => one.id === 'server:filesystem')
    expect(row?.value).toBe('Installed')
    expect(row?.status).toBe('ok')
  })

  it('installs into the folder in view when that is the button that was pressed', async () => {
    const panel = storePanel(catalogue().deps)
    const payload = await panel.act?.({
      path: HERE,
      action: 'install.here',
      id: 'server:filesystem',
      fields: {},
    })
    expect(payload?.notice).toBe('filesystem was added at project scope.')
  })

  it('shows Remove rather than Install once a row is installed', async () => {
    const { deps, configured } = catalogue()
    configured.add('filesystem')
    configured.add('page-images')
    const panel = storePanel(deps)
    const payload = await panel.read({ path: HERE })
    expect(actionsOf(payload, 'server:filesystem')).toEqual(['remove'])
    expect(actionsOf(payload, 'tool:page-images')).toEqual(['remove'])
  })

  it('draws Remove as destructive, with a line saying what does not come back', async () => {
    const { deps, configured } = catalogue()
    configured.add('filesystem')
    const panel = storePanel(deps)
    const payload = await panel.read({ path: HERE })
    const remove = payload.rows
      .find((row) => row.id === 'server:filesystem')
      ?.actions?.find((action) => action.id === 'remove')
    expect(remove?.kind).toBe('destructive')
    expect(remove?.confirm).toContain('never kept a copy')
  })

  it('removes, and the row comes back offering an Install again', async () => {
    const { deps, configured } = catalogue()
    configured.add('filesystem')
    const panel = storePanel(deps)
    const payload = await panel.act?.({
      path: HERE,
      action: 'remove',
      id: 'server:filesystem',
      fields: {},
    })
    expect(payload?.notice).toBe('filesystem was removed from user.')
    expect(actionsOf(payload ?? { rows: [] }, 'server:filesystem')).toEqual([
      'install',
      'install.here',
    ])
  })

  it('removes a browser tool through its own department', async () => {
    const { deps, configured } = catalogue()
    configured.add('page-images')
    const panel = storePanel(deps)
    const payload = await panel.act?.({
      path: HERE,
      action: 'remove',
      id: 'tool:page-images',
      fields: {},
    })
    expect(payload?.notice).toBe('page-images is removed.')
    expect(actionsOf(payload ?? { rows: [] }, 'tool:page-images')).toEqual(['install'])
  })

  it('refuses an action it never offered with a line, and changes nothing', async () => {
    const { deps, configured } = catalogue()
    const panel = storePanel(deps)
    const payload = await panel.act?.({ path: HERE, action: 'sabotage', id: 'server:filesystem', fields: {} })
    expect(payload?.notice).toContain('This store has no')
    expect(configured.size).toBe(0)
  })
})

/* ------------------------------------------------- the bug this replaces -- */

describe('a dependency that throws', () => {
  it('is caught into a note rather than propagating — the "could not answer that panel" bug', async () => {
    const { deps } = catalogue()
    const panel = storePanel({
      tools: deps.tools,
      servers: {
        ...deps.servers,
        read: async () => {
          // Exactly the shape of the original failure: the module the panel
          // asked answered with a TypeError rather than a view.
          throw new TypeError('store(...).read is not a function')
        },
      },
    })

    const payload = await panel.read({ path: HERE })

    // The half that still works is still there.
    expect(titles(payload.rows)).toEqual(['Images', 'Tables'])
    expect(payload.note).toContain('The MCP server catalogue could not be read')
    expect(payload.note).toContain('store(...).read is not a function')
  })

  it('is caught on the way out of an action too, and the panel still redraws', async () => {
    const { deps } = catalogue()
    const panel = storePanel({
      ...deps,
      tools: {
        ...deps.tools,
        install: async () => {
          throw new Error('the download failed')
        },
      },
    })
    const payload = await panel.act?.({ path: HERE, action: 'install', id: 'tool:page-tables', fields: {} })
    expect(payload?.notice).toBe('That could not be done — the download failed.')
    expect(titles(payload?.rows ?? [])).toContain('Tables')
  })

  it('loses only the department that failed when both are wired', async () => {
    const { deps } = catalogue()
    const panel = storePanel({
      servers: deps.servers,
      tools: {
        ...deps.tools,
        read: async () => {
          throw new Error('the store was never built')
        },
      },
    })
    const payload = await panel.read({ path: HERE })
    expect(titles(payload.rows)).toEqual(['filesystem', 'tavily', 'sqlite'])
    expect(payload.note).toContain('the store was never built')
  })
})

/* ----------------------------------------------------------- on a server -- */

describe('on a headless host', () => {
  it('lists the catalogue and offers no button when nothing here can write', async () => {
    const { deps } = catalogue()
    // A daemon that built no browser tool store and can read the MCP catalogue
    // without being able to write it.
    const panel = storePanel({ servers: { read: deps.servers.read } })
    const payload = await panel.read({ path: HERE })
    expect(titles(payload.rows)).toEqual(['filesystem', 'tavily', 'sqlite'])
    expect(payload.rows.every((row) => row.actions === undefined)).toBe(true)
    expect(payload.note).toContain('cannot be read from here')
    expect(payload.note).toContain('not installed from here')
  })

  it('says nothing can be installed when the CLI that writes the configuration is missing', async () => {
    const { deps } = catalogue()
    const panel = storePanel({
      servers: {
        ...deps.servers,
        read: async (projectPath) => ({
          ...(await deps.servers.read(projectPath)),
          writer: { found: false, path: '' },
        }),
      },
    })
    const payload = await panel.read({ path: HERE })
    expect(titles(payload.rows)).toEqual(['filesystem', 'tavily', 'sqlite'])
    expect(payload.rows.every((row) => row.actions === undefined)).toBe(true)
    expect(payload.note).toContain('was not found on this machine')
  })

  it('refuses an install aimed at a host that cannot install, rather than pretending', async () => {
    const { deps, configured } = catalogue()
    const panel = storePanel({ servers: { read: deps.servers.read } })
    const payload = await panel.act?.({
      path: HERE,
      action: 'install',
      id: 'server:filesystem',
      fields: {},
    })
    expect(payload?.notice).toBe('Nothing can be installed from here.')
    expect(configured.size).toBe(0)
  })

  it('says so once for a host with no store at all', async () => {
    const panel = storePanel({})
    const payload = await panel.read({ path: HERE })
    expect(payload.rows).toEqual([])
    expect(payload.note).toBe(
      'The tools this app installs into its own browser cannot be read from here. ' +
        'The MCP server catalogue cannot be read from here.',
    )
  })
})
