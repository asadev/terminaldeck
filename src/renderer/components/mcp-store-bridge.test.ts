import { describe, expect, it } from 'vitest'
import {
  CUSTOM_SOURCE,
  MCP_FACETS,
  mcpCompat,
  mcpFacets,
  mcpLinkOut,
  mcpNeeds,
  mcpStoreAvailable,
  needsWords,
  readMcpImport,
  readMcpStoreResult,
  readMcpStoreView,
  resolveMcpStoreApi,
  runsWords,
  sourceWords,
  unfilled,
  type McpStoreRow,
} from './mcp-store-bridge'

/**
 * The renderer's half of the store, held to the two things a bridge is for:
 * never trusting what arrives, and never costing more than its own feature when
 * it is absent.
 */

const ROW: McpStoreRow = {
  id: 'guarded',
  name: 'guarded',
  summary: 'Does a thing.',
  category: 'utility',
  tags: [],
  cost: 'free',
  costNote: '',
  homepage: 'https://example.com',
  registry: 'https://npmjs.com/package/guarded',
  licence: 'MIT',
  version: '1.0.0',
  runtime: 'node',
  runtimeBinary: 'npx',
  origin: 'third-party',
  command: 'npx -y guarded',
  inputs: [
    {
      key: 'API_TOKEN',
      label: 'API token',
      hint: 'From them.',
      kind: 'secret',
      into: 'env',
      required: true,
      inEnvironment: false,
    },
  ],
  state: 'available',
  scope: '',
  custom: false,
  transport: 'stdio',
  envKeys: [],
  runsWords: '',
  runtimeMissing: false,
  taken: '',
  blocked: '',
  logo: '',
  caveat: '',
}

describe('resolveMcpStoreApi', () => {
  it('binds what is there and shrugs at what is not', () => {
    const api = resolveMcpStoreApi({ mcpStore: () => Promise.resolve(null), mcpStoreInstall: 3 })
    expect(typeof api.mcpStore).toBe('function')
    expect(api.mcpStoreInstall).toBeUndefined()
  })

  it('answers with nothing rather than throwing when there is no host', () => {
    expect(resolveMcpStoreApi(null)).toEqual({})
    expect(resolveMcpStoreApi(undefined)).toEqual({})
  })
})

describe('mcpStoreAvailable', () => {
  it('wants all four, so a half-wired store is no tab at all', () => {
    /*
     * A store with a list and no Install is a catalogue of things you cannot
     * have; one with an Install and no Remove is a one-way door; one that cannot
     * take a server you typed yourself is a walled garden. Any of those is worse
     * than the tab not being there — and the absence costs the *tab*, never the
     * MCP page, which is the whole reason these methods are resolved separately
     * from `McpInspector`'s own bridge.
     */
    const whole = {
      mcpStore: async () => null,
      mcpStoreInstall: async () => null,
      removeMcpServer: async () => null,
      addMcpServer: async () => null,
    }
    expect(mcpStoreAvailable(whole)).toBe(true)
    expect(mcpStoreAvailable({ ...whole, removeMcpServer: undefined })).toBe(false)
    expect(mcpStoreAvailable({ ...whole, addMcpServer: undefined })).toBe(false)
    expect(mcpStoreAvailable({})).toBe(false)
  })
})

