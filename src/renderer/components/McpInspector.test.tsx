import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  countFor,
  formatCommand,
  McpInspector,
  resultText,
  sectionErrors,
  STATE_LABEL,
  type McpBridge,
  type McpInventory,
  type McpServerStatus,
} from './McpInspector'

/**
 * No DOM environment in this project's test setup, so rendering goes through
 * static markup and the interactive paths are covered by testing the pure
 * functions the panel is built from. That still catches what matters: a status
 * shape the panel cannot render, and a section error it silently swallows.
 */

function server(overrides: Partial<McpServerStatus> = {}): McpServerStatus {
  return {
    id: 'user:files',
    name: 'files',
    scope: 'user',
    transport: 'stdio',
    command: 'npx',
    args: ['-y', 'server-filesystem', '/tmp'],
    url: null,
    source: '/home/u/.claude.json',
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

function inventory(overrides: Partial<McpInventory> = {}): McpInventory {
  return {
    serverId: 'user:files',
    tools: [],
    resources: [],
    resourceTemplates: [],
    prompts: [],
    errors: {},
    status: server(),
    ...overrides,
  }
}

describe('formatCommand', () => {
  it('joins the command and its arguments for a stdio server', () => {
    expect(formatCommand(server())).toBe('npx -y server-filesystem /tmp')
  })

  it('shows the url for a server this inspector cannot dial', () => {
    expect(formatCommand(server({ transport: 'http', command: null, args: [], url: 'https://x/mcp' }))).toBe(
      'https://x/mcp',
    )
    expect(formatCommand(server({ transport: 'sse', command: null, args: [], url: null }))).toBe('')
  })

  it('does not throw when the status arrives without an args array', () => {
    // This renders a status pushed over IPC. A main process one version behind
    // sends a shape the renderer's types only promise, and spreading
    // `undefined` threw — blanking the whole panel over a cosmetic line.
    const stale = { ...server(), args: undefined } as unknown as McpServerStatus
    expect(() => formatCommand(stale)).not.toThrow()
    expect(formatCommand(stale)).toBe('npx')
  })
})

describe('resultText', () => {
  it('pulls the text blocks out of a tool result', () => {
    expect(resultText({ content: [{ type: 'text', text: 'one' }, { type: 'text', text: 'two' }] })).toBe('one\ntwo')
  })

  it('ignores blocks that are not text, and results that are not shaped like one', () => {
    expect(resultText({ content: [{ type: 'image', data: 'abc' }] })).toBeNull()
    expect(resultText({ content: 'not an array' })).toBeNull()
    expect(resultText(null)).toBeNull()
    expect(resultText('a string')).toBeNull()
    expect(resultText({})).toBeNull()
  })

  it('skips a malformed block rather than dropping the whole result', () => {
    expect(resultText({ content: [null, { type: 'text', text: 'kept' }, { type: 'text' }] })).toBe('kept')
  })
})

describe('countFor', () => {
  it('adds templates into the resources tab, which shows both', () => {
    const data = inventory({
      tools: [{ name: 't', title: null, description: null, inputSchema: null, outputSchema: null }],
      resources: [{ uri: 'file:///a', name: 'a', title: null, description: null, mimeType: null }],
      resourceTemplates: [{ uriTemplate: 'file:///{p}', name: 't', title: null, description: null, mimeType: null }],
    })
    expect(countFor(data, 'tools')).toBe(1)
    expect(countFor(data, 'resources')).toBe(2)
    expect(countFor(data, 'prompts')).toBe(0)
  })
})

describe('sectionErrors', () => {
  it('shows a failed template listing on the resources tab', () => {
    // Regression: the panel looked up exactly one key by the tab's own name, so
    // `resourceTemplates` was written into `errors` and then never read. The
    // section failed completely silently.
    expect(sectionErrors({ resourceTemplates: 'templates blew up' }, 'resources')).toEqual(['templates blew up'])
    expect(sectionErrors({ resources: 'index corrupt' }, 'resources')).toEqual(['index corrupt'])
  })

  it('shows a whole-server failure on every tab, since it belongs to none', () => {
    const errors = { server: 'The server exited before it could be listed.' }
    for (const section of ['tools', 'resources', 'prompts'] as const) {
      expect(sectionErrors(errors, section)).toEqual([errors.server])
    }
  })

  it('keeps one tab’s failure off another tab', () => {
    expect(sectionErrors({ prompts: 'no prompts for you' }, 'tools')).toEqual([])
    expect(sectionErrors({ tools: 'tools blew up' }, 'prompts')).toEqual([])
  })

  it('reports nothing for a healthy listing, and never repeats a message', () => {
    expect(sectionErrors({}, 'tools')).toEqual([])
    expect(sectionErrors({ resources: 'same', resourceTemplates: 'same' }, 'resources')).toEqual(['same'])
  })
})

describe('STATE_LABEL', () => {
  it('names every connection state the main process can report', () => {
    expect(Object.keys(STATE_LABEL).sort()).toEqual(['closed', 'connecting', 'failed', 'idle', 'ready'])
    expect(Object.values(STATE_LABEL).every((label) => label.length > 0)).toBe(true)
  })
})

describe('<McpInspector>', () => {
  const bridge: McpBridge = {
    listMcpServers: async () => [server()],
    connectMcpServer: async () => server({ state: 'ready' }),
    disconnectMcpServer: async () => null,
    mcpInventory: async () => inventory(),
    callMcpTool: async () => ({ ok: true, result: null, error: null, durationMs: 1, truncated: false }),
    onMcpState: () => () => undefined,
  }

  it('explains itself instead of crashing when the preload bridge is absent', () => {
    const html = renderToStaticMarkup(<McpInspector />)
    expect(html).toContain('MCP is not wired into this build yet')
  })

  it('renders its frame when a bridge is supplied', () => {
    const html = renderToStaticMarkup(<McpInspector bridge={bridge} projectPath="/work/app" />)
    expect(html).toContain('MCP servers')
    // Effects do not run under static rendering, so the first paint is the
    // loading state — the point is that it renders at all.
    expect(html).toContain('Reading')
  })
})
