import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve, sep } from 'node:path'
import type { JSONRPCMessage } from '@modelcontextprotocol/sdk/types.js'
import type { Transport } from '@modelcontextprotocol/sdk/shared/transport.js'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  applyProjectGates,
  capPayload,
  claudeJsonPath,
  claudeSettingsDir,
  collectServersFrom,
  expandEnvRefs,
  McpPool,
  mergeByPrecedence,
  parseServerEntry,
  parseServerMap,
  readJsonFile,
  readProjectGates,
  registerMcpIpc,
  resetMcpIpcForTests,
  resolveTimeouts,
  withTimeout,
  type McpServerConfig,
  type McpTimeouts,
} from './mcp-client'

/**
 * No test here spawns a process. The connection tests drive a real MCP `Client`
 * over a fake transport, so the SDK's own handshake, capability gating and
 * request timeouts are genuinely exercised — only the child process is faked.
 */

/**
 * The open project, absolute on whichever platform is running.
 *
 * `~/.claude.json` keys its `projects` map by absolute path and the product
 * looks entries up through `resolve`, so a fixture keyed on a literal
 * `/work/app` only matches on POSIX — on Windows the lookup resolves to
 * `C:\work\app` and the project scope came back empty.
 */
const PROJECT = resolve('/work/app')
const OTHER_PROJECT = resolve('/work/other')

/* ------------------------------------------------------------- fake server -- */

interface JsonRpcRequest {
  jsonrpc: '2.0'
  id: string | number
  method: string
  params?: Record<string, unknown>
}

type Reply = { result: unknown } | { error: { code: number; message: string } } | 'hang'

interface FakeOptions {
  /** Reject from `start()`, the way a missing binary does. */
  startError?: string
  /** Never resolve `start()`, the way a hung spawn does. */
  startHangs?: boolean
  handlers?: Record<string, (params: Record<string, unknown> | undefined) => Reply>
  capabilities?: Record<string, unknown>
}

const PROTOCOL_VERSION = '2025-06-18'

class FakeTransport implements Transport {
  onclose?: () => void
  onerror?: (error: Error) => void
  onmessage?: (message: JSONRPCMessage) => void

  started = false
  closed = false
  readonly seen: string[] = []

  constructor(private readonly options: FakeOptions = {}) {}

  async start(): Promise<void> {
    if (this.options.startError) throw new Error(this.options.startError)
    if (this.options.startHangs) return new Promise<void>(() => undefined)
    this.started = true
  }

  async send(message: JSONRPCMessage): Promise<void> {
    const request = message as unknown as JsonRpcRequest
    // Notifications carry no id and need no reply.
    if (request.id === undefined || typeof request.method !== 'string') return
    this.seen.push(request.method)

    const reply = this.replyFor(request)
    if (reply === 'hang') return

    // A microtask, not a timer: fake timers are in play for the timeout tests
    // and a setTimeout here would never fire.
    queueMicrotask(() => {
      this.onmessage?.(
        'result' in reply
          ? ({ jsonrpc: '2.0', id: request.id, result: reply.result } as unknown as JSONRPCMessage)
          : ({ jsonrpc: '2.0', id: request.id, error: reply.error } as unknown as JSONRPCMessage),
      )
    })
  }

  private replyFor(request: JsonRpcRequest): Reply {
    // An explicit handler wins, so a test can make even `initialize` hang.
    const handler = this.options.handlers?.[request.method]
    if (handler) return handler(request.params)

    if (request.method === 'initialize') {
      return {
        result: {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: this.options.capabilities ?? { tools: {} },
          serverInfo: { name: 'fake-server', version: '9.9.9' },
          instructions: 'Be careful.',
        },
      }
    }
    return { error: { code: -32601, message: `Method not found: ${request.method}` } }
  }

  async close(): Promise<void> {
    this.closed = true
    this.onclose?.()
  }

  /** Simulate the server process dying on its own. */
  die(): void {
    this.onclose?.()
  }
}

const TOOL = {
  name: 'echo',
  description: 'Echoes a message',
  inputSchema: {
    type: 'object',
    properties: { message: { type: 'string' } },
    required: ['message'],
  },
}

function stdioServer(overrides: Partial<McpServerConfig> = {}): McpServerConfig {
  return {
    id: 'user:fake',
    name: 'fake',
    scope: 'user',
    transport: 'stdio',
    command: 'node',
    args: ['server.js'],
    env: {},
    cwd: null,
    url: null,
    source: '/tmp/.claude.json',
    enabled: true,
    disabledReason: null,
    unsupported: null,
    ...overrides,
  }
}

/** Every pool in these tests gets a fake transport and no login-shell probe. */
function poolWith(transport: Transport, timeouts?: Partial<McpTimeouts>) {
  const seen: string[] = []
  const pool = new McpPool({
    createTransport: () => transport,
    resolveEnv: async () => ({ PATH: '/usr/bin' }),
    onStatusChange: (status) => seen.push(status.state),
    timeouts: { connectMs: 50, listMs: 50, callMs: 50, closeMs: 20, ...timeouts },
  })
  return { pool, seen }
}