describe('readMcpStoreView', () => {
  it('narrows everything, and drops what has no id', () => {
    const view = readMcpStoreView({
      rows: [{ id: 'a', name: 'a' }, { name: 'nameless' }, 7],
      runtimes: [{ id: 'node', binary: 'npx', found: true, path: '/x' }, { id: 'perl' }],
      writer: { found: true, path: '/c' },
      environmentSource: 'login-shell',
      projectPath: '/w',
    })
    expect(view.rows.map((row) => row.id)).toEqual(['a'])
    expect(view.runtimes.map((runtime) => runtime.id)).toEqual(['node'])
    expect(view.writer).toEqual({ found: true, path: '/c' })
  })

  it('survives a main process that sends nothing recognisable', () => {
    // A build one version behind sends a shape these types only promise. A view
    // that threw here would blank the tab rather than show an empty one.
    expect(readMcpStoreView(null).rows).toEqual([])
    expect(readMcpStoreView('nope').environmentSource).toBe('unavailable')
  })

  it('will not let an argument claim to be in the environment', () => {
    // Belt and braces over the main process's own rule. A `true` here would
    // offer "leave it blank, your shell has it" on a field that would ignore it.
    const view = readMcpStoreView({
      rows: [{ id: 'a', inputs: [{ key: 'ROOT', into: 'arg', inEnvironment: true }] }],
    })
    expect(view.rows[0].inputs[0].inEnvironment).toBe(false)
  })
})

describe('readMcpStoreResult', () => {
  it('treats anything that is not a result as a failure', () => {
    /*
     * `ok` defaulting to true would turn a main process that threw into a green
     * message over a thing that did not happen — which is the single defect this
     * lane was told not to ship.
     */
    expect(readMcpStoreResult(null).ok).toBe(false)
    expect(readMcpStoreResult({}).ok).toBe(false)
    expect(readMcpStoreResult({ ok: 'yes' }).ok).toBe(false)
    expect(readMcpStoreResult({ ok: true, message: 'Added x.' })).toEqual({
      ok: true,
      message: 'Added x.',
    })
  })
})

describe('needsWords', () => {
  it('names what is required, before anything is pressed', () => {
    expect(needsWords(ROW)).toBe('API token')
  })

  it('distinguishes nothing at all from nothing required', () => {
    // Not the same fact. One row takes no configuration; the other takes some
    // and will start without it.
    expect(needsWords({ ...ROW, inputs: [] })).toBe('Nothing')
    expect(
      needsWords({ ...ROW, inputs: [{ ...ROW.inputs[0], required: false }] }),
    ).toBe('Nothing required')
  })
})

describe('unfilled', () => {
  it('names the fields still stopping an install', () => {
    expect(unfilled(ROW, {})).toEqual(['API token'])
    expect(unfilled(ROW, { API_TOKEN: '  ' })).toEqual(['API token'])
    expect(unfilled(ROW, { API_TOKEN: 'x' })).toEqual([])
  })

  it('counts a value already in the shell as filled', () => {
    const inherited = { ...ROW, inputs: [{ ...ROW.inputs[0], inEnvironment: true }] }
    expect(unfilled(inherited, {})).toEqual([])
  })
})

/** The fixture with one thing changed, so each test states only its own point. */
function row(over: Partial<McpStoreRow> = {}): McpStoreRow {
  return { ...ROW, ...over }
}

