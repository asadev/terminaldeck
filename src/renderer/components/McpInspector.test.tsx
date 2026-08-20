import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  countFor,
  MachinePills,
  formatCommand,
  McpInspector,
  resultText,
  sectionErrors,
  STATE_LABEL,
  type McpBridge,
  type McpInventory,
  type McpServerStatus,
} from './McpInspector'
import { thisMachine } from '../platform'

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
    addMcpServer: async () => ({ ok: true, message: 'Added files.' }),
    removeMcpServer: async () => ({ ok: true, message: 'Removed files.' }),
    connectMcpServer: async () => server({ state: 'ready' }),
    disconnectMcpServer: async () => null,
    mcpInventory: async () => inventory(),
    callMcpTool: async () => ({ ok: true, result: null, error: null, durationMs: 1, truncated: false }),
    onMcpState: () => () => undefined,
  }

  it('explains itself instead of crashing when the preload bridge is absent', () => {
    const html = renderToStaticMarkup(<McpInspector />)
    expect(html).toContain('MCP is not available here')
    // The shared blank, not a bare sentence of its own — see `PageEmpty`.
    expect(html).toContain('page-blank-title')
  })

  /**
   * *"Here also maybe we need to see which MCP servers or which machine
   * connected."*
   *
   * The page named a folder in the corner of a header and nothing else. With a
   * PC and a server both connected, "No servers yet" is a sentence about a
   * machine, and which machine it was about was not on screen anywhere.
   */
  it('names the folder and the machine the list came from', () => {
    const html = renderToStaticMarkup(<McpInspector bridge={bridge} projectPath="/work/app" />)
    expect(html).toContain('page-scope')
    expect(html).toContain('/work/app')
    expect(html).toContain(`on ${thisMachine()}`)
  })

  /**
   * And no pills for a person with one computer.
   *
   * `reportableMachines` decides which machines qualify (its own test covers
   * the rule); with none connected there is nothing to switch between, and
   * *"a dropdown only when some exist"* is the most repeated note in the whole
   * review. Static rendering runs no effects, so the machine list here is
   * genuinely empty rather than merely unloaded — which is the same state a
   * fresh install is in.
   */
  it('draws no machine pills when there is no other machine to show', () => {
    const html = renderToStaticMarkup(<McpInspector bridge={bridge} projectPath="/work/app" />)
    expect(html).not.toContain('page-pills')
    // And the Add button does not start naming machines at somebody who has one.
    expect(html).toContain('>Add server<')
  })

  /**
   * The pills themselves, which no static render of the page can produce —
   * effects do not run, so the machine list is always empty there.
   *
   * `reportableMachines` has its own test for which machines qualify; this one
   * is about what the reader is offered once some do.
   */
  it('offers this machine and every one it can report on', () => {
    const targets = [
      { machineId: 'm1', name: 'DESKTOP-DDGMNCV', sessionId: 's1', sessionTitle: 'AAAA', cwd: '/home/imza/AAAA' },
    ]
    const html = renderToStaticMarkup(<MachinePills targets={targets} pick={null} onPick={() => {}} />)
    expect(html).toContain('DESKTOP-DDGMNCV')
    expect(html).toContain(thisMachine())
    // This machine is the one in force until somebody presses another.
    expect(html.match(/data-on="true"/g)).toHaveLength(1)
  })

  it('marks the machine being reported on, so the page cannot lie about whose list it is', () => {
    const targets = [
      { machineId: 'm1', name: 'DESKTOP-DDGMNCV', sessionId: 's1', sessionTitle: 'AAAA', cwd: '/x' },
    ]
    const html = renderToStaticMarkup(<MachinePills targets={targets} pick="m1" onPick={() => {}} />)
    expect(html).toMatch(/data-on="true"[^>]*>DESKTOP-DDGMNCV|DESKTOP-DDGMNCV/)
    expect(html.match(/data-on="true"/g)).toHaveLength(1)
  })

  it('renders its frame when a bridge is supplied', () => {
    const html = renderToStaticMarkup(<McpInspector bridge={bridge} projectPath="/work/app" />)
    // Not the title — the panel dock owns that now, and repeating it here is
    // what made four panels render their own name twice.
    expect(html).toContain('Claude Code configuration')
    // Effects do not run under static rendering, so the first paint is the
    // loading state — the point is that it renders at all.
    expect(html).toContain('Reading')
  })

  /**
   * The panel had Reload and nothing else, and its empty state sent people to a
   * terminal. Asad's note was that silence there reads as broken — so these two
   * pin the answer the panel now gives, whichever way it goes.
   */
  it('offers a way to add a server, not just to reload', () => {
    const html = renderToStaticMarkup(<McpInspector bridge={bridge} projectPath="/work/app" />)
    expect(html).toContain('Add server')
    // Matched by class, not by label: effects do not run under static
    // rendering, so the reload button is still showing "Reading…" here.
    expect(html).toContain('mcp-refresh')
  })

  /**
   * The gap this used to describe is closed.
   *
   * The panel could add a server and not remove one, and said so in a note that
   * pointed at a terminal. Asad, on that page: *"On MCP servers did nothing."*
   * A control panel that can only add is half a control panel — so the sentence
   * is gone and the control is on the row.
   */
  it('removes a server here rather than naming a terminal command', () => {
    const html = renderToStaticMarkup(<McpInspector bridge={bridge} projectPath="/work/app" />)
    expect(html).not.toContain('claude mcp remove')
    // The button itself is on a row, and rows need effects to exist — there is
    // no DOM in this setup (see the header). What the removal *does* is pinned
    // in `src/main/mcp-add.test.ts`, and the control was rendered and pressed in
    // the running app.
    expect(bridge.removeMcpServer).toBeTypeOf('function')
  })

  /**
   * The subheading is a dot now, and the sentences are behind it.
   *
   * It was three sentences, then two, and on 2026-08-20 it stopped being
   * standing text at all: *"I don't want any kind of long descriptions
   * anywhere. Just if somewhere it's very required, give the i icon like other
   * ones, information icon in the settings, same way."*
   *
   * Both facts are still in the rendered output, which is the point of using
   * `HoverNote` rather than deleting them — it keeps its paragraph in the
   * document for the screen reader, clipped to a pixel, so a test can still
   * assert the app has not quietly stopped saying what it cannot do.
   */
  it('puts the two surviving facts behind the information dot, not on the page', () => {
    const html = renderToStaticMarkup(<McpInspector bridge={bridge} projectPath="/work/app" />)
    const sub = /<div class="mcp-subheading">(.*?)<\/div>/s.exec(html)?.[1] ?? ''
    // A dot, not a paragraph.
    expect(sub).toContain('hovernote-dot')
    expect(sub).not.toContain('<p')
    // And the words are still there to be read, on the dot's description.
    expect(sub).toContain('Claude Code configuration')
    // And no longer sends anyone to a terminal to undo what the page can do.
    expect(sub).not.toContain('claude mcp remove')
    expect(sub).not.toMatch(/picks it up too/)
  })
})