/* --------------------------------------------------------------- discovery -- */

describe('claudeJsonPath', () => {
  it('sits beside ~/.claude, not inside it, on a default install', () => {
    expect(claudeJsonPath({}).endsWith(join('', '.claude.json').slice(1))).toBe(true)
    expect(claudeJsonPath({}).endsWith(join('.claude', '.claude.json'))).toBe(false)
  })

  it('moves inside CLAUDE_CONFIG_DIR when that is set', () => {
    // Verified by running the real CLI against a throwaway config dir: it
    // created exactly <dir>/.claude.json and reported no servers.
    expect(claudeJsonPath({ CLAUDE_CONFIG_DIR: '/tmp/work-profile' })).toBe(join('/tmp/work-profile', '.claude.json'))
    expect(claudeSettingsDir({ CLAUDE_CONFIG_DIR: '/tmp/work-profile' })).toBe('/tmp/work-profile')
  })

  it('ignores an empty override rather than reading from the filesystem root', () => {
    expect(claudeJsonPath({ CLAUDE_CONFIG_DIR: '   ' }).endsWith('.claude.json')).toBe(true)
  })
})

describe('readJsonFile', () => {
  let dir: string

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'terminaldeck-mcp-'))
  })
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true })
  })

  it('returns null for a file that is not there', () => {
    expect(readJsonFile(join(dir, 'nope.json'))).toBeNull()
  })

  it('returns null for truncated JSON instead of throwing', () => {
    const file = join(dir, 'half.json')
    writeFileSync(file, '{"mcpServers": {"a": {"command": "node"')
    expect(readJsonFile(file)).toBeNull()
  })

  it('parses a well-formed file', () => {
    const file = join(dir, 'ok.json')
    writeFileSync(file, JSON.stringify({ mcpServers: {} }))
    expect(readJsonFile(file)).toEqual({ mcpServers: {} })
  })

  it('refuses a path that is not a regular file rather than blocking on it', () => {
    // A directory only costs an EISDIR, but a FIFO would block `readFileSync`
    // until somebody wrote to it — on the main process's only thread, which
    // freezes the app instead of failing.
    expect(readJsonFile(dir)).toBeNull()
  })
})

describe('expandEnvRefs', () => {
  it('substitutes a set variable', () => {
    expect(expandEnvRefs('Bearer ${TOKEN}', { TOKEN: 'abc' })).toBe('Bearer abc')
  })

  it('falls back with the :- form', () => {
    expect(expandEnvRefs('${PORT:-8080}', {})).toBe('8080')
  })

  it('leaves an unresolvable reference literal so the failure names itself', () => {
    expect(expandEnvRefs('${MISSING}', {})).toBe('${MISSING}')
  })

  it('treats an empty variable as unset', () => {
    expect(expandEnvRefs('${TOKEN:-fallback}', { TOKEN: '' })).toBe('fallback')
  })
})

describe('parseServerEntry', () => {
  it('reads a stdio server that declares no type', () => {
    const parsed = parseServerEntry(
      'files',
      { command: 'npx', args: ['-y', 'server-filesystem', '/tmp'], env: { DEBUG: '1' } },
      'user',
      '/cfg/.claude.json',
      {},
    )
    expect(parsed).toMatchObject({
      id: 'user:files',
      name: 'files',
      transport: 'stdio',
      command: 'npx',
      args: ['-y', 'server-filesystem', '/tmp'],
      env: { DEBUG: '1' },
      unsupported: null,
    })
  })

  it('reads the real shape of the user-scope entry on this machine', () => {
    // The only globally configured server here is `{type: 'http', url: ...}` —
    // no command at all. Getting this wrong would drop it from the list.
    const parsed = parseServerEntry(
      'higgsfield',
      { type: 'http', url: 'https://mcp.example.ai/mcp' },
      'user',
      '/cfg/.claude.json',
      {},
    )
    expect(parsed?.transport).toBe('http')
    expect(parsed?.url).toBe('https://mcp.example.ai/mcp')
    expect(parsed?.command).toBeNull()
    // The note used to end "this inspector speaks stdio only", which answers a
    // question about our architecture rather than about their server. What the
    // reader needs is that the server is fine and this panel cannot look inside
    // it — so the assertion follows the meaning rather than the old wording.
    expect(parsed?.unsupported).toContain('cannot inspect')
    expect(parsed?.unsupported).toContain('HTTP')
  })

  it('infers sse from the declared type even when a command is also present', () => {
    const parsed = parseServerEntry('mixed', { type: 'sse', url: 'https://x/sse', command: 'node' }, 'user', 's', {})
    expect(parsed?.transport).toBe('sse')
  })

  it('rejects an entry with neither a command nor a url', () => {
    expect(parseServerEntry('empty', { args: ['x'] }, 'user', 's', {})).toBeNull()
  })

  it('rejects a non-object entry', () => {
    expect(parseServerEntry('bad', 'npx server', 'user', 's', {})).toBeNull()
    expect(parseServerEntry('bad', null, 'user', 's', {})).toBeNull()
    expect(parseServerEntry('', { command: 'node' }, 'user', 's', {})).toBeNull()
  })

  it('coerces numeric args and env values rather than dropping them', () => {
    const parsed = parseServerEntry('n', { command: 'node', args: ['--port', 3000], env: { PORT: 3000 } }, 'user', 's', {})
    expect(parsed?.args).toEqual(['--port', '3000'])
    expect(parsed?.env).toEqual({ PORT: '3000' })
  })

  it('expands env references in command, args and env', () => {
    const parsed = parseServerEntry(
      'e',
      { command: '${BIN}', args: ['${DIR:-/tmp}'], env: { KEY: '${SECRET}' } },
      'user',
      's',
      { BIN: '/usr/local/bin/node', SECRET: 's3cret' },
    )
    expect(parsed?.command).toBe('/usr/local/bin/node')
    expect(parsed?.args).toEqual(['/tmp'])
    expect(parsed?.env).toEqual({ KEY: 's3cret' })
  })
})

