import { describe, expect, it, vi } from 'vitest'
import type { McpServerStatus } from '../mcp-client'
import { fakeContext, tool } from './agents-area.fixture'
import { mcpServerTools, redactEnvValues, serverView, type McpServerToolDeps } from './mcp-server-tools'

function status(overrides: Partial<McpServerStatus> = {}): McpServerStatus {
  return {
    id: 'user:github',
    name: 'github',
    scope: 'user',
    transport: 'stdio',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-github'],
    env: { GITHUB_PERSONAL_ACCESS_TOKEN: 'ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    cwd: null,
    url: null,
    source: '/Users/someone/.claude.json',
    enabled: true,
    disabledReason: null,
    unsupported: null,
    state: 'idle',
    error: null,
    serverInfo: null,
    capabilities: [],
    instructions: null,
    pid: null,
    connectedAt: null,
    stderr: '',
    ...overrides,
  }
}

const OK = { ok: true, message: 'Added github.' }

function deps(overrides: Partial<McpServerToolDeps> = {}): McpServerToolDeps {
  return {
    list: () => [status()],
    add: async () => OK,
    edit: async () => OK,
    remove: async () => OK,
    inventory: async () => ({
      serverId: 'user:github',
      tools: [{ name: 'search', title: null, description: null, inputSchema: {}, outputSchema: null }],
      resources: [],
      resourceTemplates: [],
      prompts: [],
      errors: {},
      status: status({ state: 'ready' }),
    }),
    disconnect: async () => null,
    call: async () => ({ ok: true, result: { content: [] }, error: null, durationMs: 4, truncated: false }),
    store: async () => ({ rows: [], runtimes: [], writer: { found: true, path: '/bin/claude' }, environmentSource: 'login-shell', projectPath: '' } as never),
    install: async () => OK,
    toolFile: (name) => (name === 'github' ? { name, fileName: 'github.mcp.json', text: '{"name":"github"}' } : null),
    ...overrides,
  }
}

describe('what a configured server looks like from outside', () => {
  it('names its environment variables and never hands back their values', () => {
    const view = serverView(status())
    const text = JSON.stringify(view)
    expect(view.envKeys).toEqual(['GITHUB_PERSONAL_ACCESS_TOKEN'])
    expect(text).not.toContain('ghp_')
    expect(view).not.toHaveProperty('env')
  })

  it('redacts a token pasted into the arguments or the URL, and keeps the path readable', () => {
    const view = serverView(
      status({
        args: ['--api-key', 'sk-ant-api03-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'],
        url: 'https://user:hunter2hunter2@mcp.example.com/sse',
      }),
    )
    const text = JSON.stringify(view)
    expect(text).not.toContain('sk-ant-api03')
    expect(text).not.toContain('hunter2hunter2')
    expect(text).toContain('/Users/someone/.claude.json')
  })

  it('lists project servers only for an open folder', async () => {
    const list = vi.fn<McpServerToolDeps['list']>(() => [])
    const { context } = fakeContext()
    const spec = tool(mcpServerTools(deps({ list })), 'mcp.list')
    await spec.run({ projectPath: '/work/api' }, context)
    expect(list).toHaveBeenCalledWith('/work/api')
    // A folder that is not open is a way to make this app read some other
    // repository's .mcp.json — and to connect to what it names.
    await expect(spec.run({ projectPath: '/tmp/elsewhere' }, context)).rejects.toThrow(/not a folder this app has open/)
  })
})

describe('adding, changing, removing', () => {
  it('turns env into KEY=value lines for the CLI, and keeps the values out of the log', async () => {
    const add = vi.fn<McpServerToolDeps['add']>(async () => OK)
    const { context } = fakeContext()
    const spec = tool(mcpServerTools(deps({ add })), 'mcp.add')
    const args = { name: 'github', scope: 'user', transport: 'stdio', command: 'npx -y srv', env: { TOKEN: 'ghp_secret' } }
    await spec.run(args, context)
    expect(add).toHaveBeenCalledWith(expect.objectContaining({ name: 'github', extras: ['TOKEN=ghp_secret'] }))
    expect(JSON.stringify(spec.redactArgs?.(args))).not.toContain('ghp_secret')
    expect(spec.redactArgs?.(args)).toMatchObject({ env: { TOKEN: '[redacted]' } })
    // The dialog names what it is given and not what it is.
    expect(spec.summary(args, context)).toContain('given TOKEN')
    expect(spec.summary(args, context)).not.toContain('ghp_secret')
  })

  it('refuses a malformed server before anybody is asked, in the form’s own words', () => {
    const { context } = fakeContext()
    const spec = tool(mcpServerTools(deps()), 'mcp.add')
    expect(() => spec.precheck?.({ name: '--scope', scope: 'user', transport: 'stdio', command: 'x' }, context)).toThrow(
      /must start with a letter or number/,
    )
    expect(() => spec.precheck?.({ name: 'a', scope: 'project', transport: 'stdio', command: 'x' }, context)).toThrow(
      /Open a project first/,
    )
  })

  it('reports a write the CLI refused as a refusal with its sentence', async () => {
    const { context } = fakeContext()
    const spec = tool(mcpServerTools(deps({ add: async () => ({ ok: false, message: 'claude is not installed' }) })), 'mcp.add')
    await expect(spec.run({ name: 'a', scope: 'user', transport: 'stdio', command: 'x' }, context)).rejects.toThrow(
      /claude is not installed/,
    )
  })

  it('edits by sending the whole new definition, a blank value meaning keep the saved one', async () => {
    const edit = vi.fn<McpServerToolDeps['edit']>(async () => OK)
    const { context } = fakeContext()
    const args = { name: 'github', scope: 'user', next: { transport: 'stdio', command: 'npx srv@2', env: { TOKEN: '' } } }
    await tool(mcpServerTools(deps({ edit })), 'mcp.edit').run(args, context)
    expect(edit).toHaveBeenCalledWith({
      name: 'github',
      scope: 'user',
      projectPath: null,
      next: expect.objectContaining({ name: 'github', scope: 'user', command: 'npx srv@2', extras: ['TOKEN='] }),
    })
  })

  it('removes from exactly the scope named', async () => {
    const remove = vi.fn<McpServerToolDeps['remove']>(async () => OK)
    const { context } = fakeContext()
    await tool(mcpServerTools(deps({ remove })), 'mcp.remove').run({ name: 'github', scope: 'local', projectPath: '/work/api' }, context)
    expect(remove).toHaveBeenCalledWith({ name: 'github', scope: 'local', projectPath: '/work/api' })
  })
})

describe('using a server', () => {
  it('connects and lists what it offers, with the status as safe as the listing', async () => {
    const { context } = fakeContext()
    const out = await tool(mcpServerTools(deps()), 'mcp.connect').run({ serverId: 'user:github' }, context)
    const value = out.value as { tools: unknown[]; status: Record<string, unknown> }
    expect(value.tools).toHaveLength(1)
    expect(JSON.stringify(value)).not.toContain('ghp_')
  })

  it('confirms every call to another server’s tool, naming the arguments it is given', () => {
    const { context } = fakeContext()
    const spec = tool(mcpServerTools(deps()), 'mcp.call')
    expect(spec.tier).toBe('alter')
    expect(spec.summary({ serverId: 'user:github', tool: 'create_issue', arguments: { repo: 'x', title: 'y' } }, context)).toBe(
      'Call create_issue on the MCP server user:github with repo, title',
    )
  })
})

describe('the store and sharing', () => {
  it('keeps install values out of the log', () => {
    const spec = tool(mcpServerTools(deps()), 'mcp.install')
    expect(spec.redactArgs?.({ id: 'github', values: { TOKEN: 'ghp_x' } })).toEqual({ id: 'github', values: { TOKEN: '[redacted]' } })
  })

  it('exports a definition and refuses one that is not configured', async () => {
    const { context } = fakeContext()
    const spec = tool(mcpServerTools(deps()), 'mcp.export')
    await expect(spec.run({ name: 'github', scope: 'user' }, context)).resolves.toMatchObject({ value: { fileName: 'github.mcp.json' } })
    await expect(spec.run({ name: 'nope', scope: 'user' }, context)).rejects.toThrow(/not in the configuration/)
  })

  it('reads a shared file into a draft and writes nothing', async () => {
    const { context } = fakeContext()
    const spec = tool(mcpServerTools(deps()), 'mcp.import')
    await expect(spec.run({ text: 'not json' }, context)).rejects.toThrow(/not a server definition/)
  })

  it('redacts nested definitions too', () => {
    expect(redactEnvValues({ next: { headers: { Authorization: 'Bearer x' } } })).toEqual({
      next: { headers: { Authorization: '[redacted]' } },
    })
  })
})
