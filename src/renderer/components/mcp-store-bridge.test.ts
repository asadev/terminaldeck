import { describe, expect, it } from 'vitest'
import {
  mcpStoreAvailable,
  needsWords,
  readMcpStoreResult,
  readMcpStoreView,
  resolveMcpStoreApi,
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
  taken: '',
  blocked: '',
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