describe('parseServerMap', () => {
  it('keeps the good entries beside a broken one', () => {
    const servers = parseServerMap(
      { good: { command: 'node' }, broken: 42, alsoGood: { url: 'https://x' } },
      'user',
      's',
      {},
    )
    expect(servers.map((s) => s.name)).toEqual(['good', 'alsoGood'])
  })

  it('returns nothing for a missing map', () => {
    expect(parseServerMap(undefined, 'user', 's', {})).toEqual([])
    expect(parseServerMap([], 'user', 's', {})).toEqual([])
  })
})

describe('project approval gates', () => {
  const project = [
    parseServerEntry('shared', { command: 'node' }, 'project', '/p/.mcp.json', {}) as McpServerConfig,
  ]

  it('marks an unapproved project server pending rather than hiding it', () => {
    const [server] = applyProjectGates(project, { enabled: [], disabled: [], enableAll: false })
    expect(server.enabled).toBe(false)
    expect(server.disabledReason).toContain('Not approved')
  })

  it('approves a listed server', () => {
    const [server] = applyProjectGates(project, { enabled: ['shared'], disabled: [], enableAll: false })
    expect(server.enabled).toBe(true)
    expect(server.disabledReason).toBeNull()
  })

  it('lets a rejection beat both the allow list and the blanket switch', () => {
    const [server] = applyProjectGates(project, { enabled: ['shared'], disabled: ['shared'], enableAll: true })
    expect(server.enabled).toBe(false)
    expect(server.disabledReason).toContain('Rejected')
  })

  it('leaves user and local scopes alone', () => {
    const user = [parseServerEntry('u', { command: 'node' }, 'user', 's', {}) as McpServerConfig]
    expect(applyProjectGates(user, { enabled: [], disabled: [], enableAll: false })[0].enabled).toBe(true)
  })

  it('reads gates from settings and from the project entry, keyed on the resolved path', () => {
    // The key is the *resolved* path and the lookup is given the same path with
    // a trailing separator, which is the whole claim. Both are built from
    // `PROJECT` so the fixture is absolute on the platform running this:
    // `/work/app` resolves to `C:\work\app` on Windows, which matched no key.
    const gates = readProjectGates(
      { projects: { [PROJECT]: { enabledMcpjsonServers: ['a'], disabledMcpjsonServers: ['b'] } } },
      { enableAllProjectMcpServers: true },
      `${PROJECT}${sep}`,
    )
    expect(gates).toEqual({ enabled: ['a'], disabled: ['b'], enableAll: true })
  })
})

describe('mergeByPrecedence', () => {
  it('lets local beat project beat user for the same name', () => {
    const user = parseServerMap({ db: { command: 'user-cmd' } }, 'user', 'u', {})
    const project = parseServerMap({ db: { command: 'project-cmd' } }, 'project', 'p', {})
    const local = parseServerMap({ db: { command: 'local-cmd' } }, 'local', 'l', {})

    const merged = mergeByPrecedence(user, project, local)
    expect(merged).toHaveLength(1)
    expect(merged[0].command).toBe('local-cmd')
    expect(merged[0].scope).toBe('local')
  })

  it('sorts by name so the panel does not reshuffle between reads', () => {
    const merged = mergeByPrecedence(parseServerMap({ zeta: { command: 'z' }, alpha: { command: 'a' } }, 'user', 'u', {}))
    expect(merged.map((s) => s.name)).toEqual(['alpha', 'zeta'])
  })
})