describe('the storefront projection', () => {
  it('never claims a server works, because nothing here watched one work', () => {
    /*
     * `mcp-catalogue.ts`'s own standing statement, kept: *"Nothing here was
     * watched working, and no row says it was."* The browser store can claim
     * `works` because it loaded the artifact into this app's Electron and
     * watched it; here the artifact is a process fetched at spawn time and run
     * by the agent. The two live values are *its runtime is here* and *the
     * runtime is missing*.
     */
    for (const state of ['available', 'installed', 'taken'] as const) {
      expect(mcpCompat(row({ state }))).toBe('unknown')
    }
    expect(mcpCompat(row({ state: 'unavailable', runtimeMissing: true }))).toBe('cannot')
  })

  it('says a server you added cannot run, without pretending it is not installed', () => {
    /*
     * The two used to be one answer. A catalogue row whose runtime is missing
     * gets `state: 'unavailable'` and no Install, because installing it would
     * write a line that can never work. A server somebody *added* in the same
     * position is the opposite case — the line is already written — so it stays
     * `installed`, keeps its Remove, and would have answered "its runtime is
     * here" to the filter if this read the state instead of the measurement.
     */
    const mine = row({ state: 'installed', custom: true, runtimeMissing: true })
    expect(mcpCompat(mine)).toBe('cannot')
    expect(mcpFacets(mine).installed).toBe(true)
  })

  it('files a server you added under its own source, not under a catalogue origin', () => {
    /*
     * `origin` is a fact the catalogue established about a project — reference,
     * community, archived on a dated day. A server this app has never heard of
     * has no such fact, so it gets a source of its own and the chip says *Added
     * by you* rather than borrowing the nearest catalogue word.
     */
    const mine = row({ custom: true, origin: 'third-party' })
    expect(mcpFacets(mine).source).toBe(CUSTOM_SOURCE)
    expect(sourceWords(mine)).toBe('Added by you')
    expect(sourceWords(row({ custom: false, origin: 'third-party' }))).toBe('Third party')
  })

  it('reads an imported definition as a draft, and refuses to invent one', () => {
    /*
     * An import **writes nothing**: what comes back fills in the add form and
     * the person presses the button. So a result with no readable draft in it
     * has to answer `null` rather than a plausible-looking empty draft, which
     * would open a blank form under a message saying something had been read.
     */
    const read = readMcpImport({
      ok: true,
      message: 'my-notes is filled in below.',
      draft: { name: 'my-notes', transport: 'stdio', command: 'npx -y @me/notes', env: ['API_KEY'] },
    })
    expect(read.ok).toBe(true)
    expect(read.draft).toEqual({
      name: 'my-notes',
      transport: 'stdio',
      command: 'npx -y @me/notes',
      url: '',
      env: ['API_KEY'],
    })

    expect(readMcpImport({ ok: true, message: '' }).draft).toBeNull()
    expect(readMcpImport({ ok: true, message: '', draft: { name: '' } }).draft).toBeNull()
    expect(readMcpImport(null)).toEqual({ ok: false, message: 'That did not work.', draft: null })
  })

  it('lets a custom row say how it runs in its own words', () => {
    // "npx — fetched from npm the first time it runs" is true of eleven
    // catalogue rows and a straight lie under `/usr/local/bin/serve`.
    expect(runsWords(row())).toBe('npx — fetched from npm the first time it runs')
    expect(runsWords(row({ runsWords: 'docker on this machine — /usr/bin/docker' }))).toBe(
      'docker on this machine — /usr/bin/docker',
    )
  })

  it('does not call a name collision "installed"', () => {
    // A server of that name is configured and it is not this one, so this row is
    // a thing you do not have sitting behind a collision. Answering *do I have
    // this* with somebody else's server is the wrong yes.
    expect(mcpFacets(row({ state: 'taken' })).installed).toBe(false)
    expect(mcpFacets(row({ state: 'installed' })).installed).toBe(true)
  })

  it('reports every need a row has, not the first one', () => {
    // The GitHub row wants a personal access token *and* Docker. A single winner
    // would have hidden one from whichever filter somebody chose.
    const both = row({
      runtime: 'docker',
      inputs: [
        {
          key: 'GITHUB_PERSONAL_ACCESS_TOKEN',
          label: 'Token',
          hint: '',
          kind: 'secret',
          into: 'env',
          required: true,
          inEnvironment: false,
        },
      ],
    })
    expect(mcpNeeds(both).sort()).toEqual(['docker', 'token'])
  })

  it('does not count npx or uvx as a need, because every row has one', () => {
    // A filter that keeps the whole catalogue answers nothing.
    expect(mcpNeeds(row({ runtime: 'node', inputs: [] }))).toEqual([])
    expect(mcpNeeds(row({ runtime: 'python', inputs: [] }))).toEqual([])
  })

  it('separates a path or a setting from a key', () => {
    const rooted = row({
      inputs: [
        {
          key: 'ROOT',
          label: 'Directory',
          hint: '',
          kind: 'path',
          into: 'arg',
          required: true,
          inEnvironment: false,
        },
      ],
    })
    expect(mcpNeeds(rooted)).toEqual(['setting'])
  })

  it('ignores an optional field, which is not something a person has to bring', () => {
    const optional = row({
      inputs: [
        {
          key: 'MAYBE',
          label: 'Maybe',
          hint: '',
          kind: 'secret',
          into: 'env',
          required: false,
          inEnvironment: false,
        },
      ],
    })
    expect(mcpNeeds(optional)).toEqual([])
  })

  it('keeps the archived origin as its own value on the row', () => {
    // The one maintenance fact this catalogue checked, on a dated day, against
    // GitHub's own `archived: true`.
    expect(mcpFacets(row({ origin: 'reference-archived' })).source).toBe('reference-archived')
    expect(mcpFacets(row({ origin: 'reference' })).source).toBe('reference')
  })
})