describe('collectServersFrom', () => {
  /** Shaped like the real ~/.claude.json: a global map plus a projects map. */
  const claudeJson = {
    mcpServers: { higgsfield: { type: 'http', url: 'https://mcp.example.ai/mcp' } },
    projects: {
      [PROJECT]: {
        mcpServers: { scratch: { command: 'node', args: ['local.js'] } },
        enabledMcpjsonServers: ['shared'],
        disabledMcpjsonServers: [],
      },
      [OTHER_PROJECT]: { mcpServers: { elsewhere: { command: 'node' } } },
    },
  }

  it('merges user, project and local scopes for the open project', () => {
    const servers = collectServersFrom({
      claudeJson,
      settings: {},
      projectMcpJson: { mcpServers: { shared: { command: 'uvx', args: ['thing'] } } },
      projectPath: PROJECT,
      claudeJsonPath: '/home/u/.claude.json',
      projectMcpJsonPath: '/work/app/.mcp.json',
      env: {},
    })

    expect(servers.map((s) => `${s.scope}:${s.name}`)).toEqual([
      'user:higgsfield',
      'local:scratch',
      'project:shared',
    ])
    expect(servers.find((s) => s.name === 'shared')?.enabled).toBe(true)
    expect(servers.find((s) => s.name === 'shared')?.source).toBe('/work/app/.mcp.json')
  })

  it('never leaks another project’s local servers', () => {
    const servers = collectServersFrom({
      claudeJson,
      settings: {},
      projectMcpJson: null,
      projectPath: PROJECT,
      claudeJsonPath: '/home/u/.claude.json',
      projectMcpJsonPath: '/work/app/.mcp.json',
      env: {},
    })
    expect(servers.some((s) => s.name === 'elsewhere')).toBe(false)
  })

  it('returns only user scope when no project is open', () => {
    const servers = collectServersFrom({
      claudeJson,
      settings: {},
      projectMcpJson: null,
      projectPath: null,
      claudeJsonPath: '/home/u/.claude.json',
      projectMcpJsonPath: null,
      env: {},
    })
    expect(servers.map((s) => s.name)).toEqual(['higgsfield'])
  })

  it('survives a config file that failed to parse', () => {
    expect(
      collectServersFrom({
        claudeJson: null,
        settings: null,
        projectMcpJson: null,
        projectPath: PROJECT,
        claudeJsonPath: '/home/u/.claude.json',
        projectMcpJsonPath: '/work/app/.mcp.json',
        env: {},
      }),
    ).toEqual([])
  })
})

/* ---------------------------------------------------------------- timeouts -- */

describe('withTimeout', () => {
  it('resolves when the work wins', async () => {
    await expect(withTimeout(Promise.resolve('done'), 1000, 'work')).resolves.toBe('done')
  })

  it('rejects with a labelled message when the clock wins', async () => {
    const never = new Promise<string>(() => undefined)
    await expect(withTimeout(never, 5, 'Connecting to fake')).rejects.toThrow(/Connecting to fake timed out after 5ms/)
  })

  it('does not leave an unhandled rejection when the work fails after the timeout', async () => {
    const unhandled = vi.fn()
    process.on('unhandledRejection', unhandled)
    const late = new Promise<string>((_r, reject) => setTimeout(() => reject(new Error('too late')), 20))

    await expect(withTimeout(late, 5, 'slow')).rejects.toThrow(/timed out/)
    await new Promise((resolve) => setTimeout(resolve, 40))
    process.off('unhandledRejection', unhandled)

    expect(unhandled).not.toHaveBeenCalled()
  })
})

/* ------------------------------------------------------------------- pool -- */

describe('McpPool.connect', () => {
  it('refuses a non-stdio server without building a transport', async () => {
    const createTransport = vi.fn()
    const pool = new McpPool({ createTransport, resolveEnv: async () => ({}) })
    const status = await pool.connect(
      stdioServer({ transport: 'http', command: null, url: 'https://x', unsupported: 'stdio only, sorry' }),
    )

    expect(status.state).toBe('failed')
    expect(status.error).toBe('stdio only, sorry')
    expect(createTransport).not.toHaveBeenCalled()
  })

  it('reports a server that cannot start, and holds no connection afterwards', async () => {
    const { pool } = poolWith(new FakeTransport({ startError: 'spawn npx ENOENT' }))
    const status = await pool.connect(stdioServer())

    expect(status.state).toBe('failed')
    expect(status.error).toContain('ENOENT')
    expect(pool.getStatus('user:fake')).toBeNull()
  })

  it('times out a server that starts and never speaks', async () => {
    const transport = new FakeTransport({ startHangs: true })
    const { pool } = poolWith(transport, { connectMs: 20 })

    const status = await pool.connect(stdioServer())
    expect(status.state).toBe('failed')
    expect(status.error).toMatch(/timed out after 20ms/)
    expect(pool.getStatus('user:fake')).toBeNull()
  })

  it('times out a server that starts but never answers initialize', async () => {
    const transport = new FakeTransport({ handlers: { initialize: () => 'hang' } })
    // `initialize` is intercepted before the fake's own reply, so the SDK's
    // request timeout is what fires here.
    const { pool } = poolWith(transport, { connectMs: 25 })

    const status = await pool.connect(stdioServer())
    expect(status.state).toBe('failed')
    expect(status.error).toBeTruthy()
  })

  it('records server info, capabilities and instructions on success', async () => {
    const { pool, seen } = poolWith(new FakeTransport({ capabilities: { tools: {}, resources: {} } }))
    const status = await pool.connect(stdioServer())

    expect(status.state).toBe('ready')
    expect(status.serverInfo).toEqual({ name: 'fake-server', version: '9.9.9' })
    expect(status.capabilities.sort()).toEqual(['resources', 'tools'])
    expect(status.instructions).toBe('Be careful.')
    expect(seen).toEqual(['connecting', 'ready'])
  })

  it('reuses a ready connection instead of spawning a second one', async () => {
    const transport = new FakeTransport()
    const createTransport = vi.fn(() => transport)
    const pool = new McpPool({ createTransport, resolveEnv: async () => ({}) })

    await pool.connect(stdioServer())
    await pool.connect(stdioServer())
    expect(createTransport).toHaveBeenCalledTimes(1)
  })

  it('surfaces a failure to build the environment as a failed status', async () => {
    const pool = new McpPool({
      createTransport: () => new FakeTransport(),
      resolveEnv: async () => {
        throw new Error('no login shell')
      },
    })
    const status = await pool.connect(stdioServer())
    expect(status.state).toBe('failed')
    expect(status.error).toBe('no login shell')
  })
})

describe('McpPool mid-session death', () => {
  it('marks the server closed and drops the handle so the next call reconnects', async () => {
    const first = new FakeTransport()
    const second = new FakeTransport()
    const transports = [first, second]
    const states: string[] = []
    const pool = new McpPool({
      createTransport: () => transports.shift() as Transport,
      resolveEnv: async () => ({}),
      onStatusChange: (status) => states.push(`${status.state}`),
    })

    await pool.connect(stdioServer())
    first.die()

    expect(states).toEqual(['connecting', 'ready', 'closed'])
    expect(pool.getStatus('user:fake')).toBeNull()

    const again = await pool.connect(stdioServer())
    expect(again.state).toBe('ready')
    expect(transports).toHaveLength(0)
  })

  it('does not report a crash for a close we asked for', async () => {
    const transport = new FakeTransport()
    const { pool, seen } = poolWith(transport)

    await pool.connect(stdioServer())
    await pool.disconnect('user:fake')

    expect(seen).toEqual(['connecting', 'ready', 'idle'])
    expect(transport.closed).toBe(true)
  })

  it('ignores a disconnect for a server it never connected', async () => {
    const { pool } = poolWith(new FakeTransport())
    await expect(pool.disconnect('user:ghost')).resolves.toBeNull()
  })
})