describe('the link out', () => {
  it('is offered only where the row has no Install, so no row carries both', () => {
    const project = 'https://github.com/example/server'
    expect(mcpLinkOut(row({ homepage: project, state: 'available', blocked: '' }))).toBe('')
    expect(mcpLinkOut(row({ homepage: project, state: 'installed', blocked: '' }))).toBe('')
    expect(
      mcpLinkOut(row({ homepage: project, state: 'unavailable', blocked: 'docker is missing.' })),
    ).toBe(project)
    expect(
      mcpLinkOut(row({ homepage: project, state: 'taken', blocked: 'A server called x exists.' })),
    ).toBe(project)
  })

  it('refuses anything that is not an http address', () => {
    expect(mcpLinkOut(row({ homepage: 'file:///etc/passwd', state: 'unavailable', blocked: 'x' }))).toBe(
      '',
    )
    expect(mcpLinkOut(row({ homepage: '', state: 'unavailable', blocked: 'x' }))).toBe('')
  })
})

describe('price on an MCP row', () => {
  it('travels as its own facet rather than being read out of the licence', () => {
    // Nearly every row in the catalogue is MIT and several of them do nothing
    // without a key that is billed. A store deriving price from licence would
    // call every one of those free.
    expect(mcpFacets(row({ cost: 'metered', licence: 'MIT' })).cost).toBe('metered')
    expect(mcpFacets(row({ cost: 'paid' })).cost).toBe('paid')
  })

  it('lands on "needs an account" when a main process sends nothing, never on free', () => {
    /*
     * A preload or a main process one version behind sends no `cost` at all.
     * Both possible fallbacks are guesses; only one of them can cost somebody
     * money, so the narrowing picks the cautious one. A row that quietly read
     * *Free* because a field was missing is the exact failure this field was
     * added to prevent.
     */
    const view = readMcpStoreView({ rows: [{ id: 'a', name: 'a' }] })
    expect(view.rows[0]?.cost).toBe('account')
    expect(view.rows[0]?.costNote).toBe('')
    expect(readMcpStoreView({ rows: [{ id: 'a', cost: 'gratis' }] }).rows[0]?.cost).toBe('account')
    expect(readMcpStoreView({ rows: [{ id: 'a', cost: 'free' }] }).rows[0]?.cost).toBe('free')
  })

  it('offers a price chip for every value a row can hold, the unmeasured one included', () => {
    /*
     * This once asserted the opposite of its last line — that `unknown` was a
     * browser-store answer no MCP row could give. That held while every row here
     * came out of a catalogue this app wrote. It stopped holding when the store
     * started carrying the servers somebody typed themselves: nobody wrote a
     * catalogue entry for one of those, so nobody read its pricing page, and
     * `mcp-custom.ts` prices it `unknown` rather than guessing `free`.
     *
     * Nothing is drawn that would filter to nothing, which is what the old
     * assertion was really protecting: `facetControls` drops an option no row
     * matches, so on a machine with nothing hand-written the chip is absent
     * anyway — for the same reason, and without a hard-coded exception.
     */
    const ids = (MCP_FACETS.cost?.options ?? []).map((option) => option.id)
    expect(ids).toEqual(['free', 'account', 'metered', 'paid', 'unknown'])
  })
})