describe('McpPool.inventory', () => {
  const listHandlers = {
    'tools/list': () => ({ result: { tools: [TOOL] } }),
    'resources/list': () => ({ result: { resources: [{ uri: 'file:///a', name: 'a', mimeType: 'text/plain' }] } }),
    'resources/templates/list': () => ({ result: { resourceTemplates: [{ uriTemplate: 'file:///{p}', name: 't' }] } }),
    'prompts/list': () => ({
      result: { prompts: [{ name: 'review', arguments: [{ name: 'path', required: true }] }] },
    }),
  }

  it('collects tools, resources, templates and prompts', async () => {
    const { pool } = poolWith(
      new FakeTransport({ capabilities: { tools: {}, resources: {}, prompts: {} }, handlers: listHandlers }),
    )
    const inventory = await pool.inventory(stdioServer())

    expect(inventory.tools.map((t) => t.name)).toEqual(['echo'])
    expect(inventory.tools[0].inputSchema).toMatchObject({ type: 'object' })
    expect(inventory.resources[0].uri).toBe('file:///a')
    expect(inventory.resourceTemplates[0].uriTemplate).toBe('file:///{p}')
    expect(inventory.prompts[0].arguments).toEqual([{ name: 'path', description: null, required: true }])
    expect(inventory.errors).toEqual({})
  })

  it('skips sections the server never advertised, rather than reporting them as errors', async () => {
    const transport = new FakeTransport({ capabilities: { tools: {} }, handlers: listHandlers })
    const { pool } = poolWith(transport)

    const inventory = await pool.inventory(stdioServer())
    expect(inventory.tools).toHaveLength(1)
    expect(inventory.resources).toEqual([])
    expect(inventory.errors).toEqual({})
    expect(transport.seen).not.toContain('resources/list')
  })

  it('treats an unimplemented optional listing as empty, not as an error', async () => {
    // A real server that advertises `resources` but implements only
    // `resources/list` answers the templates call with -32601. Surfacing that
    // as an error painted a healthy server red.
    const { pool } = poolWith(
      new FakeTransport({
        capabilities: { tools: {}, resources: {} },
        handlers: {
          ...listHandlers,
          'resources/templates/list': () => ({ error: { code: -32601, message: 'Method not found' } }),
        },
      }),
    )

    const inventory = await pool.inventory(stdioServer())
    expect(inventory.resources).toHaveLength(1)
    expect(inventory.resourceTemplates).toEqual([])
    expect(inventory.errors).toEqual({})
  })

  it('keeps the tools when one section fails', async () => {
    const { pool } = poolWith(
      new FakeTransport({
        capabilities: { tools: {}, resources: {} },
        handlers: {
          ...listHandlers,
          'resources/list': () => ({ error: { code: -32603, message: 'index corrupt' } }),
        },
      }),
    )

    const inventory = await pool.inventory(stdioServer())
    expect(inventory.tools).toHaveLength(1)
    expect(inventory.errors.resources).toContain('index corrupt')
  })

  it('times out a section that hangs without losing the rest', async () => {
    const { pool } = poolWith(
      new FakeTransport({
        capabilities: { tools: {}, prompts: {} },
        handlers: { ...listHandlers, 'prompts/list': () => 'hang' },
      }),
      { listMs: 25 },
    )

    const inventory = await pool.inventory(stdioServer())
    expect(inventory.tools).toHaveLength(1)
    expect(inventory.errors.prompts).toBeTruthy()
  })

  it('follows pagination cursors', async () => {
    let page = 0
    const { pool } = poolWith(
      new FakeTransport({
        capabilities: { tools: {} },
        handlers: {
          'tools/list': () => {
            page += 1
            return page === 1
              ? { result: { tools: [TOOL], nextCursor: 'p2' } }
              : { result: { tools: [{ ...TOOL, name: 'second' }] } }
          },
        },
      }),
    )

    const inventory = await pool.inventory(stdioServer())
    expect(inventory.tools.map((t) => t.name)).toEqual(['echo', 'second'])
  })

  it('returns an empty inventory rather than throwing when the server will not start', async () => {
    const { pool } = poolWith(new FakeTransport({ startError: 'spawn ENOENT' }))
    const inventory = await pool.inventory(stdioServer())

    expect(inventory.status.state).toBe('failed')
    expect(inventory.tools).toEqual([])
  })
})

describe('McpPool.callTool', () => {
  it('returns the result on success', async () => {
    const { pool } = poolWith(
      new FakeTransport({
        capabilities: { tools: {} },
        handlers: { 'tools/call': (params) => ({ result: { content: [{ type: 'text', text: String(params?.arguments) }] } }) },
      }),
    )

    const result = await pool.callTool(stdioServer(), 'echo', { message: 'hi' })
    expect(result.ok).toBe(true)
    expect(result.error).toBeNull()
    expect(result.durationMs).toBeGreaterThanOrEqual(0)
  })

  it('reports a tool that never answers as a timeout instead of hanging', async () => {
    const { pool } = poolWith(
      new FakeTransport({ capabilities: { tools: {} }, handlers: { 'tools/call': () => 'hang' } }),
      { callMs: 25 },
    )

    const result = await pool.callTool(stdioServer(), 'echo', {})
    expect(result.ok).toBe(false)
    expect(result.error).toBeTruthy()
  })

  it('reports a server-side error without throwing across IPC', async () => {
    const { pool } = poolWith(
      new FakeTransport({
        capabilities: { tools: {} },
        handlers: { 'tools/call': () => ({ error: { code: -32602, message: 'missing message' } }) },
      }),
    )

    const result = await pool.callTool(stdioServer(), 'echo', {})
    expect(result.ok).toBe(false)
    expect(result.error).toContain('missing message')
  })

  it('refuses to call on a server that could not connect', async () => {
    const { pool } = poolWith(new FakeTransport({ startError: 'spawn ENOENT' }))
    const result = await pool.callTool(stdioServer(), 'echo', {})

    expect(result.ok).toBe(false)
    expect(result.error).toContain('ENOENT')
  })
})

/* ------------------------------------------------- regressions: the pool -- */

describe('resolveTimeouts', () => {
  it('ignores an explicitly undefined override instead of timing out instantly', () => {
    // `{ connectMs: undefined }` is what an options object built from optional
    // fields produces. A plain spread let it through, and
    // `setTimeout(fn, undefined)` fires on the next tick — every connection
    // failed as "timed out after undefined ms".
    expect(resolveTimeouts({ connectMs: undefined }).connectMs).toBe(20_000)
  })

  it('refuses a non-positive or non-finite duration', () => {
    expect(resolveTimeouts({ listMs: 0 }).listMs).toBe(15_000)
    expect(resolveTimeouts({ listMs: -5 }).listMs).toBe(15_000)
    expect(resolveTimeouts({ callMs: Number.NaN }).callMs).toBe(60_000)
  })

  it('takes a real override', () => {
    expect(resolveTimeouts({ closeMs: 40 })).toEqual({
      connectMs: 20_000,
      listMs: 15_000,
      callMs: 60_000,
      closeMs: 40,
    })
  })
})

describe('McpPool concurrent connects', () => {
  it('shares one handshake between overlapping callers instead of racing', async () => {
    // The bug: the second caller saw state `connecting`, tore the first
    // connection down and started its own — then the first one's failure
    // handler deleted the *second* one's entry from the pool, orphaning a live
    // child process and making `inventory()` report "Not connected" for a
    // server that was in fact ready. Two clicks on Refresh reached it.
    const transports: FakeTransport[] = []
    const pool = new McpPool({
      createTransport: () => {
        const transport = new FakeTransport({ capabilities: { tools: {} } })
        transports.push(transport)
        return transport
      },
      resolveEnv: async () => ({}),
    })

    const [a, b, c] = await Promise.all([
      pool.connect(stdioServer()),
      pool.connect(stdioServer()),
      pool.connect(stdioServer()),
    ])

    expect(transports).toHaveLength(1)
    expect([a.state, b.state, c.state]).toEqual(['ready', 'ready', 'ready'])
    expect(pool.getStatus('user:fake')?.state).toBe('ready')
    expect(transports[0].closed).toBe(false)
  })

  it('spawns one process for two overlapping listings, and both see the tools', async () => {
    // Double-clicking Refresh. Each transport handed out is a real child
    // process in production, so a second one here is a leaked server.
    const built: FakeTransport[] = []
    const pool = new McpPool({
      createTransport: () => {
        const transport = new FakeTransport({
          capabilities: { tools: {} },
          handlers: { 'tools/list': () => ({ result: { tools: [TOOL] } }) },
        })
        built.push(transport)
        return transport
      },
      resolveEnv: async () => ({}),
    })

    const [first, second] = await Promise.all([pool.inventory(stdioServer()), pool.inventory(stdioServer())])

    expect(built).toHaveLength(1)
    expect(first.tools).toHaveLength(1)
    expect(second.tools).toHaveLength(1)
    expect(first.errors).toEqual({})
    expect(second.errors).toEqual({})
    expect(pool.getStatus('user:fake')?.state).toBe('ready')
  })

  it('lets a failed connect be retried without the first failure poisoning the second', async () => {
    const transports = [new FakeTransport({ startError: 'spawn ENOENT' }), new FakeTransport()]
    const pool = new McpPool({
      createTransport: () => transports.shift() as Transport,
      resolveEnv: async () => ({}),
    })

    expect((await pool.connect(stdioServer())).state).toBe('failed')
    expect((await pool.connect(stdioServer())).state).toBe('ready')
    expect(pool.getStatus('user:fake')?.state).toBe('ready')
  })
})

describe('McpPool.disconnectAll', () => {
  it('closes a server that was still starting when quit began', async () => {
    // Before `live` holds the entry there is an `await` on the environment.
    // Closing only what `live` holds let that server finish spawning after
    // quit, leaving the child process behind with nothing to reap it.
    const transport = new FakeTransport()
    let releaseEnv: () => void = () => undefined
    const pool = new McpPool({
      createTransport: () => transport,
      resolveEnv: () => new Promise<Record<string, string>>((resolve) => {
        releaseEnv = () => resolve({})
      }),
      timeouts: { closeMs: 50 },
    })

    const connecting = pool.connect(stdioServer())
    const quitting = pool.disconnectAll()
    releaseEnv()

    await connecting
    await quitting

    expect(transport.closed).toBe(true)
    expect(pool.getStatus('user:fake')).toBeNull()
  })

  it('does nothing when it holds no connections', async () => {
    const { pool } = poolWith(new FakeTransport())
    await expect(pool.disconnectAll()).resolves.toBeUndefined()
  })
})

describe('McpPool.inventory when the server dies mid-listing', () => {
  it('reports the death in the inventory rather than rejecting into IPC', async () => {
    const transport = new FakeTransport({ capabilities: { tools: {} } })
    const { pool } = poolWith(transport)
    await pool.connect(stdioServer())

    // Kill it in the window `inventory()` actually has: it suspends on
    // `await this.connect(...)`, which resolves to the *ready status object it
    // captured*, and the process can die on that microtask boundary. The old
    // code then called `require()`, which throws — straight out of the
    // `mcp:inventory` IPC handler, where the panel could only show it as a bare
    // rejection.
    const listing = pool.inventory(stdioServer())
    transport.die()
    const inventory = await listing

    expect(inventory.tools).toEqual([])
    expect(inventory.errors.server).toMatch(/exited/)
    expect(inventory.status.state).not.toBe('ready')
  })
})

describe('paginate', () => {
  it('stops when a server repeats its cursor instead of walking the page cap', async () => {
    // A server that echoes the cursor it was given used to be walked 50 times,
    // duplicating its whole listing on every lap.
    let calls = 0
    const { pool } = poolWith(
      new FakeTransport({
        capabilities: { tools: {} },
        handlers: {
          'tools/list': () => {
            calls += 1
            return { result: { tools: [TOOL], nextCursor: 'always-the-same' } }
          },
        },
      }),
      { listMs: 2_000 },
    )

    const inventory = await pool.inventory(stdioServer())
    expect(calls).toBe(2)
    expect(inventory.tools).toHaveLength(2)
  })
})

/* -------------------------------------------------------------------- ipc -- */

interface FakeIpc {
  handlers: Map<string, (event: unknown, ...args: unknown[]) => unknown>
  handle(channel: string, fn: (event: unknown, ...args: unknown[]) => unknown): void
}

function fakeIpcMain(): FakeIpc {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  return {
    handlers,
    handle(channel, fn) {
      // Electron itself throws on a duplicate channel; mirror that so the test
      // fails the same way the app would.
      if (handlers.has(channel)) throw new Error(`Attempted to register a second handler for '${channel}'`)
      handlers.set(channel, fn)
    },
  }
}

const fakeSender = { isDestroyed: () => false, once: () => undefined, send: () => undefined }

describe('registerMcpIpc', () => {
  beforeEach(() => {
    resetMcpIpcForTests()
  })
  afterEach(() => {
    resetMcpIpcForTests()
  })

  it('claims every documented channel', () => {
    const ipc = fakeIpcMain()
    registerMcpIpc(ipc as unknown as Electron.IpcMain)

    expect([...ipc.handlers.keys()].sort()).toEqual([
      'mcp:add',
      'mcp:call',
      'mcp:connect',
      'mcp:disconnect',
      'mcp:get-prompt',
      'mcp:inventory',
      'mcp:list',
      'mcp:read-resource',
    ])
  })

  it('is safe to call twice rather than taking the app down on a duplicate channel', () => {
    const ipc = fakeIpcMain()
    registerMcpIpc(ipc as unknown as Electron.IpcMain)
    expect(() => registerMcpIpc(ipc as unknown as Electron.IpcMain)).not.toThrow()
    expect(ipc.handlers.size).toBe(8)
  })

  it('refuses a relative project path instead of resolving it against the app cwd', () => {
    const ipc = fakeIpcMain()
    registerMcpIpc(ipc as unknown as Electron.IpcMain)
    const list = ipc.handlers.get('mcp:list')

    expect(() => list?.({ sender: fakeSender }, '../../etc')).toThrow(/absolute/)
  })

  it('will not dial a server the renderer named but the config does not contain', async () => {
    // The security story for the whole feature: the renderer names an id, never
    // a command, and the command is read back from the user's own config.
    const ipc = fakeIpcMain()
    registerMcpIpc(ipc as unknown as Electron.IpcMain)
    const connect = ipc.handlers.get('mcp:connect')

    await expect(async () => connect?.({}, 'user:definitely-not-configured')).rejects.toThrow(/no configured server/)
    await expect(async () => connect?.({}, { command: '/bin/sh' })).rejects.toThrow(/server id is required/)
  })

  it('rejects malformed tool and prompt arguments before they reach a server', async () => {
    const ipc = fakeIpcMain()
    registerMcpIpc(ipc as unknown as Electron.IpcMain)

    await expect(async () => ipc.handlers.get('mcp:call')?.({}, 'user:x', '')).rejects.toThrow(/tool name is required/)
    await expect(async () => ipc.handlers.get('mcp:read-resource')?.({}, 'user:x', 42)).rejects.toThrow(
      /resource uri is required/,
    )
    await expect(async () => ipc.handlers.get('mcp:get-prompt')?.({}, 'user:x', '')).rejects.toThrow(
      /prompt name is required/,
    )
  })
})

describe('capPayload', () => {
  it('passes an ordinary result straight through', () => {
    const value = { content: [{ type: 'text', text: 'small' }] }
    expect(capPayload(value)).toEqual({ value, truncated: false })
  })

  it('replaces an enormous result with a preview', () => {
    const huge = { content: [{ type: 'text', text: 'x'.repeat(600_000) }] }
    const capped = capPayload(huge)

    expect(capped.truncated).toBe(true)
    expect(JSON.stringify(capped.value).length).toBeLessThan(600_000)
  })

  it('does not throw on a circular result', () => {
    const circular: Record<string, unknown> = {}
    circular.self = circular
    expect(capPayload(circular).truncated).toBe(true)
  })
})
